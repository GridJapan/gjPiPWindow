import AppKit
import ScreenCaptureKit

/// A panel showing one captured display.
///
/// Utility-styled to keep the titlebar out of the way. The content aspect ratio is locked to
/// the source display's, which keeps the picture unletterboxed and makes view→display
/// coordinate mapping exact.
///
/// This was once a non-activating panel that could become neither key nor main, so that
/// clicking it never stole focus. The cost only became visible once it stopped floating: an
/// app with no focusable window cannot be activated at all — `NSRunningApplication.activate()`
/// returned true while `isActive` stayed false — and macOS raises a normal-level window only
/// by activating its app. The PiP was therefore a window that could never be brought forward.
/// Picking it in Mission Control raised it for an instant, then macOS restored the previously
/// active app and its windows buried it again.
final class PiPPanel: NSPanel {
    init(contentRect: NSRect, aspect: NSSize, alwaysOnTop: Bool) {
        super.init(contentRect: contentRect,
                   styleMask: [.titled, .closable, .resizable, .utilityWindow],
                   backing: .buffered,
                   defer: false)
        hidesOnDeactivate = false
        setAlwaysOnTop(alwaysOnTop)
        titlebarAppearsTransparent = true
        contentAspectRatio = aspect
        isMovableByWindowBackground = false
        backgroundColor = .black

        // NSPanel's initializer does not honour contentRect's origin — it moves
        // the window horizontally on its own. Put it where it was asked to go.
        setContentSize(contentRect.size)
        setFrameOrigin(frameRect(forContentRect: contentRect).origin)
        Debug.log("panel placed at \(frame) on \(screen?.localizedName ?? "nil")")
    }

    /// Floating above everything and appearing in Mission Control are mutually exclusive:
    /// Mission Control only lays out `.managed` windows at the normal level, and a window
    /// that joins all spaces has no single space to be filed under — it is sticky, like the
    /// menu bar. So the two modes swap the whole set together rather than just the level.
    func setAlwaysOnTop(_ on: Bool) {
        isFloatingPanel = on
        level = on ? .floating : .normal
        collectionBehavior = on
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.managed, .fullScreenAuxiliary]
    }

    /// Focusable like any other window, which is what makes the app activatable and the
    /// window raisable. `NSPanel` refuses main by default, so both have to be granted.
    ///
    /// Taking key status is the deliberate reversal of an earlier rule that the PiP must never
    /// hold keyboard focus. That rule bought two things, and neither is lost here: Esc no
    /// longer closes the panel because `cancelOperation` is overridden below, and the panic
    /// exit reads Esc from a global event tap rather than from this window. What it costs is
    /// that keys pressed while the PiP itself is focused now land on gjPiP, which has nothing
    /// to do with them — click into the display being shown and its own app takes focus.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// `NSPanel` reads Esc as "cancel" and closes itself. That once killed the Esc-mashing
    /// panic exit on its very first press, and left the event tap holding the mouse with the
    /// window gone.
    override func cancelOperation(_ sender: Any?) {}
}

/// Displays capture frames and turns a click into an interaction-mode entry at
/// the matching point on the source display.
final class PiPContentView: NSView {

    var onActivateInteraction: ((CGPoint) -> Void)?

    private static let badgeVisibleSeconds: Double = 5
    private let badge = NSTextField(labelWithString: "端まで動かすと解除 ／ Esc 5回連打で強制解除")
    private var badgeHide: Task<Void, Never>?

    /// Hosts the capture. A sublayer of its own rather than the view's backing
    /// layer, because the video filters go on this layer and AppKit considers
    /// the backing layer its property.
    private let content = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Off by default, and with it off AppKit silently drops every CIFilter
        // set on a sublayer — indistinguishable from the filters being broken.
        layerUsesCoreImageFilters = true
        layer?.backgroundColor = NSColor.black.cgColor
        content.contentsGravity = .resize
        content.minificationFilter = .trilinear
        layer?.addSublayer(content)

        badge.font = .systemFont(ofSize: 11, weight: .medium)
        badge.textColor = .white
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        badge.layer?.cornerRadius = 4
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            badge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func show(surface: IOSurfaceRef) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.contents = surface
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.frame = bounds
        CATransaction.commit()
    }

    /// Swaps the whole chain at once; the layer re-renders the current frame
    /// with it, so this works the same on a paused picture as on a live one.
    func apply(filters: [VideoFilter]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.filters = filters.compactMap { $0.make() }
        CATransaction.commit()
    }

    /// The hint has done its job once it has been read, and it sits on top of the very picture
    /// it is explaining, so it gets out of the way on its own. Interaction mode itself carries
    /// on — the title bar's ● is the part that has to stay.
    func setInteractionActive(_ active: Bool) {
        badgeHide?.cancel()
        badge.isHidden = !active
        guard active else { return }
        badgeHide = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.badgeVisibleSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.badge.isHidden = true
        }
    }

    /// Let AppKit spend the first click on focusing the window, the way every other window
    /// behaves. Handing the mouse to another display is too big a thing to happen to someone
    /// who was only clicking to bring the PiP forward; it takes a second, deliberate click on
    /// an already-focused window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard bounds.contains(local), bounds.width > 0, bounds.height > 0 else { return }
        // View coords are bottom-left origin; display coords are top-left.
        let u = local.x / bounds.width
        let v = 1 - (local.y / bounds.height)
        onActivateInteraction?(CGPoint(x: u, y: v))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

@MainActor
final class PiPWindowController: NSObject, NSWindowDelegate {

    let displayID: CGDirectDisplayID
    /// Shown as this window's row in the menu, so it is not private.
    let name: String
    var onClose: ((CGDirectDisplayID) -> Void)?

    private let display: SCDisplay
    private let engine = CaptureEngine()
    private let panel: PiPPanel
    private let view: PiPContentView

    init(display: SCDisplay, name: String, on screen: NSScreen?,
         alwaysOnTop: Bool, frameRate: Int, escapingEdges: Set<Edge>, cascade: Int) {
        self.display = display
        self.displayID = display.displayID
        self.name = name
        self.alwaysOnTop = alwaysOnTop
        self.frameRate = frameRate
        self.escapingEdges = escapingEdges

        let aspect = NSSize(width: display.width, height: display.height)
        let initial = Self.initialFrame(aspect: aspect, on: screen, cascade: cascade)
        panel = PiPPanel(contentRect: initial, aspect: aspect, alwaysOnTop: alwaysOnTop)
        view = PiPContentView(frame: NSRect(origin: .zero, size: initial.size))
        super.init()

        panel.title = name
        panel.contentView = view
        panel.delegate = self

        view.onActivateInteraction = { [weak self] normalized in
            self?.enterInteraction(atNormalized: normalized)
        }
        engine.onFrame = { [weak self] surface in
            self?.view.show(surface: surface)
        }
        engine.onStop = { [weak self] error in
            NSLog("gjPiP: capture stopped: \(error.localizedDescription)")
            self?.close()
        }
    }

    // MARK: - Settings
    //
    // Each PiP carries its own, because the windows are not interchangeable: one showing a
    // virtual display you are working in wants a high frame rate and every edge open, while one
    // you are only keeping an eye on can run at 30fps and stay out of the way. A single global
    // set forced every window to be the same window.

    private(set) var alwaysOnTop: Bool
    private(set) var frameRate: Int
    /// Handed to `InteractionController` on activation — interaction runs on one display at a
    /// time, so the controller is asked for its edges when it takes the mouse rather than being
    /// told to push them ahead of time.
    var escapingEdges: Set<Edge>

    func setAlwaysOnTop(_ on: Bool) {
        alwaysOnTop = on
        panel.setAlwaysOnTop(on)
    }

    /// Which video filters this window runs. Held as a set — the chain always
    /// applies in declaration order (colour, then sharpen/blur, then effects),
    /// so the result doesn't depend on the order the boxes were ticked in.
    private(set) var videoFilters: Set<VideoFilter> = []

    func toggleFilter(_ filter: VideoFilter) {
        if videoFilters.insert(filter).inserted == false { videoFilters.remove(filter) }
        pushFilters()
    }

    func clearFilters() {
        videoFilters.removeAll()
        pushFilters()
    }

    private func pushFilters() {
        view.apply(filters: VideoFilter.allCases.filter(videoFilters.contains))
        Debug.log("\(name): filters = \(VideoFilter.allCases.filter(videoFilters.contains).map(\.rawValue))")
    }

    /// Restarts the capture at the new rate without rebuilding the window, so its size and
    /// position survive.
    func setFrameRate(_ rate: Int) {
        guard rate != frameRate else { return }
        frameRate = rate
        engine.stop()
        startCapture()
        Debug.log("\(name): frame rate → \(rate)")
    }

    func show() {
        panel.orderFront(nil)
        startCapture()
    }

    /// Moves the window back onto `screen`, at its `cascade`-th place, and raises it.
    ///
    /// A PiP can end up somewhere you cannot look: dragged onto a virtual display, which has no
    /// monitor, or onto a screen that has since been unplugged. It is still there and still
    /// capturing — it is just nowhere you can see, and the only handle on it is the one thing
    /// you cannot find. Hence a way to call every window home that does not require knowing
    /// where home went.
    ///
    /// The size is left alone; only the position moves. Whatever it was resized to is a choice
    /// worth keeping, and if it no longer fits, macOS will shrink it to the new screen anyway.
    func gather(onto screen: NSScreen?, cascade: Int) {
        let frame = Self.initialFrame(aspect: NSSize(width: display.width, height: display.height),
                                      on: screen, cascade: cascade)
        panel.setFrameOrigin(frame.origin)
        panel.orderFront(nil)
        Debug.log("\(name): gathered to \(frame.origin) on \(screen?.localizedName ?? "nil")")
    }

    private func startCapture() {
        Task {
            do {
                try await engine.start(display: display, frameRate: frameRate)
            } catch {
                presentCaptureFailure(error)
                close()
            }
        }
    }

    func close() {
        releaseMouseIfCaptured()
        engine.stop()
        panel.orderOut(nil)
        onClose?(displayID)
    }

    /// A captured mouse outlasting its window would strand the cursor on a
    /// display the user cannot see, with nothing left to walk out of.
    private func releaseMouseIfCaptured() {
        let interaction = InteractionController.shared
        guard interaction.isActive, interaction.displayID == displayID else { return }
        interaction.deactivate()
    }

    func setInteractionActive(_ active: Bool) {
        view.setInteractionActive(active)
        panel.title = active ? "\(name)  ●" : name
    }

    // MARK: - Interaction

    private func enterInteraction(atNormalized p: CGPoint) {
        let bounds = CGDisplayBounds(displayID)
        let target = CGPoint(x: bounds.minX + p.x * bounds.width,
                             y: bounds.minY + p.y * bounds.height)
        Debug.log("enter interaction, normalized \(p) → \(target) on display \(displayID)")
        let ok = InteractionController.shared.activate(
            displayID: displayID,
            at: target,
            escapingEdges: escapingEdges,
            pipContentRect: { [weak self] in self?.pictureRectInGlobalDisplayCoords() ?? .zero }
        )
        if !ok { presentAccessibilityNeeded() }
    }

    /// The picture's frame in the coordinates CGEvent and CGDisplay use: origin
    /// at the *top* left of the primary screen, y growing downward. AppKit's
    /// screen coordinates put the origin at its bottom left, hence the flip.
    private func pictureRectInGlobalDisplayCoords() -> CGRect {
        guard let window = view.window, let primary = NSScreen.screens.first else { return .zero }
        let inScreen = window.convertToScreen(view.convert(view.bounds, to: nil))
        return CGRect(x: inScreen.minX,
                      y: primary.frame.maxY - inScreen.maxY,
                      width: inScreen.width,
                      height: inScreen.height)
    }

    // MARK: - Layout

    /// Bottom-right of the chosen screen, out of the way of most work, stepped up and left by
    /// `cascade` places.
    ///
    /// Without the step every PiP lands on the same pixel. Several can be open at once — each
    /// has its own capture — but stacked exactly, all but the top one is invisible, and the
    /// window that is there looks like the one window the app can manage. Steps that would walk
    /// off the screen wrap back to the corner; overlapping there beats being unreachable.
    private static func initialFrame(aspect: NSSize, on screen: NSScreen?, cascade: Int) -> NSRect {
        let target = screen ?? NSScreen.main
        let area = target?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(area.width / 3, 720)
        let height = width * aspect.height / max(aspect.width, 1)

        let step: CGFloat = 36
        let room = min((area.width - width - 48) / step, (area.height - height - 48) / step)
        let places = max(1, Int(room))
        let offset = CGFloat(cascade % places) * step

        Debug.log("placing on \(target?.localizedName ?? "nil"), visibleFrame=\(area), cascade=\(cascade)")
        return NSRect(x: area.maxX - width - 24 - offset,
                      y: area.minY + 24 + offset,
                      width: width, height: height)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        releaseMouseIfCaptured()
        engine.stop()
        onClose?(displayID)
    }

    // MARK: - Alerts

    private func presentAccessibilityNeeded() {
        let alert = NSAlert()
        alert.messageText = "アクセシビリティ権限が必要です"
        alert.informativeText = """
            PiP ウィンドウ上のマウス操作を転送するには、システム設定 →
            プライバシーとセキュリティ → アクセシビリティ で gjPiP を許可し、
            アプリを再起動してください。
            """
        alert.addButton(withTitle: "システム設定を開く")
        alert.addButton(withTitle: "閉じる")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func presentCaptureFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "画面キャプチャを開始できませんでした"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
