import Foundation

/// What kind of thing is on the pasteboard.
public enum ClipPayload: Equatable, Sendable {
    case text(String)
    case richText(rtf: Data, plainFallback: String)
    case image(data: Data, uti: String)
    case files([URL])

    /// The plain-text rendering, if one exists. Rich text carries a fallback;
    /// images do not.
    public var plainText: String? {
        switch self {
        case .text(let s): return s
        case .richText(_, let fallback): return fallback
        case .image: return nil
        case .files(let urls): return urls.map(\.path).joined(separator: "\n")
        }
    }

    public var byteCount: Int {
        switch self {
        case .text(let s): return s.utf8.count
        case .richText(let rtf, _): return rtf.count
        case .image(let data, _): return data.count
        case .files(let urls): return urls.reduce(0) { $0 + $1.path.utf8.count }
        }
    }
}

/// A single captured clipboard entry.
public struct ClipItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let capturedAt: Date

    /// Updated when the clip is copied again or pasted. This — not `capturedAt`
    /// — is the sort key: having just used something makes it likely you want it
    /// again, so a re-used clip returns to the top of the list.
    public var lastUsedAt: Date

    public let payload: ClipPayload

    /// Bundle identifier of the app that was frontmost at capture time. This is
    /// free to collect (`NSWorkspace.frontmostApplication`, no permission
    /// required) and makes search far better — people remember where a clip came
    /// from more reliably than what it said.
    public let sourceBundleID: String?

    public let markers: Set<MarkerType>

    public init(
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        lastUsedAt: Date? = nil,
        payload: ClipPayload,
        sourceBundleID: String? = nil,
        markers: Set<MarkerType> = []
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.lastUsedAt = lastUsedAt ?? capturedAt
        self.payload = payload
        self.sourceBundleID = sourceBundleID
        self.markers = markers
    }

    public var retention: RetentionPolicy {
        RetentionPolicy.forMarkers(markers)
    }

    public var byteCount: Int { payload.byteCount }

    /// One-line rendering for the history list. Redacted items never leak their
    /// contents here — the UI layer must not have to remember to do this.
    public func displayPreview(maxLength: Int = 80) -> String {
        if retention.shouldRedact {
            return String(repeating: "•", count: 16)
        }
        switch payload {
        case .image(let data, let uti):
            return "Image · \(uti) · \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))"
        case .files(let urls):
            return urls.count == 1
                ? (urls[0].lastPathComponent)
                : "\(urls.count) files"
        case .text, .richText:
            let raw = payload.plainText ?? ""
            let collapsed = raw
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return collapsed.count > maxLength
                ? String(collapsed.prefix(maxLength)) + "…"
                : collapsed
        }
    }
}
