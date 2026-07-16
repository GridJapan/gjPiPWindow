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
            let item = NSMenuItem(title: "操作モードを解除 (⌃⌘Esc)", action: #selector(exitInteraction), keyEquivalent: "")
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
        let controller = PiPWindowController(display: display, name: name(for: display), on: placementScreen)
        controller.onClose = { [weak self] id in self?.controllers[id] = nil }
        controllers[display.displayID] = controller
        controller.show(frameRate: frameRate)
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
            let replacement = PiPWindowController(display: display, name: name(for: display), on: placementScreen)
            replacement.onClose = { [weak self] id in self?.controllers[id] = nil }
            controllers[id] = replacement
            replacement.show(frameRate: frameRate)
        }
    }

    @objc private func exitInteraction() {
        InteractionController.shared.deactivate()
    }
}
