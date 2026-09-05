<#
.SYNOPSIS
    Quickly changes a display's resolution and/or scaling.

.DESCRIPTION
    Lists active displays or changes the selected display. By default, the primary
    display is selected. The setting is applied immediately and saved for the
    current Windows user.

.EXAMPLE
    .\set-display.ps1 -List

.EXAMPLE
    .\set-display.ps1 -Width 1920 -Height 1080 -Scale 125

.EXAMPLE
    .\set-display.ps1 -Display 2 -Scale 150
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch] $List,

    [ValidateRange(1, 32)]
    [int] $Display,

    [ValidateRange(320, 16384)]
    [int] $Width,

    [ValidateRange(200, 16384)]
    [int] $Height,

    [ValidateSet(100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500)]
    [int] $Scale
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'This script only supports Windows.'
}

if (($PSBoundParameters.ContainsKey('Width')) -xor $PSBoundParameters.ContainsKey('Height')) {
    throw 'Width and Height must be specified together.'
}

if (-not ('EasyPwsh.DisplaySettings' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Runtime.InteropServices;

namespace EasyPwsh
{
    public sealed class DisplayDetails
    {
        public int Index { get; set; }
        public string DeviceName { get; set; }
        public string Name { get; set; }
        public bool Primary { get; set; }
        public int Width { get; set; }
        public int Height { get; set; }
        public int RefreshRate { get; set; }
        public int Scale { get; set; }
        public string SupportedScales { get; set; }
    }

    public static class DisplaySettings
    {
        private const int ENUM_CURRENT_SETTINGS = -1;
        private const uint DISPLAY_DEVICE_ATTACHED_TO_DESKTOP = 0x1;
        private const uint DISPLAY_DEVICE_PRIMARY_DEVICE = 0x4;
        private const uint DM_PELSWIDTH = 0x80000;
        private const uint DM_PELSHEIGHT = 0x100000;
        private const uint CDS_UPDATEREGISTRY = 0x1;
        private const uint CDS_TEST = 0x2;
        private const int DISP_CHANGE_SUCCESSFUL = 0;
        private const uint QDC_ONLY_ACTIVE_PATHS = 0x2;
        private const int DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME = 1;
        private const int DISPLAYCONFIG_DEVICE_INFO_GET_DPI_SCALE = -3;
        private const int DISPLAYCONFIG_DEVICE_INFO_SET_DPI_SCALE = -4;
        private const int ERROR_INSUFFICIENT_BUFFER = 122;

        private static readonly int[] DpiValues =
            { 100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500 };

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct DISPLAY_DEVICE
        {
            public int cb;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
            public uint StateFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct DEVMODE
        {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
            public ushort dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
            public uint dmFields;
            public int dmPositionX, dmPositionY;
            public uint dmDisplayOrientation, dmDisplayFixedOutput;
            public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
            public ushort dmLogPixels;
            public uint dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
            public uint dmICMMethod, dmICMIntent, dmMediaType, dmDitherType;
            public uint dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct LUID { public uint LowPart; public int HighPart; }

        [StructLayout(LayoutKind.Sequential)]
        private struct DISPLAYCONFIG_RATIONAL { public uint Numerator, Denominator; }

        [StructLayout(LayoutKind.Sequential)]
        private struct DISPLAYCONFIG_PATH_SOURCE_INFO
        {
            public LUID adapterId;
            public uint id, modeInfoIdx, statusFlags;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct DISPLAYCONFIG_PATH_TARGET_INFO
        {
            public LUID adapterId;
            public uint id, modeInfoIdx, outputTechnology, rotation, scaling;
            public DISPLAYCONFIG_RATIONAL refreshRate;
            public uint scanLineOrdering;
            [MarshalAs(UnmanagedType.Bool)] public bool targetAvailable;
            public uint statusFlags;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct DISPLAYCONFIG_PATH_INFO
        {
            public DISPLAYCONFIG_PATH_SOURCE_INFO sourceInfo;
            public DISPLAYCONFIG_PATH_TARGET_INFO targetInfo;
            public uint flags;
        }

        // DISPLAYCONFIG_MODE_INFO is 64 bytes. Only its size is needed here.
        [StructLayout(LayoutKind.Sequential, Size = 64)]
        private struct DISPLAYCONFIG_MODE_INFO { public uint infoType, id; public LUID adapterId; }

        [StructLayout(LayoutKind.Sequential)]
        private struct DISPLAYCONFIG_DEVICE_INFO_HEADER
        {
            public int type;
            public uint size;
            public LUID adapterId;
            public uint id;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct DISPLAYCONFIG_SOURCE_DEVICE_NAME
        {
            public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string viewGdiDeviceName;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct DISPLAYCONFIG_SOURCE_DPI_SCALE_GET
        {
            public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
            public int minScaleRel, curScaleRel, maxScaleRel;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct DISPLAYCONFIG_SOURCE_DPI_SCALE_SET
        {
            public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
            public int scaleRel;
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern bool EnumDisplayDevices(string device, uint index, ref DISPLAY_DEVICE displayDevice, uint flags);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int ChangeDisplaySettingsEx(string deviceName, ref DEVMODE devMode, IntPtr hwnd, uint flags, IntPtr param);

        [DllImport("user32.dll")]
        private static extern int GetDisplayConfigBufferSizes(uint flags, out uint pathCount, out uint modeCount);

        [DllImport("user32.dll")]
        private static extern int QueryDisplayConfig(uint flags, ref uint pathCount,
            [Out] DISPLAYCONFIG_PATH_INFO[] paths, ref uint modeCount,
            [Out] DISPLAYCONFIG_MODE_INFO[] modes, IntPtr topologyId);

        [DllImport("user32.dll")]
        private static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_SOURCE_DEVICE_NAME requestPacket);

        [DllImport("user32.dll", EntryPoint = "DisplayConfigGetDeviceInfo")]
        private static extern int DisplayConfigGetDpiInfo(ref DISPLAYCONFIG_SOURCE_DPI_SCALE_GET requestPacket);

        [DllImport("user32.dll")]
        private static extern int DisplayConfigSetDeviceInfo(ref DISPLAYCONFIG_SOURCE_DPI_SCALE_SET setPacket);

        private static DEVMODE CurrentMode(string deviceName)
        {
            var mode = new DEVMODE();
            mode.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE));
            if (!EnumDisplaySettings(deviceName, ENUM_CURRENT_SETTINGS, ref mode))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to read settings for " + deviceName + ".");
            return mode;
        }

        private static List<DISPLAY_DEVICE> ActiveDevices()
        {
            var result = new List<DISPLAY_DEVICE>();
            for (uint i = 0; ; i++)
            {
                var device = new DISPLAY_DEVICE { cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE)) };
                if (!EnumDisplayDevices(null, i, ref device, 0)) break;
                if ((device.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) != 0) result.Add(device);
            }
            return result.OrderBy(d => d.DeviceName, StringComparer.OrdinalIgnoreCase).ToList();
        }

        private static Dictionary<string, DISPLAYCONFIG_PATH_SOURCE_INFO> ActiveSources()
        {
            for (int attempt = 0; attempt < 3; attempt++)
            {
                uint pathCount, modeCount;
                int error = GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, out pathCount, out modeCount);
                if (error != 0) throw new Win32Exception(error, "Unable to size the active display configuration.");
                var paths = new DISPLAYCONFIG_PATH_INFO[pathCount];
                var modes = new DISPLAYCONFIG_MODE_INFO[modeCount];
                error = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, ref pathCount, paths, ref modeCount, modes, IntPtr.Zero);
                if (error == ERROR_INSUFFICIENT_BUFFER) continue;
                if (error != 0) throw new Win32Exception(error, "Unable to query the active display configuration.");

                var result = new Dictionary<string, DISPLAYCONFIG_PATH_SOURCE_INFO>(StringComparer.OrdinalIgnoreCase);
                for (int i = 0; i < pathCount; i++)
                {
                    var source = paths[i].sourceInfo;
                    var name = new DISPLAYCONFIG_SOURCE_DEVICE_NAME();
                    name.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
                    name.header.size = (uint)Marshal.SizeOf(typeof(DISPLAYCONFIG_SOURCE_DEVICE_NAME));
                    name.header.adapterId = source.adapterId;
                    name.header.id = source.id;
                    if (DisplayConfigGetDeviceInfo(ref name) == 0 && !result.ContainsKey(name.viewGdiDeviceName))
                        result.Add(name.viewGdiDeviceName, source);
                }
                return result;
            }
            throw new InvalidOperationException("The display configuration changed repeatedly. Please try again.");
        }

        private static DISPLAYCONFIG_SOURCE_DPI_SCALE_GET GetDpiInfo(DISPLAYCONFIG_PATH_SOURCE_INFO source)
        {
            var dpi = new DISPLAYCONFIG_SOURCE_DPI_SCALE_GET();
            dpi.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_DPI_SCALE;
            dpi.header.size = (uint)Marshal.SizeOf(typeof(DISPLAYCONFIG_SOURCE_DPI_SCALE_GET));
            dpi.header.adapterId = source.adapterId;
            dpi.header.id = source.id;
            int error = DisplayConfigGetDpiInfo(ref dpi);
            if (error != 0) throw new Win32Exception(error, "Unable to read display scaling.");
            return dpi;
        }

        private static string[] ScaleInfo(string deviceName)
        {
            DISPLAYCONFIG_PATH_SOURCE_INFO source;
            if (!ActiveSources().TryGetValue(deviceName, out source)) return new[] { "Unknown", "Unknown" };
            var dpi = GetDpiInfo(source);
            int recommendedIndex = -dpi.minScaleRel;
            int currentIndex = recommendedIndex + dpi.curScaleRel;
            int minIndex = Math.Max(0, recommendedIndex + dpi.minScaleRel);
            int maxIndex = Math.Min(DpiValues.Length - 1, recommendedIndex + dpi.maxScaleRel);
            string current = currentIndex >= 0 && currentIndex < DpiValues.Length ? DpiValues[currentIndex].ToString() : "Unknown";
            string supported = String.Join(",", DpiValues.Skip(minIndex).Take(maxIndex - minIndex + 1));
            return new[] { current, supported };
        }

        public static DisplayDetails[] GetDisplays()
        {
            var devices = ActiveDevices();
            var result = new List<DisplayDetails>();
            for (int i = 0; i < devices.Count; i++)
            {
                var device = devices[i];
                var mode = CurrentMode(device.DeviceName);
                string[] dpi;
                try { dpi = ScaleInfo(device.DeviceName); }
                catch { dpi = new[] { "Unknown", "Unknown" }; }
                int scale;
                Int32.TryParse(dpi[0], out scale);
                result.Add(new DisplayDetails {
                    Index = i + 1,
                    DeviceName = device.DeviceName,
                    Name = device.DeviceString,
                    Primary = (device.StateFlags & DISPLAY_DEVICE_PRIMARY_DEVICE) != 0,
                    Width = (int)mode.dmPelsWidth,
                    Height = (int)mode.dmPelsHeight,
                    RefreshRate = (int)mode.dmDisplayFrequency,
                    Scale = scale,
                    SupportedScales = dpi[1]
                });
            }
            return result.ToArray();
        }

        public static DisplayDetails SelectDisplay(int index)
        {
            var displays = GetDisplays();
            if (index > 0)
            {
                var selected = displays.FirstOrDefault(d => d.Index == index);
                if (selected == null) throw new ArgumentOutOfRangeException("index", "No active display has index " + index + ".");
                return selected;
            }
            var primary = displays.FirstOrDefault(d => d.Primary);
            if (primary == null) throw new InvalidOperationException("No primary display was found.");
            return primary;
        }

        public static void SetResolution(string deviceName, int width, int height)
        {
            var mode = CurrentMode(deviceName);
            mode.dmPelsWidth = (uint)width;
            mode.dmPelsHeight = (uint)height;
            mode.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT;
            int result = ChangeDisplaySettingsEx(deviceName, ref mode, IntPtr.Zero, CDS_TEST, IntPtr.Zero);
            if (result != DISP_CHANGE_SUCCESSFUL)
                throw new InvalidOperationException("The display does not support " + width + "x" + height + " (code " + result + ").");
            result = ChangeDisplaySettingsEx(deviceName, ref mode, IntPtr.Zero, CDS_UPDATEREGISTRY, IntPtr.Zero);
            if (result != DISP_CHANGE_SUCCESSFUL)
                throw new InvalidOperationException("Windows could not apply the resolution (code " + result + ").");
        }

        public static void SetScale(string deviceName, int scale)
        {
            DISPLAYCONFIG_PATH_SOURCE_INFO source;
            if (!ActiveSources().TryGetValue(deviceName, out source))
                throw new InvalidOperationException("No active display path was found for " + deviceName + ".");
            var dpi = GetDpiInfo(source);
            int desiredIndex = Array.IndexOf(DpiValues, scale);
            int recommendedIndex = -dpi.minScaleRel;
            int scaleRel = desiredIndex - recommendedIndex;
            if (scaleRel < dpi.minScaleRel || scaleRel > dpi.maxScaleRel)
                throw new ArgumentOutOfRangeException("scale", scale + "% is not supported by this display.");

            var set = new DISPLAYCONFIG_SOURCE_DPI_SCALE_SET();
            set.header.type = DISPLAYCONFIG_DEVICE_INFO_SET_DPI_SCALE;
            set.header.size = (uint)Marshal.SizeOf(typeof(DISPLAYCONFIG_SOURCE_DPI_SCALE_SET));
            set.header.adapterId = source.adapterId;
            set.header.id = source.id;
            set.scaleRel = scaleRel;
            int error = DisplayConfigSetDeviceInfo(ref set);
            if (error != 0) throw new Win32Exception(error, "Windows could not apply the display scaling.");
        }
    }
}
'@
}

$hasResolution = $PSBoundParameters.ContainsKey('Width')
$hasScale = $PSBoundParameters.ContainsKey('Scale')

if ($List -or (-not $hasResolution -and -not $hasScale)) {
    [EasyPwsh.DisplaySettings]::GetDisplays() |
        Select-Object Index, Name, DeviceName, Primary,
            @{ Name = 'Resolution'; Expression = { '{0}x{1}' -f $_.Width, $_.Height } },
            RefreshRate,
            @{ Name = 'Scale'; Expression = { if ($_.Scale) { '{0}%' -f $_.Scale } else { 'Unknown' } } },
            SupportedScales
    return
}

$displayIndex = if ($PSBoundParameters.ContainsKey('Display')) { $Display } else { 0 }
$target = [EasyPwsh.DisplaySettings]::SelectDisplay($displayIndex)
$description = if ($target.Primary) { "display $($target.Index) (primary)" } else { "display $($target.Index)" }

if ($hasResolution -and $PSCmdlet.ShouldProcess($description, "Set resolution to ${Width}x${Height}")) {
    [EasyPwsh.DisplaySettings]::SetResolution($target.DeviceName, $Width, $Height)
}

if ($hasScale -and $PSCmdlet.ShouldProcess($description, "Set scaling to ${Scale}%")) {
    [EasyPwsh.DisplaySettings]::SetScale($target.DeviceName, $Scale)
}

[EasyPwsh.DisplaySettings]::SelectDisplay($target.Index) |
    Select-Object Index, Name, DeviceName, Primary,
        @{ Name = 'Resolution'; Expression = { '{0}x{1}' -f $_.Width, $_.Height } },
        RefreshRate,
        @{ Name = 'Scale'; Expression = { if ($_.Scale) { '{0}%' -f $_.Scale } else { 'Unknown' } } }
