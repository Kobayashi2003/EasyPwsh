---
name: chrome-devtools-automation
description: Drive the Chrome DevTools front end itself over CDP — switch panels (Network, Application, Elements…), run Command Menu actions, operate the cookie/storage trees, click or type inside the DevTools UI, and screenshot DevTools. Use when a task needs a specific DevTools panel open or needs to script the DevTools UI, as opposed to the page under test (which Playwright and the page CDP session already handle).
---

# Operating the Chrome DevTools front end

Playwright and the page CDP session drive **the page**. Neither can drive **DevTools itself** —
which panel is open, the cookie tree, the network log. DevTools is its own CDP target; connect to
it and script its UI directly.

## Connect

Launch Chrome with `--remote-debugging-port=9333 --auto-open-devtools-for-tabs`, then dot-source the
helpers. Everything below goes through one cached WebSocket.

```powershell
. <skill>/scripts/devtools.ps1
Connect-DevTools -Port 9333 -PageUrl 'localhost:5173'
Select-DevToolsPanel tab-network
Clear-NetworkLog
Show-CookiePanel
Save-DevToolsScreenshot ./devtools.png
```

`http://localhost:<port>/json` lists every target. DevTools front ends are `page` targets whose url
starts with `devtools://`. With several tabs inspected at once there are several — **`-PageUrl`
picks the right one by matching the DevTools target's *title*** (`"DevTools - example.com/"`), because
modern Chrome no longer puts `targetId` in the DevTools url. Without it you connect to an arbitrary
DevTools window and every later step operates on the wrong tab.

## What breaks, and what works

- **The UI is all shadow DOM.** `document.querySelector` finds nothing — you must walk into every
  `.shadowRoot` recursively. This is the single most common reason a check "silently always fails":
  a verification predicate written with a plain `querySelector` can never be true. Use
  `Get-DevToolsElementInfo` / `Wait-DevToolsDeep`, never a raw predicate, for anything in the UI.
- **`element.click()` is ignored.** DevTools reacts to real input: read the bounding box, then
  dispatch `mouseMoved` → `mousePressed` → `mouseReleased` at its centre. (The hover event first —
  some toolbar buttons only accept the press once hovered.)
- **A compound selector usually matches something hidden first.**
  `[aria-label="Clear network log"], [title^="Clear"]` matched 18 elements here, and the first had a
  0×0 rect — clicking it does nothing. The deep query therefore returns the first **visible** match
  while still reporting that the element exists, so "exists but scrolled away" stays distinguishable
  from "does not exist". Prefer exact `aria-label`s anyway.
- **Scripted panel APIs (`showPanel`, `InspectorView.instance()`) drift across versions and silently
  no-op.** Click the tab instead; the ids are stable: `#tab-elements`, `#tab-console`,
  `#tab-sources`, `#tab-network`, `#tab-resources` (Application), `#tab-timeline` (Performance).
- **Panels that don't fit are hidden in the "More tabs" (») overflow, and that menu renders OUTSIDE
  the DevTools document** — it cannot be found or clicked over CDP. `Select-DevToolsPanel` detects
  this and falls back to the **Command Menu** (Ctrl+Shift+P → "Show Application" → Enter), which
  reaches every panel regardless of window width. Text goes in with `Input.insertText`, not
  per-character key events.
- **Tree rows are virtualised.** A row scrolled out of view has a `0×0` rect and can't be clicked;
  `scrollIntoView` and `scrollTop` don't fix it. Navigate with the keyboard — the tree scrolls itself
  to whatever it selects.
- **Keys need `rawKeyDown`** (not `keyDown`), and the tree must already have focus (click a visible
  row first). `code` is the *physical* key and differs from `key` for letters/digits (`'a'` →
  `'KeyA'`); a widget listening on `e.code` sees nothing if you send the wrong one.
- **Normalise before relative moves.** `ArrowRight` on an already-expanded node steps into its child
  instead of expanding, so a following `ArrowDown` overshoots. Collapse first:
  `ArrowLeft → ArrowRight → ArrowDown` is deterministic regardless of prior state.

## CDP transport: three ways to get silently wrong answers

`scripts/devtools.ps1` handles all three. Keep them if you write your own client.

1. **A CDP socket interleaves events with responses.** "Send, then read one frame" very often returns
   a `Network.*` or `Runtime.consoleAPICalled` event instead of your result. Give every request a
   unique id and read until *that* id comes back.
2. **Large payloads arrive in several frames.** A big `Runtime.evaluate` result exceeds the receive
   buffer; taking only the first chunk yields truncated JSON, which then fails to parse and — if the
   error is swallowed — looks exactly like "element not found". Reassemble until `EndOfMessage`.
3. **`Runtime.evaluate` reports JS exceptions in `exceptionDetails`, not as a protocol error.** A
   thrown exception otherwise reads as an empty result. Surface it.

Also: one debugger per target. If the WebSocket opens then immediately closes, another client
(Playwright, a second script, the `chrome-devtools` MCP server) already holds that target.

## Efficiency

- **One cached socket.** Reconnecting per call cost ~80–150 ms each; a ten-step recipe paid a second
  of pure handshake. `Get-DevToolsSocket` reuses the connection and transparently reconnects if
  DevTools reloads.
- **Poll a predicate, never sleep a fixed amount.** Panels and trees settle at wildly different
  speeds depending on how much the page logged. `Wait-DevToolsDeep` / `Wait-DevToolsCondition`
  replace `Start-Sleep` and are both faster and more reliable.
- **Skip work that's already done.** `Select-DevToolsPanel` returns immediately if the tab is
  already `aria-selected`.
- **Screenshot DevTools through CDP** (`Save-DevToolsScreenshot` → `Page.captureScreenshot`), not
  through an OS screen grab: sharper, cheaper, and it needs no window focus.
- One deep DOM walk scans ~1–2 k nodes; the walker is bounded by depth (14) and a 30 k node budget
  so a huge Network log or Elements tree can't turn one lookup into a multi-second hang.

## Recipes

- **Switch panel:** `Select-DevToolsPanel tab-network` — clicks the tab, or routes through the
  Command Menu when it's in the » overflow, then verifies `aria-selected`.
- **Any other DevTools action:** `Invoke-DevToolsCommand 'Disable JavaScript'` (anything the Command
  Menu offers).
- **Select a site's cookies** (the row that renders the HttpOnly/SameSite table, not the "Cookies"
  help page): `Show-CookiePanel` — opens Application, clicks the `Cookies` row to focus the tree,
  then `ArrowLeft, ArrowRight, ArrowDown`, and confirms a cookie table actually appeared.
- **Clear the network log:** `Clear-NetworkLog` (opens the Network panel first).
- **Find out what's on screen:** `Get-DevToolsTabs` lists the tab strip; `Get-DevToolsElementInfo
  '[aria-label*=Clear]'` reports `found` / `visible` / `count` for any selector.

## Helpers

`scripts/devtools.ps1` implements all of the above.

| Function | Purpose |
|---|---|
| `Connect-DevTools` / `Disconnect-DevTools` | Open (and cache) the socket; `-PageUrl` picks the right DevTools window |
| `Send-DevToolsCommand` | One CDP command, id-correlated, multi-frame safe, throws on error |
| `Invoke-DevToolsScript` | `Runtime.evaluate` returning parsed JSON; surfaces JS exceptions |
| `Get-DevToolsElementInfo` / `Get-DevToolsElementPoint` | Shadow-DOM lookup → found / visible / count / click point |
| `Get-DevToolsTabs` | Which panel tabs exist and which is selected |
| `Invoke-DevToolsClick` / `Send-DevToolsKey` | Real mouse and `rawKeyDown` input, with modifiers |
| `Select-DevToolsPanel` / `Invoke-DevToolsCommand` | Open a panel (tab or Command Menu); run any command |
| `Wait-DevToolsDeep` / `Wait-DevToolsCondition` | Poll a shadow-DOM selector / a raw JS predicate |
| `Clear-NetworkLog` / `Show-CookiePanel` | The two recipes above |
| `Save-DevToolsScreenshot` | PNG of the DevTools UI via `Page.captureScreenshot` |

For anything the DevTools UI genuinely can't expose — resizing or undocking the DevTools window so a
panel stops landing in the » overflow — drive the window itself with the **computer-use** skill.
