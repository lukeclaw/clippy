import XCTest
@testable import ClippyCore

final class TransformsTests: XCTestCase {

    // MARK: - Trailing newlines

    func testStripsTrailingNewline() {
        XCTAssertEqual(Transforms.stripTrailingNewlines("hello\n"), "hello")
    }

    func testStripsMultipleTrailingNewlines() {
        XCTAssertEqual(Transforms.stripTrailingNewlines("hello\n\n\n"), "hello")
    }

    func testStripsTrailingCRLF() {
        XCTAssertEqual(Transforms.stripTrailingNewlines("hello\r\n"), "hello")
    }

    func testStripsMultipleTrailingCRLFs() {
        XCTAssertEqual(Transforms.stripTrailingNewlines("hello\r\n\r\n"), "hello")
    }

    func testStripsTrailingLoneCR() {
        XCTAssertEqual(Transforms.stripTrailingNewlines("hello\r"), "hello")
    }

    /// Swift reads CRLF as one grapheme cluster, so every predicate here has to
    /// work in unicode scalars. These four cover the character-level scan that
    /// used to miss CRLF entirely — the exact shape of text copied out of a
    /// browser or a Windows tool.
    func testTrailingNewlineIsDetectedThroughCRLF() {
        XCTAssertTrue(Transforms.hasTrailingNewline("hello\r\n"))
        XCTAssertTrue(Transforms.hasTrailingNewline("hello\r"))
        XCTAssertTrue(Transforms.hasTrailingNewline("hello\n"))
        XCTAssertFalse(Transforms.hasTrailingNewline("hello"))
    }

    func testPreservesInteriorNewlines() {
        XCTAssertEqual(Transforms.stripTrailingNewlines("a\nb\nc\n"), "a\nb\nc")
    }

    /// Leading indentation is meaningful in code and trailing spaces are
    /// meaningful in Markdown, so we strip newlines only — never whitespace.
    func testPreservesIndentationAndTrailingSpaces() {
        XCTAssertEqual(Transforms.stripTrailingNewlines("    indented  \n"), "    indented  ")
    }

    func testEmptyStringIsSafe() {
        XCTAssertEqual(Transforms.stripTrailingNewlines(""), "")
        XCTAssertFalse(Transforms.hasTrailingNewline(""))
    }

    func testStringOfOnlyNewlinesCollapsesToEmpty() {
        XCTAssertEqual(Transforms.stripTrailingNewlines("\n\n"), "")
    }

    // MARK: - Line endings

    func testNormalizesCRLF() {
        XCTAssertEqual(Transforms.normalizeLineEndings("a\r\nb"), "a\nb")
    }

    func testNormalizesLoneCR() {
        XCTAssertEqual(Transforms.normalizeLineEndings("a\rb"), "a\nb")
    }

    func testCRLFIsDetected() {
        XCTAssertTrue(Transforms.containsCRLF("a\r\nb"))
        XCTAssertTrue(Transforms.containsCRLF("a\rb"))
        XCTAssertFalse(Transforms.containsCRLF("a\nb"))
    }

    // MARK: - Multiline detection

    /// A single line with a trailing newline is not "multiline" — otherwise
    /// every ordinary browser copy would trip the multiline notice.
    func testSingleLineWithTrailingNewlineIsNotMultiline() {
        XCTAssertFalse(Transforms.isMultiline("hello\n"))
    }

    func testGenuineMultilineIsDetected() {
        XCTAssertTrue(Transforms.isMultiline("a\nb\n"))
    }

    func testCRLFMultilineIsDetected() {
        XCTAssertTrue(Transforms.isMultiline("a\r\nb\r\n"))
    }

    /// A lone CR is a line break too — it becomes one after normalisation, so
    /// the multiline notice should fire on it rather than waiting for the
    /// transform to run first.
    func testLoneCRMultilineIsDetected() {
        XCTAssertTrue(Transforms.isMultiline("a\rb"))
    }

    func testSingleLineWithTrailingCRLFIsNotMultiline() {
        XCTAssertFalse(Transforms.isMultiline("hello\r\n"))
    }

    // MARK: - Truncation

    func testTruncateRespectsByteBudget() {
        let out = Transforms.truncate("abcdefghij", toBytes: 4)
        XCTAssertEqual(out, "abcd")
    }

    func testTruncateDoesNotSplitMultibyteScalars() {
        // Each emoji is 4 UTF-8 bytes; a budget of 6 must yield one, not one
        // and a half.
        let out = Transforms.truncate("👍👍", toBytes: 6)
        XCTAssertEqual(out, "👍")
        XCTAssertLessThanOrEqual(out.utf8.count, 6)
    }

    func testTruncateLeavesShortStringsAlone() {
        XCTAssertEqual(Transforms.truncate("hi", toBytes: 100), "hi")
    }

    // MARK: - Payload application

    func testTextTransformOnRichTextCoercesToPlain() {
        let payload = ClipPayload.richText(rtf: Data([0x01]), plainFallback: "code\n")
        let out = Transforms.apply(.stripTrailingNewlines, to: payload)
        XCTAssertEqual(out, .text("code"))
    }

    func testTextTransformsAreNoOpsOnImages() {
        let payload = ClipPayload.image(data: Data([0x89, 0x50]), uti: "public.png")
        XCTAssertEqual(Transforms.apply(.stripTrailingNewlines, to: payload), payload)
    }

    func testTransformsComposeInOrder() {
        let payload = ClipPayload.text("a\r\nb\r\n")
        let out = Transforms.apply([.normalizeLineEndings, .stripTrailingNewlines], to: payload)
        XCTAssertEqual(out, .text("a\nb"))
    }
}
