import AppKit
import ScreenCaptureKit

/// A floating panel showing one captured display.
///
/// Non-activating and utility-styled so clicking it doesn't yank focus away
/// from whatever the user is working in, and so the titlebar stays out of the
/// way. The content aspect ratio is locked to the source display's, which keeps
/// the picture unletterboxed and makes view→display coordinate mapping exact.
final class PiPPanel: NSPanel {
    init(contentRect: NSRect, aspect: NSSize) {
        super.init(contentRect: contentRect,
                   styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titlebarAppearsTransparent = true
        contentAspectRatio = aspect
        isMovableByWindowBackground = false
        backgroundColor = .black
    }

    override var canBecomeKey: Bool { true }
}

/// Displays capture frames and turns a click into an interaction-mode entry at
/// the matching point on the source display.
final class PiPContentView: NSView {

    var onActivateInteraction: ((CGPoint) -> Void)?
    private let badge = NSTextField(labelWithString: "⌃⌘Esc で操作モード解除")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resize
        layer?.minificationFilter = .trilinear

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
        layer?.contents = surface
        CATransaction.commit()
    }

    func setInteractionActive(_ active: Bool) {
        badge.isHidden = !active
    }

    /// The PiP panel is normally not the key window, and by default a click on
    /// an inactive window is consumed just to focus it. Interaction mode has to
    /// start on that very first click, so take it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
    var onClose: ((CGDirectDisplayID) -> Void)?

    private let display: SCDisplay
    private let name: String
    private let engine = CaptureEngine()
    private let panel: PiPPanel
    private let view: PiPContentView

    init(display: SCDisplay, name: String) {
        self.display = display
        self.displayID = display.displayID
        self.name = name

        let aspect = NSSize(width: display.width, height: display.height)
        let initial = Self.initialFrame(aspect: aspect)
        panel = PiPPanel(contentRect: initial, aspect: aspect)
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

    func show(frameRate: Int) {
        panel.makeKeyAndOrderFront(nil)
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
        engine.stop()
        panel.orderOut(nil)
        onClose?(displayID)
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
        let ok = InteractionController.shared.activate(displayID: displayID, at: target)
        if !ok { presentAccessibilityNeeded() }
    }

    // MARK: - Layout

    private static func initialFrame(aspect: NSSize) -> NSRect {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(screen.width / 3, 720)
        let height = width * aspect.height / max(aspect.width, 1)
        return NSRect(x: screen.maxX - width - 24, y: screen.minY + 24, width: width, height: height)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
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
