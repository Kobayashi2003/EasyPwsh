# Compile the P/Invoke helpers once to a cached DLL. Re-running the C# compiler
# every shell costs ~450ms; loading a prebuilt DLL is ~10-50ms. The DLL name
# carries the source mtime: editing this file makes the next shell compile a
# fresh build even while running shells keep the previous one loaded and locked.
$__winapiDir = Join-Path $global:CURRENT_SCRIPT_DIRECTORY 'downloads\cache'
$__winapiDll = Join-Path $__winapiDir ('WinAPI-{0:x}.dll' -f (Get-Item $PSCommandPath).LastWriteTimeUtc.Ticks)

if (-not ('WinApi' -as [type])) {
    if (-not (Test-Path $__winapiDll)) {
        if (-not (Test-Path $__winapiDir)) { New-Item -ItemType Directory -Force -Path $__winapiDir | Out-Null }
        Add-Type -TypeDefinition @'
    using System;
    using System.Runtime.InteropServices;

    public struct RECT{
        public uint left;
        public uint top;
        public uint right;
        public uint bottom;
    }

    public struct POINT {
        public int X;
        public int Y;
    }

    public static class WinApi {
        [DllImport("user32.dll")]
        public static extern bool SetWindowPos(uint hWnd,uint hAfter,uint x,uint y,uint cx,uint cy,uint flags);

        [DllImport("kernel32.dll")]
        public static extern uint GetConsoleWindow();

        [DllImport("user32.dll")]
        public static extern bool GetWindowRect(uint hwnd, ref RECT rect);

        [DllImport("user32.dll")]
        public static extern uint GetDC(uint hwnd);

        [DllImport("gdi32.dll")]
        public static extern uint GetDeviceCaps(uint hdc, int index);

        [DllImport("user32.dll", SetLastError=true)]
        public static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll", SetLastError=true)]
        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll", SetLastError=true)]
        public static extern bool IsIconic(IntPtr hWnd);    // Is the window minimized?

        [DllImport("user32.dll", CharSet=CharSet.Auto, ExactSpelling=true)]
        public static extern short GetAsyncKeyState(int vkey);

        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern IntPtr GetStdHandle(int nStdHandle);

        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);

        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEY_EVENT_RECORD {
        public int bKeyDown;
        public ushort wRepeatCount;
        public ushort wVirtualKeyCode;
        public ushort wVirtualScanCode;
        public char UnicodeChar;
        public uint dwControlKeyState;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct INPUT_RECORD {
        [FieldOffset(0)] public ushort EventType;
        [FieldOffset(4)] public KEY_EVENT_RECORD KeyEvent;
    }

    // Windows Terminal reports a click as a VT sequence, which reaches the app as
    // ordinary characters. System.Console's input layer will not hand those over
    // while it is waiting for a keystroke, so read the input queue directly.
    public static class ConsoleInput {
        const ushort KEY_EVENT = 1;

        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool GetNumberOfConsoleInputEvents(IntPtr hConsoleInput, out uint lpcNumberOfEvents);

        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern bool ReadConsoleInput(IntPtr hConsoleInput, out INPUT_RECORD lpBuffer,
                                            uint nLength, out uint lpNumberOfEventsRead);

        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern bool PeekConsoleInput(IntPtr hConsoleInput, out INPUT_RECORD lpBuffer,
                                            uint nLength, out uint lpNumberOfEventsRead);

        // Next character, LEFT IN THE QUEUE. Returns -1 when nothing is waiting,
        // and 0 for a key that carries no character (an arrow, a function key).
        //
        // Peek first, take second: a reader that consumes before it knows whose
        // character it is eats the keystroke the user meant for the line editor.
        // Records that are not key presses are dropped here, or they would sit at
        // the head of the queue for ever.
        public static int PeekChar(IntPtr handle) {
            while (true) {
                uint pending;
                if (!GetNumberOfConsoleInputEvents(handle, out pending) || pending == 0) {
                    return -1;
                }

                INPUT_RECORD record;
                uint seen;
                if (!PeekConsoleInput(handle, out record, 1, out seen) || seen == 0) {
                    return -1;
                }

                if (record.EventType == KEY_EVENT && record.KeyEvent.bKeyDown != 0) {
                    return record.KeyEvent.UnicodeChar;
                }

                uint read;
                ReadConsoleInput(handle, out record, 1, out read);
            }
        }

        // Take the character PeekChar just showed you.
        public static void Consume(IntPtr handle) {
            INPUT_RECORD record;
            uint read;
            ReadConsoleInput(handle, out record, 1, out read);
        }
    }

    public static class KeyboardSimulator {
        [DllImport("user32.dll")]
        private static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

        [DllImport("user32.dll", CharSet = CharSet.Auto, ExactSpelling = true, CallingConvention = CallingConvention.Winapi)]
        public static extern short GetKeyState(int keyCode);

        private const int KEYEVENTF_EXTENDEDKEY = 0x1;
        private const int KEYEVENTF_KEYUP = 0x2;
        public const byte VK_CAPITAL = 0x14;
        public const byte VK_NUMLOCK = 0x90;
        public const byte VK_INSERT = 0x2D;

        public static void ToggleKey(byte keyCode)
        {
            keybd_event(keyCode, 0x45, KEYEVENTF_EXTENDEDKEY, UIntPtr.Zero);
            keybd_event(keyCode, 0x45, KEYEVENTF_EXTENDEDKEY | KEYEVENTF_KEYUP, UIntPtr.Zero);
        }

        public static bool IsKeyToggled(byte keyCode)
        {
            return (((ushort)GetKeyState(keyCode)) & 0xffff) != 0;
        }
    }

    public static class MouseSimulator {
        [DllImport("user32.dll")]
        public static extern bool GetCursorPos(out POINT lpPoint);

        [DllImport("user32.dll")]
        public static extern bool SetCursorPos(int X, int Y);

        [DllImport("user32.dll")]
        public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);

        public const int MOUSEEVENTF_LEFTDOWN = 0x0002;
        public const int MOUSEEVENTF_LEFTUP = 0x0004;
        public const int MOUSEEVENTF_RIGHTDOWN = 0x0008;
        public const int MOUSEEVENTF_RIGHTUP = 0x0010;
        public const int MOUSEEVENTF_MIDDLEDOWN = 0x0020;
        public const int MOUSEEVENTF_MIDDLEUP = 0x0040;
        public const int MOUSEEVENTF_WHEEL = 0x0800;

        public static POINT GetMousePosition()
        {
            POINT point;
            GetCursorPos(out point);
            return point;
        }

        public static void SetMousePosition(int x, int y)
        {
            SetCursorPos(x, y);
        }

        public static void MouseClick(int button)
        {
            POINT position = GetMousePosition();
            switch (button)
            {
                case 0: // Left click
                    mouse_event(MOUSEEVENTF_LEFTDOWN | MOUSEEVENTF_LEFTUP, (uint)position.X, (uint)position.Y, 0, UIntPtr.Zero);
                    break;
                case 1: // Middle click
                    mouse_event(MOUSEEVENTF_MIDDLEDOWN | MOUSEEVENTF_MIDDLEUP, (uint)position.X, (uint)position.Y, 0, UIntPtr.Zero);
                    break;
                case 2: // Right click
                    mouse_event(MOUSEEVENTF_RIGHTDOWN | MOUSEEVENTF_RIGHTUP, (uint)position.X, (uint)position.Y, 0, UIntPtr.Zero);
                    break;
            }
        }

        public static void MouseDrag(int button, int startX, int startY, int endX, int endY, int steps)
        {
            // Move to start position
            SetCursorPos(startX, startY);

            // Press the mouse button
            switch (button)
            {
                case 0: // Left
                    mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, UIntPtr.Zero);
                    break;
                case 1: // Middle
                    mouse_event(MOUSEEVENTF_MIDDLEDOWN, 0, 0, 0, UIntPtr.Zero);
                    break;
                case 2: // Right
                    mouse_event(MOUSEEVENTF_RIGHTDOWN, 0, 0, 0, UIntPtr.Zero);
                    break;
            }

            // Calculate step size
            int stepX = (endX - startX) / steps;
            int stepY = (endY - startY) / steps;

            // Move in steps
            for (int i = 0; i < steps; i++)
            {
                int currentX = startX + stepX * i;
                int currentY = startY + stepY * i;
                SetCursorPos(currentX, currentY);
                System.Threading.Thread.Sleep(10); // Small delay for smoother movement
            }

            // Ensure we reach the exact end position
            SetCursorPos(endX, endY);

            // Release the mouse button
            switch (button)
            {
                case 0: // Left
                    mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, UIntPtr.Zero);
                    break;
                case 1: // Middle
                    mouse_event(MOUSEEVENTF_MIDDLEUP, 0, 0, 0, UIntPtr.Zero);
                    break;
                case 2: // Right
                    mouse_event(MOUSEEVENTF_RIGHTUP, 0, 0, 0, UIntPtr.Zero);
                    break;
            }
        }

        public static void ScrollWheel(int amount)
        {
            mouse_event(MOUSEEVENTF_WHEEL, 0, 0, (uint)amount, UIntPtr.Zero);
        }
    }
'@ -OutputAssembly $__winapiDll
        # Drop superseded builds; ones still locked by older shells stay until later.
        Get-ChildItem (Join-Path $__winapiDir 'WinAPI*.dll') |
            Where-Object { $_.FullName -ne $__winapiDll } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    Add-Type -Path $__winapiDll
}
