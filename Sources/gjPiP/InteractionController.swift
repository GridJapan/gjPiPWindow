import AppKit
import CoreGraphics

/// Forwards physical mouse input to a captured display while "interaction mode"
/// is on.
///
/// Naively mapping a PiP-window click to `CGEventPost` does not work: the very
/// first synthetic event warps the real cursor onto the source display, after
/// which the PiP window stops receiving `NSEvent`s and there is nothing left to
/// map. So instead the cursor is parked *on* the source display and simply left
/// there — physical movement then drives it natively, at normal speed and
/// acceleration, with no forwarding needed at all.
///
/// All this class does from then on is watch the boundary: a session event tap
/// inspects each mouse event's proposed location, and the moment one falls
/// outside the source display, interaction ends and the cursor is dropped just
/// outside the PiP window on the side it left from. The PiP is a portal you can
/// walk out of, not a trap. ⌃⌘Esc, and mashing Esc five times, are backstops.
///
/// Note what this deliberately does *not* do: integrate `mouseEventDelta` into a
/// position of its own. Doing that feeds the cursor's own warps back in as
/// movement — the jump from the click point to the source display arrives as a
/// delta and corrupts the tracked position immediately. The OS already computes
/// where the cursor goes; the only sane move is to read it.
///
/// The cursor is deliberately *not* hidden while forwarding: a virtual display
/// has no physical monitor, so the captured stream is the only place its cursor
/// can be seen at all.
///
/// Requires Accessibility permission (a session tap that can swallow events).
final class InteractionController {

    static let shared = InteractionController()
    private init() {}

    /// Stamped on the events we post so the tap can let its own output pass.
    private static let magic: Int64 = 0x676A_5069_50    // "gjPiP"
    private static let escapeKeyCode: Int64 = 53

    /// Panic exit: mashing Esc is what people actually do when the cursor has
    /// vanished onto a display with no monitor, and unlike a chord there is
    /// nothing to remember. Deliberately generous — a false trigger only ends
    /// interaction, while a missed one leaves someone stuck.
    private static let panicPressCount = 5
    private static let panicWindow: TimeInterval = 2

    private(set) var isActive = false
    private(set) var displayID: CGDirectDisplayID = 0

    /// Notified on activate/deactivate so menus and window chrome can update.
    var onStateChange: ((Bool) -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var restorePos: CGPoint = .zero
    /// The PiP's picture in global display coordinates. Re-read on demand
    /// because the window moves and resizes.
    private var pipContentRect: (() -> CGRect)?
    /// Timestamps of recent bare Esc presses, for the panic exit.
    private var escapePresses: [TimeInterval] = []

    // MARK: - Permission

    var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    @discardableResult
    func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Mode

    /// - Parameters:
    ///   - point: where to place the cursor, in global display coordinates on
    ///     `displayID`.
    ///   - pipContentRect: the PiP's picture in global display coordinates,
    ///     evaluated on the main thread when the cursor leaves the display.
    /// - Returns: false if Accessibility permission is missing.
    @discardableResult
    func activate(displayID: CGDirectDisplayID,
                  at point: CGPoint,
                  pipContentRect: @escaping () -> CGRect) -> Bool {
        if isActive { deactivate() }
        guard requestAccessibilityPermission() else { return false }

        let mask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
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
        self.pipContentRect = pipContentRect
        self.restorePos = CGEvent(source: nil)?.location ?? point
        self.escapePresses.removeAll()
        self.isActive = true

        warpCursor(to: clamp(point))
        Debug.log("interaction on, display \(displayID), cursor to \(clamp(point))")
        onStateChange?(true)
        return true
    }

    func deactivate() {
        deactivate(restoringCursorTo: restorePos)
    }

    private func deactivate(restoringCursorTo point: CGPoint) {
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
        pipContentRect = nil

        warpCursor(to: point)
        Debug.log("interaction off, cursor to \(point)")
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
            guard event.getIntegerValueField(.keyboardEventKeycode) == Self.escapeKeyCode else {
                return Unmanaged.passUnretained(event)
            }

            if event.flags.contains(.maskCommand) && event.flags.contains(.maskControl) {
                DispatchQueue.main.async { [weak self] in self?.deactivate() }
                return nil
            }

            // Holding Esc down must not count as mashing it.
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
                return Unmanaged.passUnretained(event)
            }
            // Nanoseconds since boot — monotonic, and already on the event.
            let now = TimeInterval(event.timestamp) / 1_000_000_000
            escapePresses.append(now)
            escapePresses.removeAll { now - $0 > Self.panicWindow }
            guard escapePresses.count >= Self.panicPressCount else {
                // A bare Esc is a normal keystroke for whatever is on the source
                // display, so it still gets through.
                return Unmanaged.passUnretained(event)
            }
            Debug.log("panic exit: \(escapePresses.count) Esc presses")
            escapePresses.removeAll()
            DispatchQueue.main.async { [weak self] in self?.deactivate() }
            return nil

        case .mouseMoved:
            let b = CGDisplayBounds(displayID)
            guard !b.isEmpty, !inside(event.location, b) else {
                return Unmanaged.passUnretained(event)
            }
            // Walking off any edge ends forwarding, the way leaving a monitor
            // does. This is the primary way out — ⌃⌘Esc is just a backstop.
            let leftAt = event.location
            DispatchQueue.main.async { [weak self] in
                self?.releaseAtEdge(leaving: leftAt, bounds: b)
            }
            return nil

        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            // Clamp rather than release: ejecting mid-drag would drop whatever
            // is being dragged somewhere unintended.
            let b = CGDisplayBounds(displayID)
            guard !b.isEmpty, !inside(event.location, b) else {
                return Unmanaged.passUnretained(event)
            }
            guard let copy = event.copy() else { return nil }
            copy.location = clamp(event.location)
            copy.setIntegerValueField(.eventSourceUserData, value: Self.magic)
            copy.post(tap: .cghidEventTap)
            return nil

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - Leaving

    /// Hands control back and puts the cursor just outside the PiP on the side
    /// the cursor left from, so the motion reads as continuous.
    private func releaseAtEdge(leaving point: CGPoint, bounds b: CGRect) {
        guard isActive else { return }
        guard let picture = pipContentRect?(), !picture.isEmpty else {
            deactivate()
            return
        }

        let u = min(max((point.x - b.minX) / b.width, 0), 1)
        let v = min(max((point.y - b.minY) / b.height, 0), 1)
        var exit = CGPoint(x: picture.minX + u * picture.width,
                           y: picture.minY + v * picture.height)

        // Land clear of the window, otherwise the next move would re-enter it.
        let margin: CGFloat = 6
        if point.x < b.minX { exit.x = picture.minX - margin }
        if point.x > b.maxX - 1 { exit.x = picture.maxX + margin }
        if point.y < b.minY { exit.y = picture.minY - margin }
        if point.y > b.maxY - 1 { exit.y = picture.maxY + margin }

        Debug.log("left display \(displayID) at \(point) → cursor to \(exit)")
        deactivate(restoringCursorTo: exit)
    }

    // MARK: - Helpers

    private func warpCursor(to point: CGPoint) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                  mouseCursorPosition: point, mouseButton: .left) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: Self.magic)
        event.post(tap: .cghidEventTap)
    }

    private func inside(_ p: CGPoint, _ b: CGRect) -> Bool {
        p.x >= b.minX && p.x <= b.maxX - 1 && p.y >= b.minY && p.y <= b.maxY - 1
    }

    /// The 1pt inset matters: at the exact edge macOS will hand the cursor to an
    /// adjacent display.
    private func clamp(_ point: CGPoint) -> CGPoint {
        let b = CGDisplayBounds(displayID)
        guard !b.isEmpty else { return point }
        return CGPoint(x: min(max(point.x, b.minX), b.maxX - 1),
                       y: min(max(point.y, b.minY), b.maxY - 1))
    }
}
