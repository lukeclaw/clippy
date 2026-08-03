# UX

One surface: a panel that opens over whatever you're doing, lets you find a clip,
and pastes it. There is no main window, no preferences window worth designing
yet, and no dock icon.

## Invocation — settled

**Hold ⌘V.** A quick ⌘V pastes normally; holding it past 350ms opens the panel at
the mouse cursor. ⌘⇧V also opens it, and is kept as a fallback that does not
depend on the event tap — see [D16](decisions.md).

⌘⇧V was the original proposal, matching Raycast. Long-press ⌘V won because it
puts the panel on the key you already press to paste, with nothing new to learn.

## The hard constraint — settled

**Capture the paste target before showing the panel.**

Snapshot the target (`NSWorkspace.frontmostApplication`, plus the AX focus probe)
*before* the panel is presented, and make the panel a non-activating `NSPanel` —
`.nonactivatingPanel` style, overriding `canBecomeKey`.

This is the single most common way this category of app breaks. It's written here
rather than left as a code comment because it constrains the UI framework choice,
not just one file.

### What "non-activating" does and does not preserve

Measured, because the distinction matters and the original wording here was
wrong. Two different things get called focus:

- **Active application** — `NSWorkspace.frontmostApplication`. This is what the
  target snapshot and the paste both use, and it does **not** change when the
  panel opens. Verified: the target app is still frontmost with the panel up, and
  still reports a focused element.
- **Key window** — which window receives keystrokes. This *does* move to the
  panel, because the panel has to receive typing. The target's title bar greys out
  and its selection highlight dims.

So the target does not keep its focus ring; it keeps the thing that matters,
which is being recoverable and pasteable. Avoiding even the key-window change
would mean reading keys through a `CGEventTap` instead of letting the panel
become key — more machinery for a cosmetic gain, not currently worth it.

## Layout

Top to bottom:

**Search field.** Focused on open. Typing filters immediately. Empty means show
everything.

**The list.** Reverse chronological. Each row shows:

- a position number for the first nine items
- a one-line preview of the content
- source app, relative time, and size where meaningful
- a badge, only when the current target makes one relevant

**Preview pane.** The selected item, rendered larger. Multi-line text keeps its
structure. Images render as thumbnails.

**Footer.** Names the paste target, and states any transform about to be applied.
Empty when there's nothing to say — see [paste.md](paste.md).

**Key hint row.** The available actions.

## Keybindings — settled

| Key | Action |
| --- | --- |
| Type | Filter |
| ↑ ↓ | Move selection |
| 1–9 | Select and paste that item immediately |
| ⏎ | Paste selected, with fixes applied |
| ⌥⏎ | Paste raw — no transforms |
| ⌘⏎ | Paste as plain text |
| ⌫ | Delete a character from the query; deletes the selected item when the query is empty |
| ⌘⌫ | Delete selected item from history, always |
| esc | Dismiss, no action |

Number keys pasting immediately is the fastest path and worth preserving —
most uses are "the thing I copied two clips ago".

⌫ is split because the original single binding predates there being a query to
edit. Deleting history out from under someone who is mid-search, with no
confirmation and no undo, is a bad surprise; ⌘⌫ is the unambiguous form and is
what the key-hint row advertises.

## Mouse

| Action | Result |
| --- | --- |
| Hover | Highlights the row |
| Click | Select |
| Double-click | Paste, with fixes applied |

Clicking needs `acceptsFirstMouse` on the hosting view: Clippy is never the
active application, so otherwise the first click on the panel is spent activating
it and never reaches the row underneath.

## Badges — settled in principle

Badges appear on rows only when the current target makes them relevant. A trailing
newline earns a badge when pasting into a terminal and nothing at all when
pasting into an editor.

This means badges recompute on every panel open, against the current target. They
cannot be computed once at capture time and stored.

## Redacted rows — settled

Concealed items appear in the list as dots, never their content, with a lock
glyph and their source app. They are pasteable but never legible in the UI, and
never written to disk. See [privacy.md](privacy.md).

Redaction happens in the model layer, not the view layer — the UI must not be
able to leak a password by forgetting to check a flag.

## Empty and error states — proposed

- **No history yet:** "Nothing copied yet." Nothing more.
- **No search results:** "No matches." Nothing more.
- **Accessibility not granted:** a single dismissible line at the top of the
  panel with a button to open System Settings. The tool still works — history
  still records, pastes still fire blind. Permission gates the focus probe and
  the failure reasons, not the core feature.
- **Paste failed:** the panel stays open and shows the reason inline rather than
  posting a notification. The user is already looking at the panel; putting the
  explanation somewhere else makes them hunt for it.

## Deliberately absent

- No preferences window until there's a setting worth changing
- No menu-bar dropdown duplicating the panel — one way to do things
- No animations beyond the panel's own appearance
- No onboarding
