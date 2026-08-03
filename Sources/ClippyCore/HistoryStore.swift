import Foundation
import SQLite3
import CryptoKit

/// Capacity limits, in one place so they are easy to revisit once there is real
/// usage to look at. Both are guesses; see docs/open-questions.md.
public enum HistoryLimits {
    /// No cap. Text and file clips run about a kilobyte each, so keeping every
    /// one forever costs well under a gigabyte per decade — there is no storage
    /// argument for throwing them away, and "the thing I copied months ago" is
    /// exactly what a history is for.
    public static let maxItems: Int? = nil

    /// Images are the exception. At 0.3–2 MB each they dominate everything else
    /// within weeks, so they keep a budget, oldest use evicted first.
    public static let maxBlobBytes = 500 * 1024 * 1024
}

public enum HistoryStoreError: Error, CustomStringConvertible {
    case open(String)
    case sql(String)

    public var description: String {
        switch self {
        case .open(let m): return "Could not open history database: \(m)"
        case .sql(let m): return "History database error: \(m)"
        }
    }
}

/// Durable clipboard history.
///
/// SQLite through the system `libsqlite3`, no ORM and no dependency — the schema
/// is small enough that hand-written SQL is less work than any abstraction over
/// it. Large payloads (image data, RTF) live in content-addressed files rather
/// than in the database, which keeps the DB small and fast to open and makes
/// eviction a file delete. Identical screenshots deduplicate for free.
///
/// Concealed items never reach this class. `History` filters on retention before
/// calling here, so "nothing confidential is on disk" is enforced one layer up
/// and cannot be forgotten by a caller of the store.
public final class HistoryStore {

    private var db: OpaquePointer?
    private let blobsDirectory: URL
    private var directory: URL!

    /// Default location: `~/Library/Application Support/Clippy/`.
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("Clippy", isDirectory: true)
    }

    public init(directory: URL = HistoryStore.defaultDirectory()) throws {
        self.blobsDirectory = directory.appendingPathComponent("blobs", isDirectory: true)

        try FileManager.default.createDirectory(
            at: blobsDirectory, withIntermediateDirectories: true
        )

        let dbURL = directory.appendingPathComponent("history.db")
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, db != nil else {
            throw HistoryStoreError.open(lastMessage)
        }

        self.directory = directory

        // WAL keeps reads from blocking the capture path, and a busy timeout
        // means a slow write never surfaces as an error.
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA busy_timeout = 2000;")
        try createSchema()

        // After the PRAGMAs, so the -wal and -shm files SQLite just created are
        // tightened too rather than left at the umask.
        restrictPermissions()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    /// Owner-only, stated rather than inherited.
    ///
    /// These files were previously created at the process umask — 755 on the
    /// directories and 644 on the database, meaning world-readable. In practice
    /// they were unreachable because `~/Library/Application Support` is 700, so
    /// the protection was real but accidental: it survived only as long as
    /// nothing changed a parent directory and nothing copied the files
    /// elsewhere.
    ///
    /// Applied on every open, not just creation, so an existing install is
    /// tightened too.
    private func restrictPermissions() {
        let fm = FileManager.default

        for dir in [directory!, blobsDirectory] {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }

        // SQLite creates -wal and -shm itself, at the umask, so they are
        // included here rather than assumed.
        for suffix in ["", "-wal", "-shm"] {
            let path = directory.appendingPathComponent("history.db\(suffix)").path
            guard fm.fileExists(atPath: path) else { continue }
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }

    // MARK: - Schema

    private func createSchema() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS items (
            id               TEXT PRIMARY KEY,
            captured_at      REAL NOT NULL,
            last_used_at     REAL NOT NULL,
            kind             TEXT NOT NULL,
            text             TEXT,
            blob_hash        TEXT,
            uti              TEXT,
            source_bundle_id TEXT,
            markers          TEXT
        );
        """)
        try exec("CREATE INDEX IF NOT EXISTS items_last_used ON items(last_used_at DESC);")

        try exec("""
        CREATE TABLE IF NOT EXISTS paste_events (
            id            TEXT PRIMARY KEY,
            clip_id       TEXT NOT NULL,
            pasted_at     REAL NOT NULL,
            preview       TEXT,
            target_bundle TEXT,
            target_kind   TEXT,
            transforms    TEXT,
            outcome       TEXT NOT NULL,
            failure       TEXT
        );
        """)
        try exec("CREATE INDEX IF NOT EXISTS paste_events_at ON paste_events(pasted_at DESC);")
    }

    // MARK: - Paste log

    public func recordPaste(_ event: PasteEvent) throws {
        let sql = """
        INSERT OR REPLACE INTO paste_events
            (id, clip_id, pasted_at, preview, target_bundle, target_kind,
             transforms, outcome, failure)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HistoryStoreError.sql(lastMessage)
        }
        defer { sqlite3_finalize(stmt) }

        bind(stmt, 1, event.id.uuidString)
        bind(stmt, 2, event.clipID.uuidString)
        sqlite3_bind_double(stmt, 3, event.pastedAt.timeIntervalSince1970)
        bind(stmt, 4, event.preview)
        bind(stmt, 5, event.targetBundleID)
        bind(stmt, 6, event.targetKind.storageKey)
        bind(stmt, 7, event.transforms.map(\.storageKey).joined(separator: ","))

        switch event.outcome {
        case .delivered:
            bind(stmt, 8, "delivered")
            bind(stmt, 9, nil)
        case .failed(let reason):
            bind(stmt, 8, "failed")
            bind(stmt, 9, reason)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw HistoryStoreError.sql(lastMessage)
        }
    }

    /// Newest first. `clipID` narrows to one clip's history.
    public func pasteEvents(limit: Int? = nil, clipID: UUID? = nil) throws -> [PasteEvent] {
        let filter = clipID == nil ? "" : "WHERE clip_id = ?"
        let sql = """
        SELECT id, clip_id, pasted_at, preview, target_bundle, target_kind,
               transforms, outcome, failure
        FROM paste_events \(filter) ORDER BY pasted_at DESC LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HistoryStoreError.sql(lastMessage)
        }
        defer { sqlite3_finalize(stmt) }

        var index: Int32 = 1
        if let clipID {
            bind(stmt, index, clipID.uuidString)
            index += 1
        }
        sqlite3_bind_int(stmt, index, Int32(limit ?? -1))

        var out: [PasteEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let event = pasteEvent(from: stmt!) { out.append(event) }
        }
        return out
    }

    private func pasteEvent(from stmt: OpaquePointer) -> PasteEvent? {
        guard let idText = column(stmt, 0), let id = UUID(uuidString: idText),
              let clipText = column(stmt, 1), let clipID = UUID(uuidString: clipText),
              let outcomeText = column(stmt, 7)
        else { return nil }

        let transforms = (column(stmt, 6) ?? "")
            .split(separator: ",")
            .compactMap { Transform(storageKey: String($0)) }

        let outcome: PasteEventOutcome = outcomeText == "delivered"
            ? .delivered
            : .failed(reason: column(stmt, 8) ?? "unknown")

        return PasteEvent(
            id: id,
            pastedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
            clipID: clipID,
            preview: column(stmt, 3) ?? "",
            targetBundleID: column(stmt, 4) ?? "unknown",
            targetKind: TargetKind(storageKey: column(stmt, 5) ?? "other"),
            transforms: transforms,
            outcome: outcome
        )
    }

    // MARK: - Reading

    /// Everything on disk, newest use first. Called once at launch.
    public func load(limit: Int? = HistoryLimits.maxItems) throws -> [ClipItem] {
        let sql = """
        SELECT id, captured_at, last_used_at, kind, text, blob_hash, uti,
               source_bundle_id, markers
        FROM items ORDER BY last_used_at DESC LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HistoryStoreError.sql(lastMessage)
        }
        defer { sqlite3_finalize(stmt) }
        // SQLite reads a negative LIMIT as "no limit".
        sqlite3_bind_int(stmt, 1, Int32(limit ?? -1))

        var out: [ClipItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let item = item(from: stmt!) { out.append(item) }
        }
        return out
    }

    private func item(from stmt: OpaquePointer) -> ClipItem? {
        guard let idText = column(stmt, 0), let id = UUID(uuidString: idText),
              let kind = column(stmt, 3)
        else { return nil }

        let capturedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
        let lastUsedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
        let text = column(stmt, 4)
        let blobHash = column(stmt, 5)
        let uti = column(stmt, 6)
        let source = column(stmt, 7)
        let markers = Set((column(stmt, 8) ?? "")
            .split(separator: ",")
            .compactMap { MarkerType(rawValue: String($0)) })

        guard let payload = payload(kind: kind, text: text, blobHash: blobHash, uti: uti)
        else { return nil }

        return ClipItem(
            id: id,
            capturedAt: capturedAt,
            lastUsedAt: lastUsedAt,
            payload: payload,
            sourceBundleID: source,
            markers: markers
        )
    }

    /// A row whose blob has gone missing yields nil rather than a broken item —
    /// the eviction pass will collect the orphaned row afterwards.
    private func payload(kind: String, text: String?, blobHash: String?, uti: String?) -> ClipPayload? {
        switch kind {
        case "text":
            return .text(text ?? "")
        case "richText":
            guard let blobHash, let data = try? readBlob(blobHash) else { return nil }
            return .richText(rtf: data, plainFallback: text ?? "")
        case "image":
            guard let blobHash, let data = try? readBlob(blobHash) else { return nil }
            return .image(data: data, uti: uti ?? "public.png")
        case "files":
            let paths = (text ?? "").split(separator: "\n").map(String.init)
            return .files(paths.map { URL(fileURLWithPath: $0) })
        default:
            return nil
        }
    }

    // MARK: - Writing

    /// Insert or replace. Blob payloads are written to disk first so a row never
    /// references a file that is not there.
    public func upsert(_ item: ClipItem) throws {
        var blobHash: String?
        var uti: String?

        switch item.payload {
        case .richText(let rtf, _):
            blobHash = try writeBlob(rtf)
        case .image(let data, let imageUTI):
            blobHash = try writeBlob(data)
            uti = imageUTI
        case .text, .files:
            break
        }

        let sql = """
        INSERT OR REPLACE INTO items
            (id, captured_at, last_used_at, kind, text, blob_hash, uti,
             source_bundle_id, markers)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HistoryStoreError.sql(lastMessage)
        }
        defer { sqlite3_finalize(stmt) }

        bind(stmt, 1, item.id.uuidString)
        sqlite3_bind_double(stmt, 2, item.capturedAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 3, item.lastUsedAt.timeIntervalSince1970)
        bind(stmt, 4, kindName(item.payload))
        bind(stmt, 5, item.payload.plainText)
        bind(stmt, 6, blobHash)
        bind(stmt, 7, uti)
        bind(stmt, 8, item.sourceBundleID)
        bind(stmt, 9, item.markers.map(\.rawValue).sorted().joined(separator: ","))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw HistoryStoreError.sql(lastMessage)
        }
    }

    public func touch(id: UUID, at date: Date) throws {
        let sql = "UPDATE items SET last_used_at = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HistoryStoreError.sql(lastMessage)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
        bind(stmt, 2, id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw HistoryStoreError.sql(lastMessage)
        }
    }

    public func delete(id: UUID) throws {
        let sql = "DELETE FROM items WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HistoryStoreError.sql(lastMessage)
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw HistoryStoreError.sql(lastMessage)
        }
    }

    // MARK: - Eviction

    /// Enforce the capacity limits and report what was removed, so an in-memory
    /// list can drop the same rows instead of showing clips whose data is gone.
    ///
    /// With `maxItems` nil — the default, see `HistoryLimits` — only the blob
    /// budget bites, so text clips are kept forever and images age out.
    ///
    /// Paste events are deliberately left alone. They carry their own preview
    /// and are meant to outlive the clip they came from.
    @discardableResult
    public func evict(
        maxItems: Int? = HistoryLimits.maxItems,
        maxBlobBytes: Int = HistoryLimits.maxBlobBytes
    ) throws -> [UUID] {
        var removed: [UUID] = []

        if let maxItems {
            let sql = """
            SELECT id FROM items WHERE id NOT IN (
                SELECT id FROM items ORDER BY last_used_at DESC LIMIT \(maxItems)
            );
            """
            for id in try ids(matching: sql) {
                try delete(id: id)
                removed.append(id)
            }
        }

        // Blob budget: walk newest-first, and drop rows once the running total
        // passes the ceiling.
        var total = 0
        for (id, hash) in try blobRowsNewestFirst() {
            total += blobSize(hash)
            if total > maxBlobBytes {
                try delete(id: id)
                removed.append(id)
            }
        }

        try collectOrphanedBlobs()
        return removed
    }

    private func ids(matching sql: String) throws -> [UUID] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HistoryStoreError.sql(lastMessage)
        }
        defer { sqlite3_finalize(stmt) }

        var out: [UUID] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let text = column(stmt!, 0), let id = UUID(uuidString: text) { out.append(id) }
        }
        return out
    }

    private func blobRowsNewestFirst() throws -> [(UUID, String)] {
        let sql = """
        SELECT id, blob_hash FROM items
        WHERE blob_hash IS NOT NULL ORDER BY last_used_at DESC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HistoryStoreError.sql(lastMessage)
        }
        defer { sqlite3_finalize(stmt) }

        var out: [(UUID, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let idText = column(stmt!, 0), let id = UUID(uuidString: idText),
               let hash = column(stmt!, 1) {
                out.append((id, hash))
            }
        }
        return out
    }

    /// Content addressing means two rows can share a file, so a blob is only
    /// safe to delete once no row references it.
    private func collectOrphanedBlobs() throws {
        var referenced = Set<String>()
        for (_, hash) in try blobRowsNewestFirst() { referenced.insert(hash) }

        let files = (try? FileManager.default.contentsOfDirectory(
            at: blobsDirectory, includingPropertiesForKeys: nil
        )) ?? []

        for file in files where !referenced.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Blobs

    private func blobURL(_ hash: String) -> URL {
        blobsDirectory.appendingPathComponent(hash)
    }

    @discardableResult
    private func writeBlob(_ data: Data) throws -> String {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let url = blobURL(hash)
        // Content-addressed: identical bytes are already the right file.
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
        }
        return hash
    }

    private func readBlob(_ hash: String) throws -> Data {
        try Data(contentsOf: blobURL(hash))
    }

    private func blobSize(_ hash: String) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: blobURL(hash).path)
        return (attrs?[.size] as? Int) ?? 0
    }

    // MARK: - SQLite plumbing

    private var lastMessage: String {
        db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw HistoryStoreError.sql(lastMessage)
        }
    }

    private func column(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    /// SQLITE_TRANSIENT — tells SQLite to copy the string, since the Swift
    /// temporary backing it is gone by the time the statement runs.
    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        guard let value else { sqlite3_bind_null(stmt, index); return }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, index, value, -1, transient)
    }

    private func kindName(_ payload: ClipPayload) -> String {
        switch payload {
        case .text: return "text"
        case .richText: return "richText"
        case .image: return "image"
        case .files: return "files"
        }
    }
}
