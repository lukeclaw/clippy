import AppKit
import ClippyCore
import SwiftUI

/// One rendered row. Everything the view needs is precomputed here so the view
/// stays a pure function of the model — including the preview string, which
/// comes from `ClipItem.displayPreview()` so redaction cannot be forgotten.
struct PanelRow: Identifiable {
    let id: UUID
    let item: ClipItem
    let preview: String
    let detail: String
    let badge: String?
    let isRedacted: Bool
}

/// State behind the panel. Owns the query, the filtered rows, and the selection.
///
/// The paste target is captured once, when the panel opens, and held for the
/// lifetime of the popup — see the hard constraint in docs/ux.md.
final class PanelModel: ObservableObject {

    @Published var query = "" { didSet { reload() } }
    @Published private(set) var rows: [PanelRow] = []
    @Published var selection = 0
    @Published var message: String?

    private(set) var target: Target?
    private let history: History

    /// Set by `PanelController`. Fired when a row is activated by mouse, so the
    /// view never has to know how a paste is performed.
    var onActivate: (() -> Void)?

    init(history: History) {
        self.history = history
    }

    var selectedItem: ClipItem? {
        guard rows.indices.contains(selection) else { return nil }
        return rows[selection].item
    }

    /// Called by the controller immediately before presenting, with the target
    /// it captured while the real app still had focus.
    func prepare(target: Target?) {
        self.target = target
        self.message = nil
        self.query = ""
        self.selection = 0
        reload()
    }

    /// Most rows the panel will build at once.
    ///
    /// History is unbounded for text (D17), and every row costs a `Preflight`
    /// pass for its badge. Building all of them made opening the panel scale with
    /// total history rather than with what is on screen. Nobody scrolls twenty
    /// thousand rows — they search — so the list is capped and says so.
    static let maxRows = 500

    private(set) var truncatedCount = 0

    func reload() {
        history.purgeExpired()
        let matches = history.search(query)

        truncatedCount = max(0, matches.count - Self.maxRows)
        rows = matches.prefix(Self.maxRows).map { row(for: $0) }
        selection = min(selection, max(0, rows.count - 1))
    }

    private func row(for item: ClipItem) -> PanelRow {
        PanelRow(
            id: item.id,
            item: item,
            preview: item.displayPreview(maxLength: 90),
            detail: detail(for: item),
            badge: badge(for: item),
            isRedacted: item.retention.shouldRedact
        )
    }

    private func detail(for item: ClipItem) -> String {
        var parts: [String] = []
        if let source = item.sourceBundleID {
            parts.append(appName(for: source))
        }
        parts.append(Self.relative.localizedString(for: item.lastUsedAt, relativeTo: Date()))
        if item.byteCount > 1024 {
            parts.append(ByteCountFormatter.string(
                fromByteCount: Int64(item.byteCount), countStyle: .file
            ))
        }
        return parts.joined(separator: " · ")
    }

    /// Badges are target-relative and recomputed on every open — a trailing
    /// newline earns one when pasting into a terminal and nothing at all when
    /// pasting into an editor. They cannot be computed at capture time.
    private func badge(for item: ClipItem) -> String? {
        guard let target else { return nil }
        let result = Preflight.inspect(item, into: target)

        if result.isBlocked { return "blocked" }

        if let fix = result.fixes.first {
            switch fix {
            case .stripTrailingNewlines: return "newline"
            case .normalizeLineEndings: return "CRLF"
            case .coerceToPlainText: return "plain"
            case .truncate: return "large"
            }
        }

        // The oversize note carries no fix below the truncation ceiling, but it
        // is still the one advisory worth a badge.
        if result.findings.contains(where: { $0.code == .oversizeForTerminal }) {
            return "large"
        }
        return nil
    }

    /// The footer line: what is about to happen, in one sentence.
    var footer: String {
        guard let target else { return "No target" }
        guard let item = selectedItem else { return target.localizedName }

        let result = Preflight.inspect(item, into: target)
        if let summary = result.footerSummary {
            return "\(target.localizedName) — \(summary)"
        }
        return "Paste into \(target.localizedName)"
    }

    private func appName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    // MARK: - Selection

    func select(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        selection = index
    }

    func activate(_ index: Int) {
        select(index)
        onActivate?()
    }

    func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        selection = max(0, min(rows.count - 1, selection + delta))
    }

    func appendToQuery(_ s: String) {
        query.append(s)
        selection = 0
    }

    func backspaceQuery() {
        guard !query.isEmpty else { return }
        query.removeLast()
        selection = 0
    }

    func deleteSelected() {
        guard let item = selectedItem else { return }
        history.delete(id: item.id)
        reload()
    }

    func markUsed(_ item: ClipItem) {
        history.markUsed(id: item.id)
    }
}
