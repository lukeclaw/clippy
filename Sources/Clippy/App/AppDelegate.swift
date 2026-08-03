import AppKit
import ClippyCore

/// The menu-bar agent.
///
/// No dock icon and no main window — `.accessory` activation policy, a status
/// item, and the panel. The status menu deliberately does not duplicate the
/// panel's contents; it exists so there is somewhere to quit from. One way to
/// do things, per docs/ux.md.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var monitor: PasteboardMonitor?
    private var hotKey: HotKey?
    private var longPress: LongPressHotKey?
    private var panel: PanelController?
    private var history: History?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = try? HistoryStore()
        if store == nil {
            NSLog("clippy: could not open the history database — running in memory only")
        }

        let history = History(store: store, ownBundleID: Bundle.main.bundleIdentifier)
        history.loadFromStore()
        self.history = history

        let panel = PanelController(history: history)
        self.panel = panel

        setUpStatusItem()

        let monitor = PasteboardMonitor { [weak history] item in
            history?.record(item)
        }
        monitor.start()
        self.monitor = monitor

        // Primary trigger: hold ⌘V. A quick ⌘V still pastes normally.
        longPress = LongPressHotKey { [weak panel] in
            panel?.show()
        }
        if longPress == nil {
            NSLog("clippy: could not create the event tap — long-press ⌘V is off. "
                + "Grant Accessibility in System Settings, or use ⌘⇧V.")
        }

        // Kept as a fallback that does not depend on the event tap, so there is
        // always a way in if the tap fails or gets disabled.
        hotKey = HotKey.commandShiftV { [weak panel] in
            panel?.toggle()
        }
        if hotKey == nil {
            NSLog("clippy: ⌘⇧V is already taken — use the menu bar icon instead")
        }
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "paperclip",
            accessibilityDescription: "Clippy"
        )

        let menu = NSMenu()
        let open = NSMenuItem(
            title: "Show Clipboard History",
            action: #selector(showPanel),
            keyEquivalent: ""
        )
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Clippy",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    @objc private func showPanel() {
        panel?.show()
    }
}
