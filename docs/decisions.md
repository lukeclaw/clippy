# Decision log

Decisions made, with the reasoning that produced them. Reversing one is fine —
knowing why it was made first is the point.

All dated 2 August 2026 unless noted; they came out of the initial design
conversation.

---

## D1 — History is the product; preflight is a convenience

Requirement 3 (explain paste failures) was initially framed as the headline
feature. It isn't. This is a personal tool, not something being differentiated
against Maccy or Raycast, and clipboard history working reliably is the entire
reason to build it.

**Consequence:** preflight never gets worked on while history is unreliable. When
a decision is close, pick the boring option.

---

## D2 — macOS only

No second machine. The Linux and Windows clipboard models are different enough
that supporting them means a different program.

---

## D3 — Swift, menu-bar agent

The accessibility and event-injection APIs are Objective-C frameworks. Driving
them from another language adds a bridging layer for no benefit.

---

## D4 — Active paste over passive staging

Clippy posts ⌘V itself rather than staging the clipboard and letting the user
paste.

Fewer keystrokes, and it's the only model in which paste failure is observable at
all. In the passive model Clippy puts bytes on the pasteboard and never learns
what happened.

**Cost accepted:** requires Accessibility permission. Degrades gracefully without
it — history still records, pastes still fire blind.

---

## D5 — Concealed clips: memory-only and redacted

`org.nspasteboard.ConcealedType` downgrades retention to in-memory, redacted,
5-minute TTL. Never written to disk.

Rejected *drop entirely* — "paste the password twice" is real, and silent gaps in
history are confusing. Rejected *encrypt on disk* — key management, Touch ID, a
keychain entry, all for a case the in-memory window already covers.

---

## D6 — Auto-fix is applied and named, not silent

Warnings carrying a transform are applied by default and stated in the footer,
with ⌥⏎ to paste raw.

Silent fixing is worse the first time it's wrong. Warning without fixing means
manually stripping the same newline forever.

---

## D7 — Multi-line paste is never flagged — *superseded by D19*

Interior newlines only misbehave when bracketed paste is off, and that state
lives in the terminal emulator where it can't be observed. Warning on every
multi-line paste would train the user to ignore the footer.

The reasoning stands; D19 took it to its conclusion and removed the finding
entirely rather than keeping one that must never be displayed.

---

## D8 — Unknown focus never blocks — *extended by D15*

If the AX probe fails, findings degrade to `.unknown` and the paste fires anyway.
Blocking would make the tool useless at the moment someone is deciding whether to
grant permission.

---

## D9 — Copy-out of TUIs is out of scope

The Ctrl+C problem in Claude Code and Copilot CLI is caused by terminal mouse
reporting suppressing native selection. It happens before anything reaches
`NSPasteboard`, so there's nothing for a clipboard manager to intercept. Full
detail in [out-of-scope.md](out-of-scope.md).

---

## D10 — Restores are marked `RestoredType`

After pasting a transformed clip, the original goes back on the pasteboard tagged
`org.nspasteboard.RestoredType`, and the monitor drops anything so tagged.

Without it, the restore bumps `changeCount`, looks like a fresh copy, and every
paste adds a phantom history entry.

---

## D11 — Target is captured before the panel is shown

Once Clippy's panel takes focus, Clippy is frontmost and the real target is
unrecoverable. The panel must be a non-activating `NSPanel`, and the target
snapshot must happen first.

Recorded as a decision rather than a code comment because it constrains the UI
framework choice.

---

## D12 — Core/App split

Everything that makes a judgement lives in a pure-Foundation module with tests.
Everything that talks to the OS is thin glue.

Partly good practice, partly circumstance: the initial scaffold was written
without a Mac, so testable-anywhere logic was the only part that could be
verified at all. The split is worth keeping regardless.

---

## D13 — Ordinary history is not encrypted

Concealed items never reach disk, which addresses the real risk. Encrypting the
rest defends against an attacker who already has the filesystem, with a key that
lives on the same machine.

Revisit if the machine stops being solely yours.

---

## D14 — Substring search, not fuzzy

Predictable — you can tell why something matched. Fuzzy matching earns its
complexity on large corpora; 1000 items isn't one. FTS5 is available without a
new dependency if it turns out to be needed.

---

## D15 — *No* focus finding blocks a paste — extends D8

D8 said unknown focus never blocks. On hardware that turned out not to go far
enough: `.nonEditable` and `.none` must not block either.

Measured across running apps — Zed and Firefox report `AXWindow`, Finder reports
`AXOutline`, Terminal reports `AXTextArea` whose value is the screen buffer, and
Obsidian publishes no focused element at all. Every one of them accepts a paste.
Apps that render their own text simply do not expose it through accessibility.

The probe cannot distinguish *read-only* from *does not publish its text*, and the
second case is the overwhelming majority. The asymmetry decides it: a wrong block
breaks the product, a wrong paste sends a keystroke somewhere harmless.

Image-into-terminal remains the one blocking finding, because it is a real
determination rather than an inference from a probe.

**Cost accepted:** pasting into a genuinely read-only element now fails silently
rather than being explained. That is the lesser failure.

---

## D16 — Long-press ⌘V is the trigger; ⌘⇧V stays as a fallback

Holding ⌘V opens the panel. A quick ⌘V pastes normally.

This cannot be a Carbon hotkey: `RegisterEventHotKey` fires on key-down and
consumes the combination, so binding ⌘V that way would break ordinary pasting
everywhere. Distinguishing a tap from a hold means intercepting ⌘V, waiting, and
then deciding — which requires an active `CGEventTap`.

**Cost accepted, and it is not small:** every ⌘V on the machine passes through
Clippy. A quick press is swallowed and replayed, so an ordinary paste is delayed
until key release — tens of milliseconds. If the tap dies, pasting breaks
system-wide.

Mitigations, both required:

1. `.tapDisabledByTimeout` and `.tapDisabledByUserInput` are handled by
   re-enabling the tap immediately.
2. ⌘⇧V remains registered as a Carbon hotkey, which depends on none of this, so
   there is always a way in. Quitting Clippy restores normal pasting instantly.

Only bare ⌘V is intercepted; ⌘⇧V, ⌘⌥V and ⌘⌃V keep whatever they already mean.

---

## D17 — Text history is forever; only images are capped

The 1000-item cap is removed. Text and file clips are ~1 KB each, so keeping
every one costs well under a gigabyte per decade. There was no storage argument
for evicting them, and reaching back months is the point of a history.

Images keep the 500 MB budget — at 0.3–2 MB each they dominate everything else
within weeks.

**Consequence:** eviction now returns the IDs it removed, so the in-memory list
drops them too. Otherwise an evicted image stays visible in the panel until
relaunch, offering a clip that cannot be pasted.

---

## D18 — Pastes are logged as events

One row per paste: clip, target app and kind, transforms applied, outcome.
Readable with `clippy log`.

This adds a category the tool did not previously keep — **behaviour**, not
content. Recorded here because that is a real change in what Clippy retains about
its user, not a detail of a feature.

Two constraints, both in [privacy.md](privacy.md):

- Concealed clips are never logged, not even as metadata. "Pasted into Slack at
  14:32" is still a record that a credential moved.
- Each event carries its own copy of the clip preview instead of joining to
  `items`, so it stays readable after the clip is evicted or deleted.

No panel UI for it yet, deliberately — the project's own rule is not to build the
interface until the plain version feels insufficient.

---

## D19 — A finding that cannot be acted on is deleted, not demoted

`Preflight` had ten finding codes; five never reached the user, because the
footer only rendered blocking reasons and fix labels. The instinct was to surface
them. Reading the actual strings killed that idea:

- "Could not confirm a text field in Zed — pasting anyway" fires for Zed,
  Firefox, Finder, Terminal and most other apps after D15. A message shown on
  nearly every paste is a disclaimer, not information.
- "This item is marked confidential…" duplicates what the panel already shows
  with a lock glyph and a preview-pane label, closer to where the user looks.
- "Multi-line paste — relies on bracketed paste being enabled" is unactionable,
  and D7 argues it must never be surfaced.

So four were deleted and the fifth — the oversize note — was surfaced.
`footerSummary` now renders findings without a fix, so everything Preflight
computes is visible.

**Rule:** if a finding cannot change what the user does, it does not belong in
Preflight. Demoting it to `info` just hides the problem behind a severity.

---

## D20 — Search reads only the first 2 KB of each clip

Search cost scales with total stored text, and D17 made that unbounded. At 20,000
clips a full scan cost 323 ms per keystroke.

Two plausible fixes measured as wrong before the right one was found:
precomputing lowercased keys was identical to inline lowercasing (299 vs 300 ms —
the cost is the scan, not the allocation), and `range(of:options:)` was four
times *slower* than `lowercased().contains`. Bounding the scan to 2 KB per clip
took it to 46 ms.

**Cost accepted:** text more than 2 KB into a large clip is not findable. Pinned
by a test rather than left to be discovered. FTS5 is the escape hatch.

Related: the panel builds at most 500 rows and says "+N more" rather than
truncating silently, since every row costs a Preflight pass for its badge.
