import XCTest
@testable import ClippyCore

final class PreflightTests: XCTestCase {

    // MARK: - Fixtures

    private func terminal(focus: FocusState = .editableText) -> Target {
        Target(
            bundleID: "com.mitchellh.ghostty",
            localizedName: "Ghostty",
            kind: .terminal,
            focus: focus,
            acceptsImages: false
        )
    }

    private func editor(focus: FocusState = .editableText) -> Target {
        Target(
            bundleID: "com.microsoft.VSCode",
            localizedName: "VS Code",
            kind: .editor,
            focus: focus,
            acceptsImages: false
        )
    }

    private func browser(focus: FocusState = .editableText) -> Target {
        Target(
            bundleID: "com.apple.Safari",
            localizedName: "Safari",
            kind: .browser,
            focus: focus,
            acceptsImages: true
        )
    }

    private func clip(_ text: String, markers: Set<MarkerType> = []) -> ClipItem {
        ClipItem(payload: .text(text), sourceBundleID: "com.apple.Safari", markers: markers)
    }

    private func codes(_ r: PreflightResult) -> Set<FindingCode> {
        Set(r.findings.map(\.code))
    }

    // MARK: - The headline rule

    func testTrailingNewlineIntoTerminalWarnsAndOffersFix() {
        let r = Preflight.inspect(clip("npm install\n"), into: terminal())
        XCTAssertTrue(codes(r).contains(.trailingNewlineInTUI))
        XCTAssertEqual(r.fixes, [.stripTrailingNewlines])
        XCTAssertFalse(r.isBlocked)
    }

    /// The realistic browser copy: CRLF line endings *and* a trailing newline.
    /// Both rules have to fire on the same clip. Neither did while the
    /// predicates scanned characters, because Swift reads the terminating CRLF
    /// as one grapheme cluster matching neither "\n" nor "\r".
    func testTrailingCRLFIntoTerminalFiresBothRules() {
        let r = Preflight.inspect(clip("npm install\r\n"), into: terminal())
        XCTAssertTrue(codes(r).contains(.trailingNewlineInTUI))
        XCTAssertTrue(codes(r).contains(.crlfLineEndings))
        XCTAssertTrue(r.fixes.contains(.stripTrailingNewlines))
        XCTAssertTrue(r.fixes.contains(.normalizeLineEndings))
    }

    /// The same clip is harmless in an editor. This is the whole argument for
    /// findings being target-relative rather than computed once at capture.
    func testTrailingNewlineIntoEditorIsNotFlagged() {
        let r = Preflight.inspect(clip("npm install\n"), into: editor())
        XCTAssertFalse(codes(r).contains(.trailingNewlineInTUI))
        XCTAssertTrue(r.fixes.isEmpty)
    }

    func testTrailingNewlineIntoBrowserIsNotFlagged() {
        let r = Preflight.inspect(clip("npm install\n"), into: browser())
        XCTAssertFalse(codes(r).contains(.trailingNewlineInTUI))
    }

    func testCleanTextIntoTerminalProducesNoFixes() {
        let r = Preflight.inspect(clip("npm install"), into: terminal())
        XCTAssertTrue(r.fixes.isEmpty)
        XCTAssertFalse(r.isBlocked)
        XCTAssertNil(r.footerSummary)
    }

    // MARK: - Focus

    /// Focus produces no findings at all any more.
    ///
    /// Measured on real apps: Zed and Firefox report AXWindow, Finder reports
    /// AXOutline, Obsidian publishes no focused element — and all of them accept
    /// a paste. Once the probe could not block (D15), a finding that fires on
    /// nearly every app was a permanent disclaimer rather than information, so it
    /// was deleted rather than left computed and hidden.
    func testFocusStateProducesNoFindingsAndNeverBlocks() {
        for focus in [FocusState.none, .nonEditable, .unknown, .editableText] {
            let r = Preflight.inspect(clip("hello"), into: terminal(focus: focus))
            XCTAssertFalse(r.isBlocked, "\(focus) must not block")
            XCTAssertTrue(r.findings.isEmpty, "\(focus) should contribute no findings")
        }
    }

    /// The reading Zed and Firefox actually produce, end to end.
    func testEditorThatPublishesNoTextFieldStillPastes() {
        let zed = Target(
            bundleID: "dev.zed.Zed",
            localizedName: "Zed",
            kind: .editor,
            focus: FocusClassifier.state(role: "AXWindow", valueIsSettable: false, kind: .editor),
            acceptsImages: false
        )
        XCTAssertFalse(Preflight.inspect(clip("hello"), into: zed).isBlocked)
    }

    /// A blocking reason outranks any transform in the footer. Uses the image
    /// case because that is now the only kind of finding that blocks — the focus
    /// probe is advisory.
    func testBlockingReasonWinsTheFooter() {
        let item = ClipItem(payload: .image(data: Data([0x89]), uti: "public.png"))
        let r = Preflight.inspect(item, into: terminal())
        XCTAssertEqual(r.footerSummary, "Ghostty is a terminal and cannot receive images")
    }

    // MARK: - Images

    func testImageIntoTerminalBlocks() {
        let item = ClipItem(payload: .image(data: Data([0x89]), uti: "public.png"))
        let r = Preflight.inspect(item, into: terminal())
        XCTAssertTrue(r.isBlocked)
        XCTAssertTrue(codes(r).contains(.targetRejectsImages))
    }

    func testImageIntoBrowserIsFine() {
        let item = ClipItem(payload: .image(data: Data([0x89]), uti: "public.png"))
        let r = Preflight.inspect(item, into: browser())
        XCTAssertFalse(r.isBlocked)
    }

    // MARK: - Rich text

    func testRichTextIntoTerminalCoercesToPlain() {
        let item = ClipItem(payload: .richText(rtf: Data([0x01]), plainFallback: "bold text"))
        let r = Preflight.inspect(item, into: terminal())
        XCTAssertTrue(r.fixes.contains(.coerceToPlainText))
    }

    // MARK: - Line endings

    func testCRLFIntoTerminalIsFixed() {
        let r = Preflight.inspect(clip("a\r\nb"), into: terminal())
        XCTAssertTrue(r.fixes.contains(.normalizeLineEndings))
    }

    // MARK: - Size

    func testOversizePastCeilingTruncates() {
        var config = PreflightConfig()
        config.terminalSizeWarning = 10
        config.terminalSizeCeiling = 20
        let r = Preflight.inspect(clip(String(repeating: "x", count: 100)), into: terminal(), config: config)
        XCTAssertTrue(r.fixes.contains(.truncate(to: 20)))
    }

    func testOversizeBelowCeilingOnlyInforms() {
        var config = PreflightConfig()
        config.terminalSizeWarning = 10
        config.terminalSizeCeiling = 1000
        let r = Preflight.inspect(clip(String(repeating: "x", count: 100)), into: terminal(), config: config)
        XCTAssertTrue(codes(r).contains(.oversizeForTerminal))
        XCTAssertTrue(r.fixes.isEmpty)
    }

    // MARK: - Multiline

    /// D7 argues a multi-line notice must never be surfaced: bracketed-paste
    /// state is not observable from outside the terminal, and firing on every
    /// code paste trains users to ignore the footer. A finding that must never be
    /// shown is dead code, so there is no longer one.
    func testMultilinePasteProducesNoFinding() {
        let r = Preflight.inspect(clip("a\nb"), into: terminal())
        XCTAssertTrue(r.findings.isEmpty)
    }

    // MARK: - Concealed content

    /// Redaction is a property of the model, and the panel shows the concealed
    /// state itself — a lock glyph on the row, "held in memory only" in the
    /// preview. Preflight duplicating that in the footer added nothing.
    func testConcealedClipProducesNoFindingButStaysRedacted() {
        let item = clip("hunter2", markers: [.concealed])
        let r = Preflight.inspect(item, into: terminal())
        XCTAssertTrue(r.findings.isEmpty)
        XCTAssertFalse(r.isBlocked)
        XCTAssertEqual(item.displayPreview(), String(repeating: "•", count: 16))
    }

    func testConcealedClipNeverLeaksIntoPreview() {
        let item = clip("hunter2", markers: [.concealed])
        XCTAssertFalse(item.displayPreview().contains("hunter2"))
    }

    // MARK: - Retention

    func testTransientIsDropped() {
        XCTAssertEqual(RetentionPolicy.forMarkers([.transient]), .drop)
    }

    func testRestoredIsDroppedToAvoidFeedbackLoop() {
        XCTAssertEqual(RetentionPolicy.forMarkers([.restored]), .drop)
    }

    func testConcealedIsMemoryOnly() {
        XCTAssertEqual(
            RetentionPolicy.forMarkers([.concealed]),
            .memoryOnlyRedacted(ttl: RetentionPolicy.concealedTTL)
        )
        XCTAssertFalse(RetentionPolicy.forMarkers([.concealed]).isPersistable)
    }

    func testUnmarkedContentPersists() {
        XCTAssertEqual(RetentionPolicy.forMarkers([]), .persist)
        XCTAssertTrue(RetentionPolicy.forMarkers([]).isPersistable)
    }

    /// Drop beats redact when both markers are present.
    func testTransientBeatsConcealed() {
        XCTAssertEqual(RetentionPolicy.forMarkers([.concealed, .transient]), .drop)
    }

    // MARK: - Ordering

    func testFindingsAreSortedBySeverity() {
        let item = ClipItem(payload: .text("a\nb\r\n"), markers: [.concealed])
        let r = Preflight.inspect(item, into: terminal(focus: .none))
        let severities = r.findings.map(\.severity)
        XCTAssertEqual(severities, severities.sorted(by: >))
    }

    // MARK: - Classifier

    func testKnownTerminalsClassify() {
        XCTAssertEqual(TargetClassifier.kind(for: "com.mitchellh.ghostty"), .terminal)
        XCTAssertEqual(TargetClassifier.kind(for: "com.googlecode.iterm2"), .terminal)
        XCTAssertEqual(TargetClassifier.kind(for: "com.apple.Terminal"), .terminal)
    }

    func testUnknownBundleFallsBackToOther() {
        XCTAssertEqual(TargetClassifier.kind(for: "com.example.Nope"), .other)
    }
}
