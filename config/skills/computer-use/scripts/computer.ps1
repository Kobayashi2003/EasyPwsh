<#
.SYNOPSIS
    Self-contained Windows desktop automation: vision (screenshots), mouse, keyboard, windows,
    UI-Automation probing, and waits. One dispatcher, optionally batched.
.DESCRIPTION
    Lets an agent drive a Windows desktop the way a human does — for apps with no automation
    API (Cursor, IDEs, native apps). Capabilities:

      vision    screenshot a window / region / foreground / all monitors, with crop (-Region),
                downscale (-Scale/-MaxWidth) and an absolute-coordinate grid overlay (-Grid).
                pixel: read colours without spending vision tokens at all.
      mouse     move, click (l/r/m, multi, +modifiers), mouse-down/up, drag (threshold-safe,
                +modifiers), scroll (vertical AND horizontal, real per-notch events).
      keyboard  type (clipboard paste — CJK/emoji/multi-line safe), keys (combos via SendInput
                WITH scan codes, incl. OEM punctuation: ctrl+`, ctrl+, ctrl+/ ...), ime (is a
                CJK input method about to eat the keystrokes?).
      windows   find (EnumWindows, cloaked/ghost windows filtered, state + process), focus
                (AttachThreadInput + ALT trick), maximize/minimize/restore, move+resize.
      probe     cursor-type (shape under a point, and -Scan along a line to find a sash/edge
                pixel-exactly in ONE process), ui-find / ui-tree (UI Automation → EXACT control
                rects, zero vision tokens), mouse-pos, screen-size (monitors + per-monitor DPI).
      waits     wait-window (appear/disappear), wait-stable (screen stopped changing) — so you
                never sleep blindly or screenshot a half-painted frame.
      batch     run many steps in ONE process. A cold process costs ~2s (P/Invoke compile), so
                batching 6 steps saves ~12s.

    Coordinates are absolute VIRTUAL-DESKTOP pixels and MAY BE NEGATIVE (a monitor left of /
    above the primary one). Every coordinate is validated against the real monitor layout, so an
    off-screen click fails loudly instead of silently doing nothing.

    Mouse/window P/Invoke adapted from EasyPwsh start/WinAPI.ps1; screenshot (DWM frame bounds →
    no shadow) from EasyPwsh utils/kobayashi/save-window-screenshot.ps1.
.PARAMETER Action
    screenshot | pixel | click | mouse-down | mouse-up | move | scroll | drag | type | keys |
    find-window | focus | window-move | maximize | minimize | restore | list-procs |
    cursor-type | ui-find | ui-tree | wait-window | wait-stable | ime | mouse-pos | screen-size | batch
.EXAMPLE
    computer.ps1 -Action find-window -Filter cursor
.EXAMPLE
    computer.ps1 -Action screenshot -Hwnd 12345 -Path shot.png -MaxWidth 900 -Grid 100
.EXAMPLE
    computer.ps1 -Action cursor-type -Scan "1200,600,1320,600" -Filter sizewe
.EXAMPLE
    computer.ps1 -Action batch -Batch @'
    focus hwnd=12345
    keys keys="ctrl+shift+p"
    wait-stable timeout=3
    type text="Toggle Terminal"
    keys keys=enter
    screenshot path=D:/tmp/a.png maxwidth=900
    '@
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('screenshot','pixel','click','mouse-down','mouse-up','move','scroll','drag','type','keys',
                 'find-window','focus','window-move','maximize','minimize','restore','list-procs',
                 'cursor-type','ui-find','ui-tree','wait-window','wait-stable','ime','edit','mouse-pos','screen-size','batch')]
    [string]$Action,

    [int]$X = [int]::MinValue,      # absolute virtual-desktop px — negative is legal
    [int]$Y = [int]::MinValue,
    [int]$X2 = [int]::MinValue,
    [int]$Y2 = [int]::MinValue,
    [int]$W = [int]::MinValue,      # window width (window-move) / sample width (pixel)
    [int]$H = [int]::MinValue,      # window height (window-move) / sample height (pixel)
    [ValidateSet('left','right','middle')]
    [string]$Button = 'left',
    [string]$Modifiers,             # held during click/drag/scroll, e.g. "ctrl", "ctrl+shift"
    [int]$Count = 1,                # click count / max rows returned / consecutive stable frames
    [int]$Amount = 3,               # scroll notches
    [ValidateSet('up','down','left','right')]
    [string]$Direction = 'down',
    [string]$Text,
    [string]$Keys,
    [string]$Path,
    [string]$WindowTitle,
    [long]$Hwnd = 0,                # explicit top-level window handle (from find-window) — beats -WindowTitle
    [switch]$Foreground,
    [switch]$AllScreens,            # screenshot: whole virtual desktop (all monitors)
    [string]$Region,                # "X,Y,W,H" in VIRTUAL coords (may be negative)
    [double]$Scale = 0,             # screenshot downscale factor (e.g. 0.5); 0 = none
    [int]$MaxWidth = 0,             # screenshot: cap output width in px; 0 = off
    [int]$Grid = 0,                 # screenshot: overlay a labelled grid every N SCREEN px
    [switch]$NoFocus,               # screenshot: capture without stealing focus
    [double]$Delay = 0,             # screenshot: wait before capture; others: wait after acting
    [int]$Steps = 0,                # drag: interpolation steps (0 = auto from distance)
    [int]$HoldMs = 0,               # drag: pause before release / cursor-type: settle per sample
    [switch]$NoRestoreClipboard,
    [string]$Filter,                # list-procs & find-window: process-name substring
                                    # cursor-type -Scan: stop at this shape
                                    # ui-find/ui-tree: control-type substring
    [string]$Name,                  # ui-find: control-name substring
    [string]$Mode,                  # ime: report | english | native | clear | 0xNNN
    [int]$Depth = 0,                # ui-find/ui-tree: max tree depth (0 = default)
    [string]$Scan,                  # cursor-type: "x1,y1,x2,y2" — probe along this line
    [double]$Timeout = 0,           # wait-*: seconds (0 = default)
    [switch]$Absent,                # wait-window: wait for it to DISAPPEAR instead
    [string]$Batch,                 # batch: newline-separated steps
    [string]$BatchFile,             # batch: read steps from a file
    [switch]$ContinueOnError        # batch: keep going after a failing step
)

$ErrorActionPreference = 'Stop'
$NOPOS = [int]::MinValue

Add-Type -AssemblyName System.Drawing, System.Windows.Forms

if (-not ('CU.Native' -as [type])) {
    Add-Type -Namespace CU -Name Native -UsingNamespace System.Text, System.Collections.Generic -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
[StructLayout(LayoutKind.Sequential)] public struct CURSORINFO { public int cbSize; public int flags; public IntPtr hCursor; public POINT ptScreenPos; }

// SendInput plumbing. keybd_event/mouse_event are legacy shims that inject events with scan
// code 0; an IME or any low-level keyboard hook (Microsoft Pinyin installs one) can drop those,
// which shows up as "the Ctrl modifier is ignored and ctrl+a types a literal 'a'". SendInput
// with a real MapVirtualKey scan code is what actually reaches the target reliably.
[StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Explicit)] public struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
[StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPUTUNION u; }

[DllImport("user32.dll", SetLastError=true)] public static extern uint SendInput(uint n, INPUT[] inputs, int cb);
[DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint mapType);

public const uint INPUT_MOUSE = 0, INPUT_KEYBOARD = 1;
public const uint KEYEVENTF_EXTENDEDKEY = 0x0001;

// Keys on the "extended" part of the keyboard need the extended flag or apps see the numpad twin.
public static bool IsExtended(ushort vk) {
    switch (vk) {
        case 0x21: case 0x22: case 0x23: case 0x24:              // pgup pgdn end home
        case 0x25: case 0x26: case 0x27: case 0x28:              // arrows
        case 0x2D: case 0x2E: case 0x2C:                         // insert delete printscreen
        case 0x5B: case 0x5C: case 0x5D:                         // lwin rwin apps
        case 0x6F: case 0x90: case 0xA3: case 0xA5:              // divide numlock rctrl ralt
            return true;
        default: return false;
    }
}
public static uint SendKey(ushort vk, bool up) {
    var inp = new INPUT[1];
    inp[0].type = INPUT_KEYBOARD;
    inp[0].u.ki.wVk = vk;
    inp[0].u.ki.wScan = (ushort)MapVirtualKey(vk, 0);            // MAPVK_VK_TO_VSC
    inp[0].u.ki.dwFlags = (up ? 0x0002u : 0u) | (IsExtended(vk) ? KEYEVENTF_EXTENDEDKEY : 0u);
    return SendInput(1, inp, Marshal.SizeOf(typeof(INPUT)));
}
public static uint SendMouse(uint flags, int data) {
    var inp = new INPUT[1];
    inp[0].type = INPUT_MOUSE;
    inp[0].u.mi.dwFlags = flags;
    inp[0].u.mi.mouseData = unchecked((uint)data);
    return SendInput(1, inp, Marshal.SizeOf(typeof(INPUT)));
}
public static uint SendMouseMoveRel(int dx, int dy) {
    var inp = new INPUT[1];
    inp[0].type = INPUT_MOUSE;
    inp[0].u.mi.dwFlags = 0x0001;                                // MOUSEEVENTF_MOVE
    inp[0].u.mi.dx = dx; inp[0].u.mi.dy = dy;
    return SendInput(1, inp, Marshal.SizeOf(typeof(INPUT)));
}

public delegate bool EnumProc(IntPtr h, IntPtr l);

[DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int max);
[DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
[DllImport("user32.dll")] public static extern bool GetCursorInfo(ref CURSORINFO pci);
[DllImport("user32.dll")] public static extern IntPtr LoadCursor(IntPtr hInstance, int lpCursorName);
[DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(POINT pt, uint flags);
[DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint tid);
[DllImport("imm32.dll")] public static extern IntPtr ImmGetDefaultIMEWnd(IntPtr h);
// MUST be the W entry point: the default CharSet is Ansi, and WM_GETTEXT through
// SendMessageTimeoutA hands back ANSI bytes that read as mojibake when parsed as UTF-16.
[DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageTimeoutW")] public static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, IntPtr wp, IntPtr lp, uint flags, uint ms, out IntPtr res);
[DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageTimeoutW")] public static extern IntPtr SendMessageTimeoutStr(IntPtr h, uint msg, IntPtr wp, string lp, uint flags, uint ms, out IntPtr res);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int max);

[StructLayout(LayoutKind.Sequential)] public struct GUITHREADINFO {
    public int cbSize; public int flags;
    public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
    public RECT rcCaret;
}
[DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint tid, ref GUITHREADINFO gti);

// The control that actually has the caret inside a top-level window. Messages sent HERE bypass
// the keyboard entirely — no IME, no low-level hook, no focus race.
public static IntPtr FocusedControl(IntPtr top) {
    uint procId;
    uint tid = GetWindowThreadProcessId(top, out procId);
    var gti = new GUITHREADINFO();
    gti.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
    if (GetGUIThreadInfo(tid, ref gti) && gti.hwndFocus != IntPtr.Zero) return gti.hwndFocus;
    return top;
}
public static string ClassOf(IntPtr h) {
    var sb = new System.Text.StringBuilder(256);
    GetClassName(h, sb, sb.Capacity);
    return sb.ToString();
}
// WM_GETTEXTLENGTH(0x000E) + WM_GETTEXT(0x000D) via a timeout so a hung app cannot block us.
public static string GetCtrlText(IntPtr h, int max) {
    IntPtr len;
    if (SendMessageTimeout(h, 0x000E, IntPtr.Zero, IntPtr.Zero, 2, 800, out len) == IntPtr.Zero) return null;
    int n = len.ToInt32();
    if (n <= 0) return "";
    if (n > max) n = max;
    IntPtr buf = Marshal.AllocHGlobal((n + 1) * 2);
    try {
        IntPtr res;
        if (SendMessageTimeout(h, 0x000D, (IntPtr)(n + 1), buf, 2, 3000, out res) == IntPtr.Zero) return null;
        return Marshal.PtrToStringUni(buf);
    } finally { Marshal.FreeHGlobal(buf); }
}
public static int GetCtrlTextLength(IntPtr h) {
    IntPtr len;
    if (SendMessageTimeout(h, 0x000E, IntPtr.Zero, IntPtr.Zero, 2, 800, out len) == IntPtr.Zero) return -1;
    return len.ToInt32();
}
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hWnd, int attr, out RECT val, int size);
[DllImport("dwmapi.dll", EntryPoint="DwmGetWindowAttribute")] public static extern int DwmGetWindowAttributeInt(IntPtr hWnd, int attr, out int val, int size);
[DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr hmon, int dpiType, out uint dx, out uint dy);

public const uint MOUSEEVENTF_MOVE = 0x0001;
public const uint MOUSEEVENTF_WHEEL = 0x0800;
public const uint MOUSEEVENTF_HWHEEL = 0x1000;
public const uint KEYEVENTF_KEYUP = 0x0002;

// DWM extended frame bounds (attr 9) so screenshots exclude the drop shadow.
public static RECT GetBounds(IntPtr hWnd) {
    RECT r;
    if (DwmGetWindowAttribute(hWnd, 9, out r, Marshal.SizeOf(typeof(RECT))) != 0) { GetWindowRect(hWnd, out r); }
    return r;
}
// DWMWA_CLOAKED (14): UWP/background windows that are "visible" to EnumWindows but painted
// nowhere. Without this filter find-window is full of ghost rows.
public static bool IsCloaked(IntPtr h) {
    int v; if (DwmGetWindowAttributeInt(h, 14, out v, 4) != 0) return false; return v != 0;
}
public static POINT GetPos() { POINT p; GetCursorPos(out p); return p; }

// Every top-level VISIBLE, titled, non-cloaked window — one hwnd each, so multiple windows of
// the same application are all returned (Get-Process exposes only one MainWindow per process).
public static IntPtr[] TopWindows() {
    var list = new System.Collections.Generic.List<IntPtr>();
    EnumWindows((h, l) => {
        if (IsWindowVisible(h) && GetWindowTextLength(h) > 0 && !IsCloaked(h)) list.Add(h);
        return true;
    }, IntPtr.Zero);
    return list.ToArray();
}
'@
}

# Make the process DPI-aware so window rects, UI-Automation rects, screenshots (physical px) and
# the mouse (SetCursorPos/GetCursorPos) all share ONE coordinate system. Without this, on a scaled
# monitor screenshot coords and mouse coords diverge and clicks land off-target.
try { [void][CU.Native]::SetProcessDpiAwarenessContext([IntPtr](-4)) }   # PER_MONITOR_AWARE_V2
catch { try { [void][CU.Native]::SetProcessDPIAware() } catch {} }

# ── Parameter-bag accessors (shared by the direct call and by `batch`) ───────────────────
function AsBool($v) {
    if ($null -eq $v) { return $false }
    if ($v -is [System.Management.Automation.SwitchParameter]) { return $v.IsPresent }
    if ($v -is [bool]) { return $v }
    return (@('1','true','yes','on') -contains "$v".Trim().ToLower())
}
function PStr([hashtable]$p, [string]$k, [string]$def = '') {
    if ($p.ContainsKey($k) -and $null -ne $p[$k]) { return [string]$p[$k] } ; $def
}
function PInt([hashtable]$p, [string]$k, [int]$def) {
    if ($p.ContainsKey($k) -and "$($p[$k])".Trim() -ne '') { return [int]$p[$k] } ; $def
}
function PNum([hashtable]$p, [string]$k, [double]$def) {
    if ($p.ContainsKey($k) -and "$($p[$k])".Trim() -ne '') { return [double]$p[$k] } ; $def
}
function PBool([hashtable]$p, [string]$k) {
    if ($p.ContainsKey($k)) { return (AsBool $p[$k]) } ; $false
}

# ── Geometry / monitor guards ───────────────────────────────────────────────────────────
function Get-VirtualRect { [System.Windows.Forms.SystemInformation]::VirtualScreen }
function Get-MonitorAt([int]$x, [int]$y) {
    foreach ($sc in [System.Windows.Forms.Screen]::AllScreens) { if ($sc.Bounds.Contains($x, $y)) { return $sc } }
    $null
}
# A click on a coordinate that is inside the virtual bounding box but on NO monitor does nothing
# at all — silently. Fail loudly instead. (Non-rectangular multi-monitor layouts make this real.)
function Assert-OnScreen([int]$x, [int]$y, [string]$what) {
    if ($x -eq $NOPOS -or $y -eq $NOPOS) { throw "$what needs -X and -Y" }
    if (-not (Get-MonitorAt $x $y)) {
        $mons = (([System.Windows.Forms.Screen]::AllScreens) | ForEach-Object {
            "$($_.DeviceName)=$($_.Bounds.X),$($_.Bounds.Y),$($_.Bounds.Width),$($_.Bounds.Height)" }) -join '  '
        throw "$what target $x,$y is on no monitor (input there is discarded). Monitors: $mons"
    }
}
function Get-MonitorScale([int]$x, [int]$y) {
    try {
        $pt = New-Object 'CU.Native+POINT'; $pt.X = $x; $pt.Y = $y
        $hm = [CU.Native]::MonitorFromPoint($pt, 2)   # MONITOR_DEFAULTTONEAREST
        $dx = 0; $dy = 0
        if ([CU.Native]::GetDpiForMonitor($hm, 0, [ref]$dx, [ref]$dy) -eq 0) { return [math]::Round($dx / 96.0, 3) }
    } catch {}
    return 1.0
}

# ── Mouse button flags ──────────────────────────────────────────────────────────────────
$BTN = @{ 'left' = @(0x0002,0x0004); 'right' = @(0x0008,0x0010); 'middle' = @(0x0020,0x0040) }

# ── Keyboard: virtual-key map + combo sender (shared by `keys`, `type`, modifier holds) ──
$VK = @{
    'enter'=0x0D; 'return'=0x0D; 'tab'=0x09; 'esc'=0x1B; 'escape'=0x1B; 'space'=0x20;
    'backspace'=0x08; 'bksp'=0x08; 'delete'=0x2E; 'del'=0x2E; 'insert'=0x2D; 'ins'=0x2D;
    'home'=0x24; 'end'=0x23; 'pageup'=0x21; 'pgup'=0x21; 'pagedown'=0x22; 'pgdn'=0x22;
    'left'=0x25; 'up'=0x26; 'right'=0x27; 'down'=0x28;
    'ctrl'=0x11; 'control'=0x11; 'shift'=0x10; 'alt'=0x12; 'win'=0x5B; 'cmd'=0x5B;
    'apps'=0x5D; 'menu'=0x5D; 'capslock'=0x14; 'printscreen'=0x2C; 'pause'=0x13;
    'f1'=0x70;'f2'=0x71;'f3'=0x72;'f4'=0x73;'f5'=0x74;'f6'=0x75;'f7'=0x76;'f8'=0x77;'f9'=0x78;'f10'=0x79;'f11'=0x7A;'f12'=0x7B;
    'f13'=0x7C;'f14'=0x7D;'f15'=0x7E;'f16'=0x7F;'f17'=0x80;'f18'=0x81;'f19'=0x82;'f20'=0x83;'f21'=0x84;'f22'=0x85;'f23'=0x86;'f24'=0x87;
    # OEM punctuation — without these you cannot send ctrl+` (terminal), ctrl+, (settings),
    # ctrl+/ (comment), ctrl+- / ctrl+= (zoom), ctrl+[ / ctrl+] (indent) to any IDE.
    ';'=0xBA; 'semicolon'=0xBA; '='=0xBB; 'equal'=0xBB; 'equals'=0xBB;
    ','=0xBC; 'comma'=0xBC; '-'=0xBD; 'minus'=0xBD; 'dash'=0xBD;
    '.'=0xBE; 'period'=0xBE; 'dot'=0xBE; '/'=0xBF; 'slash'=0xBF;
    '`'=0xC0; 'backtick'=0xC0; 'grave'=0xC0; 'tilde'=0xC0;
    '['=0xDB; 'lbracket'=0xDB; '\'=0xDC; 'backslash'=0xDC; ']'=0xDD; 'rbracket'=0xDD;
    "'"=0xDE; 'quote'=0xDE; 'apostrophe'=0xDE;
    'numpad0'=0x60;'numpad1'=0x61;'numpad2'=0x62;'numpad3'=0x63;'numpad4'=0x64;
    'numpad5'=0x65;'numpad6'=0x66;'numpad7'=0x67;'numpad8'=0x68;'numpad9'=0x69;
    'multiply'=0x6A; 'add'=0x6B; 'subtract'=0x6D; 'decimal'=0x6E; 'divide'=0x6F;
}
$MODS = @('ctrl','control','shift','alt','win','cmd')
function Resolve-Vk([string]$name) {
    $n = $name.Trim(); $l = $n.ToLower()
    if ($VK.ContainsKey($l)) { return $VK[$l] }
    if ($VK.ContainsKey($n)) { return $VK[$n] }
    if ($n.Length -eq 1) {
        $c = [char]::ToUpper($n[0])
        if (($c -ge 'A' -and $c -le 'Z') -or ($c -ge '0' -and $c -le '9')) { return [int][byte][char]$c }
    }
    throw "Unknown key '$name' (letters/digits, named keys, or OEM punctuation ; = , - . / `` [ \ ] ')"
}
function Key-Down([int]$vk) { [void][CU.Native]::SendKey([uint16]$vk, $false) }
function Key-Up([int]$vk)   { [void][CU.Native]::SendKey([uint16]$vk, $true) }

# ── IME (输入法) ────────────────────────────────────────────────────────────────────────
# A CJK input method sits between the injected keystroke and the app. Two distinct hazards:
#   1) native/中文 mode: a bare letter starts a COMPOSITION instead of reaching the app;
#   2) while the candidate box (字词选择框) is open, EVERY key — ctrl+a, ctrl+v, enter — is
#      consumed by the IME. One stolen keystroke opens the box, so failures cascade.
# WM_IME_CONTROL(0x0283) subcommands used here (IMM32, honoured by Microsoft IME):
#   IMC_GETCONVERSIONMODE 0x0001 · IMC_SETCONVERSIONMODE 0x0002 · IMC_GETOPENSTATUS 0x0005
# IME_CMODE bits: NATIVE 0x0001 · FULLSHAPE 0x0008 · SYMBOL 0x0400 (0x0000 = alphanumeric/English)
function Get-ImeWnd([IntPtr]$hwnd) {
    if ($hwnd -eq [IntPtr]::Zero) { return [IntPtr]::Zero }
    try { return [CU.Native]::ImmGetDefaultIMEWnd($hwnd) } catch { return [IntPtr]::Zero }
}
function Send-ImeControl([IntPtr]$imeWnd, [int]$sub, [int]$lParam) {
    $res = [IntPtr]::Zero
    # SMTO_ABORTIFHUNG(2) + a timeout: a wedged IME host must never wedge this script.
    [void][CU.Native]::SendMessageTimeout($imeWnd, 0x0283, [IntPtr]$sub, [IntPtr]$lParam, 2, 500, [ref]$res)
    return $res.ToInt64()
}
function Get-ImeState([IntPtr]$hwnd) {
    try {
        if ($hwnd -eq [IntPtr]::Zero) { return $null }
        $pid0 = 0
        $tid  = [CU.Native]::GetWindowThreadProcessId($hwnd, [ref]$pid0)
        $lang = ([CU.Native]::GetKeyboardLayout($tid)).ToInt64() -band 0xFFFF
        $ime  = Get-ImeWnd $hwnd
        if ($ime -eq [IntPtr]::Zero) { return @{ Lang = $lang; Ime = $false; Conv = 0; Native = $false; Open = $false } }
        $conv = Send-ImeControl $ime 0x0001 0
        $open = Send-ImeControl $ime 0x0005 0
        return @{ Lang = $lang; Ime = $true; Conv = $conv; Native = (($conv -band 1) -ne 0); Open = ($open -ne 0) }
    } catch { return $null }
}
# Only alphanumeric keys are at risk — they are what an IME composes. enter/f5/arrows pass
# straight through, so stay quiet for those (no warning spam on a CJK desktop).
function Get-ImeWarning([string]$combos) {
    if ($combos -notmatch '(^|[+\s])[a-zA-Z0-9]($|\s|$)') { return '' }
    $st = Get-ImeState ([CU.Native]::GetForegroundWindow())
    if (-not $st -or -not $st.Native) { return '' }
    return "WARNING: the focused window's IME is in native/CJK mode (conv=0x{0:X}). Alphanumeric keys — the letter in ctrl+a, the ctrl+v behind -Action type — are swallowed while a composition/candidate box is open, and one stolen keystroke opens it, so failures cascade. Fix first: -Action ime -Mode english (Microsoft IME; also closes the candidate box), then -Mode 0x{0:X} to restore." -f $st.Conv
}

# Press one combo like 'ctrl+shift+p', 'enter', 'ctrl+`' or 'ctrl++'.
# A literal '+' key splits into an empty trailing token — that case is mapped to shift+'='.
function Send-Combo([string]$combo) {
    $mods = @(); $main = $null
    $parts = @($combo -split '\+')
    for ($i = 0; $i -lt $parts.Count; $i++) {
        $t = $parts[$i]
        if ($t -eq '') { if ($i -gt 0 -and $i -eq $parts.Count - 1) { $main = '+' } ; continue }
        if ($t.Trim().ToLower() -in $MODS) { $mods += $t.Trim().ToLower() } else { $main = $t }
    }
    if ($main -eq '+') { $main = '='; if ('shift' -notin $mods) { $mods += 'shift' } }
    if (-not $main -and $mods.Count -eq 0) { throw "Empty key combo" }
    $modVks = @($mods | ForEach-Object { Resolve-Vk $_ })
    foreach ($m in $modVks) { Key-Down $m }
    if ($main) {
        $mv = Resolve-Vk $main
        Key-Down $mv; Start-Sleep -Milliseconds 30; Key-Up $mv
    }
    [array]::Reverse($modVks)
    foreach ($m in $modVks) { Key-Up $m }
}
# Hold a modifier set around a mouse action (ctrl+click, shift+drag, ctrl+scroll = zoom).
function Push-Modifiers([string]$mods) {
    if (-not $mods) { return @() }
    $vks = @(($mods -split '[+\s,]+' | Where-Object { $_ }) | ForEach-Object { Resolve-Vk $_ })
    foreach ($v in $vks) { Key-Down $v }
    if ($vks.Count) { Start-Sleep -Milliseconds 40 }
    return $vks
}
function Pop-Modifiers($vks) {
    if (-not $vks -or $vks.Count -eq 0) { return }
    $r = @($vks); [array]::Reverse($r)
    foreach ($v in $r) { Key-Up $v }
}

# ── Window messages: text in/out WITHOUT the keyboard ───────────────────────────────────
# On Windows the clipboard solves the *encoding* half of the input problem (CJK, emoji,
# newlines) but ctrl+v is still a keystroke an IME or a hook can steal. Standard Win32 edit
# controls accept the operation as a MESSAGE instead — no keys, no IME, no focus race:
#   WM_PASTE 0x0302 · WM_CLEAR 0x0303 · WM_COPY 0x0301 · WM_CUT 0x0300
#   WM_SETTEXT 0x000C · EM_SETSEL 0x00B1 · EM_REPLACESEL 0x00C2 (undoable, no clipboard at all)
# This does NOT work for Chromium/Electron/WPF/Qt, which paint their own text and expose one
# HWND for the whole window — hence Test-EditControl, and the ctrl+v fallback.
$WM = @{ CUT=0x0300; COPY=0x0301; PASTE=0x0302; CLEAR=0x0303; SETTEXT=0x000C
         EM_SETSEL=0x00B1; EM_REPLACESEL=0x00C2 }
function Get-FocusControl([IntPtr]$top) { [CU.Native]::FocusedControl($top) }
function Test-EditControl([IntPtr]$h) {
    $cls = [CU.Native]::ClassOf($h)
    # Win32 Edit, all RichEdit generations, and the WinForms TextBox (which IS a native Edit).
    return ($cls -match '^(Edit|RichEdit\w*|RICHEDIT\w*)$')
}
function Send-Msg([IntPtr]$h, [int]$msg, [int]$wp, [int]$lp, [int]$ms = 2000) {
    $res = [IntPtr]::Zero
    $ok = [CU.Native]::SendMessageTimeout($h, [uint32]$msg, [IntPtr]$wp, [IntPtr]$lp, 2, [uint32]$ms, [ref]$res)
    return @{ Ok = ($ok -ne [IntPtr]::Zero); Result = $res.ToInt64() }
}
function Send-MsgStr([IntPtr]$h, [int]$msg, [int]$wp, [string]$lp, [int]$ms = 3000) {
    $res = [IntPtr]::Zero
    $ok = [CU.Native]::SendMessageTimeoutStr($h, [uint32]$msg, [IntPtr]$wp, $lp, 2, [uint32]$ms, [ref]$res)
    return @{ Ok = ($ok -ne [IntPtr]::Zero); Result = $res.ToInt64() }
}

# ── Clipboard (retried — another process can hold it open) ──────────────────────────────
function Set-ClipText([string]$s) {
    for ($i = 0; $i -lt 3; $i++) {
        try { Set-Clipboard -Value $s -ErrorAction Stop; return $true } catch { Start-Sleep -Milliseconds 120 }
    }
    return $false
}
function Get-ClipText {
    for ($i = 0; $i -lt 3; $i++) {
        try { return Get-Clipboard -Raw -ErrorAction Stop } catch { Start-Sleep -Milliseconds 80 }
    }
    return $null
}

# ── Windows: enumerate / resolve / focus ────────────────────────────────────────────────
function Get-TopWindows {
    $fg = [CU.Native]::GetForegroundWindow()
    foreach ($h in [CU.Native]::TopWindows()) {
        $len = [CU.Native]::GetWindowTextLength($h)
        $sb = New-Object System.Text.StringBuilder ($len + 2)
        [void][CU.Native]::GetWindowText($h, $sb, $sb.Capacity)
        $procId = 0
        [void][CU.Native]::GetWindowThreadProcessId($h, [ref]$procId)
        $r = [CU.Native]::GetBounds($h)
        $w = $r.Right - $r.Left; $ht = $r.Bottom - $r.Top
        $state = if ([CU.Native]::IsIconic($h)) { 'Min' } elseif ([CU.Native]::IsZoomed($h)) { 'Max' } else { 'Norm' }
        # A minimized window's rect is bogus (~-32000,-32000); report the state, not the rect.
        [pscustomobject]@{
            Hwnd    = [long]$h
            Process = (Get-Process -Id $procId -ErrorAction SilentlyContinue).ProcessName
            Title   = $sb.ToString()
            Rect    = if ($state -eq 'Min') { '(minimized)' } else { "$($r.Left),$($r.Top),$w,$ht" }
            State   = $state
            Focused = ($h -eq $fg)
        }
    }
}
function Find-Win([string]$title, [string]$proc) {
    $w = Get-TopWindows
    if ($title) { $w = $w | Where-Object { $_.Title -like "*$title*" } }
    if ($proc)  { $w = $w | Where-Object { $_.Process -like "*$proc*" } }
    @($w)
}
# Turn -Hwnd / -WindowTitle into exactly one live hwnd, or fail loudly on ambiguity.
function Resolve-Hwnd([long]$hp, [string]$tp, [string]$proc = '') {
    if ($hp -ne 0) {
        $h = [IntPtr]$hp
        if (-not [CU.Native]::IsWindow($h)) { throw "hwnd $hp no longer exists — re-run find-window (windows are recreated on reopen)" }
        return $h
    }
    if (-not $tp -and -not $proc) { throw "need -WindowTitle or -Hwnd" }
    $m = Find-Win $tp $proc
    if ($m.Count -eq 0) { throw "No visible window matching title='$tp' process='$proc'" }
    if ($m.Count -gt 1) {
        $cands = ($m | ForEach-Object { "$($_.Hwnd)='$($_.Title)'" }) -join '  |  '
        throw "Ambiguous: $($m.Count) windows match. Pass -Hwnd. Candidates: $cands"
    }
    return [IntPtr]$m[0].Hwnd
}
function Focus-Hwnd([IntPtr]$h) {
    if ([CU.Native]::IsIconic($h)) { [void][CU.Native]::ShowWindow($h, 9); Start-Sleep -Milliseconds 150 }
    if ([CU.Native]::GetForegroundWindow() -eq $h) { return $true }
    # SetForegroundWindow is blocked for background processes. Two workarounds, combined:
    #  1) attach our input queue to the current foreground thread (removes the block outright);
    #  2) an injected ALT keypress makes the OS treat the call as user-initiated.
    $cur = [CU.Native]::GetCurrentThreadId()
    $fgPid = 0
    $fgTid = [CU.Native]::GetWindowThreadProcessId([CU.Native]::GetForegroundWindow(), [ref]$fgPid)
    $attached = $false
    if ($fgTid -ne 0 -and $fgTid -ne $cur) { $attached = [CU.Native]::AttachThreadInput($cur, $fgTid, $true) }
    try {
        for ($i = 0; $i -lt 4; $i++) {
            Key-Down 0x12; Key-Up 0x12
            [void][CU.Native]::ShowWindow($h, 9)          # SW_RESTORE
            [void][CU.Native]::BringWindowToTop($h)
            [void][CU.Native]::SetForegroundWindow($h)
            Start-Sleep -Milliseconds (120 + $i * 120)     # back off — some apps focus slowly
            if ([CU.Native]::GetForegroundWindow() -eq $h) { return $true }
        }
    } finally { if ($attached) { [void][CU.Native]::AttachThreadInput($cur, $fgTid, $false) } }
    return $false
}

# ── Mouse helpers ───────────────────────────────────────────────────────────────────────
function Move-To([int]$x, [int]$y, [int]$sleepMs = 40) {
    if ($x -ne $NOPOS -and $y -ne $NOPOS) {
        [void][CU.Native]::SetCursorPos($x, $y)
        if ($sleepMs) { Start-Sleep -Milliseconds $sleepMs }
    }
}
function Btn-Down([int[]]$flags) { [void][CU.Native]::SendMouse([uint32]$flags[0], 0) }
function Btn-Up([int[]]$flags)   { [void][CU.Native]::SendMouse([uint32]$flags[1], 0) }

# ── Screenshot helpers ──────────────────────────────────────────────────────────────────
# A labelled grid in ABSOLUTE screen coordinates: read a target's coordinate straight off the
# image instead of estimating it from image pixels (the single biggest source of misclicks).
function Draw-Grid([System.Drawing.Bitmap]$img, [int]$spacing, [int]$ox, [int]$oy, [double]$factor) {
    if ($spacing -le 0) { return }
    # Keep labels legible: widen the spacing until gridlines are >= 44 px apart in the OUTPUT image.
    $eff = $spacing
    while (($eff * $factor) -lt 44) { $eff *= 2 }
    $g = [System.Drawing.Graphics]::FromImage($img)
    $pen  = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(85,255,0,255), 1)
    $font = [System.Drawing.Font]::new('Consolas', 8)
    $back = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(200,0,0,0))
    $fore = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255,255,90,255))
    try {
        $sx = [int]([Math]::Ceiling($ox / [double]$eff) * $eff)
        while ($true) {
            $ix = [int](($sx - $ox) * $factor)
            if ($ix -ge $img.Width) { break }
            if ($ix -ge 0) {
                $g.DrawLine($pen, $ix, 0, $ix, $img.Height)
                $sz = $g.MeasureString("$sx", $font)
                $g.FillRectangle($back, ($ix + 1), 0, $sz.Width, $sz.Height)
                $g.DrawString("$sx", $font, $fore, ($ix + 1), 0)
            }
            $sx += $eff
        }
        $sy = [int]([Math]::Ceiling($oy / [double]$eff) * $eff)
        while ($true) {
            $iy = [int](($sy - $oy) * $factor)
            if ($iy -ge $img.Height) { break }
            if ($iy -ge 12) {   # skip the row that would collide with the X labels
                $g.DrawLine($pen, 0, $iy, $img.Width, $iy)
                $sz = $g.MeasureString("$sy", $font)
                $g.FillRectangle($back, 0, ($iy + 1), $sz.Width, $sz.Height)
                $g.DrawString("$sy", $font, $fore, 0, ($iy + 1))
            }
            $sy += $eff
        }
    } finally { $pen.Dispose(); $font.Dispose(); $back.Dispose(); $fore.Dispose(); $g.Dispose() }
}
# Save as PNG, optionally downscaled (-Scale and/or -MaxWidth) to cut vision-token cost, with an
# optional coordinate grid. Returns the effective scale factor.
function Save-Image([System.Drawing.Bitmap]$bmp, [string]$full, [double]$scale, [int]$maxWidth,
                    [int]$grid, [int]$ox, [int]$oy) {
    $w = $bmp.Width; $h = $bmp.Height
    $factor = if ($scale -gt 0) { $scale } else { 1.0 }
    if ($maxWidth -gt 0 -and ($w * $factor) -gt $maxWidth) { $factor = $maxWidth / [double]$w }
    if ($factor -le 0) { throw "Invalid scale $factor" }
    $out = $bmp; $made = $false
    try {
        if ([Math]::Abs($factor - 1.0) -ge 1e-6) {
            $nw = [Math]::Max(1, [int]($w * $factor)); $nh = [Math]::Max(1, [int]($h * $factor))
            $out = [System.Drawing.Bitmap]::new($nw, $nh); $made = $true
            $g = [System.Drawing.Graphics]::FromImage($out)
            try {
                $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $g.DrawImage($bmp, 0, 0, $nw, $nh)
            } finally { $g.Dispose() }
        }
        if ($grid -gt 0) { Draw-Grid $out $grid $ox $oy $factor }
        $out.Save($full, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { if ($made) { $out.Dispose() } }
    return $factor
}
# Clip a requested rect to the real desktop so an off-screen window yields a clear error rather
# than a black image (CopyFromScreen happily "captures" nothing).
function Clip-Rect([System.Drawing.Rectangle]$r, [string]$what) {
    if ($r.Width -le 0 -or $r.Height -le 0) { throw "$what has an empty area ($($r.Width)x$($r.Height))" }
    $vs = Get-VirtualRect
    $i = [System.Drawing.Rectangle]::Intersect($r, [System.Drawing.Rectangle]::new($vs.X,$vs.Y,$vs.Width,$vs.Height))
    if ($i.Width -le 0 -or $i.Height -le 0) {
        throw "$what rect $($r.X),$($r.Y),$($r.Width),$($r.Height) is entirely off-screen (minimized or moved off the desktop?). Virtual desktop: $($vs.X),$($vs.Y),$($vs.Width),$($vs.Height)"
    }
    return $i
}
function Capture-Bitmap([System.Drawing.Rectangle]$rect) {
    $bmp = [System.Drawing.Bitmap]::new($rect.Width, $rect.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try { $g.CopyFromScreen($rect.Location, [System.Drawing.Point]::Empty, $rect.Size) } finally { $g.Dispose() }
    return $bmp
}
function Resolve-OutPath([string]$outPath) {
    $full = if ([System.IO.Path]::IsPathRooted($outPath)) { $outPath } else { Join-Path (Get-Location) $outPath }
    $parent = Split-Path -Parent $full
    if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    return $full
}
function Rect-From([IntPtr]$h) {
    $r = [CU.Native]::GetBounds($h)
    [System.Drawing.Rectangle]::new($r.Left, $r.Top, $r.Right - $r.Left, $r.Bottom - $r.Top)
}
# Fingerprint a region cheaply (downscaled) so wait-stable can compare frames without vision.
function Get-RegionHash([System.Drawing.Rectangle]$rect) {
    $bmp = Capture-Bitmap $rect
    try {
        $nw = [Math]::Max(1, [Math]::Min(320, $bmp.Width)); $f = $nw / [double]$bmp.Width
        $nh = [Math]::Max(1, [int]($bmp.Height * $f))
        $sm = [System.Drawing.Bitmap]::new($nw, $nh)
        try {
            $g = [System.Drawing.Graphics]::FromImage($sm)
            try { $g.DrawImage($bmp, 0, 0, $nw, $nh) } finally { $g.Dispose() }
            $ms = [System.IO.MemoryStream]::new()
            try {
                $sm.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
                $md5 = [System.Security.Cryptography.MD5]::Create()
                try { return [Convert]::ToBase64String($md5.ComputeHash($ms.ToArray())) } finally { $md5.Dispose() }
            } finally { $ms.Dispose() }
        } finally { $sm.Dispose() }
    } finally { $bmp.Dispose() }
}

# ── UI Automation (lazy — only pay for it when a ui-* action is used) ────────────────────
function Ensure-Uia {
    if (-not ('System.Windows.Automation.AutomationElement' -as [type])) {
        try { Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction Stop }
        catch { throw "UI Automation is unavailable in this PowerShell host ($($_.Exception.Message)). Fall back to screenshot + cursor-type probing." }
    }
}
function Uia-Prop($el, [string]$name, $def = $null) {
    try { return $el.Current.$name } catch { return $def }
}
# Bounded walk: depth cap, node budget AND a wall-clock deadline. Electron/Chromium trees can be
# enormous or answer slowly, so all three limits matter — a runaway walk would hang the step.
function Walk-Uia($root, [int]$maxDepth, [int]$budget, [double]$timeoutSec) {
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $out = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push(@($root, 0))
    $truncated = $false
    while ($stack.Count -gt 0) {
        if ($out.Count -ge $budget -or $sw.Elapsed.TotalSeconds -ge $timeoutSec) { $truncated = $true; break }
        $item = $stack.Pop(); $el = $item[0]; $d = $item[1]
        $r = Uia-Prop $el 'BoundingRectangle'
        $rectStr = '-'
        if ($r -and -not [double]::IsInfinity($r.Width) -and $r.Width -gt 0) {
            $rectStr = "$([int]$r.X),$([int]$r.Y),$([int]$r.Width),$([int]$r.Height)"
        }
        $ct = Uia-Prop $el 'ControlType'
        $out.Add([pscustomobject]@{
            Depth  = $d
            Type   = if ($ct) { ($ct.ProgrammaticName -replace '^ControlType\.','') } else { '?' }
            Name   = (Uia-Prop $el 'Name' '')
            AutoId = (Uia-Prop $el 'AutomationId' '')
            Rect   = $rectStr
            Click  = if ($rectStr -ne '-') { "$([int]($r.X + $r.Width/2)),$([int]($r.Y + $r.Height/2))" } else { '-' }
            Off    = [bool](Uia-Prop $el 'IsOffscreen' $false)
            Enabled= [bool](Uia-Prop $el 'IsEnabled' $true)
        })
        if ($d -lt $maxDepth) {
            try {
                $kids = @()
                $c = $walker.GetFirstChild($el)
                while ($c) { $kids += $c; $c = $walker.GetNextSibling($c) }
                # push reversed so the emitted order matches the visual/tree order
                for ($i = $kids.Count - 1; $i -ge 0; $i--) { $stack.Push(@($kids[$i], $d + 1)) }
            } catch {}
        }
    }
    return [pscustomobject]@{ Rows = $out; Truncated = $truncated; Ms = [int]$sw.Elapsed.TotalMilliseconds }
}

# ── Cursor shape probing ────────────────────────────────────────────────────────────────
$CURSOR_NAMES = @{ 32512='arrow'; 32513='ibeam'; 32514='wait'; 32649='hand'; 32515='cross';
                   32644='sizewe'; 32645='sizens'; 32642='sizenwse'; 32643='sizenesw'; 32646='sizeall';
                   32648='no'; 32651='help' }
function Get-CursorShape {
    $ci = New-Object 'CU.Native+CURSORINFO'
    $ci.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($ci)
    [void][CU.Native]::GetCursorInfo([ref]$ci)
    foreach ($id in $CURSOR_NAMES.Keys) {
        if ([CU.Native]::LoadCursor([IntPtr]::Zero, $id) -eq $ci.hCursor) { return $CURSOR_NAMES[$id] }
    }
    return 'other'   # app-supplied cursor (custom resize handles, drawing tools, …)
}
# SetCursorPos alone does NOT repaint the cursor shape (no WM_SETCURSOR is generated); a real
# relative move does. Nudge +1/-1 so the pointer lands back exactly on (x,y) either way.
function Probe-Shape([int]$x, [int]$y, [int]$settleMs) {
    [void][CU.Native]::SetCursorPos($x, $y)
    [void][CU.Native]::SendMouseMoveRel(1, 0)
    Start-Sleep -Milliseconds 15
    [void][CU.Native]::SendMouseMoveRel(-1, 0)
    [void][CU.Native]::SetCursorPos($x, $y)   # relative moves obey pointer acceleration; re-pin
    Start-Sleep -Milliseconds $settleMs
    return Get-CursorShape
}

# ════════════════════════════════════════════════════════════════════════════════════════
#  One step
# ════════════════════════════════════════════════════════════════════════════════════════
function Invoke-Step([hashtable]$p) {
    $act         = PStr  $p 'Action'
    $x           = PInt  $p 'X'  $NOPOS
    $y           = PInt  $p 'Y'  $NOPOS
    $x2          = PInt  $p 'X2' $NOPOS
    $y2          = PInt  $p 'Y2' $NOPOS
    $w           = PInt  $p 'W'  $NOPOS
    $h           = PInt  $p 'H'  $NOPOS
    $button      = PStr  $p 'Button' 'left'
    $modifiers   = PStr  $p 'Modifiers'
    $count       = PInt  $p 'Count' 1
    $amount      = PInt  $p 'Amount' 3
    $direction   = PStr  $p 'Direction' 'down'
    $text        = PStr  $p 'Text'
    $keys        = PStr  $p 'Keys'
    $path        = PStr  $p 'Path'
    $winTitle    = PStr  $p 'WindowTitle'
    $hwndParam   = [long](PNum $p 'Hwnd' 0)
    $foreground  = PBool $p 'Foreground'
    $allScreens  = PBool $p 'AllScreens'
    $region      = PStr  $p 'Region'
    $scale       = PNum  $p 'Scale' 0
    $maxWidth    = PInt  $p 'MaxWidth' 0
    $grid        = PInt  $p 'Grid' 0
    $noFocus     = PBool $p 'NoFocus'
    $delay       = PNum  $p 'Delay' 0
    $stepsParam  = PInt  $p 'Steps' 0
    $holdMs      = PInt  $p 'HoldMs' 0
    $noRestoreCb = PBool $p 'NoRestoreClipboard'
    $filter      = PStr  $p 'Filter'
    $name        = PStr  $p 'Name'
    $depth       = PInt  $p 'Depth' 0
    $scanSpec    = PStr  $p 'Scan'
    $timeout     = PNum  $p 'Timeout' 0
    $absent      = PBool $p 'Absent'

    if ($button -notin @('left','right','middle')) { throw "button must be left|right|middle" }

    function Focus-If-Targeted {
        if ($hwndParam -ne 0 -or $winTitle) { [void](Focus-Hwnd (Resolve-Hwnd $hwndParam $winTitle)) }
    }
    # Resolve a capture rect from -Region / -Hwnd / -WindowTitle / -Foreground / -AllScreens / primary.
    function Resolve-CaptureRect([bool]$focusWindow) {
        if ($region) {
            $v = $region -split '\s*,\s*'
            if ($v.Count -ne 4) { throw "Region must be 'X,Y,Width,Height'" }
            $r = [System.Drawing.Rectangle]::new([int]$v[0], [int]$v[1], [int]$v[2], [int]$v[3])
            if ($r.Width -le 0 -or $r.Height -le 0) { throw "Region width/height must be > 0 (got $($r.Width)x$($r.Height))" }
            return (Clip-Rect $r 'Region')
        }
        if ($hwndParam -ne 0 -or $winTitle) {
            $hh = Resolve-Hwnd $hwndParam $winTitle
            if ($focusWindow) { [void](Focus-Hwnd $hh) }
            elseif ([CU.Native]::IsIconic($hh)) { [void][CU.Native]::ShowWindow($hh, 9); Start-Sleep -Milliseconds 200 }
            return (Clip-Rect (Rect-From $hh) "window $([long]$hh)")
        }
        if ($foreground) { return (Clip-Rect (Rect-From ([CU.Native]::GetForegroundWindow())) 'foreground window') }
        if ($allScreens) {
            $vs = Get-VirtualRect
            return [System.Drawing.Rectangle]::new($vs.X, $vs.Y, $vs.Width, $vs.Height)
        }
        return [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    }

    switch ($act) {

        'screen-size' {
            foreach ($sc in [System.Windows.Forms.Screen]::AllScreens) {
                $b = $sc.Bounds
                $s = Get-MonitorScale ($b.X + [int]($b.Width/2)) ($b.Y + [int]($b.Height/2))
                Write-Output ("{0}  Primary={1}  Bounds={2},{3},{4},{5}  Scale={6}x" -f `
                    $sc.DeviceName, $sc.Primary, $b.X, $b.Y, $b.Width, $b.Height, $s)
            }
            $vs = Get-VirtualRect
            Write-Output ("virtual-desktop: {0},{1},{2},{3}   (coords may be negative)" -f $vs.X, $vs.Y, $vs.Width, $vs.Height)
        }

        'mouse-pos' {
            $pt = [CU.Native]::GetPos()
            $mon = Get-MonitorAt $pt.X $pt.Y
            Write-Output "mouse: $($pt.X),$($pt.Y)$(if ($mon) { " on $($mon.DeviceName)" } else { ' (off-monitor)' })"
        }

        # Cursor shape: ibeam = text/input, sizewe/sizens = sash, hand = link/button, arrow, other
        # (= app-supplied). -Scan probes a whole line in ONE process and reports each transition —
        # that is how you find a 3-px-wide splitter without guessing.
        'cursor-type' {
            if ($scanSpec) {
                $v = $scanSpec -split '\s*,\s*'
                if ($v.Count -ne 4) { throw "Scan must be 'x1,y1,x2,y2'" }
                $sx1=[int]$v[0]; $sy1=[int]$v[1]; $sx2=[int]$v[2]; $sy2=[int]$v[3]
                Assert-OnScreen $sx1 $sy1 'scan start'; Assert-OnScreen $sx2 $sy2 'scan end'
                $step = [Math]::Max(1, $(if ($p.ContainsKey('Amount')) { $amount } else { 4 }))
                $dist = [int][Math]::Sqrt([Math]::Pow($sx2-$sx1,2) + [Math]::Pow($sy2-$sy1,2))
                $n = [Math]::Max(1, [int]($dist / $step))
                if ($n -gt 400) { throw "Scan would take $n samples (~$([int]($n*0.06))s). Shorten the line or raise -Amount (step px)." }
                $settle = if ($holdMs -gt 0) { $holdMs } else { 45 }
                $origin = [CU.Native]::GetPos()
                $prev = $null; $runStart = $null; $hits = @()
                try {
                    for ($i = 0; $i -le $n; $i++) {
                        $cx = $sx1 + [int]((($sx2-$sx1) * $i) / $n)
                        $cy = $sy1 + [int]((($sy2-$sy1) * $i) / $n)
                        $shape = Probe-Shape $cx $cy $settle
                        if ($shape -ne $prev) {
                            if ($prev) { $hits += [pscustomobject]@{ Shape=$prev; From=$runStart; To=@($lx,$ly) } }
                            $prev = $shape; $runStart = @($cx,$cy)
                        }
                        $lx = $cx; $ly = $cy
                    }
                    if ($prev) { $hits += [pscustomobject]@{ Shape=$prev; From=$runStart; To=@($lx,$ly) } }
                } finally { [void][CU.Native]::SetCursorPos($origin.X, $origin.Y) }
                foreach ($hh in $hits) {
                    $cxm = [int](($hh.From[0] + $hh.To[0]) / 2); $cym = [int](($hh.From[1] + $hh.To[1]) / 2)
                    $mark = if ($filter -and $hh.Shape -eq $filter) { '  <== MATCH' } else { '' }
                    Write-Output ("{0,-10} {1},{2} .. {3},{4}   center={5},{6}{7}" -f `
                        $hh.Shape, $hh.From[0], $hh.From[1], $hh.To[0], $hh.To[1], $cxm, $cym, $mark)
                }
                if ($filter -and -not ($hits | Where-Object { $_.Shape -eq $filter })) {
                    Write-Output "no '$filter' found along the scan line"
                }
                Write-Output "(cursor restored to $($origin.X),$($origin.Y); $($n+1) samples)"
            } else {
                if ($x -ne $NOPOS -or $y -ne $NOPOS) {
                    Assert-OnScreen $x $y 'cursor-type'
                    $settle = if ($holdMs -gt 0) { $holdMs } else { 150 }
                    $shape = Probe-Shape $x $y $settle
                } else { $shape = Get-CursorShape }
                $pt = [CU.Native]::GetPos()
                Write-Output "cursor at $($pt.X),$($pt.Y): $shape"
            }
        }

        # Colour without vision tokens: verify a toggle flipped, a row highlighted, a light turned green.
        'pixel' {
            if ($region) { $rect = Resolve-CaptureRect $false }
            else {
                Assert-OnScreen $x $y 'pixel'
                $pw = if ($w -ne $NOPOS -and $w -gt 0) { $w } else { 1 }
                $ph = if ($h -ne $NOPOS -and $h -gt 0) { $h } else { 1 }
                $rect = Clip-Rect ([System.Drawing.Rectangle]::new($x, $y, $pw, $ph)) 'pixel'
            }
            $bmp = Capture-Bitmap $rect
            try {
                if ($rect.Width -eq 1 -and $rect.Height -eq 1) {
                    $c = $bmp.GetPixel(0,0)
                    Write-Output ("pixel {0},{1}: #{2:X2}{3:X2}{4:X2}  rgb({2},{3},{4})" -f $rect.X, $rect.Y, $c.R, $c.G, $c.B)
                } else {
                    $rs=0; $gs=0; $bs=0; $n=0; $uniform=$true; $first=$null
                    $stepX = [Math]::Max(1, [int]($rect.Width / 40)); $stepY = [Math]::Max(1, [int]($rect.Height / 40))
                    for ($iy = 0; $iy -lt $rect.Height; $iy += $stepY) {
                        for ($ix = 0; $ix -lt $rect.Width; $ix += $stepX) {
                            $c = $bmp.GetPixel($ix, $iy)
                            if ($null -eq $first) { $first = $c }
                            elseif ($uniform -and ([Math]::Abs($c.R-$first.R) + [Math]::Abs($c.G-$first.G) + [Math]::Abs($c.B-$first.B)) -gt 12) { $uniform = $false }
                            $rs += $c.R; $gs += $c.G; $bs += $c.B; $n++
                        }
                    }
                    $ar=[int]($rs/$n); $ag=[int]($gs/$n); $ab=[int]($bs/$n)
                    Write-Output ("region {0},{1},{2},{3}: mean #{4:X2}{5:X2}{6:X2}  rgb({4},{5},{6})  uniform={7}  samples={8}" -f `
                        $rect.X, $rect.Y, $rect.Width, $rect.Height, $ar, $ag, $ab, $uniform, $n)
                }
            } finally { $bmp.Dispose() }
        }

        'find-window' {
            $wins = Find-Win $winTitle $filter
            if ($wins.Count -eq 0) { Write-Output "no window matches title='$winTitle' process='$filter'"; break }
            $max = if ($p.ContainsKey('Count')) { $count } else { 40 }
            $sorted = $wins | Sort-Object @{E={-not $_.Focused}}, Process, Title
            $shown = @($sorted | Select-Object -First $max)
            $shown | Format-Table Hwnd, Process, Title, Rect, State, Focused -AutoSize | Out-String -Width 260 | Write-Output
            if ($wins.Count -gt $shown.Count) { Write-Output "... $($wins.Count - $shown.Count) more (raise -Count or narrow with -Filter/-WindowTitle)" }
        }

        'list-procs' {
            $procs = Get-Process
            if ($filter) { $procs = $procs | Where-Object { $_.ProcessName -like "*$filter*" } }
            $max = if ($p.ContainsKey('Count')) { $count } else { 40 }
            $procs | Sort-Object WorkingSet64 -Descending | Select-Object -First $max `
                Id, ProcessName,
                @{N='MB';E={[int]($_.WorkingSet64/1MB)}},
                @{N='HasWindow';E={ $_.MainWindowHandle -ne 0 }},
                @{N='Title';E={$_.MainWindowTitle}} |
                Format-Table -AutoSize | Out-String -Width 200 | Write-Output
        }

        'focus' {
            $hh = Resolve-Hwnd $hwndParam $winTitle $filter
            if (Focus-Hwnd $hh) { Write-Output "focused: hwnd $([long]$hh)" }
            else { throw "Could not bring hwnd $([long]$hh) to front (a modal dialog, an elevated window, or a full-screen app may be holding focus). Tip: a physical click inside the window also activates it." }
        }

        'maximize' {
            $hh = Resolve-Hwnd $hwndParam $winTitle $filter
            [void][CU.Native]::ShowWindow($hh, 3)   # SW_MAXIMIZE
            [void](Focus-Hwnd $hh)
            $r = [CU.Native]::GetBounds($hh)
            Write-Output "maximized hwnd $([long]$hh): $($r.Left),$($r.Top),$($r.Right-$r.Left),$($r.Bottom-$r.Top)"
        }

        'minimize' {
            $hh = Resolve-Hwnd $hwndParam $winTitle $filter
            [void][CU.Native]::ShowWindow($hh, 6)   # SW_MINIMIZE
            Write-Output "minimized hwnd $([long]$hh)"
        }

        'restore' {
            $hh = Resolve-Hwnd $hwndParam $winTitle $filter
            [void][CU.Native]::ShowWindow($hh, 9)   # SW_RESTORE
            [void](Focus-Hwnd $hh)
            $r = [CU.Native]::GetBounds($hh)
            Write-Output "restored hwnd $([long]$hh): $($r.Left),$($r.Top),$($r.Right-$r.Left),$($r.Bottom-$r.Top)"
        }

        'window-move' {
            $hh = Resolve-Hwnd $hwndParam $winTitle $filter
            if ($x -eq $NOPOS -or $y -eq $NOPOS -or $w -eq $NOPOS -or $h -eq $NOPOS) { throw "window-move needs -X -Y -W -H (X/Y may be negative for a monitor left of / above the primary)" }
            if ($w -le 0 -or $h -le 0) { throw "window-move needs a positive -W and -H" }
            [void][CU.Native]::ShowWindow($hh, 9)   # SW_RESTORE (a maximized window won't move)
            Start-Sleep -Milliseconds 80
            [void][CU.Native]::SetWindowPos($hh, [IntPtr]::Zero, $x, $y, $w, $h, 0x4)   # SWP_NOZORDER
            [void](Focus-Hwnd $hh)
            Start-Sleep -Milliseconds 120
            $r = [CU.Native]::GetBounds($hh)
            $got = "$($r.Left),$($r.Top),$($r.Right-$r.Left),$($r.Bottom-$r.Top)"
            # Many apps clamp to a minimum size or snap to a monitor — report what actually happened.
            $note = if ($got -ne "$x,$y,$w,$h") { "  (app adjusted; requested $x,$y,$w,$h)" } else { '' }
            Write-Output "window-move hwnd $([long]$hh): $got$note"
        }

        'screenshot' {
            if (-not $path) { throw "screenshot needs -Path" }
            $rect = Resolve-CaptureRect (-not $noFocus)
            if ($delay -gt 0) { Start-Sleep -Milliseconds ([int]($delay * 1000)) }
            $full = Resolve-OutPath $path
            if ([System.IO.Path]::GetExtension($full).ToLower() -ne '.png') { $full = [System.IO.Path]::ChangeExtension($full, '.png') }
            $bmp = Capture-Bitmap $rect
            try { $factor = Save-Image $bmp $full $scale $maxWidth $grid $rect.X $rect.Y } finally { $bmp.Dispose() }
            $ow = [Math]::Max(1,[int]($rect.Width * $factor)); $oh = [Math]::Max(1,[int]($rect.Height * $factor))
            Write-Output "screenshot: ${ow}x${oh} (~$([int]($ow*$oh/750)) vision tokens) -> $full"
            Write-Output ("map: screen_x = {0} + image_x / {1:F4} ;  screen_y = {2} + image_y / {1:F4}" -f $rect.X, $factor, $rect.Y)
        }

        'move' {
            Assert-OnScreen $x $y 'move'
            Move-To $x $y 0
            if ($delay -gt 0) { Start-Sleep -Milliseconds ([int]($delay * 1000)) }   # hover for a tooltip/menu
            Write-Output "moved: $x,$y"
        }

        'click' {
            if ($x -ne $NOPOS -or $y -ne $NOPOS) { Assert-OnScreen $x $y 'click'; Move-To $x $y }
            $flags = $BTN[$button]
            $mv = Push-Modifiers $modifiers
            try {
                for ($i = 0; $i -lt $count; $i++) {
                    Btn-Down $flags; Start-Sleep -Milliseconds 25; Btn-Up $flags
                    # 80ms < the ~500ms Windows double-click time, so -Count 2 IS a double-click.
                    # For two INDEPENDENT single clicks, issue two click steps instead.
                    if ($i -lt $count - 1) { Start-Sleep -Milliseconds 80 }
                }
            } finally { Pop-Modifiers $mv }
            if ($delay -gt 0) { Start-Sleep -Milliseconds ([int]($delay * 1000)) }
            $pt = [CU.Native]::GetPos()
            Write-Output "$button click x$count$(if ($modifiers) { " [$modifiers]" }) at $($pt.X),$($pt.Y)"
        }

        'mouse-down' {
            if ($x -ne $NOPOS -or $y -ne $NOPOS) { Assert-OnScreen $x $y 'mouse-down'; Move-To $x $y }
            Btn-Down $BTN[$button]
            $pt = [CU.Native]::GetPos()
            Write-Output "$button down at $($pt.X),$($pt.Y)  (remember to mouse-up — a stuck button breaks the desktop)"
        }

        'mouse-up' {
            if ($x -ne $NOPOS -or $y -ne $NOPOS) { Assert-OnScreen $x $y 'mouse-up'; Move-To $x $y }
            Btn-Up $BTN[$button]
            $pt = [CU.Native]::GetPos()
            Write-Output "$button up at $($pt.X),$($pt.Y)"
        }

        'scroll' {
            if ($x -ne $NOPOS -or $y -ne $NOPOS) { Assert-OnScreen $x $y 'scroll'; Move-To $x $y }
            if ($direction -notin @('up','down','left','right')) { throw "direction must be up|down|left|right" }
            $horiz = $direction -in @('left','right')
            $sign  = if ($direction -in @('up','right')) { 1 } else { -1 }
            $ev    = if ($horiz) { [CU.Native]::MOUSEEVENTF_HWHEEL } else { [CU.Native]::MOUSEEVENTF_WHEEL }
            $mv = Push-Modifiers $modifiers    # ctrl+scroll = zoom in most apps
            try {
                # One notch per event (not one giant delta): smooth-scrolling apps (Electron,
                # Chrome, VS Code) treat a single large delta as ONE step and under-scroll.
                for ($i = 0; $i -lt [Math]::Max(1, $amount); $i++) {
                    [void][CU.Native]::SendMouse($ev, (120 * $sign))
                    Start-Sleep -Milliseconds 25
                }
            } finally { Pop-Modifiers $mv }
            if ($delay -gt 0) { Start-Sleep -Milliseconds ([int]($delay * 1000)) }
            Write-Output "scrolled $direction x$amount$(if ($modifiers) { " [$modifiers]" })"
        }

        'drag' {
            Assert-OnScreen $x $y 'drag start'
            Assert-OnScreen $x2 $y2 'drag end'
            $flags = $BTN[$button]
            $dist = [int][Math]::Sqrt([Math]::Pow($x2-$x,2) + [Math]::Pow($y2-$y,2))
            $steps = if ($stepsParam -gt 0) { $stepsParam } else { [Math]::Min(40, [Math]::Max(10, [int]($dist / 12))) }
            $hold  = if ($holdMs -gt 0) { $holdMs } else { 140 }
            $mv = Push-Modifiers $modifiers
            try {
                Move-To $x $y 80
                Btn-Down $flags
                Start-Sleep -Milliseconds 90          # let the app register the press before moving
                # Cross the drag threshold with a small deliberate move; many toolkits ignore a
                # press+teleport+release and treat it as a click.
                [void][CU.Native]::SetCursorPos($x + 3, $y + 3); Start-Sleep -Milliseconds 40
                [void][CU.Native]::SetCursorPos($x, $y); Start-Sleep -Milliseconds 40
                for ($i = 1; $i -le $steps; $i++) {
                    $cx = $x + [int]((($x2 - $x) * $i) / $steps)
                    $cy = $y + [int]((($y2 - $y) * $i) / $steps)
                    [void][CU.Native]::SetCursorPos($cx, $cy); Start-Sleep -Milliseconds 12
                }
                [void][CU.Native]::SetCursorPos($x2, $y2)
                Start-Sleep -Milliseconds $hold       # let the drop target settle/highlight
                Btn-Up $flags
            } finally { Pop-Modifiers $mv; Btn-Up $flags }   # never leave the button stuck down
            if ($delay -gt 0) { Start-Sleep -Milliseconds ([int]($delay * 1000)) }
            Write-Output "dragged $x,$y -> $x2,$y2 ($steps steps, hold ${hold}ms)"
        }

        # -Mode auto (default) | msg | clipboard
        #   msg       EM_REPLACESEL straight to the focused edit control: no clipboard, no
        #             keystroke, immune to the IME, and undoable. Native controls only.
        #   clipboard clipboard + ctrl+v — works everywhere (Electron, WPF, Qt, browsers) but
        #             the ctrl+v can be eaten by a CJK IME.
        #   auto      msg when the focused control is a real Win32 edit, else clipboard.
        'type' {
            if (-not $p.ContainsKey('Text')) { throw "type needs -Text" }
            Focus-If-Targeted
            if ([string]::IsNullOrEmpty($text)) { Write-Output "typed 0 chars (empty -Text, nothing sent)"; break }
            $mode = PStr $p 'Mode' 'auto'
            if ($mode -notin @('auto','msg','clipboard')) { throw "type -Mode must be auto|msg|clipboard" }

            $top = [CU.Native]::GetForegroundWindow()
            $ctrl = Get-FocusControl $top
            $cls = [CU.Native]::ClassOf($ctrl)
            $useMsg = ($mode -eq 'msg') -or ($mode -eq 'auto' -and (Test-EditControl $ctrl))

            if ($useMsg) {
                $before = [CU.Native]::GetCtrlTextLength($ctrl)
                # EM_REPLACESEL(wParam=1 => keep undo history) replaces the selection, which is
                # exactly what a paste does — but with the text passed in the message itself.
                $r = Send-MsgStr $ctrl $WM.EM_REPLACESEL 1 $text
                Start-Sleep -Milliseconds 60
                $after = [CU.Native]::GetCtrlTextLength($ctrl)
                if ($r.Ok -and $after -ne $before) {
                    if ($delay -gt 0) { Start-Sleep -Milliseconds ([int]($delay * 1000)) }
                    Write-Output "typed $($text.Length) chars via EM_REPLACESEL into '$cls' (no keyboard, no clipboard, IME-proof)"
                    break
                }
                if ($mode -eq 'msg') { throw "EM_REPLACESEL had no effect on focused control '$cls' (hwnd $([long]$ctrl)) — it is not a native edit control. Use -Mode clipboard." }
                Write-Output "note: '$cls' ignored EM_REPLACESEL — falling back to clipboard+ctrl+v"
            }

            # NOTE: only TEXT is preserved by the restore. A picture/file on the clipboard is lost.
            $old = Get-ClipText
            if (-not (Set-ClipText $text)) { throw "Could not put text on the clipboard (another app is holding it open). Retry, or use -Mode msg." }
            Start-Sleep -Milliseconds 120
            $warn = Get-ImeWarning 'v'
            if ($warn) { Write-Output $warn }
            Send-Combo 'ctrl+v'
            Start-Sleep -Milliseconds ([Math]::Min(600, 180 + [int]($text.Length / 40)))   # long pastes need longer
            if (-not $noRestoreCb -and $null -ne $old) { [void](Set-ClipText $old) }
            if ($delay -gt 0) { Start-Sleep -Milliseconds ([int]($delay * 1000)) }
            Write-Output "typed $($text.Length) chars via clipboard+ctrl+v (focus='$cls')"
        }

        # Talk to the focused edit control directly — read/replace/select/clear its text with no
        # keyboard involved at all. -Mode read is also the cheapest possible verification step:
        # it confirms what landed in a field for ZERO vision tokens.
        'edit' {
            $top = if ($hwndParam -ne 0 -or $winTitle) { $hh = Resolve-Hwnd $hwndParam $winTitle $filter; [void](Focus-Hwnd $hh); $hh }
                   else { [CU.Native]::GetForegroundWindow() }
            $ctrl = Get-FocusControl $top
            $cls = [CU.Native]::ClassOf($ctrl)
            $mode = PStr $p 'Mode' 'read'
            switch ($mode) {
                'read' {
                    $t = [CU.Native]::GetCtrlText($ctrl, 200000)
                    if ($null -eq $t) { throw "control '$cls' (hwnd $([long]$ctrl)) did not answer WM_GETTEXT — Electron/WPF/Qt paint their own text; screenshot it instead." }
                    Write-Output "edit read '$cls' ($($t.Length) chars):"
                    Write-Output $t
                }
                'selectall' { [void](Send-Msg $ctrl $WM.EM_SETSEL 0 -1); Write-Output "selected all in '$cls'" }
                'clear'     { [void](Send-Msg $ctrl $WM.EM_SETSEL 0 -1); [void](Send-Msg $ctrl $WM.CLEAR 0 0); Write-Output "cleared '$cls'" }
                'copy'      {
                    [void](Send-Msg $ctrl $WM.COPY 0 0); Start-Sleep -Milliseconds 120
                    $c = Get-ClipText
                    Write-Output "copied from '$cls' ($($c.Length) chars):"; Write-Output $c
                }
                'paste'     {
                    if (-not $p.ContainsKey('Text')) { throw "edit -Mode paste needs -Text" }
                    if (-not (Set-ClipText $text)) { throw "Could not set the clipboard" }
                    Start-Sleep -Milliseconds 100
                    $r = Send-Msg $ctrl $WM.PASTE 0 0
                    Write-Output "WM_PASTE -> '$cls' (delivered=$($r.Ok))"
                }
                'set'       {
                    if (-not $p.ContainsKey('Text')) { throw "edit -Mode set needs -Text" }
                    $r = Send-MsgStr $ctrl $WM.SETTEXT 0 $text
                    Write-Output "WM_SETTEXT -> '$cls' (delivered=$($r.Ok), replaced the ENTIRE control content)"
                }
                default { throw "edit -Mode must be read|set|paste|selectall|clear|copy (got '$mode')" }
            }
            if ($delay -gt 0) { Start-Sleep -Milliseconds ([int]($delay * 1000)) }
        }

        'keys' {
            if (-not $keys) { throw "keys needs -Keys (e.g. 'ctrl+l', 'enter', 'ctrl+shift+p', 'ctrl+``')" }
            Focus-If-Targeted
            $combos = @(($keys -split '\s+') | Where-Object { $_ })
            $warn = Get-ImeWarning $keys
            if ($warn) { Write-Output $warn }
            foreach ($combo in $combos) { Send-Combo $combo; Start-Sleep -Milliseconds 60 }
            if ($delay -gt 0) { Start-Sleep -Milliseconds ([int]($delay * 1000)) }
            Write-Output "sent keys: $keys"
        }

        # -Mode report (default) | english | native | clear | 0xNNN (restore an exact mode).
        # Programmatic switching works for the Microsoft IME (微软拼音/输入法) and other IMM32
        # IMEs. Third-party TSF-only IMEs (搜狗/QQ/百度…) may ignore it — this action therefore
        # ALWAYS verifies and tells you when the switch did not take, so you can fall back to
        # driving the IME's own UI (screenshot the tray indicator 中/英 and click it).
        'ime' {
            $target = if ($hwndParam -ne 0 -or $winTitle) { Resolve-Hwnd $hwndParam $winTitle $filter } else { [CU.Native]::GetForegroundWindow() }
            $mode = PStr $p 'Mode' 'report'
            $st = Get-ImeState $target
            if (-not $st) { Write-Output "ime: could not query hwnd $([long]$target)"; break }
            $langName = switch ($st.Lang) { 0x0804 {'zh-CN'} 0x0404 {'zh-TW'} 0x0411 {'ja-JP'} 0x0412 {'ko-KR'} 0x0409 {'en-US'} default { "0x{0:X4}" -f $st.Lang } }
            if (-not $st.Ime) { Write-Output "ime: hwnd $([long]$target) layout=$langName — no IME attached (plain keyboard layout, nothing to worry about)"; break }

            if ($mode -eq 'report') {
                Write-Output ("ime: hwnd {0} layout={1} conv=0x{2:X} native={3} open={4}" -f [long]$target, $langName, $st.Conv, $st.Native, $st.Open)
                if ($st.Native) {
                    Write-Output "  -> CJK mode is ON: shortcuts and pasted text can be eaten. Before a burst of keys run: -Action ime -Mode english"
                    Write-Output ("  -> restore afterwards with: -Action ime -Mode 0x{0:X}" -f $st.Conv)
                }
                break
            }

            $imeWnd = Get-ImeWnd $target
            if ($mode -eq 'clear') {
                # ESC cancels a pending composition WITHOUT committing it — but it also closes
                # menus, popups and dialogs, so only use it when a candidate box is really open.
                Send-Combo 'esc'
                Start-Sleep -Milliseconds 150
                Write-Output "ime: sent esc to cancel any pending composition (note: esc also closes menus/dialogs)"
                break
            }
            $want = switch -Regex ($mode) {
                '^english$|^en$|^alpha' { 0 }
                '^native$|^cjk$|^zh'    { $st.Conv -bor 1 }
                '^0[xX][0-9a-fA-F]+$'   { [Convert]::ToInt32($mode, 16) }
                '^\d+$'                 { [int]$mode }
                default { throw "ime -Mode must be report|english|native|clear|0xNNN (got '$mode')" }
            }
            $before = $st.Conv
            [void](Send-ImeControl $imeWnd 0x0002 $want)
            Start-Sleep -Milliseconds 250
            $after = (Get-ImeState $target).Conv
            Write-Output ("ime: conv 0x{0:X} -> 0x{1:X} (requested 0x{2:X})" -f $before, $after, $want)
            if ($after -ne $want) {
                Write-Output "ime: the IME IGNORED the request — it is probably a TSF-only third-party IME (搜狗/QQ/百度…). Fall back to its UI: screenshot the tray/indicator, click the 中/英 toggle, or send 'shift' / 'ctrl+space', then re-run -Action ime to verify."
            } elseif ($want -eq 0) {
                Write-Output ("ime: English mode — any open candidate box is closed and pending letters were committed. Restore with -Action ime -Mode 0x{0:X}" -f $before)
            }
        }

        # EXACT control rects with zero vision tokens. Great for native/Win32/WPF apps and dialogs;
        # Chromium/Electron expose a partial tree, so treat a miss as "fall back to screenshots".
        { $_ -in 'ui-find','ui-tree' } {
            Ensure-Uia
            if ($hwndParam -eq 0 -and -not $winTitle) { throw "$act needs -Hwnd or -WindowTitle (walking the whole desktop tree is far too slow)" }
            $hh = Resolve-Hwnd $hwndParam $winTitle $filter
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($hh)
            if (-not $root) { throw "No UI Automation element for hwnd $([long]$hh)" }
            $maxDepth = if ($depth -gt 0) { $depth } elseif ($act -eq 'ui-tree') { 4 } else { 12 }
            $tmo = if ($timeout -gt 0) { $timeout } else { 8 }
            $res = Walk-Uia $root $maxDepth 2500 $tmo
            $rows = $res.Rows
            if ($act -eq 'ui-find') {
                if ($name)   { $rows = $rows | Where-Object { $_.Name -like "*$name*" } }
                if ($filter) { $rows = $rows | Where-Object { $_.Type -like "*$filter*" } }
                $rows = $rows | Where-Object { -not $_.Off -and $_.Rect -ne '-' }
            }
            $max = if ($p.ContainsKey('Count')) { $count } else { 40 }
            $shown = @($rows | Select-Object -First $max)
            if ($shown.Count -eq 0) {
                Write-Output "no UIA match (name~'$name' type~'$filter', depth<=$maxDepth). Chromium/Electron trees are often empty — use screenshot + cursor-type instead."
            } else {
                $shown | Format-Table Depth, Type, Name, AutoId, Rect, Click, Enabled -AutoSize | Out-String -Width 240 | Write-Output
                Write-Output "Click = exact centre in absolute screen px; feed it straight to -Action click."
            }
            $extra = @($rows).Count - $shown.Count
            if ($extra -gt 0) { Write-Output "... $extra more (raise -Count, or narrow with -Name/-Filter)" }
            if ($res.Truncated) { Write-Output "WARNING: walk hit the node/time budget ($($res.Ms)ms) — results are partial; narrow with -Depth." }
        }

        'wait-window' {
            if (-not $winTitle -and -not $filter) { throw "wait-window needs -WindowTitle (and/or -Filter for the process name)" }
            $tmo = if ($timeout -gt 0) { $timeout } else { 15 }
            $sw = [Diagnostics.Stopwatch]::StartNew()
            while ($sw.Elapsed.TotalSeconds -lt $tmo) {
                $m = Find-Win $winTitle $filter
                if ($absent) { if ($m.Count -eq 0) { Write-Output "gone after $([int]$sw.Elapsed.TotalMilliseconds)ms"; return } }
                elseif ($m.Count -gt 0) {
                    Write-Output "appeared after $([int]$sw.Elapsed.TotalMilliseconds)ms"
                    $m | Format-Table Hwnd, Process, Title, Rect, State -AutoSize | Out-String -Width 260 | Write-Output
                    return
                }
                Start-Sleep -Milliseconds 300
            }
            throw "wait-window timed out after ${tmo}s (title='$winTitle' process='$filter' absent=$absent)"
        }

        # Wait until the pixels stop changing — the right way to wait for a menu to finish
        # animating, a page to render, or a build to stop scrolling. Never screenshot a moving
        # frame: you pay full vision tokens for a picture you have to retake.
        'wait-stable' {
            $rect = Resolve-CaptureRect $false
            $tmo  = if ($timeout -gt 0) { $timeout } else { 10 }
            $need = if ($p.ContainsKey('Count')) { [Math]::Max(2, $count) } else { 2 }
            $poll = if ($holdMs -gt 0) { $holdMs } else { 350 }
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $last = $null; $same = 1
            while ($sw.Elapsed.TotalSeconds -lt $tmo) {
                $hash = Get-RegionHash $rect
                if ($hash -eq $last) { $same++ ; if ($same -ge $need) { Write-Output "stable after $([int]$sw.Elapsed.TotalMilliseconds)ms ($need identical frames)"; return } }
                else { $same = 1; $last = $hash }
                Start-Sleep -Milliseconds $poll
            }
            Write-Output "NOT stable after ${tmo}s — the region is still animating (video/spinner/caret?). Proceeding is usually fine; a blinking caret alone never settles."
        }

        default { throw "Unknown action '$act'" }
    }
}

# ════════════════════════════════════════════════════════════════════════════════════════
#  batch: many steps, ONE process (a cold start costs ~2s of P/Invoke compilation)
# ════════════════════════════════════════════════════════════════════════════════════════
$VALID_KEYS = @('Action','X','Y','X2','Y2','W','H','Button','Modifiers','Count','Amount','Direction',
                'Text','Keys','Path','WindowTitle','Hwnd','Foreground','AllScreens','Region','Scale',
                'MaxWidth','Grid','NoFocus','Delay','Steps','HoldMs','NoRestoreClipboard','Filter',
                'Name','Mode','Depth','Scan','Timeout','Absent','Ms')
function Parse-BatchLine([string]$line) {
    # `action key=value key="value with spaces" flag text64=<base64-utf8>`
    $t = $line.Trim()
    if (-not $t -or $t.StartsWith('#')) { return $null }
    $m = [regex]::Match($t, '^([a-zA-Z][\w-]*)\s*(.*)$')
    if (-not $m.Success) { throw "Cannot parse batch line: $line" }
    $p = @{ Action = $m.Groups[1].Value.ToLower() }
    foreach ($tok in [regex]::Matches($m.Groups[2].Value, '([A-Za-z][\w]*)\s*=\s*(?:"([^"]*)"|''([^'']*)''|(\S+))|(?<bare>[A-Za-z][\w]*)')) {
        if ($tok.Groups['bare'].Success) { $p[$tok.Groups['bare'].Value] = $true; continue }
        $k = $tok.Groups[1].Value
        $v = if ($tok.Groups[2].Success) { $tok.Groups[2].Value }
             elseif ($tok.Groups[3].Success) { $tok.Groups[3].Value }
             else { $tok.Groups[4].Value }
        if ($k -match '^(.*)64$' -and $matches[1]) {          # text64=<base64> — escape hatch for
            $k = $matches[1]                                   # quotes/newlines inside a value
            $v = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($v))
        }
        $canon = $VALID_KEYS | Where-Object { $_ -ieq $k } | Select-Object -First 1
        if (-not $canon) { throw "Unknown parameter '$k' in batch line: $line" }
        $p[$canon] = $v
    }
    return $p
}

try {
    if ($Action -eq 'batch') {
        $src = if ($BatchFile) { Get-Content -Raw -LiteralPath $BatchFile } else { $Batch }
        if (-not $src) { throw "batch needs -Batch '<steps>' or -BatchFile <path>" }
        $lines = $src -split '\r?\n'
        $n = 0; $failed = 0
        foreach ($line in $lines) {
            $step = Parse-BatchLine $line
            if (-not $step) { continue }
            $n++
            $label = "[$n $($step.Action)]"
            try {
                if ($step.Action -eq 'sleep') {
                    $ms = PInt $step 'Ms' 300
                    Start-Sleep -Milliseconds $ms
                    Write-Output "$label slept ${ms}ms"
                } else {
                    $out = Invoke-Step $step
                    foreach ($o in @($out)) { Write-Output "$label $o" }
                }
            } catch {
                $failed++
                Write-Output "$label ERROR: $($_.Exception.Message)"
                if (-not $ContinueOnError) { Write-Output "batch aborted at step $n ($($n) of $(@($lines).Count) lines read); pass -ContinueOnError to push through"; exit 1 }
            }
        }
        Write-Output "batch done: $n steps, $failed failed"
        if ($failed -gt 0) { exit 1 }
    } else {
        # .psbase is required: PowerShell's dictionary adapter resolves `$PSBoundParameters.Keys`
        # to the VALUE of the bound parameter named -Keys, not to the key collection. Without
        # .psbase, every `-Keys ...` call silently loses all its parameters.
        $bag = @{}
        foreach ($k in @($PSBoundParameters.psbase.Keys)) { $bag[$k] = $PSBoundParameters[$k] }
        $bag['Action'] = $Action
        Invoke-Step $bag
    }
    exit 0
} catch {
    Write-Output "ERROR line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)"
    exit 1
}
