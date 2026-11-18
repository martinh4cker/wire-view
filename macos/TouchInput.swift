import Carbon
import CoreGraphics

// Used only on the sender queue. All positions are in Quartz global coordinates.
final class TouchInput {
    private let display: CGDirectDisplayID
    private var pressedAt: CGPoint?
    private var reportedInput = false
    private var reportedPermission: Bool?

    init(display: CGDirectDisplayID) { self.display = display }

    func handle(_ packet: UInt64) {
        let action = (packet >> 56) & 0x7f
        if action == 5 { release(); return }
        let permitted = CGPreflightPostEventAccess()
        if !reportedInput || reportedPermission != permitted {
            reportedInput = true
            reportedPermission = permitted
            touchLog.notice("Received tablet touch. macOS event permission: \(permitted, privacy: .public)")
        }
        guard permitted, CGDisplayIsActive(display) != 0 else {
            release()
            return
        }
        let bounds = CGDisplayBounds(display)
        guard bounds.width > 1, bounds.height > 1 else { release(); return }
        let x = CGFloat((packet >> 40) & 0xffff) / 65535
        let y = CGFloat((packet >> 24) & 0xffff) / 65535
        let point = CGPoint(x: bounds.minX + x * (bounds.width - 1),
                            y: bounds.minY + y * (bounds.height - 1))
        switch action {
        case 1 where pressedAt == nil:
            _ = post(.mouseMoved, at: point)
            if post(.leftMouseDown, at: point) { pressedAt = point }
        case 2 where pressedAt != nil:
            if post(.leftMouseDragged, at: point) { pressedAt = point }
        case 3 where pressedAt != nil:
            pressedAt = point
            release()
        case 4 where pressedAt == nil:
            let dx = Int32(Int8(bitPattern: UInt8(truncatingIfNeeded: packet >> 16)))
            let dy = Int32(Int8(bitPattern: UInt8(truncatingIfNeeded: packet >> 8)))
            // Scroll follows the pointer. Move it to the gesture centroid first.
            if dx != 0 || dy != 0, post(.mouseMoved, at: point),
               let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                   wheel1: dy, wheel2: dx, wheel3: 0) {
                event.location = point
                event.post(tap: .cghidEventTap)
            }
        case 8 where pressedAt == nil:
            handleGesture(UInt8(truncatingIfNeeded: packet >> 16), at: point)
        default: break
        }
    }

    private func handleGesture(_ command: UInt8, at point: CGPoint) {
        let key: Int
        let modifiers: [(Int, CGEventFlags)]
        let control = [(kVK_Control, CGEventFlags.maskControl)]
        let commandKey = [(kVK_Command, CGEventFlags.maskCommand)]
        switch command {
        case 1: key = kVK_LeftArrow; modifiers = control
        case 2: key = kVK_RightArrow; modifiers = control
        case 3: key = kVK_UpArrow; modifiers = control
        case 4: key = kVK_DownArrow; modifiers = control
        case 5: key = kVK_Tab; modifiers = commandKey + [(kVK_Shift, .maskShift)]
        case 6: key = kVK_Tab; modifiers = commandKey
        default: return
        }

        // Keep the shortcut independent of modifiers the user holds on a real keyboard.
        let shortcutModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        guard CGEventSource.flagsState(.combinedSessionState).intersection(shortcutModifiers).isEmpty,
              let source = CGEventSource(stateID: .privateState),
              let press = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: true),
              let lift = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: false)
        else { return }

        var events: [CGEvent] = []
        var flags: CGEventFlags = []
        for (code, flag) in modifiers {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: true) else { return }
            flags.insert(flag)
            event.type = .flagsChanged
            event.flags = flags
            events.append(event)
        }
        press.flags = flags
        lift.flags = flags
        events += [press, lift]
        for (code, flag) in modifiers.reversed() {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: false) else { return }
            flags.remove(flag)
            event.type = .flagsChanged
            event.flags = flags
            events.append(event)
        }
        _ = post(.mouseMoved, at: point)
        for event in events { event.post(tap: .cghidEventTap) }
        touchLog.notice("Posted tablet gesture shortcut: \(command, privacy: .public)")
    }

    func release() {
        guard let point = pressedAt else { return }
        pressedAt = nil
        _ = post(.leftMouseUp, at: point)
    }

    @discardableResult
    private func post(_ type: CGEventType, at point: CGPoint) -> Bool {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left) else { return false }
        if type != .mouseMoved { event.setIntegerValueField(.mouseEventClickState, value: 1) }
        event.post(tap: .cghidEventTap)
        return true
    }
}
