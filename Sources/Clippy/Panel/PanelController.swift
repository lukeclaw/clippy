import AppKit
import ClippyCore
import SwiftUI

/// An `NSPanel` that takes keyboard focus without activating the application.
///
/// Both overrides are load-bearing. `canBecomeKey` is what lets the panel
/// receive keystrokes at all; `.nonactivatingPanel` is what stops Clippy
/// becoming the frontmost app, which would make the real paste target
/// unrecoverable and leave every paste landing in our own search field.
final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Clippy is never the active application, so without this every click on the
/// panel would be spent activating it and the row underneath would never see
/// the event — the first click on each row would simply do nothing.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Presents the history panel and performs the paste.
final class PanelController {

    private let panel: NonActivatingPanel
    private let model: PanelModel
    private let history: History
    private let injector = Injector()
    private var keyMonitor: Any?

    var isVisible: Bool { panel.isVisible }

    init(history: History) {
        self.history = history
        self.model = PanelModel(history: history)

        panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = FirstMouseHostingView(rootView: PanelView(model: model))

        model.onActivate = { [weak self] in
            self?.paste(mode: .fixed)
        }
    }

    // MARK: - Presentation

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        // THE hard constraint: snapshot the target before anything is presented.
        // Once our panel is on screen the frontmost application is us, and the
        // real destination is gone. See docs/ux.md.
        let target = TargetInspector.current()

        model.prepare(target: target)
        reveal()
    }

    /// Put the panel back up without resetting the query or the target — used
    /// when a paste failed and the reason needs showing.
    private func reveal() {
        positionAtMouse()
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    func hide() {
        removeKeyMonitor()
        panel.orderOut(nil)
    }

    /// The panel opens at the mouse, clamped to the screen it is on.
    private func positionAtMouse() {
        let mouse = NSEvent.mouseLocation
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero

        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height)
        origin.x = min(max(visible.minX, origin.x), visible.maxX - size.width)
        origin.y = min(max(visible.minY, origin.y), visible.maxY - size.height)
        panel.setFrameOrigin(origin)
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Returns true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.keyCode {
        case 53:  // esc
            hide()
            return true

        case 125:  // down
            model.moveSelection(by: 1)
            return true

        case 126:  // up
            model.moveSelection(by: -1)
            return true

        case 36, 76:  // return, enter
            paste(mode: PasteMode(flags: flags))
            return true

        case 51:  // delete
            // ⌘⌫ always removes the selected item. A bare ⌫ edits the query
            // first — deleting history out from under someone mid-search would
            // be a nasty surprise, and docs/ux.md's plain ⌫ predates there
            // being a query to edit.
            if flags.contains(.command) || model.query.isEmpty {
                model.deleteSelected()
            } else {
                model.backspaceQuery()
            }
            return true

        default:
            break
        }

        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
            return false
        }

        // 1–9 paste that row immediately — the fastest path, and worth keeping.
        if !flags.contains(.command), let digit = Int(characters), (1...9).contains(digit) {
            if model.rows.indices.contains(digit - 1) {
                model.selection = digit - 1
                paste(mode: .fixed)
            }
            return true
        }

        // Anything else printable extends the query.
        if !flags.contains(.command), !flags.contains(.control),
           characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            model.appendToQuery(characters)
            return true
        }

        return false
    }

    // MARK: - Pasting

    private enum PasteMode {
        case fixed, raw, plain

        init(flags: NSEvent.ModifierFlags) {
            if flags.contains(.option) { self = .raw }
            else if flags.contains(.command) { self = .plain }
            else { self = .fixed }
        }
    }

    private func paste(mode: PasteMode) {
        guard let item = model.selectedItem else { return }
        guard let target = model.target else {
            model.message = "No target — nothing was frontmost when the panel opened"
            return
        }

        // Dismiss first so the target is unambiguously frontmost when the
        // keystroke lands.
        hide()

        let payload: ClipPayload
        switch mode {
        case .plain:
            payload = Transforms.apply(.coerceToPlainText, to: item.payload)
        case .fixed, .raw:
            payload = item.payload
        }

        let toPaste = ClipItem(
            id: item.id,
            capturedAt: item.capturedAt,
            lastUsedAt: item.lastUsedAt,
            payload: payload,
            sourceBundleID: item.sourceBundleID,
            markers: item.markers
        )

        switch injector.paste(toPaste, into: target, autoFix: mode != .raw) {
        case .delivered(let applied):
            model.markUsed(item)
            history.recordPaste(
                item: item, target: target, transforms: applied, outcome: .delivered
            )
        case .failed(let failure):
            history.recordPaste(
                item: item, target: target, transforms: [],
                outcome: .failed(reason: failure.reason)
            )
            // The panel comes back with the reason inline rather than posting a
            // notification — the user is already looking here. `reveal` rather
            // than `show` so the query and captured target survive.
            reveal()
            model.message = failure.reason
        }
    }
}
