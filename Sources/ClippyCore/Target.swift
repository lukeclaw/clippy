import Foundation

/// The broad category of the app we are about to paste into. Category drives
/// which Preflight rules apply — a trailing newline is catastrophic in a TUI and
/// completely harmless in a text editor.
public enum TargetKind: Equatable, Sendable {
    /// Terminal emulators. Anything running a TUI — including Claude Code and
    /// Copilot CLI — appears to us as its host terminal.
    case terminal
    case editor
    case browser
    case other
}

/// What the focused element will accept. Populated from the accessibility API
/// where available; `.unknown` when we could not probe (no permission, or the
/// app exposes nothing useful).
public enum FocusState: Equatable, Sendable {
    /// A focused element that accepts text.
    case editableText
    /// A focused element that exists but is not editable (a static label, a
    /// list, a web view in read mode).
    case nonEditable
    /// No focused element at all.
    case none
    /// Could not determine — treat optimistically, but say so in findings.
    case unknown
}

/// Where a paste is headed.
public struct Target: Equatable, Sendable {
    public let bundleID: String
    public let localizedName: String
    public let kind: TargetKind
    public let focus: FocusState

    /// Whether the target advertises that it can receive images. Terminals
    /// cannot; most editors cannot; browsers and image apps can.
    public let acceptsImages: Bool

    public init(
        bundleID: String,
        localizedName: String,
        kind: TargetKind,
        focus: FocusState = .unknown,
        acceptsImages: Bool = false
    ) {
        self.bundleID = bundleID
        self.localizedName = localizedName
        self.kind = kind
        self.focus = focus
        self.acceptsImages = acceptsImages
    }
}

public enum TargetClassifier {

    /// Terminal emulators in common use on macOS. Bundle IDs are stable across
    /// versions, unlike process names.
    public static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "dev.warp.Warp-Stable",
        "co.zeit.hyper",
        "io.alacritty",
        "com.tabby.Tabby",
    ]

    public static let editorBundleIDs: Set<String> = [
        "com.microsoft.VSCode",
        "com.apple.dt.Xcode",
        "com.sublimetext.4",
        "com.jetbrains.intellij",
        "dev.zed.Zed",
        "com.apple.TextEdit",
    ]

    public static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
    ]

    public static func kind(for bundleID: String) -> TargetKind {
        if terminalBundleIDs.contains(bundleID) { return .terminal }
        if editorBundleIDs.contains(bundleID) { return .editor }
        if browserBundleIDs.contains(bundleID) { return .browser }
        return .other
    }
}

/// Turns a raw accessibility reading into a `FocusState`.
///
/// The decision lives here rather than in `TargetInspector` so it can be tested
/// without a running app: the inspector's job is to gather `role` and
/// `valueIsSettable` from the AX API, and this decides what they mean.
public enum FocusClassifier {

    /// Roles that denote a text-entry element. Spelled as literals because this
    /// module is Foundation-only; these are the values of `kAXTextFieldRole`,
    /// `kAXTextAreaRole`, and `kAXComboBoxRole`.
    public static let textRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
    ]

    /// - Parameters:
    ///   - role: `AXRole` of the focused element, or nil if it could not be read.
    ///   - valueIsSettable: whether `AXValue` is writable on that element.
    ///   - kind: what sort of app the element belongs to.
    public static func state(
        role: String?,
        valueIsSettable: Bool,
        kind: TargetKind
    ) -> FocusState {
        guard let role else { return .unknown }

        if textRoles.contains(role) {
            // A terminal's AXValue is its screen buffer: readable, never
            // assignable. Settability therefore says nothing about whether it
            // accepts input — it always does, by sending keystrokes to the pty.
            //
            // Terminal.app reports exactly this shape (AXTextArea, AXValue not
            // settable). Running it through the general rule below produced
            // .nonEditable, which Preflight raises as blocking, which meant
            // every paste into a terminal was refused. See
            // docs/open-questions.md.
            if kind == .terminal { return .editableText }

            return valueIsSettable ? .editableText : .nonEditable
        }

        // Web views and Electron apps frequently report AXGroup or AXWebArea for
        // a focused contenteditable. Settability of AXValue is the more reliable
        // signal there than role.
        return valueIsSettable ? .editableText : .nonEditable
    }
}
