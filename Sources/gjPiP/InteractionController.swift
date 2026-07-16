import AppKit
import CoreGraphics

/// Forwards physical mouse input to a captured display while "interaction mode"
/// is on.
///
/// Naively mapping a PiP-window click to `CGEventPost` does not work: the very
/// first synthetic event warps the real cursor onto the source display, after
/// which the PiP window stops receiving `NSEvent`s and there is nothing left to
/// map. So instead we park the cursor on the source display and install a
/// session event tap that swallows every physical mouse event, integrates its
/// delta into a position we track ourselves, clamps that to the source display,
/// and re-posts the event there. The cursor can never wander off the source
/// display, and ⌃⌘Esc is the way out.
///
/// Requires Accessibility permission (a session tap that can swallow events).
final class InteractionController {

    static let shared = InteractionController()
    private init() {}

    /// Stamped on every event we post so the tap can let its own output pass.
    private static let magic: Int64 = 0x676A_5069_50    // "gjPiP"
    private static let escapeKeyCode: Int64 = 53

    private(set) var isActive = false
    private(set) var displayID: CGDirectDisplayID = 0

    /// Notified on activate/deactivate so menus and window chrome can update.
    var onStateChange: ((Bool) -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var virtualPos: CGPoint = .zero
    private var restorePos: CGPoint = .zero

    // MARK: - Permission

    var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    @discardableResult
    func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Mode

    /// - Parameter point: where to place the cursor, in global display
    ///   coordinates on `displayID`.
    /// - Returns: false if Accessibility permission is missing.
    @discardableResult
    func activate(displayID: CGDirectDisplayID, at point: CGPoint) -> Bool {
        if isActive { deactivate() }
        guard requestAccessibilityPermission() else { return false }

        let mask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<InteractionController>.fromOpaque(refcon).takeUnretainedValue()
                return controller.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        self.displayID = displayID
        self.restorePos = CGEvent(source: nil)?.location ?? point
        self.virtualPos = clamp(point)
        self.isActive = true

        warpCursor(to: virtualPos)
        NSCursor.hide()
        onStateChange?(true)
        return true
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil

        warpCursor(to: restorePos)
        NSCursor.unhide()
        onStateChange?(false)
    }

    // MARK: - Tap callback

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that blocks for too long; revive it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        }
        guard isActive else { return Unmanaged.passUnretained(event) }
        // Don't re-process the events we ourselves post.
        guard event.getIntegerValueField(.eventSourceUserData) != Self.magic else {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .keyDown:
            let wantsExit = event.flags.contains(.maskCommand)
                && event.flags.contains(.maskControl)
                && event.getIntegerValueField(.keyboardEventKeycode) == Self.escapeKeyCode
            guard wantsExit else { return Unmanaged.passUnretained(event) }
            DispatchQueue.main.async { [weak self] in self?.deactivate() }
            return nil

        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let dx = event.getDoubleValueField(.mouseEventDeltaX)
            let dy = event.getDoubleValueField(.mouseEventDeltaY)
            virtualPos = clamp(CGPoint(x: virtualPos.x + dx, y: virtualPos.y + dy))
            repost(event, at: virtualPos)
            return nil

        case .leftMouseDown, .leftMouseUp,
             .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp:
            // Re-post at our tracked position rather than passing through, so a
            // click can never land somewhere the clamp would have disallowed.
            // The copy keeps clickState, so double-clicks still register.
            repost(event, at: virtualPos)
            return nil

        default:
            // Scroll and everything else pass through untouched: the real cursor
            // already sits at `virtualPos`, so they route to the right window and
            // keep their momentum/phase semantics intact.
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - Helpers

    private func repost(_ event: CGEvent, at point: CGPoint) {
        guard let copy = event.copy() else { return }
        copy.location = point
        copy.setIntegerValueField(.eventSourceUserData, value: Self.magic)
        copy.post(tap: .cghidEventTap)
    }

    private func warpCursor(to point: CGPoint) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                  mouseCursorPosition: point, mouseButton: .left) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: Self.magic)
        event.post(tap: .cghidEventTap)
    }

    /// Keeps the cursor inside the source display. The 1pt inset matters: at the
    /// exact edge macOS will hand the cursor to an adjacent display.
    private func clamp(_ point: CGPoint) -> CGPoint {
        let b = CGDisplayBounds(displayID)
        guard !b.isEmpty else { return point }
        return CGPoint(x: min(max(point.x, b.minX), b.maxX - 1),
                       y: min(max(point.y, b.minY), b.maxY - 1))
    }
}
