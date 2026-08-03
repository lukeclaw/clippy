# Clippy

A personal clipboard manager for macOS. Keeps a history of what you've copied and
lets you paste any of it back.

Not a product. Not competing with anything. One person, one Mac.

## Docs

Product decisions live in [docs/](docs/README.md) — read
[docs/product.md](docs/product.md) first, then
[docs/clipboard-history.md](docs/clipboard-history.md) for the core feature.

## State of the code

**It runs.** `swift build && .build/debug/clippy` puts a paperclip in the menu
bar; holding ⌘V opens the panel. Capture, persistence, search, and paste are wired
together. 109 tests pass.

What's verified: the capture loop end to end — copy something, and it lands in
`~/Library/Application Support/Clippy/history.db` attributed to the app you
copied from, and is still there after a restart. The AX focus probe has been run
against Terminal.app for real.

Also verified by driving the real UI: long-press ⌘V opens the panel while a quick
⌘V still pastes, ⏎ and double-click both paste into the target, and esc dismisses.

What isn't: most of the panel's keyboard surface — 1–9, ⌥⏎, ⌘⏎, ⌘⌫, search — has
only been exercised as logic in tests, not by a human. Expect rough edges there.

```
Sources/ClippyCore/      pure Foundation — all of it unit-tested
  MarkerTypes.swift      nspasteboard.org conventions, retention policy
  ClipItem.swift         model + redaction-safe preview
  Target.swift           target kinds, focus classifier, bundle-ID classifier
  Transforms.swift       newline strip, CRLF normalise, plain coercion, truncate
  Preflight.swift        paste diagnosis
  History.swift          in-memory list, dedup, search, concealed TTL
  HistoryStore.swift     SQLite + content-addressed blobs
  PasteEvent.swift       the paste log's model

Sources/Clippy/          AppKit glue
  main.swift             entry point; bare `clippy` runs the app
  App/
    AppDelegate.swift    status item, monitor, hotkey wiring
    HotKey.swift         Carbon ⌘⇧V (fallback)
    LongPressHotKey.swift  CGEventTap — hold ⌘V, replay a quick one
  Panel/
    PanelController.swift  non-activating NSPanel, target capture, paste
    PanelModel.swift       query, rows, badges, footer
    PanelView.swift        SwiftUI layout
  Monitor/
    PasteboardMonitor.swift   changeCount polling
  Paste/
    TargetInspector.swift     frontmost app + AX focus probe
    Injector.swift            CGEvent ⌘V, pasteboard save/restore

Tests/ClippyCoreTests/   109 tests
```

Still missing: pinning, search filters, and any preferences UI — all deferred on
purpose, see [docs/open-questions.md](docs/open-questions.md).

## Build

```sh
swift build
swift test          # ClippyCore only — this is the part that's actually verified
```

## Run it

```sh
.build/debug/clippy
```

A paperclip appears in the menu bar. **Hold ⌘V** to open the panel over whatever
you're doing — a quick ⌘V still pastes normally. **⌘⇧V** also opens it.

Type to filter, ↑↓ to move, ⏎ to paste, 1–9 to paste that row straight away, ⌥⏎
to paste without transforms, ⌘⌫ to delete, esc to dismiss. Click to select,
double-click to paste. Quit from the menu bar icon.

Long-press works by intercepting ⌘V with an event tap, so **every paste on the
machine passes through Clippy** while it runs. If pasting ever misbehaves, quit
from the menu bar and it is immediately back to normal. See
[D16](docs/decisions.md).

History lives in `~/Library/Application Support/Clippy/`. Delete that directory
to start over.

Text clips are kept **forever** — no item limit. Images are capped at 500 MB and
age out oldest-first, since they are the only payload big enough to matter.

Every paste is also logged — which clip, into which app, what was applied:

```sh
.build/debug/clippy log        # last 50
.build/debug/clippy log 200
```

Concealed clips are never logged. See [privacy.md](docs/privacy.md).

## Running it on another Mac

```sh
git clone <this-repo> && cd clippy
swift build
nohup .build/debug/clippy > /dev/null 2>&1 & disown
```

Two requirements on that machine:

- **A Swift toolchain** — Xcode or the Command Line Tools (`xcode-select --install`).
- **Accessibility granted to the terminal you launch from.** Clippy inherits the
  grant from its parent process, which is why `clippy permissions` usually
  reports "granted" without you doing anything. System Settings → Privacy &
  Security → Accessibility.

  Worth understanding what that means: the grant belongs to the *terminal*, so
  everything you run from it can post synthetic keystrokes and read other apps'
  UI — not just Clippy. Broader than you would choose deliberately.

Without Accessibility, history still records and the panel still opens, but
pasting fails with `accessibilityDenied` and long-press ⌘V won't work. ⌘⇧V still
opens the panel, since a Carbon hotkey needs no permission.

### It does not survive a reboot

Re-run the command. If that gets old, a LaunchAgent can start it at login — and
it does **not** need an `.app` bundle, because `.accessory` activation policy is
set in code rather than via `Info.plist`.

The catch is worth knowing before you start: a LaunchAgent-launched process is
parented to `launchd`, not your terminal, so it stops inheriting that
Accessibility grant and needs its own. Ad-hoc signing — what SwiftPM does by
default — has no stable identity, so TCC falls back to the binary hash and the
grant breaks on **every rebuild**. Making it stick means signing with a real
identity: an Apple Development certificate, or a self-signed one from Keychain
Access. Neither costs anything. Developer ID and notarisation are only needed for
apps downloaded through a browser, which this isn't.

So: `nohup` until restarting it annoys you, then LaunchAgent plus signing.

### Managed laptops

If the machine is under MDM, it may refuse unsigned or non-notarised binaries,
block Accessibility grants outright, or prevent clearing the quarantine
attribute. That is policy rather than packaging, and no signing choice works
around it. You will find out within a minute of trying.

Also worth a thought before installing on a work machine: Clippy writes
everything you copy to an unencrypted SQLite file, plus a log of where each paste
went. Concealed clips are excluded, but most applications never set that marker.

## Harness commands

For checking assumptions with the UI out of the way:

```sh
.build/debug/clippy permissions        # Accessibility is inherited from the
                                       # host terminal, so this usually says
                                       # "granted" without you doing anything

.build/debug/clippy target             # probe the frontmost app
.build/debug/clippy target --after 5   # …or another one, after switching to it

.build/debug/clippy watch              # copy something, then switch apps —
                                       # preflight re-runs against each one

printf 'npm install\n' | .build/debug/clippy paste   # actually paste it
```

`paste` is the only command that exercises `Injector`. It waits 3 seconds
(`--after N` to change that) so you can switch to the target, then reports what
it applied or why it refused. `--raw` skips the transforms, which is the ⌥⏎ path.

Point it somewhere harmless the first time — TextEdit, not a shell prompt.

## Before writing more code

[docs/open-questions.md](docs/open-questions.md) has three unverified assumptions
left. The first — whether a trailing newline actually submits in Claude Code — is
a one-minute check that decides whether the headline paste rule survives.
