import AppKit
import ClippyCore

/// Why a paste did not happen. These are real, observable conditions — not
/// guesses. Anything we cannot observe stays out of this enum.
public enum PasteFailure: Equatable {
    case accessibilityDenied
    case blocked([Finding])
    case targetVanished
    case couldNotActivateTarget
    case eventCreationFailed
    case emptyAfterTransforms
}

public enum PasteOutcome: Equatable {
    /// Keystroke was delivered. Note this means "we posted the event and the
    /// target accepted focus" — the receiving app's own handling of the paste
    /// is beyond anything we can observe, and we do not claim otherwise.
    case delivered(applied: [Transform])
    case failed(PasteFailure)
}

/// Places a clip on the pasteboard and drives ⌘V into the target.
public final class Injector {

    private let pasteboard: NSPasteboard
    private static let vKeyCode: CGKeyCode = 0x09

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// Run Preflight, apply fixes if enabled, then paste.
    ///
    /// - Parameter autoFix: when true, warning-level findings that carry a
    ///   transform are applied and reported. When false the clip goes through
    ///   untouched (the ⌥⏎ "raw" path).
    public func paste(
        _ item: ClipItem,
        into target: Target,
        autoFix: Bool = true,
        config: PreflightConfig = PreflightConfig()
    ) -> PasteOutcome {

        guard TargetInspector.isTrusted else {
            return .failed(.accessibilityDenied)
        }

        let result = Preflight.inspect(item, into: target, config: config)
        guard !result.isBlocked else {
            return .failed(.blocked(result.findings))
        }

        let applied = autoFix ? result.fixes : []
        let payload = Transforms.apply(applied, to: item.payload)

        if let text = payload.plainText, text.isEmpty, !isImage(payload) {
            return .failed(.emptyAfterTransforms)
        }

        // Snapshot what the user actually had, so we can put it back. Pasting a
        // transformed clip must not silently rewrite their clipboard.
        let restore = snapshotPasteboard()

        guard write(payload) else {
            return .failed(.eventCreationFailed)
        }

        guard let app = NSRunningApplication(processIdentifier: pidFor(target)) else {
            restorePasteboard(restore)
            return .failed(.targetVanished)
        }

        guard app.activate(options: []) else {
            restorePasteboard(restore)
            return .failed(.couldNotActivateTarget)
        }

        guard postCommandV() else {
            restorePasteboard(restore)
            return .failed(.eventCreationFailed)
        }

        // Give the target a moment to actually read the pasteboard before we
        // put the original back. There is no completion signal to wait on —
        // this delay is the pragmatic compromise every manager makes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.restorePasteboard(restore)
        }

        return .delivered(applied: applied)
    }

    // MARK: - Keystroke

    private func postCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: false)
        else { return false }

        down.flags = .maskCommand
        up.flags = .maskCommand

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - Pasteboard I/O

    private func write(_ payload: ClipPayload) -> Bool {
        pasteboard.clearContents()
        switch payload {
        case .text(let s):
            return pasteboard.setString(s, forType: .string)
        case .richText(let rtf, let fallback):
            let ok = pasteboard.setData(rtf, forType: .rtf)
            return pasteboard.setString(fallback, forType: .string) && ok
        case .image(let data, let uti):
            return pasteboard.setData(data, forType: NSPasteboard.PasteboardType(uti))
        case .files(let urls):
            return pasteboard.writeObjects(urls as [NSURL])
        }
    }

    private func snapshotPasteboard() -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    /// Restore the user's original clip, tagged as `RestoredType` so our own
    /// monitor recognises it and does not record a duplicate. Without this
    /// marker the restore would look like a fresh copy and every paste would
    /// grow the history by one phantom entry.
    private func restorePasteboard(_ items: [NSPasteboardItem]) {
        guard !items.isEmpty else { return }
        for item in items {
            item.setData(Data(), forType: NSPasteboard.PasteboardType(MarkerType.restored.rawValue))
        }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
    }

    private func isImage(_ payload: ClipPayload) -> Bool {
        if case .image = payload { return true }
        return false
    }

    private func pidFor(_ target: Target) -> pid_t {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == target.bundleID }?
            .processIdentifier ?? -1
    }
}

public extension PasteFailure {
    /// The sentence shown to the user. Same standard as Preflight reasons: name
    /// the cause and the remedy, never "an error occurred".
    var reason: String {
        switch self {
        case .accessibilityDenied:
            return "Clippy needs Accessibility permission to paste — grant it in System Settings → Privacy & Security → Accessibility"
        case .blocked(let findings):
            return findings.first(where: { $0.severity == .blocking })?.reason
                ?? "The paste was blocked"
        case .targetVanished:
            return "The target application quit before the paste could be delivered"
        case .couldNotActivateTarget:
            return "The target application refused to come to the front"
        case .eventCreationFailed:
            return "macOS refused to create the keystroke event"
        case .emptyAfterTransforms:
            return "Nothing left to paste once the clip was cleaned up"
        }
    }
}
