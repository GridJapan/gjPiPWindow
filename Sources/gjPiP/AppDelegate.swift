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

    private static let frameRates = [30, 60, 120]

    /// Ties a per-window edge toggle to the window it belongs to, since an `NSMenuItem` carries
    /// exactly one `representedObject` and this needs both.
    private final class EdgeChoice: NSObject {
        let controller: PiPWindowController
        let edge: Edge
        init(controller: PiPWindowController, edge: Edge) {
            self.controller = controller
            self.edge = edge
        }
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
        // One row per display, whether or not its PiP is open. A closed one opens on click; an
        // open one carries its own settings in a submenu, and is closed from in there.
        //
        // The open windows were briefly listed again in a section of their own, which read
        // worse than it sounds: the same display name appeared twice, one row a toggle and the
        // other a submenu, with nothing to say which was which.
        for display in displays {
            let controller = controllers[display.displayID]
            let item = NSMenuItem(title: name(for: display),
                                  action: controller == nil ? #selector(togglePiP(_:)) : nil,
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = display
            item.state = controller != nil ? .on : .off
            if let controller {
                item.submenu = settingsMenu(for: controller)
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(header("新しい PiP の既定"))

        let placement = NSMenuItem(title: "開く画面", action: nil, keyEquivalent: "")
        placement.submenu = placementMenu()
        menu.addItem(placement)

        let defaultsOnTop = NSMenuItem(title: "常に最前面", action: #selector(toggleAlwaysOnTop), keyEquivalent: "")
        defaultsOnTop.target = self
        defaultsOnTop.state = alwaysOnTop ? .on : .off
        menu.addItem(defaultsOnTop)

        let defaultRate = NSMenuItem(title: "フレームレート", action: nil, keyEquivalent: "")
        defaultRate.submenu = frameRateMenu(selected: frameRate, action: #selector(setFrameRate(_:)))
        menu.addItem(defaultRate)

        let defaultEdges = NSMenuItem(title: "枠の外に出たら解除する辺", action: nil, keyEquivalent: "")
        defaultEdges.submenu = edgesMenu(selected: Set(Edge.allCases.filter(escapes)),
                                         action: #selector(toggleEscapeEdge(_:)))
        menu.addItem(defaultEdges)

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

    // MARK: - Submenus

    /// One window's own settings, reached through the window it belongs to.
    private func settingsMenu(for controller: PiPWindowController) -> NSMenu {
        let menu = NSMenu()

        let interaction = InteractionController.shared
        if interaction.isActive, interaction.displayID == controller.displayID {
            let item = NSMenuItem(title: "操作モードを解除 (Control + Command + Esc)",
                                  action: #selector(exitInteraction), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }

        let onTop = NSMenuItem(title: "常に最前面", action: #selector(togglePiPAlwaysOnTop(_:)), keyEquivalent: "")
        onTop.target = self
        onTop.representedObject = controller
        onTop.state = controller.alwaysOnTop ? .on : .off
        menu.addItem(onTop)
        menu.addItem(header(controller.alwaysOnTop ? "  Control + ↑ の Mission Control には出ません"
                                                   : "  Control + ↑ の Mission Control に出ます"))

        menu.addItem(.separator())
        menu.addItem(header("フレームレート"))
        for rate in Self.frameRates {
            let item = NSMenuItem(title: "\(rate) fps", action: #selector(setPiPFrameRate(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = controller
            item.tag = rate
            item.state = rate == controller.frameRate ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(header("枠の外に出たら解除する辺"))
        for edge in Edge.allCases {
            let item = NSMenuItem(title: edge.label, action: #selector(togglePiPEscapeEdge(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = EdgeChoice(controller: controller, edge: edge)
            item.state = controller.escapingEdges.contains(edge) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let close = NSMenuItem(title: "この PiP を閉じる", action: #selector(closePiP(_:)), keyEquivalent: "")
        close.target = self
        close.representedObject = controller
        menu.addItem(close)

        return menu
    }

    private func placementMenu() -> NSMenu {
        let menu = NSMenu()
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
        return menu
    }

    private func frameRateMenu(selected: Int, action: Selector) -> NSMenu {
        let menu = NSMenu()
        for rate in Self.frameRates {
            let item = NSMenuItem(title: "\(rate) fps", action: action, keyEquivalent: "")
            item.target = self
            item.tag = rate
            item.state = rate == selected ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func edgesMenu(selected: Set<Edge>, action: Selector) -> NSMenu {
        let menu = NSMenu()
        for edge in Edge.allCases {
            let item = NSMenuItem(title: edge.label, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = edge.rawValue
            item.state = selected.contains(edge) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func togglePiP(_ sender: NSMenuItem) {
        guard let display = sender.representedObject as? SCDisplay else { return }
        if let existing = controllers[display.displayID] {
            existing.close()
            return
        }
        // Step the new window clear of the ones already open, which all default to the same
        // corner and would otherwise hide each other completely.
        let controller = PiPWindowController(display: display, name: name(for: display),
                                             on: placementScreen,
                                             alwaysOnTop: alwaysOnTop,
                                             frameRate: frameRate,
                                             escapingEdges: Set(Edge.allCases.filter(escapes)),
                                             cascade: controllers.count)
        controller.onClose = { [weak self] id in self?.controllers[id] = nil }
        controllers[display.displayID] = controller
        controller.show()
    }

    // MARK: - Per-window actions

    @objc private func togglePiPAlwaysOnTop(_ sender: NSMenuItem) {
        guard let controller = sender.representedObject as? PiPWindowController else { return }
        controller.setAlwaysOnTop(!controller.alwaysOnTop)
        Debug.log("\(controller.name): always on top = \(controller.alwaysOnTop)")
    }

    @objc private func setPiPFrameRate(_ sender: NSMenuItem) {
        guard let controller = sender.representedObject as? PiPWindowController else { return }
        controller.setFrameRate(sender.tag)
    }

    @objc private func togglePiPEscapeEdge(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? EdgeChoice else { return }
        let controller = choice.controller
        if controller.escapingEdges.contains(choice.edge) {
            controller.escapingEdges.remove(choice.edge)
        } else {
            controller.escapingEdges.insert(choice.edge)
        }
        // Takes effect on the next click into the PiP; a live session keeps the edges it began
        // with rather than having the walls move under the cursor.
        Debug.log("\(controller.name): escaping edges = \(controller.escapingEdges.map(\.rawValue).sorted())")
    }

    @objc private func closePiP(_ sender: NSMenuItem) {
        guard let controller = sender.representedObject as? PiPWindowController else { return }
        controller.close()
    }

    // MARK: - Default actions

    // These three set what the *next* PiP starts with. Open windows keep what they have —
    // reaching in and changing a window from here would undo a choice made deliberately on that
    // window, and there is no way to tell the two apart afterwards.

    @objc private func toggleEscapeEdge(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let edge = Edge(rawValue: raw) else { return }
        UserDefaults.standard.set(!escapes(edge), forKey: escapeKey(edge))
        Debug.log("default escaping edges = \(Edge.allCases.filter(escapes).map(\.rawValue).sorted())")
    }

    @objc private func toggleAlwaysOnTop() {
        alwaysOnTop.toggle()
        Debug.log("default always on top = \(alwaysOnTop)")
    }

    @objc private func setPlacement(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        placementName = name
        // Existing windows stay put; moving them under the user would be rude.
        Debug.log("PiP placement set to \(name)")
    }

    @objc private func setFrameRate(_ sender: NSMenuItem) {
        frameRate = sender.tag
        Debug.log("default frame rate = \(frameRate)")
    }

    @objc private func exitInteraction() {
        InteractionController.shared.deactivate()
    }
}
