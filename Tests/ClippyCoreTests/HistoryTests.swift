import XCTest
@testable import ClippyCore

final class HistoryTests: XCTestCase {

    private func clip(
        _ text: String,
        source: String? = "com.apple.Safari",
        markers: Set<MarkerType> = [],
        at: Date = Date()
    ) -> ClipItem {
        ClipItem(capturedAt: at, payload: .text(text), sourceBundleID: source, markers: markers)
    }

    // MARK: - Dedup

    /// Copying the same thing twice should not churn the list — no reorder, no
    /// timestamp bump, no second row.
    func testIdenticalToMostRecentIsUnchanged() {
        let h = History()
        h.record(clip("hello"))
        let outcome = h.record(clip("hello"))
        XCTAssertEqual(outcome, .unchanged)
        XCTAssertEqual(h.items.count, 1)
    }

    func testIdenticalToOlderItemPromotesRatherThanDuplicates() {
        let h = History()
        h.record(clip("first"))
        h.record(clip("second"))
        XCTAssertEqual(h.items.count, 2)

        let outcome = h.record(clip("first"))
        guard case .promoted = outcome else {
            return XCTFail("expected promotion, got \(outcome)")
        }
        XCTAssertEqual(h.items.count, 2, "must not create a second row")
        XCTAssertEqual(h.items.first?.payload.plainText, "first")
    }

    func testDistinctContentInserts() {
        let h = History()
        h.record(clip("a"))
        h.record(clip("b"))
        XCTAssertEqual(h.items.map { $0.payload.plainText }, ["b", "a"])
    }

    /// Differing RTF with identical plain text is a real difference — the
    /// formatting is content.
    func testSameFallbackDifferentRTFAreDistinctItems() {
        let h = History()
        h.record(ClipItem(payload: .richText(rtf: Data([0x01]), plainFallback: "x")))
        h.record(ClipItem(payload: .richText(rtf: Data([0x02]), plainFallback: "x")))
        XCTAssertEqual(h.items.count, 2)
    }

    // MARK: - What is never recorded

    func testTransientAndRestoredAreDropped() {
        let h = History()
        XCTAssertEqual(h.record(clip("t", markers: [.transient])), .ignored)
        XCTAssertEqual(h.record(clip("r", markers: [.restored])), .ignored)
        XCTAssertTrue(h.items.isEmpty)
    }

    func testEmptyPayloadIsDropped() {
        XCTAssertEqual(History().record(clip("")), .ignored)
    }

    /// Prevents a feedback loop through our own pasteboard restore.
    func testClippyIsNeverItsOwnSource() {
        let h = History(ownBundleID: "com.clippy.app")
        XCTAssertEqual(h.record(clip("x", source: "com.clippy.app")), .ignored)
        XCTAssertTrue(h.items.isEmpty)
    }

    // MARK: - Concealed items

    func testConcealedItemIsKeptButRedacted() {
        let h = History()
        h.record(clip("hunter2", markers: [.concealed]))
        XCTAssertEqual(h.items.count, 1)
        XCTAssertFalse(h.items[0].displayPreview().contains("hunter2"))
    }

    func testConcealedItemExpiresAfterTTL() {
        let h = History()
        let old = Date().addingTimeInterval(-(RetentionPolicy.concealedTTL + 1))
        h.record(clip("hunter2", markers: [.concealed], at: old), now: old)
        XCTAssertEqual(h.items.count, 1)

        h.purgeExpired()
        XCTAssertTrue(h.items.isEmpty, "concealed item should not outlive its TTL")
    }

    func testOrdinaryItemDoesNotExpire() {
        let h = History()
        let old = Date().addingTimeInterval(-86_400)
        h.record(clip("ordinary", at: old), now: old)
        h.purgeExpired()
        XCTAssertEqual(h.items.count, 1)
    }

    // MARK: - Ordering

    func testPastingAnItemBringsItToTheTop() {
        let h = History()
        h.record(clip("first"))
        h.record(clip("second"))
        let bottom = h.items[1]

        h.markUsed(id: bottom.id)
        XCTAssertEqual(h.items.first?.id, bottom.id)
    }

    func testDeleteRemovesItem() {
        let h = History()
        h.record(clip("gone"))
        h.delete(id: h.items[0].id)
        XCTAssertTrue(h.items.isEmpty)
    }

    // MARK: - Search

    func testSearchIsCaseInsensitiveSubstring() {
        let h = History()
        h.record(clip("Install Xcode"))
        h.record(clip("brew update"))
        XCTAssertEqual(h.search("xcode").count, 1)
        XCTAssertEqual(h.search("INSTALL").count, 1)
    }

    func testEmptyQueryReturnsEverything() {
        let h = History()
        h.record(clip("a"))
        h.record(clip("b"))
        XCTAssertEqual(h.search("   ").count, 2)
    }

    func testSearchMatchesSourceApp() {
        let h = History()
        h.record(clip("nothing relevant", source: "com.apple.Safari"))
        XCTAssertEqual(h.search("safari").count, 1)
    }

    func testSearchMatchesFileName() {
        let h = History()
        h.record(ClipItem(payload: .files([URL(fileURLWithPath: "/tmp/report.pdf")])))
        XCTAssertEqual(h.search("report").count, 1)
    }

    /// Searching concealed content would let a password be recovered a character
    /// at a time by watching rows appear and disappear.
    func testConcealedContentIsNotSearchable() {
        let h = History()
        h.record(clip("hunter2", source: nil, markers: [.concealed]))
        XCTAssertTrue(h.search("hunter").isEmpty)
    }

    func testImagesAreNotMatchedByArbitraryText() {
        let h = History()
        h.record(ClipItem(payload: .image(data: Data([0x89]), uti: "public.png"), sourceBundleID: nil))
        XCTAssertTrue(h.search("anything").isEmpty)
    }

    /// The search bound is a real limitation, so it is pinned rather than left
    /// to be discovered. See `HistorySearch.searchPrefixBytes`.
    func testSearchFindsTextWithinThePrefixBound() {
        let h = History()
        let padding = String(repeating: "x", count: 100)
        h.record(ClipItem(payload: .text(padding + "needle" + padding)))
        XCTAssertEqual(h.search("needle").count, 1)
    }

    func testSearchDoesNotFindTextPastThePrefixBound() {
        let h = History()
        let padding = String(repeating: "x", count: HistorySearch.searchPrefixBytes + 100)
        h.record(ClipItem(payload: .text(padding + "needle")))
        XCTAssertTrue(h.search("needle").isEmpty,
                      "documented trade-off: deep text is not searchable")
    }
}
