# Out of scope

Things that sound like they belong, with the reason they don't.

## Copying *out* of Claude Code and Copilot CLI

The original requirement mentioned Ctrl+C behaving oddly in these tools. That is
real, and it cannot be fixed from a clipboard manager.

### What's actually happening

These TUIs enable terminal mouse reporting. Once that's on, the terminal emulator
forwards mouse events to the running application instead of using them for native
text selection. Drag-select stops working, so ⌘C copies nothing or stale content.
The application then provides its own in-app copy binding to compensate — and
Copilot CLI bound it to Ctrl+C, which already means SIGINT.

Documented in [copilot-cli#2344](https://github.com/github/copilot-cli/issues/2344),
closed, filed under their `area:input-keyboard` label. Related reports:
[#1733](https://github.com/github/copilot-cli/issues/1733) (paste not working),
[#2082](https://github.com/github/copilot-cli/issues/2082) (Ctrl+Shift+C on Linux),
[#267](https://github.com/github/copilot-cli/issues/267) (Windows copy/paste).

### Why Clippy can't help

The failure happens entirely inside the terminal, before anything reaches
`NSPasteboard`. There is no event to intercept and no pasteboard write to correct.
A clipboard manager can only act on content that reaches the clipboard.

### What actually fixes it

Terminal configuration, not software. In iTerm2 and Terminal.app, holding ⌥ while
dragging bypasses mouse reporting and gives native selection. Some terminals let
you disable mouse reporting per-profile.

Worth knowing, not worth building.

## Detecting which TUI is running inside a terminal

Clippy sees the host terminal — Ghostty, iTerm2, Terminal.app — not whether Claude
Code or Copilot CLI is running inside it. Knowing that would require inspecting
the terminal's tty and walking the foreground process group.

Not worth it: the paste hazards are the same for every TUI, so "is this a
terminal" is already the right granularity. Revisit only if a rule is needed that
applies to one CLI and not others.

## Cross-platform support

macOS only. The Linux clipboard model (X11 selection ownership, or Wayland where
clips die with the source process) and the Windows model are different enough
that supporting them is a different program. There is no second machine.

## Sync

One machine. No.

## Encrypting ordinary history

Concealed items never reach disk, which addresses the real risk. Encrypting the
rest defends against someone who already has filesystem access, and the key would
have to live on the same machine regardless. See [privacy.md](privacy.md).

## Publishing it

Not an App Store product, not open source with users to support, no landing page.
This is a personal tool. Features that only make sense for a product — onboarding,
settings UI, update checks, crash reporting — are all out.

## Clipboard transforms as a user-facing feature

Transforms exist to fix known paste hazards. They are not a "run text through a
pipeline" surface. If arbitrary text munging is wanted later, that's a different
tool and shouldn't be smuggled in here.
