import Foundation

/// Mutations Preflight can apply to a clip before it reaches the target.
///
/// Every case must be losslessly describable to the user in a short phrase —
/// if we cannot explain a transform in the footer, we have no business applying
/// it automatically.
public enum Transform: Equatable, Sendable {
    case stripTrailingNewlines
    case normalizeLineEndings
    case coerceToPlainText
    case truncate(to: Int)

    /// Stable string form for the paste log. Deliberately not the `label` —
    /// that is prose meant for a human and is free to change wording, and a
    /// stored value has to survive rewording.
    public var storageKey: String {
        switch self {
        case .stripTrailingNewlines: return "stripTrailingNewlines"
        case .normalizeLineEndings: return "normalizeLineEndings"
        case .coerceToPlainText: return "coerceToPlainText"
        case .truncate(let n): return "truncate:\(n)"
        }
    }

    public init?(storageKey: String) {
        switch storageKey {
        case "stripTrailingNewlines": self = .stripTrailingNewlines
        case "normalizeLineEndings": self = .normalizeLineEndings
        case "coerceToPlainText": self = .coerceToPlainText
        default:
            guard storageKey.hasPrefix("truncate:"),
                  let n = Int(storageKey.dropFirst("truncate:".count))
            else { return nil }
            self = .truncate(to: n)
        }
    }

    /// User-facing description, present tense, for the "what I'm about to do"
    /// line in the panel footer.
    public var label: String {
        switch self {
        case .stripTrailingNewlines: return "stripping trailing newline"
        case .normalizeLineEndings: return "converting CRLF to LF"
        case .coerceToPlainText: return "pasting as plain text"
        case .truncate(let n):
            let size = ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
            return "truncating to \(size)"
        }
    }
}

public enum Transforms {

    /// Remove trailing newlines (and any trailing carriage returns) while
    /// leaving interior structure untouched. Deliberately does not trim other
    /// whitespace: leading indentation is meaningful in code, and trailing
    /// spaces are meaningful in Markdown.
    ///
    /// Works in unicode scalars, not characters: Swift treats CRLF as a single
    /// grapheme cluster that compares equal to neither "\n" nor "\r", so a
    /// character-level scan silently skips exactly the Windows-flavoured text
    /// this is here to clean up.
    public static func stripTrailingNewlines(_ s: String) -> String {
        var out = s.unicodeScalars
        while let last = out.last, isLineBreak(last) {
            out.removeLast()
        }
        return String(out)
    }

    /// Normalise CRLF and lone CR to LF. Text copied from Windows tools and some
    /// web pages carries CRLF, which many TUIs render as a stray ^M.
    public static func normalizeLineEndings(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n")
         .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Truncate to a byte budget without splitting a UTF-8 scalar.
    public static func truncate(_ s: String, toBytes limit: Int) -> String {
        guard s.utf8.count > limit else { return s }
        var out = ""
        var used = 0
        for ch in s {
            let w = String(ch).utf8.count
            if used + w > limit { break }
            out.append(ch)
            used += w
        }
        return out
    }

    public static func hasTrailingNewline(_ s: String) -> Bool {
        guard let last = s.unicodeScalars.last else { return false }
        return isLineBreak(last)
    }

    /// True for CRLF and for a lone CR — both render as a stray ^M in a TUI and
    /// both are fixed by the same transform.
    public static func containsCRLF(_ s: String) -> Bool {
        s.unicodeScalars.contains("\r")
    }

    public static func isMultiline(_ s: String) -> Bool {
        stripTrailingNewlines(s).unicodeScalars.contains(where: isLineBreak)
    }

    private static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\n" || scalar == "\r"
    }

    /// Apply an ordered list of transforms to a payload. Transforms that do not
    /// apply to the payload kind are no-ops rather than errors, so callers can
    /// pass the full finding set without filtering.
    public static func apply(_ transforms: [Transform], to payload: ClipPayload) -> ClipPayload {
        var current = payload
        for t in transforms {
            current = apply(t, to: current)
        }
        return current
    }

    public static func apply(_ transform: Transform, to payload: ClipPayload) -> ClipPayload {
        switch transform {
        case .coerceToPlainText:
            guard let plain = payload.plainText else { return payload }
            return .text(plain)

        case .stripTrailingNewlines:
            return mapText(payload) { stripTrailingNewlines($0) }

        case .normalizeLineEndings:
            return mapText(payload) { normalizeLineEndings($0) }

        case .truncate(let n):
            return mapText(payload) { truncate($0, toBytes: n) }
        }
    }

    /// Text transforms coerce rich text to plain: once we are rewriting the
    /// characters, preserving RTF alongside would let the two representations
    /// disagree, and the target would silently pick whichever it prefers.
    private static func mapText(_ payload: ClipPayload, _ f: (String) -> String) -> ClipPayload {
        switch payload {
        case .text(let s):
            return .text(f(s))
        case .richText(_, let fallback):
            return .text(f(fallback))
        case .image, .files:
            return payload
        }
    }
}
