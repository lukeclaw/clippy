import Foundation

/// What `History.record` did with a clip. Returned rather than logged so the
/// capture path can be tested without inspecting the list afterwards.
public enum RecordOutcome: Equatable, Sendable {
    /// Marker said drop, the payload was empty, or Clippy itself was the source.
    case ignored
    /// Identical to the item already at the top. Deliberately not a reorder —
    /// copying the same thing twice should not churn the list.
    case unchanged
    /// Matched an older item, which moved back to the top.
    case promoted(UUID)
    case inserted(UUID)
}

/// The clipboard history: the list the panel renders, and the thing the capture
/// path writes into.
///
/// Persistable items are written through to a `HistoryStore`. Concealed items
/// live here and nowhere else — the retention check happens before the store is
/// ever called, so "no credential reaches disk" is enforced in one place rather
/// than trusted to every caller.
///
/// Main-thread only. The pasteboard timer and the panel both run there, and a
/// personal tool with a 200ms poll has no reason to introduce a queue.
public final class History {

    public private(set) var items: [ClipItem] = []

    private let store: HistoryStore?
    private let ownBundleID: String?
    private let maxBlobBytes: Int

    /// - Parameters:
    ///   - store: nil runs the history purely in memory, which is what the tests
    ///     and the `watch` harness use.
    ///   - ownBundleID: clips whose source is Clippy are never recorded, to
    ///     prevent feedback loops through our own pasteboard restore.
    ///   - maxBlobBytes: the image budget. Injectable so tests can trip eviction
    ///     with a few kilobytes instead of half a gigabyte.
    public init(
        store: HistoryStore? = nil,
        ownBundleID: String? = nil,
        maxBlobBytes: Int = HistoryLimits.maxBlobBytes
    ) {
        self.store = store
        self.ownBundleID = ownBundleID
        self.maxBlobBytes = maxBlobBytes
    }

    /// Load persisted history. Concealed items are simply gone after a restart;
    /// that is correct behaviour, not a bug.
    public func loadFromStore() {
        guard let store else { return }
        items = (try? store.load()) ?? []
    }

    // MARK: - Capture

    @discardableResult
    public func record(_ item: ClipItem, now: Date = Date()) -> RecordOutcome {
        guard item.retention != .drop else { return .ignored }
        guard item.byteCount > 0 else { return .ignored }
        if let ownBundleID, item.sourceBundleID == ownBundleID { return .ignored }

        // Dropped outright rather than downgraded to memory-only: a password
        // manager's clipboard has no value in a history, and not recording it is
        // the only handling with no failure mode.
        if SensitiveSources.isSensitive(item.sourceBundleID) { return .ignored }

        // Identical to the most recent item: do nothing at all. Not a reorder,
        // not a timestamp bump.
        if let first = items.first, first.payload == item.payload {
            return .unchanged
        }

        // Identical to something older: promote it rather than creating a
        // second row for the same content.
        if let index = items.firstIndex(where: { $0.payload == item.payload }) {
            var existing = items.remove(at: index)
            existing.lastUsedAt = now
            items.insert(existing, at: 0)
            if existing.retention.isPersistable {
                try? store?.touch(id: existing.id, at: now)
            }
            return .promoted(existing.id)
        }

        items.insert(item, at: 0)
        if item.retention.isPersistable {
            try? store?.upsert(item)
            // Eviction reports what it removed so the list here stays in step.
            // Without this an image evicted under the blob budget would keep
            // showing in the panel until the next launch, then vanish.
            if let removed = try? store?.evict(maxBlobBytes: maxBlobBytes), !removed.isEmpty {
                let gone = Set(removed)
                items.removeAll { gone.contains($0.id) }
            }
        }
        trimToLimit()
        return .inserted(item.id)
    }

    // MARK: - Paste log

    /// Record that a clip was pasted. See `PasteEvent` for why concealed clips
    /// are excluded rather than logged without their content.
    public func recordPaste(
        item: ClipItem,
        target: Target,
        transforms: [Transform],
        outcome: PasteEventOutcome,
        at date: Date = Date()
    ) {
        guard !item.retention.shouldRedact else { return }
        guard let store else { return }

        try? store.recordPaste(PasteEvent(
            pastedAt: date,
            clipID: item.id,
            preview: item.displayPreview(maxLength: 120),
            targetBundleID: target.bundleID,
            targetKind: target.kind,
            transforms: transforms,
            outcome: outcome
        ))
    }

    public func pasteEvents(limit: Int? = nil) -> [PasteEvent] {
        guard let store else { return [] }
        return (try? store.pasteEvents(limit: limit)) ?? []
    }

    /// Called when an item is pasted, so it returns to the top.
    public func markUsed(id: UUID, at date: Date = Date()) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: index)
        item.lastUsedAt = date
        items.insert(item, at: 0)
        if item.retention.isPersistable {
            try? store?.touch(id: id, at: date)
        }
    }

    public func delete(id: UUID) {
        items.removeAll { $0.id == id }
        try? store?.delete(id: id)
    }

    // MARK: - Expiry

    /// Drop concealed items past their TTL. The panel calls this before it
    /// renders, which is often enough for a five-minute window and avoids
    /// running a timer purely to delete things nobody is looking at.
    ///
    /// Measured from `capturedAt`, not `lastUsedAt`: the point is a hard bound on
    /// how long a credential can sit in memory, and letting repeated pastes
    /// extend that indefinitely would defeat it.
    public func purgeExpired(now: Date = Date()) {
        items.removeAll { item in
            guard case .memoryOnlyRedacted(let ttl) = item.retention else { return false }
            return now.timeIntervalSince(item.capturedAt) > ttl
        }
    }

    private func trimToLimit() {
        guard let max = HistoryLimits.maxItems, items.count > max else { return }
        items.removeLast(items.count - max)
    }

    // MARK: - Search

    public func search(_ query: String) -> [ClipItem] {
        HistorySearch.filter(items, query: query)
    }
}

/// Substring match, case-insensitive. Deliberately not fuzzy to begin with:
/// substring is predictable — you can always tell why something matched — and
/// fuzzy matching mostly earns its keep on far larger corpora.
public enum HistorySearch {

    public static func filter(_ items: [ClipItem], query: String) -> [ClipItem] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return items }
        return items.filter { matches($0, query: needle) }
    }

    /// How much of each clip is searched.
    ///
    /// Search cost scales with the total *volume* of stored text, not the number
    /// of clips, and history is now unbounded (D17). Measured at 20,000 clips:
    /// scanning every byte cost 323ms per keystroke; capping each clip at 2 KB
    /// brings it to 46ms.
    ///
    /// Two things this is *not*: it is not an allocation problem — precomputing
    /// lowercased keys measured identically to computing them inline — and
    /// `range(of:options:.caseInsensitive)` is four times *slower* than
    /// `lowercased().contains`, not faster.
    ///
    /// The cost is real and worth stating plainly: **text more than 2 KB into a
    /// large clip is not findable by search.** What you search for is nearly
    /// always near the start of a clip, so this trades a rare miss for a usable
    /// panel. SQLite FTS5 is the escape hatch if it starts to matter — see
    /// docs/clipboard-history.md.
    public static let searchPrefixBytes = 2048

    /// `needle` must already be lowercased.
    private static func contains(_ haystack: String, _ needle: String) -> Bool {
        // utf8.count is O(1) on a native String; Character-counting is not, and
        // would cost the same walk this is trying to avoid.
        let head = haystack.utf8.count > searchPrefixBytes
            ? String(haystack.prefix(searchPrefixBytes))
            : haystack
        return head.lowercased().contains(needle)
    }

    public static func matches(_ item: ClipItem, query: String) -> Bool {
        let needle = query.lowercased()

        if let source = item.sourceBundleID, contains(source, needle) {
            return true
        }

        // A concealed item is never searchable by content. Matching on it would
        // let anyone recover a password a character at a time by watching rows
        // appear and disappear — redaction has to hold in search, not just in
        // the row rendering.
        if item.retention.shouldRedact { return false }

        switch item.payload {
        case .image:
            // No text rendering; source app is the only handle, and that was
            // already checked above.
            return false
        case .files(let urls):
            return urls.contains { contains($0.lastPathComponent, needle) }
        case .text, .richText:
            return contains(item.payload.plainText ?? "", needle)
        }
    }
}
