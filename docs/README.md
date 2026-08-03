# Clippy docs

Product decisions for a personal macOS clipboard manager. No code here — this is
the settled thinking, written down so implementation doesn't have to re-derive it.

| Doc | What's in it |
| --- | --- |
| [product.md](product.md) | What this is, what it's for, what it isn't |
| [clipboard-history.md](clipboard-history.md) | The core feature: capture, storage, dedup, search |
| [ux.md](ux.md) | Panel layout, keybindings, states |
| [privacy.md](privacy.md) | Marker types, retention, what touches disk |
| [paste.md](paste.md) | Active paste model and preflight |
| [out-of-scope.md](out-of-scope.md) | What this deliberately won't do, and why |
| [decisions.md](decisions.md) | Decision log with rationale |
| [open-questions.md](open-questions.md) | Unsettled, plus assumptions to test on device |

## Status marks

Docs use these consistently:

- **Settled** — decided, don't relitigate without a reason
- **Proposed** — a sensible default written down so there's something to react
  to; change it freely
- **Open** — genuinely undecided
- **Unverified** — assumed true, not yet tested on hardware
