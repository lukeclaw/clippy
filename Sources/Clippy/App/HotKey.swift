import AppKit
import Carbon.HIToolbox

/// A system-wide hotkey.
///
/// Carbon's `RegisterEventHotKey` rather than an `NSEvent` global monitor: a
/// global monitor cannot consume the event, so the keystroke would also reach
/// whatever app is frontmost. It is also the only mechanism that works without
/// Accessibility permission, which matters because permission gates the focus
/// probe, not the core feature.
public final class HotKey {

    /// Carbon hands the callback a C function pointer with no context, so
    /// registered actions are looked up by the id we assigned at registration.
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    private var ref: EventHotKeyRef?
    private let id: UInt32

    /// - Parameters:
    ///   - keyCode: a `kVK_` virtual key code.
    ///   - modifiers: Carbon modifier mask (`cmdKey`, `shiftKey`, …).
    public init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        Self.installHandlerIfNeeded()

        id = Self.nextID
        Self.nextID += 1
        Self.actions[id] = action

        let hotKeyID = EventHotKeyID(signature: OSType(0x434C5059), id: id)  // 'CLPY'
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref
        )

        guard status == noErr else {
            Self.actions[id] = nil
            return nil
        }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.actions[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var id = EventHotKeyID()
                let err = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &id
                )
                guard err == noErr else { return err }
                HotKey.actions[id.id]?()
                return noErr
            },
            1, &spec, nil, nil
        )
    }
}

public extension HotKey {
    /// ⌘⇧V. Matches Raycast; Maccy uses ⌘⇧C. Either is fine — see docs/ux.md.
    static func commandShiftV(action: @escaping () -> Void) -> HotKey? {
        HotKey(
            keyCode: UInt32(kVK_ANSI_V),
            modifiers: UInt32(cmdKey | shiftKey),
            action: action
        )
    }
}
