import AppKit
import ScreenCaptureKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var displays: [SCDisplay] = []
    private var controllers: [CGDirectDisplayID: PiPWindowController] = [:]
    private var frameRate = 60

    private static let placementKey = "PiPScreenName"
    private static let defaultPlacement = "BenQ EX3410R"
    private static let alwaysOnTopKey = "PiPAlwaysOnTop"

    /// Off by default: a window pinned above everything is also a window Mission Control
    /// refuses to show, and being able to find the PiP with Control+Up turns out to matter more
    /// day to day than never having it covered.
    private var alwaysOnTop: Bool {
        get { UserDefaults.standard.bool(forKey: Self.alwaysOnTopKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.alwaysOnTopKey) }
    }

    /// Per-side, because the sides are not interchangeable: the bottom edge is where the Dock
    /// is revealed, and a side that ejects you cannot also be a side you reach for.
    private func escapeKey(_ edge: Edge) -> String { "PiPEscapeEdge.\(edge.rawValue)" }

    private func escapes(_ edge: Edge) -> Bool {
        guard UserDefaults.standard.object(forKey: escapeKey(edge)) != nil else {
            return edge.escapesByDefault
        }
        return UserDefaults.standard.bool(forKey: escapeKey(edge))
    }

    /// The controller is told rather than asked: it reads this on every mouse event, and the
    /// tap callback is not where UserDefaults lookups belong.
    private func pushEscapingEdges() {
        InteractionController.shared.escapingEdges = Set(Edge.allCases.filter(escapes))
    }

    /// Which screen new PiP windows open on, by `NSScreen.localizedName`.
    /// Stored by name rather than display ID because IDs are not stable across
    /// reconnects, and this should survive unplugging a monitor.
    private var placementName: String {
        get { UserDefaults.standard.string(forKey: Self.placementKey) ?? Self.defaultPlacement }
        set { UserDefaults.standard.set(newValue, forKey: Self.placementKey) }
    }

    private var placementScreen: NSScreen? {
        NSScreen.screens.first { $0.localizedName == placementName } ?? NSScreen.main
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pip", accessibilityDescription: "gjPiP")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        InteractionController.shared.onStateChange = { [weak self] active in
            guard let self else { return }
            for controller in controllers.values {
                controller.setInteractionActive(active && controller.displayID == InteractionController.shared.displayID)
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshDisplays() }
        }

        // Returns the *current* status and raises the prompt asynchronously, so
        // false here just means "ask again after the user answers".
        if !CGRequestScreenCaptureAccess() {
            NSLog("gjPiP: screen capture not authorized yet — grant it and relaunch")
        }
        pushEscapingEdges()
        refreshDisplays()
    }

    func applicationWillTerminate(_ notification: Notification) {
        InteractionController.shared.deactivate()
        for controller in controllers.values { controller.close() }
    }

    // MARK: - Displays

    private func refreshDisplays() {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                displays = content.displays
                // Drop PiPs whose display went away.
                for id in controllers.keys where !displays.contains(where: { $0.displayID == id }) {
                    controllers[id]?.close()
                }
            } catch {
                NSLog("gjPiP: cannot list displays: \(error.localizedDescription)")
                displays = []
            }
        }
    }

    private func name(for display: SCDisplay) -> String {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
        }
        let label = screen?.localizedName ?? "Display \(display.displayID)"
        return "\(label) — \(display.width)×\(display.height)"
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshDisplays()
        menu.removeAllItems()

        menu.addItem(header("ディスプレイ"))
        if displays.isEmpty {
            let item = NSMenuItem(title: "ディスプレイを取得中… (画面収録の許可が必要)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        for display in displays {
            let item = NSMenuItem(title: name(for: display), action: #selector(togglePiP(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = display
            item.state = controllers[display.displayID] != nil ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(header("PiP ウィンドウを開く画面"))
        for screen in NSScreen.screens {
            let item = NSMenuItem(title: screen.localizedName, action: #selector(setPlacement(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = screen.localizedName
            item.state = screen.localizedName == placementName ? .on : .off
            menu.addItem(item)
        }
        if !NSScreen.screens.contains(where: { $0.localizedName == placementName }) {
            let item = NSMenuItem(title: "\(placementName)（未接続）", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.state = .on
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(header("枠の外に出たら解除する辺"))
        for edge in Edge.allCases {
            let item = NSMenuItem(title: edge.label, action: #selector(toggleEscapeEdge(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = edge.rawValue
            item.state = escapes(edge) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let onTop = NSMenuItem(title: "常に最前面", action: #selector(toggleAlwaysOnTop), keyEquivalent: "")
        onTop.target = self
        onTop.state = alwaysOnTop ? .on : .off
        menu.addItem(onTop)
        let onTopNote = header(alwaysOnTop ? "  Control + ↑ の Mission Control には出ません"
                             : "  Control + ↑ の Mission Control に出ます")
        menu.addItem(onTopNote)

        menu.addItem(.separator())
        menu.addItem(header("フレームレート"))
        for rate in [30, 60, 120] {
            let item = NSMenuItem(title: "\(rate) fps", action: #selector(setFrameRate(_:)), keyEquivalent: "")
            item.target = self
            item.tag = rate
            item.state = rate == frameRate ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        if InteractionController.shared.isActive {
            let item = NSMenuItem(title: "操作モードを解除 (Control + Command + Esc)",
                                  action: #selector(exitInteraction), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        } else {
            let item = NSMenuItem(title: "PiP をクリックすると操作モード", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "gjPiP を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func togglePiP(_ sender: NSMenuItem) {
        guard let display = sender.representedObject as? SCDisplay else { return }
        if let existing = controllers[display.displayID] {
            existing.close()
            return
        }
        let controller = PiPWindowController(display: display, name: name(for: display),
                                             on: placementScreen, alwaysOnTop: alwaysOnTop)
        controller.onClose = { [weak self] id in self?.controllers[id] = nil }
        controllers[display.displayID] = controller
        controller.show(frameRate: frameRate)
    }

    @objc private func toggleEscapeEdge(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let edge = Edge(rawValue: raw) else { return }
        UserDefaults.standard.set(!escapes(edge), forKey: escapeKey(edge))
        pushEscapingEdges()
        Debug.log("escaping edges = \(InteractionController.shared.escapingEdges.map(\.rawValue).sorted())")
    }

    @objc private func toggleAlwaysOnTop() {
        alwaysOnTop.toggle()
        // Applied in place: reopening the windows would lose their size and position.
        for controller in controllers.values {
            controller.setAlwaysOnTop(alwaysOnTop)
        }
        Debug.log("always on top = \(alwaysOnTop)")
    }

    @objc private func setPlacement(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        placementName = name
        // Existing windows stay put; moving them under the user would be rude.
        Debug.log("PiP placement set to \(name)")
    }

    @objc private func setFrameRate(_ sender: NSMenuItem) {
        frameRate = sender.tag
        // Restart live captures at the new rate.
        for (id, controller) in controllers {
            guard let display = displays.first(where: { $0.displayID == id }) else { continue }
            controller.close()
            let replacement = PiPWindowController(display: display, name: name(for: display),
                                                  on: placementScreen, alwaysOnTop: alwaysOnTop)
            replacement.onClose = { [weak self] id in self?.controllers[id] = nil }
            controllers[id] = replacement
            replacement.show(frameRate: frameRate)
        }
    }

    @objc private func exitInteraction() {
        InteractionController.shared.deactivate()
    }
}
