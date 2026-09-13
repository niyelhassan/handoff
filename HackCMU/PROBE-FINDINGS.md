# Phase 0b — AX probe results

Measured on macOS 26.6.2, 2026-09-12. Rerun with `./loopy probe`.

| App | Nodes | Actionable | kAXIdentifier | AXWebArea AXURL | Omnibox | Verdict |
|---|---|---|---|---|---|---|
| **Safari** | 1232 (depth 13) | 350 | 10% | yes | yes | **Strong** |
| **Finder** | 204 (depth 6) | 126 | 5% | — | — | **Strong** |
| **Chrome** | 118 (depth 13) | 31 | 0% | yes | yes | **Degraded** |
| **Terminal** | 16 (depth 4) | 8 | 6% | — | — | **Unusable for AX** |

## What this changes

**Browser task context works — both ways.** This was the open risk: semantic
matching in browsers is anchored on the URL, and we did not know if it was
readable. Both `AXWebArea`'s `AXURL` and the omnibox `AXValue` return the live
URL in *both* Safari and Chrome. Prefer AXURL, fall back to the omnibox.
Caveat: on `chrome://` pages there is no AXWebArea at all, so the omnibox
fallback is load-bearing, not decorative.

**Safari is the browser to demo, not Chrome.** Even with AXManualAccessibility
*and* AXEnhancedUserInterface forced, Chrome exposes a stub content tree: 118
nodes with 2 AXLinks on a Wikipedia article, against Safari's 1232 nodes with
128 AXLinks on a comparable page. Element-level replay inside Chrome web
content will mostly fall through to coordinates. Chrome's *browser chrome*
(tabs, toolbar, omnibox) is fine.

**Terminal has no usable tree.** 16 nodes, all window furniture — the text grid
is not enumerable. Consequence for the plan: Terminal `TaskContext` cannot come
from the AX tree and must be derived from captured keystroke atoms (first token
of the typed line). Replay in Terminal is keystroke synthesis only. This is
workable — we capture keystrokes directly — but the window-movement robustness
story does not apply there.

**kAXIdentifier is 0–10% populated everywhere.** Confirms the plan's design:
`rolePath` + stabilized title + ordinal is the primary locator. Identifier is a
bonus, never a requirement.

## Demo ranking

1. **Finder** — 31 AXRow/AXCell in a single window is exactly the structure the
   `axSibling` generator needs, and it yields the loop bound for free.
2. **Safari** — richest tree of anything measured; the Gmail-style
   "same task across different pages" demo should be built here.
3. Chrome — only if the demo stays in browser chrome (tab/omnibox level).
4. Terminal — keystroke-level patterns only.
