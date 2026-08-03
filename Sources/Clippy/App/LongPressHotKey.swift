import AppKit

/// Opens the panel when ⌘V is *held*, while a normal tap of ⌘V still pastes.
///
/// This cannot be a Carbon hotkey. `RegisterEventHotKey` fires on key-down and
/// consumes the combination outright, which would break ordinary pasting
/// everywhere. The only way to tell a tap from a hold is to intercept ⌘V, wait,
/// and then decide — which means an active `CGEventTap`.
///
/// The consequence is worth stating plainly: **every ⌘V on the machine now
/// passes through this class.** A quick press is swallowed and replayed, so a
/// paste is delayed until you release the key (tens of milliseconds, the speed
/// you already type at). If the tap dies, pasting would break system-wide, so
/// the system's two "tap disabled" events are handled by turning it straight
/// back on, and `HotKey` keeps ⌘⇧V registered as a way in that does not depend
/// on any of this.
final class LongPressHotKey {

    /// Stamped on the events we synthesise so the callback can recognise its own
    /// replay and let it through instead of intercepting it again.
    private static let marker: Int64 = 0x434C5059  // 'CLPY'

    private static let vKeyCode: Int64 = 9

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    private var pending: DispatchWorkItem?
    private var pressActive = false
    private var firedForThisPress = false

    private let threshold: TimeInterval
    private let action: () -> Void

    /// - Parameter threshold: how long ⌘V must be held before the panel opens.
    ///   350ms is long enough not to trip on an ordinary paste and short enough
    ///   not to feel like waiting.
    init?(threshold: TimeInterval = 0.35, action: @escaping () -> Void) {
        self.threshold = threshold
        self.action = action

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,  // active — a listen-only tap cannot consume
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<LongPressHotKey>
                    .fromOpaque(refcon)
                    .takeUnretainedValue()
                    .handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return nil
        }

        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    deinit {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    // MARK: - Interception

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a tap whose callback runs long, and after certain user
        // input. Leaving it disabled would silently break ⌘V everywhere.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        // Our own replayed paste.
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker {
            return Unmanaged.passUnretained(event)
        }

        guard event.getIntegerValueField(.keyboardEventKeycode) == Self.vKeyCode else {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .keyDown:
            let flags = event.flags
            // Only bare ⌘V. ⌘⇧V, ⌘⌥V and ⌘⌃V keep whatever they already mean.
            guard flags.contains(.maskCommand),
                  !flags.contains(.maskShift),
                  !flags.contains(.maskAlternate),
                  !flags.contains(.maskControl)
            else { return Unmanaged.passUnretained(event) }

            // Holding a key autorepeats. Those must be swallowed too, or a long
            // press would paste over and over on the way to opening the panel.
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }

            beginPress()
            return nil

        case .keyUp:
            // Deliberately not checking ⌘ here: releasing command before V is
            // common, and missing that key-up would strand a pending press.
            guard pressActive else { return Unmanaged.passUnretained(event) }
            endPress()
            return nil

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func beginPress() {
        pending?.cancel()
        pressActive = true
        firedForThisPress = false

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pressActive else { return }
            self.firedForThisPress = true
            self.action()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + threshold, execute: work)
    }

    private func endPress() {
        pending?.cancel()
        pending = nil
        pressActive = false

        // Released before the threshold: the user meant an ordinary paste, so
        // put the keystroke they typed back into the stream.
        if !firedForThisPress { replayPaste() }
        firedForThisPress = false
    }

    private func replayPaste() {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source,
                                 virtualKey: CGKeyCode(Self.vKeyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: source,
                               virtualKey: CGKeyCode(Self.vKeyCode), keyDown: false)
        else { return }

        for event in [down, up] {
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
