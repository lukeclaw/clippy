import AppKit
import ClippyCore

/// Watches the general pasteboard for new content.
///
/// macOS has no change notification for NSPasteboard — `changeCount` polling is
/// the only mechanism available, and every clipboard manager on the platform
/// does exactly this. 200ms is the usual interval: fast enough that the panel
/// never shows stale content, slow enough to be invisible in Activity Monitor.
public final class PasteboardMonitor {

    public typealias Handler = (ClipItem) -> Void

    private let pasteboard: NSPasteboard
    private let interval: TimeInterval
    private var timer: Timer?
    private var lastChangeCount: Int
    private let onCapture: Handler

    public init(
        pasteboard: NSPasteboard = .general,
        interval: TimeInterval = 0.2,
        onCapture: @escaping Handler
    ) {
        self.pasteboard = pasteboard
        self.interval = interval
        self.lastChangeCount = pasteboard.changeCount
        self.onCapture = onCapture
    }

    public func start() {
        stop()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        // .common keeps polling alive while menus and panels are tracking,
        // which is exactly when the user is most likely to copy something.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        guard let item = readCurrentItem() else { return }

        // Markers are consulted before anything else touches the item: a
        // transient or restored clip must never reach the store, and a
        // concealed one must never reach disk.
        guard item.retention != .drop else { return }

        onCapture(item)
    }

    /// Build a ClipItem from whatever is on the pasteboard right now.
    func readCurrentItem() -> ClipItem? {
        let markers = readMarkers()
        let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        guard let payload = readPayload() else { return nil }

        return ClipItem(
            payload: payload,
            sourceBundleID: source,
            markers: markers
        )
    }

    private func readMarkers() -> Set<MarkerType> {
        let present = pasteboard.types?.map(\.rawValue) ?? []
        return Set(MarkerType.allCases.filter { present.contains($0.rawValue) })
    }

    /// Read in descending order of fidelity. Files beat images beat rich text
    /// beats plain text — taking the richest representation the source offered,
    /// so that Preflight rather than the reader decides what to downgrade.
    private func readPayload() -> ClipPayload? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           !urls.isEmpty,
           urls.allSatisfy(\.isFileURL) {
            return .files(urls)
        }

        for uti in [NSPasteboard.PasteboardType.tiff, .png] {
            if let data = pasteboard.data(forType: uti) {
                return .image(data: data, uti: uti.rawValue)
            }
        }

        let plain = pasteboard.string(forType: .string)

        if let rtf = pasteboard.data(forType: .rtf) {
            return .richText(rtf: rtf, plainFallback: plain ?? "")
        }

        if let plain, !plain.isEmpty {
            return .text(plain)
        }

        return nil
    }
}
