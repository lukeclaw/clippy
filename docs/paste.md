# Paste

Getting a clip back out. Two parts: the mechanism (how the paste happens) and
preflight (a convenience layered on top).

Keep the proportion straight — **preflight is quality of life.** It makes the tool
pleasant. It is not why the tool exists, and it should never be worked on while
history is still unreliable.

## Active paste — settled

Clippy fires the keystroke itself rather than just staging the clipboard and
letting the user press ⌘V.

Sequence:

1. Snapshot the user's current pasteboard contents
2. Write the clip (transformed, if applicable)
3. Activate the target application
4. Post ⌘V via `CGEvent` to `.cghidEventTap`
5. After a short delay, restore the original pasteboard, tagged `RestoredType`

### Why active

Two reasons, in order of importance:

**It's fewer keystrokes.** Select an item, press ⏎, done. The passive model makes
you dismiss the panel and then paste separately.

**It's the only way to observe failure.** In the passive model, Clippy puts bytes
on the pasteboard and never learns what happened to them. Driving the keystroke
means real, observable outcomes.

### Costs, accepted

- Requires Accessibility permission. Without it, Clippy still records history and
  can still paste blind — permission gates the diagnostics, not the core feature.
- The pasteboard restore is timing-dependent. There's no completion signal to
  wait on; a fixed delay is the compromise every clipboard manager makes.

### Restoring the original — settled

Pasting a transformed clip must not silently rewrite what's on the user's
clipboard. Snapshot before, restore after.

The restore must carry `org.nspasteboard.RestoredType`, or the monitor will see
it as a fresh copy and add a phantom history entry on every single paste.

## Preflight — quality of life

Before pasting, compare the clip against the target and report anything that will
go wrong.

### Target-relative — settled

Findings depend on where the clip is headed. A trailing newline is flagged in a
terminal and silent in an editor. This is why findings are computed at panel-open
time against the current target, not once at capture.

### The rules

| Condition | Severity | Fix |
| --- | --- | --- |
| Image into a target that won't take one | blocking | none — don't fire the keystroke |
| Trailing newline, target is a terminal | warning | strip it |
| CRLF, target is terminal or editor | warning | normalise to LF |
| Rich text into a plain-text target | warning | coerce to plain |
| Past the terminal size ceiling | warning | truncate |
| Large but under the ceiling | info | none |

That is the whole list. **Everything Preflight produces is shown to the user** —
the footer renders findings without a fix too.

Four rules were deleted rather than demoted to a severity that hid them:

- **The three focus states.** Once the probe could no longer block, they fired on
  nearly every app on the machine. "Could not confirm a text field in Zed" on
  every paste is a permanent disclaimer, not information.
- **Concealed content.** The panel already shows it better and closer to where
  the user is looking: a lock glyph on the row, "held in memory only" in the
  preview pane.
- **Multi-line into a terminal.** The section below argues it must never be
  surfaced. A finding that must never be shown is dead code.

The rule this leaves: if a finding cannot be acted on, it does not belong in
Preflight at all.

### Nothing from the focus probe blocks — settled, the hard way

The first three rules originally had the two focus conditions as blocking. On
hardware that turned out to refuse pastes into most of the machine. Measured
across running applications:

| App | Focused element | Old verdict |
| --- | --- | --- |
| Zed | `AXWindow`, not settable | blocked |
| Firefox | `AXWindow`, not settable | blocked |
| Finder | `AXOutline`, not settable | blocked |
| Terminal | `AXTextArea`, not settable | blocked |
| Obsidian | none published | blocked |
| Notes | `AXTextArea`, settable | fine |

All of them accept a paste. Apps that render their own text — editors, browsers,
terminals, anything Electron or GPUI — either publish nothing useful or publish a
value that is definitionally not settable, because the "value" is a rendered
buffer rather than a control.

The probe therefore cannot distinguish *read-only* from *does not expose its text
to accessibility*, and the second case is the overwhelming majority. The
asymmetry decides it: a wrong block breaks the product, a wrong paste sends a
keystroke somewhere harmless. Focus findings are advisory only.

Image-into-terminal stays blocking because it is a real determination — a
terminal genuinely cannot receive image data — not an inference from a probe.

### Auto-fix is visible — settled

Warnings that carry a fix are applied by default, and named in the footer.
⌥⏎ pastes raw.

The alternative — fixing silently — is worse the first time it guesses wrong,
and a tool that quietly rewrites your clipboard is hard to trust afterwards.
Warning without fixing is also worse: you'd be manually stripping the same
newline forever.

### Multi-line stays at info — settled

Interior newlines only misbehave when bracketed paste is disabled, and bracketed
paste state lives inside the terminal emulator where it can't be observed from
outside. Rather than guess, this stays informational.

Escalating it to a warning would fire on nearly every code paste and train the
user to ignore the footer — which would cost more than it saves.

### Unknown focus never blocks — settled

If Accessibility isn't granted, or an app is busy and the probe fails, findings
degrade to `.unknown` and the paste fires anyway. Refusing to paste without a
successful probe would make the tool useless at exactly the moment someone is
deciding whether to grant permission.

### Failure reasons — settled

Every reason names the cause and, where possible, the remedy. Never "an error
occurred", never a raw error code. The text is the entire value of the feature —
if a reason can't be explained in one sentence, the rule doesn't belong.

Observable failures — these are reported because they're real, not guessed:

- Accessibility permission denied
- Blocked by a preflight rule
- Target application quit before delivery
- Target refused to activate
- macOS refused to create the keystroke event
- Nothing left after transforms

What is **not** claimed: that the receiving application successfully handled the
paste. Once the keystroke is delivered, what the target does with it is
unobservable. Clippy reports delivery, not success, and shouldn't pretend
otherwise.

## Terminal hazards, in detail

The three that motivated requirement 2.

**Trailing newline.** Code copied from a browser almost always carries one. It's
invisible in every clipboard UI. In a TUI prompt it may submit before you've
finished composing. *Unverified against Claude Code and Copilot CLI specifically
— see [open-questions.md](open-questions.md).*

**CRLF.** Text from Windows tools and some web pages carries `\r\n`, which many
TUIs render as a stray `^M`.

**Size.** Terminals read pasted input in chunks through a pty. Large payloads are
slow, and some TUIs drop the tail. Warn at 64 KB, truncate at 512 KB — both
numbers are guesses pending real use.
