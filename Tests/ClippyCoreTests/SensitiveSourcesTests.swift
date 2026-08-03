import XCTest
@testable import ClippyCore

final class SensitiveSourcesTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clippy-sensitive-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Password managers set ConcealedType, but relying on that means trusting
    /// the source to declare itself. The denylist does not.
    func testClipsFromAPasswordManagerAreNeverRecorded() {
        let h = History()
        let outcome = h.record(ClipItem(
            payload: .text("correct horse battery staple"),
            sourceBundleID: "com.bitwarden.desktop"
        ))
        XCTAssertEqual(outcome, .ignored)
        XCTAssertTrue(h.items.isEmpty)
    }

    /// The point of the denylist: it fires even when the app sets no marker at
    /// all, which is the case the concealed policy cannot cover.
    func testDenylistAppliesEvenWithNoConcealedMarker() {
        let h = History()
        for bundleID in ["com.1password.1password", "com.apple.keychainaccess",
                         "org.keepassxc.keepassxc"] {
            XCTAssertEqual(
                h.record(ClipItem(payload: .text("secret"), sourceBundleID: bundleID)),
                .ignored,
                "\(bundleID) should never be recorded"
            )
        }
        XCTAssertTrue(h.items.isEmpty)
    }

    func testOrdinaryAppsAreUnaffected() {
        let h = History()
        let outcome = h.record(ClipItem(
            payload: .text("npm install"), sourceBundleID: "com.apple.Safari"
        ))
        guard case .inserted = outcome else { return XCTFail("expected insert") }
        XCTAssertEqual(h.items.count, 1)
    }

    func testNilSourceIsNotTreatedAsSensitive() {
        XCTAssertFalse(SensitiveSources.isSensitive(nil))
    }

    /// Nothing from a denylisted app reaches disk, checked against the raw file
    /// rather than the API.
    func testDenylistedContentNeverReachesDisk() throws {
        let store = try HistoryStore(directory: directory)
        let h = History(store: store)
        h.record(ClipItem(payload: .text("hunter2-denylist"),
                          sourceBundleID: "com.bitwarden.desktop"))

        XCTAssertTrue(try store.load().isEmpty)
        let raw = try String(contentsOf: directory.appendingPathComponent("history.db"),
                             encoding: .isoLatin1)
        XCTAssertFalse(raw.contains("hunter2-denylist"))
    }

    // MARK: - Permissions

    func testStoreFilesAreOwnerOnly() throws {
        _ = try HistoryStore(directory: directory)
        let fm = FileManager.default

        for dir in [directory!, directory.appendingPathComponent("blobs")] {
            let mode = try fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o700, "\(dir.lastPathComponent) should be owner-only")
        }

        let db = directory.appendingPathComponent("history.db").path
        let mode = try fm.attributesOfItem(atPath: db)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600, "history.db should be owner-only")
    }

    /// Applied on every open, so an install created before this existed gets
    /// tightened rather than staying world-readable forever.
    func testExistingLoosePermissionsAreTightenedOnOpen() throws {
        _ = try HistoryStore(directory: directory)
        let fm = FileManager.default
        let db = directory.appendingPathComponent("history.db").path
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: db)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)

        _ = try HistoryStore(directory: directory)

        XCTAssertEqual(try fm.attributesOfItem(atPath: db)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(
            try fm.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int, 0o700)
    }
}
