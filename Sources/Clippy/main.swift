import AppKit
import ClippyCore

// A headless harness, not the finished app.
//
// The menu-bar UI is deliberately not built yet: the assumptions underneath it
// (does a trailing newline actually submit in Claude Code?) have to be confirmed
// on real hardware first, and a UI would only make them harder to observe. Run
// `clippy watch` alongside your terminal and read what it prints.

enum CLI {

    /// The most recent capture, held so that switching apps can re-evaluate it
    /// against a new target. See `watch()`.
    private static var pending: ClipItem?

    static func run() {
        let args = Array(CommandLine.arguments.dropFirst())
        let rest = Array(args.dropFirst())

        switch args.first {
        case nil, "app":
            runApp()
        case "watch":
            watch()
        case "target":
            printTarget(after: delay(in: rest, default: 0))
        case "paste":
            paste(rest)
        case "log":
            printLog(limit: Int(rest.first ?? "") ?? 50)
        case "permissions":
            printPermissions()
        default:
            usage()
        }
    }

    /// The actual product: a menu-bar agent with a panel. Everything else in
    /// this file is the harness that was built first to check assumptions.
    static func runApp() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Held here because NSApplication does not retain its delegate.
        Self.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private static var delegate: AppDelegate?

    static func usage() {
        print("""
        clippy — clipboard manager

          clippy                          run the menu-bar app (⌘⇧V opens the panel)

        Harness commands, for checking assumptions without the UI in the way:

          clippy watch                    capture clips, then re-run preflight each time you switch apps
          clippy target [--after N]       print what the frontmost app looks like to the AX probe
          clippy paste [--after N] [--raw] [text]
                                          paste text into the frontmost app, reporting the outcome
          clippy log [N]                  the paste log — where clips went and what was applied
          clippy permissions              check Accessibility trust, prompting if needed

        --after N waits N seconds before probing, so you can switch to the app you
        want to look at. `paste` reads stdin when no text is given, which is the
        way to test payloads whose whitespace matters:

          printf 'npm install\\n' | clippy paste

        """)
    }

    // MARK: - Argument parsing

    private static func delay(in args: [String], default fallback: TimeInterval) -> TimeInterval {
        guard let i = args.firstIndex(of: "--after"),
              i + 1 < args.count,
              let value = Double(args[i + 1])
        else { return fallback }
        return value
    }

    private static func countDown(_ seconds: TimeInterval, _ what: String) {
        guard seconds > 0 else { return }
        print("\(what) in \(Int(seconds))s — switch to the app you want…")
        Thread.sleep(forTimeInterval: seconds)
    }

    // MARK: - Commands

    /// The paste log — where clips went, when, and what was done to them.
    /// Reads the same database the running app writes to.
    static func printLog(limit: Int) {
        guard let store = try? HistoryStore() else {
            print("Could not open the history database")
            return
        }
        let events = (try? store.pasteEvents(limit: limit)) ?? []
        guard !events.isEmpty else {
            print("No pastes recorded yet.")
            return
        }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"

        for event in events {
            let mark = event.outcome.succeeded ? " " : "✗"
            print("\(mark) \(stamp.string(from: event.pastedAt))  \(event.summary)")
            print("    \(event.preview)")
        }
    }

    static func printPermissions() {
        if TargetInspector.isTrusted {
            print("Accessibility: granted")
        } else {
            print("Accessibility: not granted — prompting")
            TargetInspector.requestTrust()
            print("Approve Clippy in System Settings, then re-run.")
        }
    }

    static func printTarget(after seconds: TimeInterval) {
        countDown(seconds, "Probing")

        guard let t = TargetInspector.current() else {
            print("No frontmost application")
            return
        }
        print("""
        bundle:  \(t.bundleID)
        name:    \(t.localizedName)
        kind:    \(t.kind)
        focus:   \(t.focus)
        images:  \(t.acceptsImages)
        """)
    }

    /// Pastes text into whatever is frontmost after the delay. This is the only
    /// path that actually exercises `Injector` — everything else in this harness
    /// only observes.
    static func paste(_ args: [String]) {
        var raw = false
        var words: [String] = []
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--raw":
                raw = true
            case "--after":
                i += 1  // consumed by delay(in:default:)
            default:
                words.append(args[i])
            }
            i += 1
        }

        let text = words.isEmpty ? readStdin() : words.joined(separator: " ")
        guard !text.isEmpty else {
            print("Nothing to paste. Pass text as arguments, or pipe it on stdin.")
            return
        }

        // Activation policy has to be set before we ask another app to come to
        // the front, or the frontmost-app dance does not work from a bare
        // command-line process.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        countDown(delay(in: args, default: 3), "Pasting")

        guard let target = TargetInspector.current() else {
            print("No frontmost application")
            return
        }

        let item = ClipItem(payload: .text(text))
        print("target: \(target.localizedName) (\(target.kind), focus: \(target.focus))")

        switch Injector().paste(item, into: target, autoFix: !raw) {
        case .delivered(let applied):
            let what = applied.isEmpty
                ? "unchanged"
                : applied.map(\.label).joined(separator: ", ")
            print("delivered — \(what)")
        case .failed(let failure):
            print("failed — \(failure.reason)")
        }

        // Injector defers the pasteboard restore by 400ms on the main queue.
        // Exiting immediately would skip it and leave the transformed clip
        // sitting on the user's pasteboard.
        RunLoop.main.run(until: Date().addingTimeInterval(1))
    }

    private static func readStdin() -> String {
        // Reading a terminal here would block forever waiting for EOF.
        guard isatty(FileHandle.standardInput.fileDescriptor) == 0 else { return "" }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func watch() {
        if !TargetInspector.isTrusted {
            print("warning: Accessibility not granted — focus will report as unknown\n")
        }

        print("Watching pasteboard. Copy something, then switch apps to see how it would paste.\n")

        let monitor = PasteboardMonitor { item in
            pending = item
            describe(item)
        }
        monitor.start()

        // Preflight is target-relative, so the interesting reading is not at
        // capture time — at capture time the frontmost app is the one you copied
        // *from*. Re-running it on every app switch is what actually shows the
        // rules working: copy once, then alternate between a terminal and an
        // editor and watch the findings change.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            guard let item = pending, let target = TargetInspector.current() else { return }
            preflight(item, into: target)
        }

        // Terminal-launched processes have no run loop by default; NSApplication
        // is what drives both the polling timer and NSWorkspace notifications.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.run()
    }

    // MARK: - Output

    static func describe(_ item: ClipItem) {
        let stamp = ISO8601DateFormatter().string(from: item.capturedAt)
        print("[\(stamp)] \(item.displayPreview(maxLength: 60))")
        print("  from: \(item.sourceBundleID ?? "unknown")  ·  \(item.byteCount) bytes  ·  retention: \(item.retention)")
    }

    static func preflight(_ item: ClipItem, into target: Target) {
        let result = Preflight.inspect(item, into: target)
        print("  → \(target.localizedName) (\(target.kind), focus: \(target.focus))")

        if result.findings.isEmpty {
            print("    clean\n")
            return
        }

        for f in result.findings {
            let mark = f.severity == .blocking ? "✗" : (f.severity == .warning ? "!" : "·")
            let fix = f.fix.map { " → \($0.label)" } ?? ""
            print("    \(mark) [\(f.code.rawValue)] \(f.reason)\(fix)")
        }
        print("")
    }
}

CLI.run()
