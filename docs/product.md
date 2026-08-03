# Product

## What this is

A clipboard manager for one person, on one Mac. It keeps a history of what you've
copied and lets you paste any of it back.

That's the product. Everything else in these docs is in service of that or is a
convenience layered on top.

## What this is not

Not a product to publish. Not competing with Maccy, Raycast, or Alfred. There is
no need for a differentiating feature, and no reason to carry the complexity that
chasing one would bring. If an existing tool already does something well, copying
its behaviour outright is the correct move.

The practical consequence: **when a decision is close, pick the boring option.**
No plugin system, no sync, no themes, no telemetry, no onboarding flow.

## Requirements

Three, from the original brief, as scoped after discussion.

### 1. Clipboard history — the core

Capture what goes on the pasteboard, keep it, let it be searched and pasted back.
Everything in [clipboard-history.md](clipboard-history.md). This is the reason
the tool exists; if only this worked, the tool would be a success.

### 2. Interoperability with Claude Code and Copilot CLI

Scoped down during discussion to **paste-in only**.

Pasting into these tools should not mangle content. The known hazards are
trailing newlines, CRLF line endings, and oversized payloads — all handled in
[paste.md](paste.md).

Copying *out* of them is out of scope for a reason that isn't laziness; see
[out-of-scope.md](out-of-scope.md).

### 3. Explain why a paste failed

Achievable only because we chose the active paste model — Clippy fires the
keystroke itself, so it can observe real failures rather than guessing. See
[paste.md](paste.md).

Sized correctly: this is **quality of life**, not the headline. It's a nicety
that makes the tool pleasant. It is not a reason to build the tool, and it should
never be prioritised over history working properly.

## Priority order

When time is short, this is the order:

1. History captures reliably and survives restart
2. Panel opens, searches, and pastes back
3. Concealed content never hits disk
4. Preflight warnings
5. Everything else

## Platform

macOS only. **Settled.** No cross-platform ambitions — the Linux and Windows
clipboard models are different enough that supporting them means a different
program, and there's no second machine to run it on.

Minimum target: macOS 14. **Settled.** Raised from 13 because there is no install
base to worry about and the only machine runs macOS 26. This removed the
`NSRunningApplication.activate(options:)` question outright — the empty-options
form is correct on 14+.

## Language and shape

Swift, menu-bar agent (`LSUIElement` / `.accessory` activation policy).
**Settled.** The accessibility and event-injection APIs this needs are
Objective-C frameworks; driving them from anything other than Swift or ObjC means
a bridging layer for no benefit.
