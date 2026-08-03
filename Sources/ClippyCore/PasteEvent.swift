import Foundation

public enum PasteEventOutcome: Equatable, Sendable {
    case delivered
    case failed(reason: String)

    public var succeeded: Bool { self == .delivered }
}

/// One paste, recorded after the fact.
///
/// This is a log of *actions*, not content — where a clip went, when, and what
/// was done to it on the way. It is a category of data the rest of the tool does
/// not keep, so two rules constrain it, both enforced in `History.recordPaste`:
///
/// - Concealed clips are never logged at all. Even without content, "pasted into
///   Slack at 14:32" is a record that a credential went somewhere.
/// - `preview` is denormalised rather than joined from `items`. Image clips are
///   still evicted under the blob budget, and an event that silently became
///   unreadable when its clip aged out would be worse than one that outlives it.
public struct PasteEvent: Identifiable, Equatable, Sendable {

    public let id: UUID
    public let pastedAt: Date

    /// The clip this came from. May dangle: the clip can be evicted or deleted
    /// while the event remains.
    public let clipID: UUID

    /// A copy of the clip's preview, so the event reads standalone.
    public let preview: String

    public let targetBundleID: String
    public let targetKind: TargetKind

    /// Transforms actually applied, in order. Empty for a raw paste.
    public let transforms: [Transform]

    public let outcome: PasteEventOutcome

    public init(
        id: UUID = UUID(),
        pastedAt: Date = Date(),
        clipID: UUID,
        preview: String,
        targetBundleID: String,
        targetKind: TargetKind,
        transforms: [Transform] = [],
        outcome: PasteEventOutcome
    ) {
        self.id = id
        self.pastedAt = pastedAt
        self.clipID = clipID
        self.preview = preview
        self.targetBundleID = targetBundleID
        self.targetKind = targetKind
        self.transforms = transforms
        self.outcome = outcome
    }

    /// One-line rendering for `clippy log`.
    public var summary: String {
        var parts = [targetBundleID]
        if !transforms.isEmpty {
            parts.append(transforms.map(\.label).joined(separator: ", "))
        }
        if case .failed(let reason) = outcome {
            parts.append("FAILED: \(reason)")
        }
        return parts.joined(separator: " · ")
    }
}

extension TargetKind {
    /// Stable string form for storage.
    var storageKey: String {
        switch self {
        case .terminal: return "terminal"
        case .editor: return "editor"
        case .browser: return "browser"
        case .other: return "other"
        }
    }

    init(storageKey: String) {
        switch storageKey {
        case "terminal": self = .terminal
        case "editor": self = .editor
        case "browser": self = .browser
        default: self = .other
        }
    }
}
