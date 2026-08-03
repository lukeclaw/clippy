import XCTest
@testable import ClippyCore

final class PasteLogTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clippy-log-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() throws -> HistoryStore {
        try HistoryStore(directory: directory)
    }

    private func terminal() -> Target {
        Target(bundleID: "com.apple.Terminal", localizedName: "Terminal", kind: .terminal)
    }

    // MARK: - Round trip

    func testPasteEventSurvivesAReopen() throws {
        let clipID = UUID()
        try makeStore().recordPaste(PasteEvent(
            clipID: clipID,
            preview: "npm install",
            targetBundleID: "com.apple.Terminal",
            targetKind: .terminal,
            transforms: [.stripTrailingNewlines],
            outcome: .delivered
        ))

        let loaded = try makeStore().pasteEvents()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].clipID, clipID)
        XCTAssertEqual(loaded[0].preview, "npm install")
        XCTAssertEqual(loaded[0].targetKind, .terminal)
        XCTAssertEqual(loaded[0].transforms, [.stripTrailingNewlines])
        XCTAssertEqual(loaded[0].outcome, .delivered)
    }

    func testFailureReasonRoundTrips() throws {
        try makeStore().recordPaste(PasteEvent(
            clipID: UUID(),
            preview: "x",
            targetBundleID: "com.apple.Terminal",
            targetKind: .terminal,
            outcome: .failed(reason: "macOS refused to create the keystroke event")
        ))

        let loaded = try makeStore().pasteEvents()
        XCTAssertEqual(loaded[0].outcome,
                       .failed(reason: "macOS refused to create the keystroke event"))
        XCTAssertFalse(loaded[0].outcome.succeeded)
    }

    /// `truncate` carries an associated value, so its encoding is the one that
    /// can actually lose information.
    func testTransformsRoundTripIncludingAssociatedValues() throws {
        let transforms: [Transform] = [
            .normalizeLineEndings, .coerceToPlainText, .truncate(to: 524_288),
        ]
        try makeStore().recordPaste(PasteEvent(
            clipID: UUID(), preview: "x",
            targetBundleID: "com.apple.Terminal", targetKind: .terminal,
            transforms: transforms, outcome: .delivered
        ))

        XCTAssertEqual(try makeStore().pasteEvents()[0].transforms, transforms)
    }

    func testStorageKeysRoundTripForEveryTransform() {
        let all: [Transform] = [
            .stripTrailingNewlines, .normalizeLineEndings,
            .coerceToPlainText, .truncate(to: 42),
        ]
        for t in all {
            XCTAssertEqual(Transform(storageKey: t.storageKey), t)
        }
        XCTAssertNil(Transform(storageKey: "nonsense"))
        XCTAssertNil(Transform(storageKey: "truncate:notanumber"))
    }

    func testEventsAreNewestFirst() throws {
        let store = try makeStore()
        let now = Date()
        for (i, name) in ["old", "mid", "new"].enumerated() {
            try store.recordPaste(PasteEvent(
                pastedAt: now.addingTimeInterval(Double(i)),
                clipID: UUID(), preview: name,
                targetBundleID: "com.apple.Terminal", targetKind: .terminal,
                outcome: .delivered
            ))
        }
        XCTAssertEqual(try store.pasteEvents().map(\.preview), ["new", "mid", "old"])
    }

    func testEventsCanBeFilteredToOneClip() throws {
        let store = try makeStore()
        let wanted = UUID()
        try store.recordPaste(PasteEvent(clipID: wanted, preview: "a",
            targetBundleID: "x", targetKind: .other, outcome: .delivered))
        try store.recordPaste(PasteEvent(clipID: UUID(), preview: "b",
            targetBundleID: "x", targetKind: .other, outcome: .delivered))

        XCTAssertEqual(try store.pasteEvents(clipID: wanted).map(\.preview), ["a"])
    }

    // MARK: - Through History

    func testHistoryLogsADeliveredPaste() throws {
        let history = History(store: try makeStore())
        let item = ClipItem(payload: .text("npm install"))
        history.record(item)
        history.recordPaste(item: item, target: terminal(),
                            transforms: [.stripTrailingNewlines], outcome: .delivered)

        let events = history.pasteEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].clipID, item.id)
    }

    /// "Pasted into Slack at 14:32" is still a record that a credential went
    /// somewhere, so concealed clips are excluded from the log entirely.
    func testConcealedPastesAreNeverLogged() throws {
        let store = try makeStore()
        let history = History(store: store)
        let secret = ClipItem(payload: .text("hunter2"), markers: [.concealed])
        history.record(secret)
        history.recordPaste(item: secret, target: terminal(),
                            transforms: [], outcome: .delivered)

        XCTAssertTrue(history.pasteEvents().isEmpty)

        let db = try String(contentsOf: directory.appendingPathComponent("history.db"),
                            encoding: .isoLatin1)
        XCTAssertFalse(db.contains("hunter2"))
    }

    /// The event denormalises its preview so it stays readable after the clip
    /// it came from is gone.
    func testEventOutlivesItsClipAndStaysReadable() throws {
        let store = try makeStore()
        let history = History(store: store)
        let item = ClipItem(payload: .text("a screenshot caption"))
        history.record(item)
        history.recordPaste(item: item, target: terminal(),
                            transforms: [], outcome: .delivered)

        history.delete(id: item.id)

        XCTAssertTrue(try store.load().isEmpty)
        let events = try store.pasteEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].preview, "a screenshot caption")
    }

    func testEvictionLeavesPasteEventsAlone() throws {
        let store = try makeStore()
        let item = ClipItem(payload: .text("kept"))
        try store.upsert(item)
        try store.recordPaste(PasteEvent(clipID: item.id, preview: "kept",
            targetBundleID: "x", targetKind: .other, outcome: .delivered))

        try store.evict(maxItems: 0, maxBlobBytes: 0)

        XCTAssertTrue(try store.load().isEmpty)
        XCTAssertEqual(try store.pasteEvents().count, 1)
    }
}
