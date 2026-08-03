import AppKit
import ApplicationServices
import ClippyCore

/// Determines where a paste is about to land.
///
/// Critical ordering constraint: this must be called *before* the history panel
/// is shown. Once our panel takes focus we become the frontmost application and
/// the real target is no longer discoverable. `PanelController` captures a
/// `Target` first, then presents — and the panel must be a non-activating
/// `NSPanel` so the target keeps its focus ring and this probe stays valid for
/// the lifetime of the popup.
public enum TargetInspector {

    /// Whether we hold the Accessibility permission needed to both probe focus
    /// and post synthetic keystrokes. Without it we can still paste blind, but
    /// every finding degrades to `.unknown`.
    public static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompt for Accessibility permission. Shows the system dialog once; after
    /// the user has answered, macOS remembers and this becomes a no-op, so the
    /// only way to re-prompt is through System Settings.
    @discardableResult
    public static func requestTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Snapshot the current frontmost application as a paste target.
    public static func current() -> Target? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier
        else { return nil }

        let kind = TargetClassifier.kind(for: bundleID)

        return Target(
            bundleID: bundleID,
            localizedName: app.localizedName ?? bundleID,
            kind: kind,
            focus: focusState(pid: app.processIdentifier, kind: kind),
            acceptsImages: kind == .browser || kind == .other
        )
    }

    // MARK: - Accessibility probe

    /// Reads the focused element and hands the raw findings to
    /// `FocusClassifier`. Everything here is I/O; the interpretation lives in
    /// ClippyCore so it can be tested without a running app.
    private static func focusState(pid: pid_t, kind: TargetKind) -> FocusState {
        guard isTrusted else { return .unknown }

        let appElement = AXUIElementCreateApplication(pid)

        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )

        // A surprising number of apps return .cannotComplete here simply
        // because they are busy. Treating that as "no focus" would block
        // legitimate pastes, so anything other than a clean success is unknown.
        guard err == .success, let element = focused else {
            return err == .noValue ? .none : .unknown
        }

        // swiftlint:disable:next force_cast
        let axElement = element as! AXUIElement

        return FocusClassifier.state(
            role: stringAttribute(axElement, kAXRoleAttribute),
            valueIsSettable: isSettable(axElement, kAXValueAttribute),
            kind: kind
        )
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
        else { return false }
        return settable.boolValue
    }
}
