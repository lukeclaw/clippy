# Open questions and unverified assumptions

Two categories: things not yet decided, and things assumed true that haven't been
tested on hardware.

The scaffold was written without access to a Mac. It now builds and its tests
pass, and the accessibility probe has been run for real — see Resolved below.
The paste path itself has still never executed.

## Resolved on hardware

### Terminal.app reports a focused element that Clippy reads as read-only

**Checked. The assumption was wrong, and worse than the failure mode predicted.**

Probed on macOS 26.5.2 with Terminal.app frontmost and Accessibility granted:

```
AXFocusedUIElement:  success
  role:              AXTextArea
  subrole:           nil
  roleDescription:   text entry area
  AXValue settable:  false
```

`AXTextArea` *is* in `TargetInspector.editableRoles`, so the probe falls through
to the settability check — and a terminal's `AXValue` is its screen buffer, which
is definitionally not assignable. The probe returns `.nonEditable`, Preflight
raises `focusNotEditable` at `.blocking`, and `Injector` refuses to send the
keystroke.

Verified end to end: `Preflight.inspect` on that exact target returns
`isBlocked: true`, reason "The focused element in Terminal is read-only".

**Consequence: every paste into a terminal is categorically blocked** — the one
target requirement 2 exists to serve. This is not a tuning problem; settability
of `AXValue` is simply the wrong editability signal for a terminal, which accepts
keystrokes without ever exposing a writable value. The rule needs a
terminal-specific path before the paste side can work at all.

Not yet checked in Zed, Xcode, Safari, or Firefox.

### Bundle identifiers — verified for everything installed

`com.apple.Terminal`, `dev.zed.Zed`, `com.apple.dt.Xcode`, `com.apple.TextEdit`,
`com.apple.Safari`, `org.mozilla.firefox` all confirmed correct against installed
bundles. No third-party terminal is installed, so the other eight terminal IDs in
the classifier remain unverified — harmless, and worth keeping for the day one
gets installed.

### `NSRunningApplication.activate(options:)` — moot

Deployment target raised to macOS 14, where the empty-options form is correct.

### Hotkey — settled as long-press ⌘V

⌘⇧V was proposed; long-press ⌘V won. Registered and verified: a quick ⌘V pastes
normally and does not open the panel, a 700ms hold opens the panel and does not
paste. ⌘⇧V is kept as a fallback. See [D16](decisions.md).

### The panel takes key-window status, not frontmost — by design

Opening the panel greys out the target app's title bar. Verified that this is
cosmetic: the target remains `frontmostApplication` throughout, still reports a
focused element, and a paste driven from the panel lands in it correctly
(observed end to end into TextEdit). Detail in [ux.md](ux.md).

## Unverified — test these first

Ordered by how much damage a wrong assumption does.

### 1. Does a trailing newline actually submit in Claude Code and Copilot CLI?

The whole trailing-newline rule rests on this. With bracketed paste enabled, a
TUI may insert the newline literally into the input buffer rather than submitting.
If that's what happens, the rule is noise and should be dropped or narrowed.

**How to check:** copy text with a trailing newline, paste into each tool, observe
whether the prompt submits. Takes a minute.

### 2. Pasteboard restore timing

The delay before restoring the user's original clipboard is currently a guess at
400ms. Too short and the target reads the wrong content; too long and a fast
second paste gets a stale clip.

**How to check:** paste repeatedly in quick succession and watch for wrong
content. Tune from there.

### 3. Size thresholds

Warn at 64 KB, truncate at 512 KB. Both are guesses with no measurement behind
them. Find out where terminals actually start struggling.

## Open — not yet decided

### Storage limits

1000 items and 500 MB of blobs, both proposed. No usage data behind either.
Should be constants in one place and revisited after a few weeks of real use.

### Search filters

Filtering by source app and content type is clearly useful. Whether it needs UI
or search-syntax prefixes is undecided. Don't build until the plain list feels
insufficient.

### Pinning

Common feature, probably wanted eventually, not needed for a working tool.
Deferred.

### CLI / socket interface

The idea of `clippy list|get|search` over a unix socket, so Claude Code could
query history directly, came up but was never actually decided on. It's a
plausible nice-to-have, not a requirement. Currently unbuilt and unspecified.

### Blob storage layout

Content-addressed files under `blobs/<sha256>` proposed, with text and metadata in
SQLite. Reasonable, but untested against real image volume.

## Non-questions

Settled, listed here only because they're the kind of thing that gets
relitigated:

- Not cross-platform
- Not encrypted beyond concealed items
- Not syncing
- Not fixing copy-*out* of TUIs
- Not being published
