import XCTest
@testable import ClippyCore

final class FocusClassifierTests: XCTestCase {

    // MARK: - Terminals

    /// The regression that mattered. Terminal.app reports AXTextArea with
    /// AXValue not settable, because a terminal's value is its screen buffer and
    /// nothing can assign to it. Reading that as read-only made Preflight block
    /// every paste into a terminal — the one target the paste rules exist for.
    func testTerminalTextAreaIsEditableEvenWhenValueIsNotSettable() {
        let state = FocusClassifier.state(
            role: "AXTextArea",
            valueIsSettable: false,
            kind: .terminal
        )
        XCTAssertEqual(state, .editableText)
    }

    func testTerminalTextAreaIsEditableWhenValueIsSettable() {
        XCTAssertEqual(
            FocusClassifier.state(role: "AXTextArea", valueIsSettable: true, kind: .terminal),
            .editableText
        )
    }

    /// The exemption is scoped to text roles. A terminal showing a preferences
    /// sheet with a checkbox focused is genuinely not a paste target.
    func testTerminalNonTextRoleStillFallsBackToSettability() {
        XCTAssertEqual(
            FocusClassifier.state(role: "AXCheckBox", valueIsSettable: false, kind: .terminal),
            .nonEditable
        )
    }

    // MARK: - Everything else

    /// The same reading in a non-terminal keeps the strict rule: a text area
    /// whose value cannot be set really is read-only there.
    func testEditorTextAreaWithUnsettableValueIsNotEditable() {
        XCTAssertEqual(
            FocusClassifier.state(role: "AXTextArea", valueIsSettable: false, kind: .editor),
            .nonEditable
        )
    }

    func testEditorTextAreaWithSettableValueIsEditable() {
        XCTAssertEqual(
            FocusClassifier.state(role: "AXTextArea", valueIsSettable: true, kind: .editor),
            .editableText
        )
    }

    func testTextFieldAndComboBoxAreTextRoles() {
        for role in ["AXTextField", "AXComboBox"] {
            XCTAssertEqual(
                FocusClassifier.state(role: role, valueIsSettable: true, kind: .browser),
                .editableText,
                "\(role) should count as a text role"
            )
        }
    }

    /// Web views and Electron apps report AXGroup or AXWebArea for a focused
    /// contenteditable, so settability carries the decision there.
    func testUnknownRoleWithSettableValueIsEditable() {
        XCTAssertEqual(
            FocusClassifier.state(role: "AXWebArea", valueIsSettable: true, kind: .browser),
            .editableText
        )
    }

    func testUnknownRoleWithUnsettableValueIsNotEditable() {
        XCTAssertEqual(
            FocusClassifier.state(role: "AXGroup", valueIsSettable: false, kind: .browser),
            .nonEditable
        )
    }

    /// An unreadable role means we learned nothing — which is not the same as
    /// learning the element is read-only, and must not block.
    func testUnreadableRoleIsUnknown() {
        XCTAssertEqual(
            FocusClassifier.state(role: nil, valueIsSettable: false, kind: .terminal),
            .unknown
        )
    }

    // MARK: - The end-to-end consequence

    /// Guards the whole point: with the real reading from Terminal.app, a
    /// paste must not be blocked.
    func testRealTerminalReadingDoesNotBlockAPaste() {
        let focus = FocusClassifier.state(
            role: "AXTextArea",
            valueIsSettable: false,
            kind: .terminal
        )
        let target = Target(
            bundleID: "com.apple.Terminal",
            localizedName: "Terminal",
            kind: .terminal,
            focus: focus,
            acceptsImages: false
        )
        let result = Preflight.inspect(ClipItem(payload: .text("npm install")), into: target)
        XCTAssertFalse(result.isBlocked)
    }
}
