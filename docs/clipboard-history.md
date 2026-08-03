# Clipboard history

The core feature. If this works and nothing else does, the tool is worth running.

## Capture

### Mechanism — settled

Poll `NSPasteboard.general.changeCount` on a timer. When it differs from the last
observed value, read the pasteboard and record.

There is no alternative. macOS provides no change notification for the
pasteboard; polling is what every clipboard manager on the platform does.

**Interval: 200ms.** Fast enough that the panel never shows stale content, cheap
enough to be invisible. The timer must be scheduled in `RunLoop.Mode.common` so
it keeps firing while menus and panels are tracking — that's precisely when a
copy is likely.

### What gets read — settled

Read the richest representation the source offered, and let paste-time decide
what to downgrade. Priority order:

1. File URLs (if all items are file URLs)
2. Image data — TIFF, then PNG
3. Rich text (RTF), keeping the plain-text rendering alongside as a fallback
4. Plain text

Anything that yields none of the above is not recorded.

### Attribution — settled

Record `NSWorkspace.shared.frontmostApplication?.bundleIdentifier` at capture
time. It requires no permission, costs nothing, and makes search far better in
practice — people remember *where* they copied something from more reliably than
what it said.

### What is never recorded — settled

Checked before anything else touches the item:

| Condition | Behaviour |
| --- | --- |
| `org.nspasteboard.TransientType` | Drop |
| `org.nspasteboard.RestoredType` | Drop |
| `org.nspasteboard.ConcealedType` | Memory only, redacted — see [privacy.md](privacy.md) |
| Empty payload | Drop |
| Clippy is the source app | Drop |

The `RestoredType` rule matters more than it looks. After pasting a transformed
clip, Clippy puts the user's original back on the pasteboard. That restore bumps
`changeCount` and looks exactly like a fresh copy. Without the marker, every
paste would add a phantom duplicate to history. This is the kind of bug that
takes a week to notice and an hour to trace, so it's designed out rather than
fixed later.

## The item model

Settled:

| Field | Notes |
| --- | --- |
| `id` | UUID |
| `capturedAt` | First seen |
| `lastUsedAt` | Updated on re-copy and on paste — this is the sort key |
| `payload` | text / richText / image / files |
| `sourceBundleID` | Nullable |
| `markers` | Set of nspasteboard marker types |

## Deduplication — settled

Comparison is on payload content: exact string for text, byte-equality (or a
hash) for images and files.

- **Identical to the most recent item** → do nothing. Don't reorder, don't
  update timestamps. Copying the same thing twice shouldn't churn the list.
- **Identical to an older item** → update that item's `lastUsedAt` and let it
  sort to the top. Do not create a second row.
- **Otherwise** → new item.

Rich text and its plain fallback count as the same item if the plain text
matches and the RTF matches. Differing RTF with identical plain text is a new
item — the formatting is a real difference.

## Ordering — settled

Reverse chronological by `lastUsedAt`. Pasting an old item brings it to the top,
because having just used it makes it likely you'll want it again.

## Storage

### Engine — settled

SQLite, via the system `libsqlite3`. No ORM, no dependency. The schema is small
enough that hand-written SQL is less work than any abstraction over it.

### Location — proposed

```
~/Library/Application Support/Clippy/
  history.db          text items, metadata, references to blobs
  blobs/<sha256>      image and file payloads
```

Large payloads live on disk rather than in the database. Keeps the DB small and
fast to open, and makes eviction a file delete. Content-addressing gives
deduplication of identical screenshots for free.

### Capacity — settled

**Text is kept forever. Images are capped at 500 MB.**

The 1000-item cap originally proposed here is gone. Text and file clips run about
a kilobyte each, so keeping every one forever costs well under a gigabyte per
decade — there was never a storage argument for discarding them, and "the thing I
copied months ago" is exactly what a history is for.

Images are the exception and keep their budget. At 0.3–2 MB each they dominate
everything else within weeks, so the oldest by `lastUsedAt` are evicted once the
blob directory passes the ceiling.

Both live in `HistoryLimits`; `maxItems` is `nil`, meaning no cap.

Eviction reports which items it removed so the in-memory list can drop them too.
Without that, an image evicted under the budget would keep appearing in the panel
until the next launch and then vanish — a clip that is offered but cannot be
pasted.

## The paste log

Separate from the clips themselves: one row per paste, recording which clip, the
target application and kind, the transforms applied, and whether it succeeded.
Read it with `clippy log`.

Two design points, both covered in [privacy.md](privacy.md): concealed clips are
never logged, and each event carries its own copy of the clip preview so it stays
readable after the clip is evicted or deleted.

### Restart — settled

Persisted history loads on launch. Concealed items are memory-only and are simply
gone after a restart; that's correct behaviour, not a bug.

## Search

### Behaviour — settled

Substring match, case-insensitive, against the plain-text rendering. Matches as
you type, no submit.

**Only the first 2 KB of each clip is searched.** Search cost scales with the
total volume of stored text, and history is now unbounded for text (D17). At
20,000 clips a full scan cost 323 ms per keystroke; the bound brings it to 46 ms.
The trade is that text more than 2 KB into a large clip cannot be found — what
you search for is nearly always near the start.

Two measurements worth recording, because both contradict the obvious guess:
precomputing lowercased search keys is *no faster* than lowercasing inline (the
cost is the scan, not the allocation), and `range(of:options:.caseInsensitive)`
is four times *slower* than `lowercased().contains`.

FTS5 remains the escape hatch if the 2 KB bound starts to bite.

Deliberately not fuzzy to begin with. Substring is predictable — you can tell
why something matched — and fuzzy matching's benefit shows up mostly in large
corpora. Revisit if 1000 items feels slow or imprecise in practice; SQLite FTS5
is available without adding a dependency.

Items with no text rendering (images) match on their source app name and file
name only.

### Filters — open

Filtering by source app and by content type is obviously useful. Whether it needs
UI, or whether search-syntax prefixes are enough, is undecided. Don't build it
until the plain list feels insufficient.

## Pinning — open

Keeping a few items permanently at the top is a common feature and probably
worth having eventually. Not needed for a working tool. Deferred.

## Explicitly not doing

- **Sync across machines.** One machine.
- **Encryption of ordinary history.** Concealed items never reach disk, which is
  the actual risk. Encrypting the rest protects against an attacker who already
  has your filesystem — at which point the clipboard database is not the problem.
  Revisit only if the threat model changes.
- **Editing clips in place.** Paste it, change it there.
- **Clipboard-to-clipboard transforms as a feature surface.** Transforms exist
  only to fix known paste hazards; see [paste.md](paste.md).
