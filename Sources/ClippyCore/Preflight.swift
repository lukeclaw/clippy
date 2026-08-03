import Foundation

/// How much a finding should interrupt the user.
public enum Severity: Int, Comparable, Sendable {
    /// The paste cannot succeed. Do not fire the keystroke; explain instead.
    case blocking = 3
    /// The paste will land but probably not do what was intended. Show it, and
    /// auto-fix if a fix exists.
    case warning = 2
    /// Worth stating in the footer, no action needed.
    case info = 1

    public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
}

/// Stable identifiers so the UI, logs, and tests can refer to a finding without
/// matching on prose.
/// Deliberately short. Findings that could not be acted on, or that fired on
/// nearly every paste, were removed rather than demoted — see the note on
/// `Preflight` below.
public enum FindingCode: String, Sendable {
    case targetRejectsImages
    case trailingNewlineInTUI
    case crlfLineEndings
    case oversizeForTerminal
    case richTextIntoPlainTarget
}

/// One reason a paste may not do what the user expects.
public struct Finding: Equatable, Sendable {
    public let code: FindingCode
    public let severity: Severity
    /// User-facing explanation. Says what will happen and why — never "an error
    /// occurred". This string is the entire point of the product.
    public let reason: String
    /// The mutation that would resolve it, if one exists.
    public let fix: Transform?

    public init(code: FindingCode, severity: Severity, reason: String, fix: Transform? = nil) {
        self.code = code
        self.severity = severity
        self.reason = reason
        self.fix = fix
    }
}

/// The result of inspecting a clip against a target.
public struct PreflightResult: Equatable, Sendable {
    public let findings: [Finding]

    /// True when no keystroke should be sent.
    public var isBlocked: Bool {
        findings.contains { $0.severity == .blocking }
    }

    /// Transforms to apply, in declaration order, when auto-fix is enabled.
    public var fixes: [Transform] {
        findings.compactMap(\.fix)
    }

    /// The single line the panel footer shows. Blocking reasons win; otherwise
    /// we describe what we are about to change, then anything advisory.
    ///
    /// Findings without a fix are included: now that only the useful ones
    /// survive, every finding Preflight produces reaches the user.
    public var footerSummary: String? {
        if let blocker = findings.first(where: { $0.severity == .blocking }) {
            return blocker.reason
        }
        let parts = fixes.map(\.label)
            + findings.filter { $0.fix == nil }.map(\.reason)
        guard let first = parts.first else { return nil }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + parts.dropFirst())
            .joined(separator: ", ")
    }
}

public struct PreflightConfig: Sendable {
    /// Byte count above which a paste into a terminal is worth warning about.
    /// Terminals read pasted input in chunks through a pty; very large payloads
    /// are slow and some TUIs drop the tail.
    public var terminalSizeWarning: Int = 64 * 1024

    /// Hard ceiling — above this we truncate rather than warn.
    public var terminalSizeCeiling: Int = 512 * 1024

    public init() {}
}

/// Decides what will go wrong with a paste, before it happens.
///
/// Every rule here is target-relative. The same clip produces different findings
/// depending on where it is headed, which is the reason this cannot be computed
/// once at capture time and cached.
///
/// **Everything Preflight produces is shown to the user.** Four findings were
/// deleted rather than left computed-and-hidden:
///
/// - The three focus states. Once the probe stopped being allowed to block
///   (D15), they fired on nearly every app on the machine — a permanent "could
///   not confirm a text field" disclaimer is not information.
/// - Concealed content. The panel already shows a lock glyph on the row and
///   "held in memory only" in the preview, closer to where the user is looking.
/// - Multi-line into a terminal. D7 argues it should never be surfaced, because
///   warning on every multi-line paste trains the user to ignore the footer — and
///   a finding that must never be shown is dead code.
///
/// If a rule cannot be acted on, it does not belong here.
public enum Preflight {

    public static func inspect(
        _ item: ClipItem,
        into target: Target,
        config: PreflightConfig = PreflightConfig()
    ) -> PreflightResult {
        var findings: [Finding] = []
        findings.append(contentsOf: payloadFindings(item, target, config))
        findings.append(contentsOf: textFindings(item, target, config))
        return PreflightResult(findings: findings.sorted { $0.severity > $1.severity })
    }

    // MARK: - Payload shape

    private static func payloadFindings(
        _ item: ClipItem,
        _ target: Target,
        _ config: PreflightConfig
    ) -> [Finding] {
        var findings: [Finding] = []

        if case .image = item.payload, !target.acceptsImages {
            findings.append(Finding(
                code: .targetRejectsImages,
                severity: .blocking,
                reason: target.kind == .terminal
                    ? "\(target.localizedName) is a terminal and cannot receive images"
                    : "\(target.localizedName) does not accept image data"
            ))
        }

        if case .richText = item.payload, target.kind == .terminal || target.kind == .editor {
            findings.append(Finding(
                code: .richTextIntoPlainTarget,
                severity: .warning,
                reason: "Clip carries formatting that \(target.localizedName) will discard",
                fix: .coerceToPlainText
            ))
        }

        return findings
    }

    // MARK: - Text content

    private static func textFindings(
        _ item: ClipItem,
        _ target: Target,
        _ config: PreflightConfig
    ) -> [Finding] {
        guard let text = item.payload.plainText, !text.isEmpty else { return [] }
        var findings: [Finding] = []

        // The headline rule. A trailing newline is invisible in every UI that
        // shows you your clipboard, harmless in an editor, and in a TUI prompt
        // it submits the input before you have finished composing it. Code
        // copied out of a browser almost always carries one.
        if target.kind == .terminal, Transforms.hasTrailingNewline(text) {
            findings.append(Finding(
                code: .trailingNewlineInTUI,
                severity: .warning,
                reason: "Trailing newline would submit the prompt early",
                fix: .stripTrailingNewlines
            ))
        }

        if Transforms.containsCRLF(text), target.kind == .terminal || target.kind == .editor {
            findings.append(Finding(
                code: .crlfLineEndings,
                severity: .warning,
                reason: "Windows line endings would appear as stray ^M",
                fix: .normalizeLineEndings
            ))
        }

        if target.kind == .terminal {
            let bytes = text.utf8.count
            if bytes > config.terminalSizeCeiling {
                findings.append(Finding(
                    code: .oversizeForTerminal,
                    severity: .warning,
                    reason: "\(byteLabel(bytes)) is past what \(target.localizedName) will reliably read",
                    fix: .truncate(to: config.terminalSizeCeiling)
                ))
            } else if bytes > config.terminalSizeWarning {
                findings.append(Finding(
                    code: .oversizeForTerminal,
                    severity: .info,
                    reason: "\(byteLabel(bytes)) may paste slowly"
                ))
            }
        }

        return findings
    }

    private static func byteLabel(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}
