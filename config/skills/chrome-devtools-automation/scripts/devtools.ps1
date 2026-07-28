<#
.SYNOPSIS
    Drives the Chrome DevTools front end over CDP
.DESCRIPTION
    Dot-source this file to get helpers that talk to the DevTools UI itself (not the page):
    switching panels, clicking inside shadow roots, sending keys, and clearing the network log.
    Chrome must already be running with --remote-debugging-port.

    Design notes that matter for correctness:
      * ONE cached WebSocket per session. Reconnecting per call cost ~80-150ms each and made a
        10-step recipe take seconds.
      * Every request gets a UNIQUE id and we read until THAT id comes back. A CDP socket
        interleaves events with responses, so "send, read one frame" silently returns an event.
      * Frames are reassembled until EndOfMessage. A large Runtime.evaluate result arrives in
        several chunks; taking only the first yields truncated JSON.
      * Runtime.evaluate exceptions are surfaced, not swallowed.
      * Waits are predicate polls, not fixed sleeps.
.EXAMPLE
    PS> . ./devtools.ps1
    PS> Connect-DevTools -Port 9333
    PS> Select-DevToolsPanel tab-network
    PS> Clear-NetworkLog
.EXAMPLE
    PS> . ./devtools.ps1
    PS> Connect-DevTools -PageUrl 'localhost:5173'
    PS> Show-CookiePanel
.NOTES
    Author: KOBAYASHI
#>

$script:CdpPort   = 9333
$script:CdpSocket = $null
$script:CdpId     = 0
$script:CdpTarget = $null

# ── Connection ──────────────────────────────────────────────────────────────────────────

<#
.SYNOPSIS
    Opens (and caches) a WebSocket to the DevTools front-end target
.DESCRIPTION
    /json lists every target. DevTools front ends appear as page targets whose url starts with
    devtools://. With several tabs inspected at once there are several — -PageUrl picks the one
    inspecting the matching page instead of grabbing an arbitrary first.
#>
function Connect-DevTools {
    [CmdletBinding()]
    param([int]$Port = 0, [string]$PageUrl, [switch]$Force)

    if ($Port -gt 0) { $script:CdpPort = $Port }
    if (-not $Force -and $script:CdpSocket -and $script:CdpSocket.State -eq 'Open') { return $script:CdpSocket }
    Disconnect-DevTools

    try { $targets = Invoke-RestMethod "http://localhost:$($script:CdpPort)/json" -TimeoutSec 5 }
    catch { throw "Cannot reach the CDP endpoint on port $($script:CdpPort). Start Chrome with --remote-debugging-port=$($script:CdpPort) --auto-open-devtools-for-tabs. ($($_.Exception.Message))" }

    $devtools = @($targets | Where-Object { $_.url -like 'devtools://*' })
    if ($devtools.Count -eq 0) {
        $pages = @($targets | Where-Object { $_.type -eq 'page' -and $_.url -notlike 'devtools://*' } | ForEach-Object { $_.url })
        throw "No DevTools front-end target found — DevTools is not open. Launch Chrome with --auto-open-devtools-for-tabs, or press F12 in the tab. Page targets seen: $($pages -join ', ')"
    }
    if ($PageUrl) {
        # Correlating a DevTools window with the page it inspects:
        #   * its TITLE is "DevTools - <inspected url>" — present in every version seen;
        #   * older builds also put &targetId=<page id> in the url. Try both.
        $page = @($targets | Where-Object { $_.type -eq 'page' -and $_.url -like "*$PageUrl*" -and $_.url -notlike 'devtools://*' }) | Select-Object -First 1
        $match = @($devtools | Where-Object { $_.title -like "*$PageUrl*" }) | Select-Object -First 1
        if (-not $match -and $page) { $match = @($devtools | Where-Object { $_.url -like "*$($page.id)*" }) | Select-Object -First 1 }
        if ($match) { $devtools = @($match) }
        else { Write-Warning "No DevTools window matched '$PageUrl' (titles: $(($devtools | ForEach-Object { $_.title }) -join ' | ')); using the first." }
    } elseif ($devtools.Count -gt 1) {
        Write-Warning "$($devtools.Count) DevTools windows are open; using the first. Pass -PageUrl to choose."
    }

    $target = $devtools[0]
    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    if (-not $ws.ConnectAsync([Uri]$target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait(5000)) {
        $ws.Dispose(); throw "Timed out connecting to $($target.webSocketDebuggerUrl)"
    }
    if ($ws.State -ne 'Open') { $ws.Dispose(); throw "WebSocket did not open (state=$($ws.State)). Another client may already hold this target — DevTools allows one debugger per target." }
    $script:CdpSocket = $ws
    $script:CdpTarget = $target
    return $ws
}

function Disconnect-DevTools {
    if ($script:CdpSocket) { try { $script:CdpSocket.Dispose() } catch {} }
    $script:CdpSocket = $null
    $script:CdpTarget = $null
}

function Get-DevToolsSocket {
    if ($script:CdpSocket -and $script:CdpSocket.State -eq 'Open') { return $script:CdpSocket }
    return Connect-DevTools   # transparent reconnect after a DevTools reload
}

# ── Transport ───────────────────────────────────────────────────────────────────────────

<#
.SYNOPSIS
    Sends one CDP command and returns ITS response
.DESCRIPTION
    Correlates on the message id and reassembles multi-frame payloads. Events that arrive while
    waiting are discarded. Throws on protocol errors so failures are visible rather than silent.
#>
function Send-DevToolsCommand {
    [CmdletBinding()]
    param([string]$Method, [hashtable]$Params = @{}, [int]$TimeoutMs = 10000)

    $ws = Get-DevToolsSocket
    $script:CdpId++
    $id = $script:CdpId
    $payload = @{ id = $id; method = $Method; params = $Params } | ConvertTo-Json -Depth 20 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    if (-not $ws.SendAsync([ArraySegment[byte]]::new($bytes),
            [Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).Wait(5000)) {
        throw "Timed out sending $Method"
    }

    $deadline = [datetime]::UtcNow.AddMilliseconds($TimeoutMs)
    $buffer = [byte[]]::new(65536)
    while ([datetime]::UtcNow -lt $deadline) {
        $sb = [Text.StringBuilder]::new()
        do {
            $remaining = [int][Math]::Max(200, ($deadline - [datetime]::UtcNow).TotalMilliseconds)
            $r = $ws.ReceiveAsync([ArraySegment[byte]]::new($buffer), [Threading.CancellationToken]::None)
            if (-not $r.Wait($remaining)) { throw "Timed out waiting for the response to $Method (id $id)" }
            if ($r.Result.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) {
                Disconnect-DevTools; throw "DevTools closed the CDP socket while running $Method"
            }
            [void]$sb.Append([Text.Encoding]::UTF8.GetString($buffer, 0, $r.Result.Count))
        } while (-not $r.Result.EndOfMessage)   # a big evaluate result spans several frames

        $msg = $sb.ToString() | ConvertFrom-Json
        if ($null -ne $msg.id) {
            if ($msg.id -ne $id) { continue }           # a stale response — keep reading
            if ($msg.error) { throw "CDP error on $Method : $($msg.error.message) (code $($msg.error.code))" }
            return $msg.result
        }
        # otherwise it is an event (Network.*, Runtime.consoleAPICalled, …) — ignore it
    }
    throw "Timed out waiting for the response to $Method (id $id)"
}

<#
.SYNOPSIS
    Evaluates JavaScript inside the DevTools front end
.DESCRIPTION
    The snippet should return a JSON string (or '' when the target is missing); the parsed object
    is returned, or $null for ''. A thrown JS exception is reported rather than swallowed.
#>
function Invoke-DevToolsScript {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Expression, [int]$TimeoutMs = 10000)

    $res = Send-DevToolsCommand -Method 'Runtime.evaluate' -TimeoutMs $TimeoutMs -Params @{
        expression = $Expression; returnByValue = $true; awaitPromise = $true
    }
    if ($res.exceptionDetails) {
        $desc = $res.exceptionDetails.exception.description
        if (-not $desc) { $desc = $res.exceptionDetails.text }
        throw "JS exception in the DevTools front end: $desc"
    }
    $raw = $res.result.value
    if ([string]::IsNullOrEmpty($raw)) { return $null }
    if ($raw -is [string]) { return ($raw | ConvertFrom-Json) }
    return $raw
}

# ── Input ───────────────────────────────────────────────────────────────────────────────

# DevTools ignores synthetic .click(); dispatch real mouse input. A mouseMoved first puts the
# widget into its hover state — some toolbar buttons only accept the press once hovered.
function Invoke-DevToolsClick {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Coords, [int]$ClickCount = 1)

    if (-not $Coords) { throw "Invoke-DevToolsClick got no coordinates (the element was not found or has a 0x0 rect)" }
    Send-DevToolsCommand -Method 'Input.dispatchMouseEvent' -Params @{
        type = 'mouseMoved'; x = $Coords.x; y = $Coords.y; buttons = 0 } | Out-Null
    Send-DevToolsCommand -Method 'Input.dispatchMouseEvent' -Params @{
        type = 'mousePressed'; x = $Coords.x; y = $Coords.y; button = 'left'; buttons = 1; clickCount = $ClickCount } | Out-Null
    Send-DevToolsCommand -Method 'Input.dispatchMouseEvent' -Params @{
        type = 'mouseReleased'; x = $Coords.x; y = $Coords.y; button = 'left'; buttons = 0; clickCount = $ClickCount } | Out-Null
}

# key -> [windowsVirtualKeyCode, code]. `code` is the PHYSICAL key and differs from `key` for
# letters/digits ('a' -> 'KeyA'); widgets that listen on e.code see nothing if you send the wrong one.
$script:DevToolsKeys = @{
    'ArrowLeft'  = @(37,'ArrowLeft');  'ArrowUp'    = @(38,'ArrowUp')
    'ArrowRight' = @(39,'ArrowRight'); 'ArrowDown'  = @(40,'ArrowDown')
    'Enter'      = @(13,'Enter');      'Tab'        = @(9,'Tab')
    'Escape'     = @(27,'Escape');     'Backspace'  = @(8,'Backspace')
    'Delete'     = @(46,'Delete');     'Home'       = @(36,'Home')
    'End'        = @(35,'End');        'PageUp'     = @(33,'PageUp')
    'PageDown'   = @(34,'PageDown');   ' '          = @(32,'Space')
}
function Resolve-DevToolsKey([string]$Key) {
    if ($script:DevToolsKeys.ContainsKey($Key)) { return $script:DevToolsKeys[$Key] }
    if ($Key.Length -eq 1) {
        $c = $Key.ToUpper()[0]
        if ($c -ge 'A' -and $c -le 'Z') { return @([int][byte][char]$c, "Key$c") }
        if ($c -ge '0' -and $c -le '9') { return @([int][byte][char]$c, "Digit$c") }
    }
    throw "Unknown DevTools key '$Key'"
}

# rawKeyDown (not keyDown) is what the DevTools tree widgets listen for. The tree must already
# have focus — click a visible row first.
function Send-DevToolsKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Key, [string[]]$Modifiers = @())

    $info = Resolve-DevToolsKey $Key
    $mod = 0
    foreach ($m in $Modifiers) {
        switch ($m.ToLower()) { 'alt' {$mod = $mod -bor 1} 'ctrl' {$mod = $mod -bor 2} 'meta' {$mod = $mod -bor 4} 'shift' {$mod = $mod -bor 8} }
    }
    foreach ($type in 'rawKeyDown', 'keyUp') {
        $p = @{ type = $type; key = $Key; code = $info[1]
                windowsVirtualKeyCode = $info[0]; nativeVirtualKeyCode = $info[0]; modifiers = $mod }
        if ($type -eq 'rawKeyDown' -and $Key.Length -eq 1) { $p.text = $Key; $p.unmodifiedText = $Key }
        Send-DevToolsCommand -Method 'Input.dispatchKeyEvent' -Params $p | Out-Null
    }
}

# ── Querying the shadow DOM ─────────────────────────────────────────────────────────────

# The whole DevTools UI lives in nested shadow roots, so document.querySelector finds NOTHING.
# Every query here injects this walker. Bounded by depth and node budget so a huge panel (a long
# Network log, a deep Elements tree) cannot turn one lookup into a multi-second hang.
$script:DeepQueryJs = @'
  let __seen = 0;
  // Returns { first, firstVisible, count }. Keeping BOTH matters:
  //  * a compound selector ([aria-label="X"], [title^="Y"]) often matches a hidden element first,
  //    and clicking a 0x0 element does nothing — so callers want firstVisible;
  //  * a virtualised tree row genuinely exists with a 0x0 rect, and "exists but scrolled away"
  //    needs a different fix from "does not exist" — so callers also want first.
  const __deepAll = (sel) => {
    let first = null, firstVisible = null, count = 0;
    const walk = (root, depth) => {
      if (depth > 14 || __seen > 30000) return;
      for (const el of root.querySelectorAll('*')) {
        if (++__seen > 30000) return;
        if (el.matches(sel)) {
          count++;
          if (!first) first = el;
          if (!firstVisible) {
            const r = el.getBoundingClientRect();
            if (r.width > 0 && r.height > 0) firstVisible = el;
          }
        }
        if (el.shadowRoot) walk(el.shadowRoot, depth + 1);
      }
    };
    walk(document, 0);
    return { first, firstVisible, count };
  };
  const __deep = (sel) => { const r = __deepAll(sel); return r.firstVisible || r.first; };
'@

<#
.SYNOPSIS
    Returns the click point of the first element matching a CSS selector
.DESCRIPTION
    The DevTools UI is entirely shadow DOM, so every shadowRoot is walked. Returns $null when the
    element is absent OR present with a 0x0 rect (a virtualised row scrolled out of view) — call
    Get-DevToolsElementInfo when you need to tell those two apart.
#>
function Get-DevToolsElementPoint([Parameter(Mandatory)][string]$Selector) {
    $info = Get-DevToolsElementInfo $Selector
    if (-not $info -or -not $info.found -or -not $info.visible) { return $null }
    return [pscustomobject]@{ x = $info.x; y = $info.y }
}

<#
.SYNOPSIS
    Reports whether a selector matches, and whether the match is clickable
.DESCRIPTION
    Distinguishes "no such element" from "element exists but is virtualised away (0x0)", which are
    fixed in completely different ways. A node budget keeps the walk bounded on a huge panel, and
    an invalid selector is reported instead of blowing up the whole evaluate.
#>
function Get-DevToolsElementInfo([Parameter(Mandatory)][string]$Selector) {
    $escaped = $Selector.Replace('\', '\\').Replace("'", "\'")
    $info = Invoke-DevToolsScript @"
(() => {
  const sel = '$escaped';
  try { document.querySelector(sel); } catch (e) { return JSON.stringify({error: 'bad selector: ' + e.message}); }
  $($script:DeepQueryJs)
  const m = __deepAll(sel);
  if (!m.first) return JSON.stringify({found: false, visible: false, count: 0, scanned: __seen});
  const hit = m.firstVisible || m.first;
  const r = hit.getBoundingClientRect();
  return JSON.stringify({
    found: true,
    visible: r.width > 0 && r.height > 0,
    count: m.count,
    x: Math.round(r.left + r.width / 2),
    y: Math.round(r.top + r.height / 2),
    w: Math.round(r.width), h: Math.round(r.height),
    selected: hit.getAttribute('aria-selected') === 'true',
    text: (hit.textContent || '').trim().slice(0, 80),
    scanned: __seen
  });
})()
"@
    if ($info -and $info.error) { throw "Get-DevToolsElementInfo: $($info.error)" }
    return $info
}

<#
.SYNOPSIS
    Lists the DevTools panel tabs that are currently on the tab strip
.DESCRIPTION
    Panels that don't fit are moved into the "More tabs" (») overflow, whose menu is rendered
    OUTSIDE the DevTools document and therefore cannot be scripted. Knowing which ids are actually
    present is what turns "tab not found" into an actionable error.
#>
function Get-DevToolsTabs {
    Invoke-DevToolsScript @"
(() => {
  const out = [];
  const walk = (root, d) => {
    if (d > 14) return;
    for (const el of root.querySelectorAll('[role=tab]')) {
      const r = el.getBoundingClientRect();
      out.push({id: el.id, text: (el.textContent||'').trim().slice(0,24),
                selected: el.getAttribute('aria-selected') === 'true', visible: r.width > 0});
    }
    for (const el of root.querySelectorAll('*')) if (el.shadowRoot) walk(el.shadowRoot, d + 1);
  };
  walk(document, 0);
  return JSON.stringify(out);
})()
"@
}

<#
.SYNOPSIS
    Polls a JS predicate until it returns true
.DESCRIPTION
    Replaces fixed Start-Sleep calls: panels and trees settle at wildly different speeds depending
    on how much the page logged, so a fixed wait is either slow or flaky.
#>
function Wait-DevToolsCondition {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Predicate, [int]$TimeoutMs = 5000, [int]$PollMs = 100)

    $deadline = [datetime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([datetime]::UtcNow -lt $deadline) {
        $ok = Invoke-DevToolsScript "JSON.stringify(!!($Predicate))"
        if ($ok) { return $true }
        Start-Sleep -Milliseconds $PollMs
    }
    return $false
}

# ── Recipes ─────────────────────────────────────────────────────────────────────────────

<#
.SYNOPSIS
    Opens a DevTools panel by clicking its tab, and verifies it opened
.DESCRIPTION
    Scripted panel APIs (showPanel, InspectorView.instance()) drift between Chrome versions and
    silently no-op, so the tab is clicked. Ids: tab-elements, tab-console, tab-network,
    tab-resources (Application), tab-sources, tab-timeline (Performance).
#>
$script:PanelNames = @{
    'tab-elements' = 'Elements'; 'tab-console' = 'Console'; 'tab-sources' = 'Sources'
    'tab-network'  = 'Network';  'tab-timeline' = 'Performance'; 'tab-resources' = 'Application'
    'tab-security' = 'Security'; 'tab-memory' = 'Memory'; 'tab-lighthouse' = 'Lighthouse'
    'tab-issues-pane' = 'Issues'
}
function Select-DevToolsPanel {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TabId, [int]$TimeoutMs = 6000)

    $TabId = $TabId -replace '^#', ''
    $info = Get-DevToolsElementInfo "#$TabId"

    if ($info -and $info.found -and $info.visible) {
        if ($info.selected) { return }                       # already there — don't re-click
        Invoke-DevToolsClick ([pscustomobject]@{ x = $info.x; y = $info.y })
    } else {
        # Not on the strip: it is in the "More tabs" (») overflow, whose menu renders outside this
        # document and cannot be clicked over CDP. The Command Menu reaches every panel regardless.
        $name = $script:PanelNames[$TabId]
        if (-not $name) {
            $have = (Get-DevToolsTabs | ForEach-Object { $_.id }) -join ', '
            throw "Unknown DevTools tab '#$TabId' and it is not on the tab strip. Tabs present: $have. Known ids: $($script:PanelNames.Keys -join ', ')."
        }
        Invoke-DevToolsCommand "Show $name"
    }

    if (-not (Wait-DevToolsDeep "#$TabId" -Attribute 'aria-selected' -Equals 'true' -TimeoutMs $TimeoutMs)) {
        $have = (Get-DevToolsTabs | Where-Object { $_.visible } | ForEach-Object { $_.id }) -join ', '
        throw "Panel '#$TabId' did not become selected. Tabs on the strip: $have. Widen/undock the DevTools window if the panel you want keeps landing in the » overflow."
    }
}

<#
.SYNOPSIS
    Runs a DevTools Command Menu entry (Ctrl+Shift+P)
.DESCRIPTION
    The Command Menu reaches every panel and action by name, including panels hidden in the »
    overflow, so it is the version-proof way to open something. Text goes in with Input.insertText
    rather than per-character key events — faster and immune to keyboard-layout differences.
#>
function Invoke-DevToolsCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Command, [int]$SettleMs = 500)

    # ctrl(2) + shift(8) = 10
    foreach ($type in 'rawKeyDown', 'keyUp') {
        Send-DevToolsCommand -Method 'Input.dispatchKeyEvent' -Params @{
            type = $type; key = 'P'; code = 'KeyP'
            windowsVirtualKeyCode = 80; nativeVirtualKeyCode = 80; modifiers = 10 } | Out-Null
    }
    if (-not (Wait-DevToolsDeep '.quick-open-container, input.suggestion' -TimeoutMs 3000)) {
        throw "The Command Menu did not open (ctrl+shift+P). Is the DevTools window focused/attached?"
    }
    Send-DevToolsCommand -Method 'Input.insertText' -Params @{ text = $Command } | Out-Null
    Start-Sleep -Milliseconds $SettleMs      # let the fuzzy filter rank before committing
    Send-DevToolsKey 'Enter'
}

<#
.SYNOPSIS
    Polls until a shadow-DOM selector exists (optionally with an attribute value)
.DESCRIPTION
    Wait-DevToolsCondition takes a raw predicate, but a raw predicate cannot see into shadow roots
    — the mistake that makes a verification silently always fail. Use this for anything in the UI.
#>
function Wait-DevToolsDeep {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Selector, [string]$Attribute, [string]$Equals,
          [int]$TimeoutMs = 5000, [int]$PollMs = 120)

    $deadline = [datetime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ($true) {
        $info = Get-DevToolsElementInfo $Selector
        if ($info -and $info.found) {
            if (-not $Attribute) { return $true }
            if ($Attribute -eq 'aria-selected' -and $info.selected -eq ($Equals -eq 'true')) { return $true }
        }
        if ([datetime]::UtcNow -ge $deadline) { return $false }
        Start-Sleep -Milliseconds $PollMs
    }
}

<#
.SYNOPSIS
    Empties the Network log so a screenshot shows only the current scene
#>
function Clear-NetworkLog {
    Select-DevToolsPanel tab-network
    # Exact aria-label first. A loose fallback like [title^="Clear"] matches "Clear console" and
    # other hidden toolbar buttons, so it stays second and is only a safety net.
    $point = Get-DevToolsElementPoint '[aria-label="Clear network log"]'
    if (-not $point) { $point = Get-DevToolsElementPoint '[aria-label^="Clear network"]' }
    if (-not $point) { Write-Warning "Clear-network-log button not found — this Chrome build may label it differently. Enumerate with: Get-DevToolsElementInfo '[aria-label*=Clear]'"; return }
    Invoke-DevToolsClick $point
    Start-Sleep -Milliseconds 200
}

<#
.SYNOPSIS
    Selects a site's cookie table in the Application panel
.DESCRIPTION
    Only the origin row under Storage > Cookies renders the table with the HttpOnly and SameSite
    columns. Tree rows are virtualised — a row scrolled out of view has a 0x0 rect and cannot be
    clicked, and scrollIntoView/scrollTop do not fix it — so the row is reached with the keyboard,
    which makes the tree scroll itself.

    ArrowRight on an already-expanded node steps INTO its first child instead of expanding it, so a
    following ArrowDown overshoots. Collapsing first makes ArrowLeft -> ArrowRight -> ArrowDown
    deterministic regardless of the tree's previous state.
#>
function Show-CookiePanel {
    [CmdletBinding()]
    param([string]$AppUrl)

    Select-DevToolsPanel 'tab-resources'

    $locator = @'
(() => {
  const rows = [];
  const walk = (root, depth) => {
    if (depth > 14 || rows.length > 4000) return;
    for (const el of root.querySelectorAll('[role=treeitem]')) rows.push(el);
    for (const el of root.querySelectorAll('*')) if (el.shadowRoot) walk(el.shadowRoot, depth + 1);
  };
  walk(document, 0);
  const row = rows.find(e => (e.textContent || '').trim() === 'Cookies');
  if (!row) return JSON.stringify({found: false, rows: rows.length});
  const r = row.getBoundingClientRect();
  if (r.width === 0) return JSON.stringify({found: true, visible: false});
  return JSON.stringify({found: true, visible: true, x: Math.round(r.left + 60), y: Math.round(r.top + r.height / 2)});
})()
'@
    $hit = Invoke-DevToolsScript $locator
    if (-not $hit.found)   { throw "No 'Cookies' row in the Application panel tree (scanned $($hit.rows) rows). Is the Application panel actually open?" }
    if (-not $hit.visible) { throw "The 'Cookies' row is virtualised out of view (0x0 rect). Scroll the Storage tree so it is on screen, then retry." }

    Invoke-DevToolsClick ([pscustomobject]@{ x = $hit.x; y = $hit.y })   # focus the tree
    Start-Sleep -Milliseconds 300
    Send-DevToolsKey 'ArrowLeft'    # collapse -> known state
    Start-Sleep -Milliseconds 200
    Send-DevToolsKey 'ArrowRight'   # expand
    Start-Sleep -Milliseconds 300
    Send-DevToolsKey 'ArrowDown'    # first child = the origin row

    # The cookie table is what proves we landed on the origin row, not the "Cookies" help page.
    if (-not (Wait-DevToolsCondition "!!document.querySelector('devtools-data-grid, .cookies-table, [aria-label*=Cookie]')" -TimeoutMs 4000)) {
        Write-Warning "Selected the first child of Cookies but no cookie table appeared — the site may have no cookies, or the tree had a different shape."
    }
}

<#
.SYNOPSIS
    Screenshots the DevTools UI itself
.DESCRIPTION
    The DevTools front end is a page, so Page.captureScreenshot works on it — cheaper and sharper
    than an OS-level screen grab, and it needs no window focus.
#>
function Save-DevToolsScreenshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $res = Send-DevToolsCommand -Method 'Page.captureScreenshot' -Params @{ format = 'png' } -TimeoutMs 20000
    if (-not $res.data) { throw "Page.captureScreenshot returned no data" }
    $full = if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path (Get-Location) $Path }
    $dir = Split-Path -Parent $full
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllBytes($full, [Convert]::FromBase64String($res.data))
    return $full
}
