<#
.SYNOPSIS
    Chill Mode - one-panel battery optimizer for Windows 10/11 laptops.

.DESCRIPTION
    Shows every battery-related setting (power mode, CPU limits, iGPU vs dGPU,
    refresh rate, brightness, browser efficiency, wireless power saving, sleep
    timers, background activity) in one window with toggles, drop-downs, radio
    buttons and sliders. Includes one-click presets and an automatic backup so
    every change can be undone with "Restore original".

    Power-plan values are written to the *On battery* (DC) side of the active
    power plan only, so plugged-in performance is not affected.

.PARAMETER Preset
    Apply a preset without opening the window: MaxBattery or Balanced.

.PARAMETER Restore
    Restore the values that were backed up before Chill Mode first changed them.

.EXAMPLE
    .\ChillMode.ps1                      # open the panel
    .\ChillMode.ps1 -Preset MaxBattery   # one-click from a shortcut / task
    .\ChillMode.ps1 -Restore             # undo everything
#>
[CmdletBinding()]
param(
    [ValidateSet('MaxBattery', 'Balanced')]
    [string]$Preset,
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'
$script:AppName    = 'Chill Mode'
$script:AppVersion = '1.1.2'
$script:CliMode    = [bool]($Preset -or $Restore)
$script:ScriptPath = $PSCommandPath

# ---------------------------------------------------------------------------
# Elevation + STA (WPF needs a single-threaded apartment)
# ---------------------------------------------------------------------------
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$isSta     = [Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA'

if (-not $isAdmin -or (-not $script:CliMode -and -not $isSta)) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA')
    if (-not $script:CliMode) { $argList += @('-WindowStyle', 'Hidden') }
    $argList += @('-File', "`"$PSCommandPath`"")
    if ($Preset)  { $argList += @('-Preset', $Preset) }
    if ($Restore) { $argList += '-Restore' }
    $exe = (Get-Process -Id $PID).Path
    try {
        if ($isAdmin) { Start-Process -FilePath $exe -ArgumentList $argList }
        else          { Start-Process -FilePath $exe -ArgumentList $argList -Verb RunAs }
    } catch {
        Write-Warning "$($script:AppName) needs administrator rights to change power and policy settings."
    }
    exit
}

# ---------------------------------------------------------------------------
# Native helpers (power plan API, display modes, system parameters)
# ---------------------------------------------------------------------------
$nativeSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

[ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IChillPropertyStore
{
    [PreserveSig] int GetCount(out uint count);
    [PreserveSig] int GetAt(uint index, out ChillPropertyKey key);
    [PreserveSig] int GetValue(ref ChillPropertyKey key, out ChillPropVariant value);
    [PreserveSig] int SetValue(ref ChillPropertyKey key, ref ChillPropVariant value);
    [PreserveSig] int Commit();
}

[StructLayout(LayoutKind.Sequential, Pack = 4)]
public struct ChillPropertyKey
{
    public Guid fmtid;
    public uint pid;
    public ChillPropertyKey(Guid f, uint p) { fmtid = f; pid = p; }
}

[StructLayout(LayoutKind.Explicit)]
public struct ChillPropVariant
{
    [FieldOffset(0)] public ushort vt;
    [FieldOffset(8)] public IntPtr pointer;
    [FieldOffset(8)] public long padding1;
    [FieldOffset(16)] public long padding2;
}

public static class ChillNative
{
    [DllImport("powrprof.dll")] private static extern uint PowerGetActiveScheme(IntPtr root, out IntPtr guid);
    [DllImport("powrprof.dll")] private static extern uint PowerSetActiveScheme(IntPtr root, ref Guid scheme);
    [DllImport("powrprof.dll")] private static extern uint PowerReadDCValueIndex(IntPtr root, ref Guid scheme, ref Guid sub, ref Guid setting, out uint value);
    [DllImport("powrprof.dll")] private static extern uint PowerWriteDCValueIndex(IntPtr root, ref Guid scheme, ref Guid sub, ref Guid setting, uint value);
    [DllImport("powrprof.dll", EntryPoint = "PowerSetActiveOverlayScheme")] private static extern uint NativeSetOverlay(Guid overlay);
    [DllImport("powrprof.dll", EntryPoint = "PowerGetEffectiveOverlayScheme")] private static extern uint NativeGetOverlay(out Guid overlay);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr mem);
    [DllImport("kernel32.dll")] private static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS status);
    [DllImport("kernel32.dll")] private static extern IntPtr GetConsoleWindow();
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] private static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
    [DllImport("shell32.dll")] private static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid iid, [Out, MarshalAs(UnmanagedType.Interface)] out IChillPropertyStore store);
    [DllImport("ole32.dll")] private static extern int PropVariantClear(ref ChillPropVariant pv);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hwnd, int cmd);
    [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW")] private static extern bool SpiGetBool(uint action, uint uiParam, ref int pvParam, uint winIni);
    [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW")] private static extern bool SpiSet(uint action, uint uiParam, IntPtr pvParam, uint winIni);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint msg, UIntPtr wParam, string lParam, uint flags, uint timeout, out UIntPtr result);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool EnumDisplaySettingsW(string device, int modeNum, ref DEVMODE mode);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int ChangeDisplaySettingsExW(string device, ref DEVMODE mode, IntPtr hwnd, uint flags, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct SYSTEM_POWER_STATUS
    {
        public byte ACLineStatus;
        public byte BatteryFlag;
        public byte BatteryLifePercent;
        public byte SystemStatusFlag;
        public int BatteryLifeTime;
        public int BatteryFullLifeTime;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DEVMODE
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion;
        public short dmDriverVersion;
        public short dmSize;
        public short dmDriverExtra;
        public int dmFields;
        public int dmPositionX;
        public int dmPositionY;
        public int dmDisplayOrientation;
        public int dmDisplayFixedOutput;
        public short dmColor;
        public short dmDuplex;
        public short dmYResolution;
        public short dmTTOption;
        public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel;
        public int dmPelsWidth;
        public int dmPelsHeight;
        public int dmDisplayFlags;
        public int dmDisplayFrequency;
        public int dmICMMethod;
        public int dmICMIntent;
        public int dmMediaType;
        public int dmDitherType;
        public int dmReserved1;
        public int dmReserved2;
        public int dmPanningWidth;
        public int dmPanningHeight;
    }

    private const int ENUM_CURRENT_SETTINGS = -1;
    private const int DM_BITSPERPEL = 0x40000;
    private const int DM_PELSWIDTH = 0x80000;
    private const int DM_PELSHEIGHT = 0x100000;
    private const int DM_DISPLAYFREQUENCY = 0x400000;
    private const uint CDS_UPDATEREGISTRY = 0x01;
    private const uint CDS_TEST = 0x02;

    // ---------------- power plan ----------------
    public static Guid ActiveScheme()
    {
        IntPtr p;
        if (PowerGetActiveScheme(IntPtr.Zero, out p) != 0) throw new InvalidOperationException("PowerGetActiveScheme failed");
        try { return (Guid)Marshal.PtrToStructure(p, typeof(Guid)); }
        finally { LocalFree(p); }
    }

    public static string ActiveSchemeId() { return ActiveScheme().ToString(); }

    public static long ReadDC(string sub, string setting)
    {
        Guid scheme = ActiveScheme();
        Guid s = new Guid(sub);
        Guid g = new Guid(setting);
        uint v;
        uint rc = PowerReadDCValueIndex(IntPtr.Zero, ref scheme, ref s, ref g, out v);
        if (rc != 0) return -1;
        return v;
    }

    public static bool WriteDC(string sub, string setting, uint value)
    {
        Guid scheme = ActiveScheme();
        Guid s = new Guid(sub);
        Guid g = new Guid(setting);
        return PowerWriteDCValueIndex(IntPtr.Zero, ref scheme, ref s, ref g, value) == 0;
    }

    public static void ReapplyScheme()
    {
        Guid scheme = ActiveScheme();
        PowerSetActiveScheme(IntPtr.Zero, ref scheme);
    }

    public static string GetOverlay()
    {
        try { Guid g; if (NativeGetOverlay(out g) == 0) return g.ToString(); }
        catch (EntryPointNotFoundException) { }
        return "";
    }

    public static bool SetOverlay(string guid)
    {
        try { return NativeSetOverlay(new Guid(guid)) == 0; }
        catch (EntryPointNotFoundException) { return false; }
    }

    // ---------------- battery ----------------
    public static int ACLine()      { SYSTEM_POWER_STATUS s; GetSystemPowerStatus(out s); return s.ACLineStatus; }
    public static int BatteryPct()  { SYSTEM_POWER_STATUS s; GetSystemPowerStatus(out s); return s.BatteryLifePercent; }
    public static int BatteryFlag() { SYSTEM_POWER_STATUS s; GetSystemPowerStatus(out s); return s.BatteryFlag; }
    public static int BatteryMinutes()
    {
        SYSTEM_POWER_STATUS s; GetSystemPowerStatus(out s);
        return s.BatteryLifeTime < 0 ? -1 : s.BatteryLifeTime / 60;
    }

    // ---------------- taskbar identity ----------------
    // Gives the app its own taskbar button + icon instead of grouping under powershell.exe.
    public static void SetProcessAppId(string appId)
    {
        SetCurrentProcessExplicitAppUserModelID(appId);
    }

    private static readonly Guid AppUserModelFmtId = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");

    private static void SetStringProp(IChillPropertyStore store, uint pid, string value)
    {
        ChillPropertyKey key = new ChillPropertyKey(AppUserModelFmtId, pid);
        ChillPropVariant pv = new ChillPropVariant();
        pv.vt = 31; // VT_LPWSTR
        pv.pointer = Marshal.StringToCoTaskMemUni(value);
        try { store.SetValue(ref key, ref pv); }
        finally { PropVariantClear(ref pv); }
    }

    // Window-level AppUserModel properties so a pinned taskbar button relaunches Chill Mode with its icon.
    public static void SetWindowAppProps(IntPtr hwnd, string appId, string relaunchCommand, string iconResource, string displayName)
    {
        Guid iid = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
        IChillPropertyStore store;
        if (SHGetPropertyStoreForWindow(hwnd, ref iid, out store) != 0 || store == null) return;
        try
        {
            SetStringProp(store, 5, appId);              // System.AppUserModel.ID
            SetStringProp(store, 2, relaunchCommand);    // RelaunchCommand
            SetStringProp(store, 3, iconResource);       // RelaunchIconResource
            SetStringProp(store, 4, displayName);        // RelaunchDisplayNameResource
            store.Commit();
        }
        finally { Marshal.ReleaseComObject(store); }
    }

    // ---------------- misc ----------------
    public static void HideConsole()
    {
        IntPtr h = GetConsoleWindow();
        if (h != IntPtr.Zero) ShowWindow(h, 0);
    }

    public static bool GetClientAnimation()
    {
        int v = 1;
        SpiGetBool(0x1042, 0, ref v, 0);
        return v != 0;
    }

    public static bool SetClientAnimation(bool on)
    {
        return SpiSet(0x1043, 0, new IntPtr(on ? 1 : 0), 0x01 | 0x02);
    }

    public static void BroadcastSettingChange(string area)
    {
        UIntPtr r;
        SendMessageTimeout(new IntPtr(0xffff), 0x001A, UIntPtr.Zero, area, 0x0002, 1000, out r);
    }

    // ---------------- display (primary) ----------------
    private static DEVMODE NewMode()
    {
        DEVMODE dm = new DEVMODE();
        dm.dmDeviceName = new string('\0', 32);
        dm.dmFormName = new string('\0', 32);
        dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        return dm;
    }

    private static DEVMODE Current()
    {
        DEVMODE dm = NewMode();
        if (!EnumDisplaySettingsW(null, ENUM_CURRENT_SETTINGS, ref dm)) throw new InvalidOperationException("EnumDisplaySettings failed");
        return dm;
    }

    public static int CurrentRefresh() { return Current().dmDisplayFrequency; }

    public static string CurrentModeText()
    {
        DEVMODE c = Current();
        return c.dmPelsWidth + "x" + c.dmPelsHeight + " @ " + c.dmDisplayFrequency + " Hz";
    }

    public static int[] RefreshRates()
    {
        DEVMODE c = Current();
        List<int> rates = new List<int>();
        DEVMODE dm = NewMode();
        for (int i = 0; EnumDisplaySettingsW(null, i, ref dm); i++)
        {
            if (dm.dmPelsWidth == c.dmPelsWidth && dm.dmPelsHeight == c.dmPelsHeight &&
                dm.dmBitsPerPel == c.dmBitsPerPel && dm.dmDisplayFrequency > 1 &&
                !rates.Contains(dm.dmDisplayFrequency))
            {
                rates.Add(dm.dmDisplayFrequency);
            }
            dm = NewMode();
        }
        if (!rates.Contains(c.dmDisplayFrequency)) rates.Add(c.dmDisplayFrequency);
        rates.Sort();
        return rates.ToArray();
    }

    // 0 = OK, 1 = restart required, negative = failure (see ChangeDisplaySettingsEx docs)
    public static int SetRefresh(int hz)
    {
        DEVMODE dm = Current();
        dm.dmDisplayFrequency = hz;
        dm.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT | DM_BITSPERPEL | DM_DISPLAYFREQUENCY;
        int test = ChangeDisplaySettingsExW(null, ref dm, IntPtr.Zero, CDS_TEST, IntPtr.Zero);
        if (test != 0) return test;
        return ChangeDisplaySettingsExW(null, ref dm, IntPtr.Zero, CDS_UPDATEREGISTRY, IntPtr.Zero);
    }
}
'@
if (-not ('ChillNative' -as [type])) { Add-Type -TypeDefinition $nativeSource -Language CSharp }

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$G = @{
    SUB_PROCESSOR   = '54533251-82be-4824-96c1-47b60b740d00'
    PROCTHROTTLEMAX = 'bc5038f7-23e0-4960-96da-33abaf5935ec'
    PERFBOOSTMODE   = 'be337238-0d82-4146-a960-4f3749d470c7'
    PERFEPP         = '36687f9e-e3a5-4dbf-b1dc-15eb381c6863'
    SYSCOOLPOL      = '94d3a615-a899-4ac5-ae2b-e4d8f634367f'

    SUB_ENERGYSAVER = 'de830923-a562-41af-a086-e3a2c6bad2da'
    ESBATTTHRESHOLD = 'e69653ca-cf7f-4f05-aa73-cb833fa90ad4'
    ESBRIGHTNESS    = '13d09884-f74e-474a-a852-b6bde8ad03a8'

    SUB_VIDEO        = '7516b95f-f776-4464-8c53-06167f40cc99'
    VIDEOIDLE        = '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'
    VIDEONORMALLEVEL = 'aded5e82-b909-4619-9949-f5d71dac0bcb'
    VIDEODIM         = '17aaa29b-8b43-4b94-aafe-35f64daaf1ee'
    VIDEODIMLEVEL    = 'f1fbfde2-a960-4165-9f88-50667911ce96'
    ADAPTBRIGHT      = 'fbd9aa66-9553-4097-ba44-ed6e9d65eab8'

    SUB_MULTIMEDIA   = '9596fb26-9850-41fd-ac3e-f7c3c00afd4b'
    VIDEOPLAYBACK    = '34c7b99f-9a6d-4b3c-8dc7-b6693b78cef4'
    VIDEOQUALITYBIAS = '10778347-1370-4ee0-8bbd-33bdacaade49'

    SUB_SLEEP     = '238c9fa8-0aad-41ed-83f4-97be242c8f20'
    STANDBYIDLE   = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'
    HIBERNATEIDLE = '9d7815a6-7ee4-497e-8888-515a05f02364'

    SUB_BUTTONS = '4f971e89-eebd-4455-a8de-9e59040e7347'
    LIDACTION   = '5ca83367-6e45-459f-a27b-476b1d01c936'

    SUB_WIFI   = '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'
    WIFIPOWER  = '12bbebe6-58d6-4636-95bb-3217ef867c1a'
    SUB_PCIE   = '501a4d13-42af-4429-9fd1-a8218c268e20'
    ASPM       = 'ee12f906-d277-404b-b6da-e5fa1a576df5'
    SUB_USB    = '2a737441-1930-4402-8d77-b2bebba308a3'
    USBSUSPEND = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
    SUB_DISK   = '0012ee47-9041-4b5d-9b77-535fba8b1442'
    DISKIDLE   = '6738e2c4-e8a5-4a42-b16a-e040e769756e'

    SUB_INTELGFX = '44f3beca-a7c0-460e-9df2-bb8b99e0cba6'
    INTELGFXPLAN = '3619c3f2-afb2-4afc-b0e9-e7fef372de36'
    SUB_SWITCHGFX = 'e276e160-7cb0-43c6-b20b-73f5dce39954'
    SWITCHGFX     = 'a1662ab2-9d34-4e53-ba8b-2639b9e20857'
}

$Overlay = @{
    Efficiency    = '961cc777-2547-4f9d-8174-7d86181b8a7a'
    BetterBattery = '3af9b8d9-7c97-431d-ad78-34a8bfea439f'
    Balanced      = '00000000-0000-0000-0000-000000000000'
    Performance   = 'ded574b5-45a0-4f42-8737-46345c09c238'
}
$PowerSchemesKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes'
$GpuPrefKey      = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
$PersonalizeKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'

$DataDir    = Join-Path $env:LOCALAPPDATA 'ChillMode'
$BackupFile = Join-Path $DataDir 'backup.json'
$UNSET      = '__unset'

$Sections = [ordered]@{
    power        = @('Power & Processor',            'How hard the CPU is allowed to work while unplugged.')
    graphics     = @('Graphics - Leverage the iGPU', 'Keep the power-hungry dedicated GPU asleep; run everyday apps on the integrated GPU.')
    display      = @('Display & Panel',              'The screen is usually the biggest battery drain. Refresh rate, brightness, dimming and effects.')
    browser      = @('Browser Efficiency',           'Tame hardware acceleration, sleep idle tabs and stop browsers running after you close them.')
    sleep        = @('Sleep & Timeouts',             'How quickly the screen turns off and the laptop sleeps on battery.')
    connectivity = @('Wireless & Devices',           'Power saving for Wi-Fi, PCIe links, USB, disks and Bluetooth.')
    system       = @('Background & System',          'Stop background work that wakes the CPU.')
}

# ---------------------------------------------------------------------------
# Item model
# ---------------------------------------------------------------------------
$script:Items = New-Object System.Collections.ArrayList

function O([string]$Value, [string]$Label) { [pscustomobject]@{ Value = $Value; Label = $Label } }

function TimeOpts([int[]]$Seconds) { foreach ($s in $Seconds) { O "$s" (Format-Secs $s) } }

function Format-Secs([int]$s) {
    if ($s -eq 0)    { return 'Never' }
    if ($s -lt 60)   { return "$s sec" }
    if ($s -lt 3600) { return "$([math]::Round($s / 60, 1)) min" }
    return "$([math]::Round($s / 3600, 1)) hr"
}

function Add-Item([hashtable]$h) {
    $defaults = @{
        Type = 'Choice'; Options = @(); Presets = @{}; Desc = ''; Format = ''
        OnValue = '1'; OffValue = '0'; Min = 0; Max = 100; Unit = '%'
        AbsentAs = $UNSET; Names = @(); Path = ''; Sub = ''; Setting = ''; Exe = ''
        Available = $true; Current = $null; Pending = $null; Ui = $null; Broadcast = ''
    }
    foreach ($k in $defaults.Keys) { if (-not $h.ContainsKey($k)) { $h[$k] = $defaults[$k] } }
    $item = [pscustomobject]$h
    [void]$script:Items.Add($item)
    return $item
}

function Find-Item([string]$Id) {
    foreach ($i in $script:Items) { if ($i.Id -eq $Id) { return $i } }
    return $null
}

# --- app discovery --------------------------------------------------------
function Find-Exe([string[]]$Candidates) {
    foreach ($c in $Candidates) {
        if (-not $c) { continue }
        $hit = Get-Item -Path $c -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

$pf   = $env:ProgramFiles
$pf86 = ${env:ProgramFiles(x86)}
$la   = $env:LOCALAPPDATA
$ra   = $env:APPDATA

$KnownApps = [ordered]@{
    'Google Chrome'   = @("$pf\Google\Chrome\Application\chrome.exe", "$pf86\Google\Chrome\Application\chrome.exe", "$la\Google\Chrome\Application\chrome.exe")
    'Microsoft Edge'  = @("$pf86\Microsoft\Edge\Application\msedge.exe", "$pf\Microsoft\Edge\Application\msedge.exe")
    'Mozilla Firefox' = @("$pf\Mozilla Firefox\firefox.exe", "$pf86\Mozilla Firefox\firefox.exe")
    'Brave'           = @("$pf\BraveSoftware\Brave-Browser\Application\brave.exe", "$la\BraveSoftware\Brave-Browser\Application\brave.exe")
    'Opera'           = @("$la\Programs\Opera\opera.exe")
    'Vivaldi'         = @("$la\Vivaldi\Application\vivaldi.exe", "$pf\Vivaldi\Application\vivaldi.exe")
    'Discord'         = @("$la\Discord\app-*\Discord.exe")
    'Slack'           = @("$la\slack\app-*\slack.exe")
    'Spotify'         = @("$ra\Spotify\Spotify.exe")
    'Zoom'            = @("$ra\Zoom\bin\Zoom.exe")
    'Microsoft Teams (classic)' = @("$la\Microsoft\Teams\current\Teams.exe")
    'VS Code'         = @("$la\Programs\Microsoft VS Code\Code.exe", "$pf\Microsoft VS Code\Code.exe")
    'Outlook'         = @("$pf\Microsoft Office\root\Office16\OUTLOOK.EXE", "$pf86\Microsoft Office\root\Office16\OUTLOOK.EXE")
    'Word'            = @("$pf\Microsoft Office\root\Office16\WINWORD.EXE", "$pf86\Microsoft Office\root\Office16\WINWORD.EXE")
    'Excel'           = @("$pf\Microsoft Office\root\Office16\EXCEL.EXE", "$pf86\Microsoft Office\root\Office16\EXCEL.EXE")
    'PowerPoint'      = @("$pf\Microsoft Office\root\Office16\POWERPNT.EXE", "$pf86\Microsoft Office\root\Office16\POWERPNT.EXE")
}

$script:Installed = @{}
foreach ($name in $KnownApps.Keys) {
    $exe = Find-Exe $KnownApps[$name]
    if ($exe) { $script:Installed[$name] = $exe }
}

function Get-AppLabel([string]$Path) {
    foreach ($k in $script:Installed.Keys) { if ($script:Installed[$k] -ieq $Path) { return $k } }
    try {
        $d = (Get-Item -LiteralPath $Path).VersionInfo.FileDescription
        if ($d) { return $d.Trim() }
    } catch { }
    return [IO.Path]::GetFileNameWithoutExtension($Path)
}

function New-GpuItem([string]$Path) {
    $id = "gpu|$($Path.ToLower())"
    $existing = Find-Item $id
    if ($existing) { return $existing }
    Add-Item @{
        Id = $id; Section = 'graphics'; Kind = 'GpuPref'; Exe = $Path; Type = 'Choice'
        Title = Get-AppLabel $Path
        Desc  = $Path
        Options = @((O $UNSET 'Let Windows decide'), (O '1' 'Power saving (iGPU)'), (O '2' 'High performance (dGPU)'))
        Presets = @{ MaxBattery = '1'; Balanced = '1' }
    }
}

# ---------------------------------------------------------------------------
# Setting catalogue
# ---------------------------------------------------------------------------
function Initialize-Items {
    $script:Items.Clear()

    # ===== Power & Processor =====
    Add-Item @{ Id = 'overlay'; Section = 'power'; Kind = 'Overlay'; Type = 'Radio'
        Title = 'Power mode on battery'
        Desc  = 'The Windows power mode used while unplugged (Settings > System > Power & battery).'
        Options = @((O $Overlay.Efficiency 'Best power efficiency'), (O $Overlay.Balanced 'Balanced'), (O $Overlay.Performance 'Best performance'))
        Presets = @{ MaxBattery = $Overlay.Efficiency; Balanced = $Overlay.Balanced } } | Out-Null

    Add-Item @{ Id = 'cpu.boost'; Section = 'power'; Kind = 'Power'; Sub = $G.SUB_PROCESSOR; Setting = $G.PERFBOOSTMODE
        Title = 'Turbo boost on battery'
        Desc  = 'Turbo bursts burn a lot of power for short gains. Disabling it is one of the biggest CPU savings.'
        Options = @((O 0 'Disabled'), (O 1 'Enabled'), (O 2 'Aggressive'), (O 3 'Efficient enabled'), (O 4 'Efficient aggressive'))
        Presets = @{ MaxBattery = '0'; Balanced = '3' } } | Out-Null

    Add-Item @{ Id = 'cpu.max'; Section = 'power'; Kind = 'Power'; Sub = $G.SUB_PROCESSOR; Setting = $G.PROCTHROTTLEMAX
        Title = 'Maximum processor state on battery'
        Desc  = 'Caps CPU speed. 99% also blocks turbo on most Intel/AMD chips.'
        Options = @((O 100 '100%'), (O 99 '99% (no turbo)'), (O 90 '90%'), (O 80 '80%'), (O 70 '70%'), (O 60 '60%'), (O 50 '50%'))
        Presets = @{ MaxBattery = '99'; Balanced = '100' } } | Out-Null

    Add-Item @{ Id = 'cpu.epp'; Section = 'power'; Kind = 'Power'; Sub = $G.SUB_PROCESSOR; Setting = $G.PERFEPP; Type = 'Slider'
        Title = 'Processor energy preference (EPP)'
        Desc  = '0 = favour performance, 100 = favour energy saving. Windows default on battery is about 50.'
        Presets = @{ MaxBattery = '80'; Balanced = '60' } } | Out-Null

    Add-Item @{ Id = 'cpu.cooling'; Section = 'power'; Kind = 'Power'; Sub = $G.SUB_PROCESSOR; Setting = $G.SYSCOOLPOL; Type = 'Radio'
        Title = 'System cooling policy on battery'
        Desc  = 'Passive slows the CPU before spinning fans up - quieter and more efficient.'
        Options = @((O 0 'Passive'), (O 1 'Active'))
        Presets = @{ MaxBattery = '0'; Balanced = '0' } } | Out-Null

    Add-Item @{ Id = 'saver.threshold'; Section = 'power'; Kind = 'Power'; Sub = $G.SUB_ENERGYSAVER; Setting = $G.ESBATTTHRESHOLD
        Title = 'Turn Battery / Energy saver on at'
        Desc  = 'Battery level at which Windows saver mode kicks in automatically.'
        Options = @((O 0 'Never'), (O 10 '10%'), (O 20 '20%'), (O 30 '30%'), (O 40 '40%'), (O 50 '50%'), (O 100 'Always'))
        Presets = @{ MaxBattery = '40'; Balanced = '20' } } | Out-Null

    Add-Item @{ Id = 'saver.brightness'; Section = 'power'; Kind = 'Power'; Sub = $G.SUB_ENERGYSAVER; Setting = $G.ESBRIGHTNESS; Type = 'Slider'
        Title = 'Screen brightness while saver is on'
        Desc  = 'Percentage of normal brightness used when battery/energy saver is active.'
        Presets = @{ MaxBattery = '50'; Balanced = '70' } } | Out-Null

    # ===== Graphics =====
    Add-Item @{ Id = 'gfx.intel'; Section = 'graphics'; Kind = 'Power'; Sub = $G.SUB_INTELGFX; Setting = $G.INTELGFXPLAN
        Title = 'Intel Graphics power plan on battery'
        Desc  = 'Intel iGPU driver power policy. Only present with Intel graphics drivers.'
        Options = @((O 0 'Maximum battery life'), (O 1 'Balanced'), (O 2 'Maximum performance'))
        Presets = @{ MaxBattery = '0'; Balanced = '1' } } | Out-Null

    Add-Item @{ Id = 'gfx.switchable'; Section = 'graphics'; Kind = 'Power'; Sub = $G.SUB_SWITCHGFX; Setting = $G.SWITCHGFX
        Title = 'Switchable dynamic graphics on battery'
        Desc  = 'Hybrid-graphics policy (mainly AMD). "Force power-saving" keeps the dGPU off on battery.'
        Options = @((O 0 'Force power-saving graphics'), (O 1 'Optimize power savings'), (O 2 'Optimize performance'), (O 3 'Maximize performance'))
        Presets = @{ MaxBattery = '0'; Balanced = '1' } } | Out-Null

    $gpuPaths = New-Object System.Collections.ArrayList
    foreach ($p in $script:Installed.Values) { [void]$gpuPaths.Add($p) }
    try {
        $reg = Get-Item -Path $GpuPrefKey -ErrorAction SilentlyContinue
        if ($reg) {
            foreach ($n in $reg.GetValueNames()) {
                if ($n -like '*.exe' -and (Test-Path -LiteralPath $n)) { [void]$gpuPaths.Add($n) }
            }
        }
    } catch { }
    $seen = @{}
    foreach ($p in $gpuPaths) {
        $k = $p.ToLower()
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        New-GpuItem $p | Out-Null
    }

    # ===== Display =====
    $refreshOpts = @()
    try { foreach ($r in [ChillNative]::RefreshRates()) { $refreshOpts += (O "$r" "$r Hz") } } catch { }
    Add-Item @{ Id = 'display.refresh'; Section = 'display'; Kind = 'Refresh'; Type = 'Choice'
        Title = 'Refresh rate (main display)'
        Desc  = 'High refresh rates (120/144/165 Hz) cost a lot of battery. 60 Hz is the sweet spot. Applies immediately, plugged in or not.'
        Options = $refreshOpts
        Presets = @{ MaxBattery = 'lowest60' } } | Out-Null

    Add-Item @{ Id = 'display.brightness'; Section = 'display'; Kind = 'Power'; Sub = $G.SUB_VIDEO; Setting = $G.VIDEONORMALLEVEL; Type = 'Slider'
        Title = 'Display brightness on battery'
        Desc  = 'Brightness the power plan uses when unplugged (not supported by every panel driver).'
        Presets = @{ MaxBattery = '50' } } | Out-Null

    Add-Item @{ Id = 'display.adaptive'; Section = 'display'; Kind = 'Power'; Sub = $G.SUB_VIDEO; Setting = $G.ADAPTBRIGHT; Type = 'Toggle'
        Title = 'Adaptive brightness on battery'
        Desc  = 'Let the ambient light sensor lower brightness in dim rooms.'
        Presets = @{ MaxBattery = '1'; Balanced = '1' } } | Out-Null

    Add-Item @{ Id = 'display.dimafter'; Section = 'display'; Kind = 'Power'; Sub = $G.SUB_VIDEO; Setting = $G.VIDEODIM; Format = 'secs'
        Title = 'Dim display after'
        Desc  = 'Idle time before the screen dims on battery.'
        Options = @(TimeOpts 30, 60, 120, 180, 300, 600, 0)
        Presets = @{ MaxBattery = '60'; Balanced = '120' } } | Out-Null

    Add-Item @{ Id = 'display.dimlevel'; Section = 'display'; Kind = 'Power'; Sub = $G.SUB_VIDEO; Setting = $G.VIDEODIMLEVEL; Type = 'Slider'
        Title = 'Dimmed brightness level'
        Desc  = 'How bright the screen is once it has dimmed.'
        Presets = @{ MaxBattery = '20'; Balanced = '30' } } | Out-Null

    Add-Item @{ Id = 'display.video'; Section = 'display'; Kind = 'Power'; Sub = $G.SUB_MULTIMEDIA; Setting = $G.VIDEOPLAYBACK
        Title = 'Video playback on battery'
        Desc  = 'Lets Windows lower video processing quality to save power.'
        Options = @((O 2 'Optimize for battery life'), (O 1 'Balanced'), (O 0 'Optimize video quality'))
        Presets = @{ MaxBattery = '2'; Balanced = '1' } } | Out-Null

    Add-Item @{ Id = 'display.videobias'; Section = 'display'; Kind = 'Power'; Sub = $G.SUB_MULTIMEDIA; Setting = $G.VIDEOQUALITYBIAS; Type = 'Radio'
        Title = 'Video quality bias'
        Desc  = 'Prefer power saving over smoothness when decoding video.'
        Options = @((O 0 'Power-saving bias'), (O 1 'Performance bias'))
        Presets = @{ MaxBattery = '0'; Balanced = '0' } } | Out-Null

    Add-Item @{ Id = 'display.dark'; Section = 'display'; Kind = 'Reg'; Type = 'Toggle'
        Path = $PersonalizeKey; Names = @('AppsUseLightTheme', 'SystemUsesLightTheme'); AbsentAs = '1'
        OnValue = '0'; OffValue = '1'; Broadcast = 'ImmersiveColorSet'
        Title = 'Dark mode'
        Desc  = 'Dark pixels draw much less power on OLED panels.'
        Presets = @{ MaxBattery = '0' } } | Out-Null

    Add-Item @{ Id = 'display.transparency'; Section = 'display'; Kind = 'Reg'; Type = 'Toggle'
        Path = $PersonalizeKey; Names = @('EnableTransparency'); AbsentAs = '1'
        OnValue = '0'; OffValue = '1'; Broadcast = 'ImmersiveColorSet'
        Title = 'Turn off transparency effects'
        Desc  = 'Acrylic / Mica blur keeps the GPU busy.'
        Presets = @{ MaxBattery = '0'; Balanced = '0' } } | Out-Null

    Add-Item @{ Id = 'display.animations'; Section = 'display'; Kind = 'Animation'; Type = 'Toggle'
        OnValue = '0'; OffValue = '1'
        Title = 'Turn off animation effects'
        Desc  = 'Fewer window and UI animations means fewer GPU wake-ups.'
        Presets = @{ MaxBattery = '0' } } | Out-Null

    # ===== Browsers =====
    $browsers = @(
        @{ Key = 'chrome';  Name = 'Google Chrome';   Path = 'HKLM:\SOFTWARE\Policies\Google\Chrome' },
        @{ Key = 'edge';    Name = 'Microsoft Edge';  Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' },
        @{ Key = 'brave';   Name = 'Brave';           Path = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave' },
        @{ Key = 'firefox'; Name = 'Mozilla Firefox'; Path = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox' }
    )
    $present = @($browsers | Where-Object { $script:Installed.ContainsKey($_.Name) })
    if ($present.Count -eq 0) { $present = @($browsers | Where-Object { $_.Key -in @('chrome', 'edge') }) }

    foreach ($b in $present) {
        $hwName = if ($b.Key -eq 'firefox') { 'HardwareAcceleration' } else { 'HardwareAccelerationModeEnabled' }
        Add-Item @{ Id = "browser.$($b.Key).hwaccel"; Section = 'browser'; Kind = 'Reg'; Type = 'Radio'
            Path = $b.Path; Names = @($hwName)
            Title = "$($b.Name) - hardware acceleration"
            Desc  = 'Keeping it ON while the browser is pinned to the iGPU (Graphics section) is usually best: video decoding stays on efficient hardware. Turn it OFF only if the browser keeps waking the dGPU. Takes effect after a browser restart.'
            Options = @((O $UNSET 'Browser decides'), (O '1' 'Force ON (iGPU)'), (O '0' 'Force OFF'))
            Presets = @{ MaxBattery = '1'; Balanced = '1' } } | Out-Null

        if ($b.Key -ne 'firefox') {
            Add-Item @{ Id = "browser.$($b.Key).background"; Section = 'browser'; Kind = 'Reg'; Type = 'Toggle'
                Path = $b.Path; Names = @('BackgroundModeEnabled'); OnValue = '0'; OffValue = $UNSET
                Title = "$($b.Name) - stop running after it is closed"
                Desc  = 'Blocks background apps and extensions from keeping the browser alive.'
                Presets = @{ MaxBattery = '0'; Balanced = '0' } } | Out-Null
        }

        if ($b.Key -eq 'edge') {
            Add-Item @{ Id = 'browser.edge.efficiency'; Section = 'browser'; Kind = 'Reg'
                Path = $b.Path; Names = @('EfficiencyMode')
                Title = 'Microsoft Edge - efficiency mode'
                Desc  = 'Edge lowers tab and video activity to stretch battery life.'
                Options = @((O $UNSET 'Browser default'), (O '0' 'Always on'), (O '2' 'When unplugged'), (O '3' 'When unplugged and battery low'), (O '1' 'Never'))
                Presets = @{ MaxBattery = '2'; Balanced = '3' } } | Out-Null

            Add-Item @{ Id = 'browser.edge.sleeping'; Section = 'browser'; Kind = 'Reg'; Type = 'Toggle'
                Path = $b.Path; Names = @('SleepingTabsEnabled'); OnValue = '1'; OffValue = $UNSET
                Title = 'Microsoft Edge - sleeping tabs'
                Desc  = 'Puts background tabs to sleep so they stop using CPU.'
                Presets = @{ MaxBattery = '1'; Balanced = '1' } } | Out-Null

            Add-Item @{ Id = 'browser.edge.sleeptimeout'; Section = 'browser'; Kind = 'Reg'
                Path = $b.Path; Names = @('SleepingTabsTimeout'); Format = 'secs'
                Title = 'Microsoft Edge - put tabs to sleep after'
                Options = @((O $UNSET 'Browser default'), (O '300' '5 min'), (O '900' '15 min'), (O '1800' '30 min'), (O '3600' '1 hr'))
                Presets = @{ MaxBattery = '300'; Balanced = '900' } } | Out-Null

            Add-Item @{ Id = 'browser.edge.startupboost'; Section = 'browser'; Kind = 'Reg'; Type = 'Toggle'
                Path = $b.Path; Names = @('StartupBoostEnabled'); OnValue = '0'; OffValue = $UNSET
                Title = 'Microsoft Edge - disable Startup boost'
                Desc  = 'Stops Edge pre-loading itself in the background at sign-in.'
                Presets = @{ MaxBattery = '0'; Balanced = '0' } } | Out-Null
        }

        if ($b.Key -in @('chrome', 'brave')) {
            Add-Item @{ Id = "browser.$($b.Key).energysaver"; Section = 'browser'; Kind = 'Reg'
                Path = $b.Path; Names = @('BatterySaverModeAvailability')
                Title = "$($b.Name) - Energy Saver"
                Desc  = 'Limits background activity and visual effects such as smooth scrolling and video frame rates.'
                Options = @((O $UNSET 'Browser default'), (O '2' 'Whenever unplugged'), (O '1' 'When battery is low'), (O '0' 'Disabled'))
                Presets = @{ MaxBattery = '2'; Balanced = '1' } } | Out-Null

            Add-Item @{ Id = "browser.$($b.Key).memorysaver"; Section = 'browser'; Kind = 'Reg'; Type = 'Toggle'
                Path = $b.Path; Names = @('HighEfficiencyModeEnabled'); OnValue = '1'; OffValue = $UNSET
                Title = "$($b.Name) - Memory Saver"
                Desc  = 'Discards inactive tabs so they stop using CPU.'
                Presets = @{ MaxBattery = '1'; Balanced = '1' } } | Out-Null
        }
    }

    # ===== Sleep =====
    Add-Item @{ Id = 'sleep.display'; Section = 'sleep'; Kind = 'Power'; Sub = $G.SUB_VIDEO; Setting = $G.VIDEOIDLE; Format = 'secs'
        Title = 'Turn off screen after'
        Options = @(TimeOpts 60, 120, 180, 300, 600, 900, 1800, 0)
        Presets = @{ MaxBattery = '120'; Balanced = '300' } } | Out-Null

    Add-Item @{ Id = 'sleep.sleep'; Section = 'sleep'; Kind = 'Power'; Sub = $G.SUB_SLEEP; Setting = $G.STANDBYIDLE; Format = 'secs'
        Title = 'Sleep after'
        Options = @(TimeOpts 180, 300, 600, 900, 1800, 3600, 0)
        Presets = @{ MaxBattery = '300'; Balanced = '900' } } | Out-Null

    Add-Item @{ Id = 'sleep.hibernate'; Section = 'sleep'; Kind = 'Power'; Sub = $G.SUB_SLEEP; Setting = $G.HIBERNATEIDLE; Format = 'secs'
        Title = 'Hibernate after'
        Desc  = 'Hibernation uses no power at all, unlike sleep.'
        Options = @(TimeOpts 1800, 3600, 7200, 10800, 21600, 0)
        Presets = @{ MaxBattery = '3600'; Balanced = '10800' } } | Out-Null

    Add-Item @{ Id = 'sleep.lid'; Section = 'sleep'; Kind = 'Power'; Sub = $G.SUB_BUTTONS; Setting = $G.LIDACTION; Type = 'Radio'
        Title = 'When I close the lid (on battery)'
        Options = @((O 0 'Do nothing'), (O 1 'Sleep'), (O 2 'Hibernate'), (O 3 'Shut down'))
        Presets = @{ MaxBattery = '1'; Balanced = '1' } } | Out-Null

    # ===== Connectivity =====
    Add-Item @{ Id = 'conn.wifi'; Section = 'connectivity'; Kind = 'Power'; Sub = $G.SUB_WIFI; Setting = $G.WIFIPOWER
        Title = 'Wi-Fi adapter power saving'
        Options = @((O 0 'Maximum performance'), (O 1 'Low power saving'), (O 2 'Medium power saving'), (O 3 'Maximum power saving'))
        Presets = @{ MaxBattery = '3'; Balanced = '2' } } | Out-Null

    Add-Item @{ Id = 'conn.aspm'; Section = 'connectivity'; Kind = 'Power'; Sub = $G.SUB_PCIE; Setting = $G.ASPM
        Title = 'PCI Express link state power management'
        Desc  = 'Lets NVMe drives, the dGPU and Wi-Fi cards drop their PCIe links into low-power states.'
        Options = @((O 0 'Off'), (O 1 'Moderate power savings'), (O 2 'Maximum power savings'))
        Presets = @{ MaxBattery = '2'; Balanced = '1' } } | Out-Null

    Add-Item @{ Id = 'conn.usb'; Section = 'connectivity'; Kind = 'Power'; Sub = $G.SUB_USB; Setting = $G.USBSUSPEND; Type = 'Toggle'
        Title = 'USB selective suspend'
        Desc  = 'Idle USB devices are put into a low-power state.'
        Presets = @{ MaxBattery = '1'; Balanced = '1' } } | Out-Null

    Add-Item @{ Id = 'conn.disk'; Section = 'connectivity'; Kind = 'Power'; Sub = $G.SUB_DISK; Setting = $G.DISKIDLE; Format = 'secs'
        Title = 'Turn off hard disk after'
        Options = @(TimeOpts 60, 180, 300, 600, 1200, 0)
        Presets = @{ MaxBattery = '180'; Balanced = '600' } } | Out-Null

    Add-Item @{ Id = 'conn.bluetooth'; Section = 'connectivity'; Kind = 'Bluetooth'; Type = 'Toggle'
        Title = 'Bluetooth radio'
        Desc  = 'Turn Bluetooth off when you are not using wireless peripherals. Not changed by the presets.' } | Out-Null

    # ===== Background & System =====
    Add-Item @{ Id = 'sys.bgapps'; Section = 'system'; Kind = 'Reg'; Type = 'Toggle'
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications'; Names = @('GlobalUserDisabled'); AbsentAs = '0'
        Title = 'Block Store apps from running in the background'
        Desc  = 'Stops UWP / Store apps (Mail, Photos, Your Phone...) refreshing in the background.'
        Presets = @{ MaxBattery = '1' } } | Out-Null

    Add-Item @{ Id = 'sys.indexing'; Section = 'system'; Kind = 'Reg'; Type = 'Toggle'
        Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Names = @('PreventIndexOnBattery'); OnValue = '1'; OffValue = $UNSET
        Title = 'Pause search indexing on battery'
        Desc  = 'Windows Search waits until you are plugged in to index files.'
        Presets = @{ MaxBattery = '1'; Balanced = '1' } } | Out-Null

    Add-Item @{ Id = 'sys.gamedvr'; Section = 'system'; Kind = 'Reg'; Type = 'Toggle'
        Path = 'HKCU:\System\GameConfigStore'; Names = @('GameDVR_Enabled'); AbsentAs = '1'; OnValue = '0'; OffValue = '1'
        Title = 'Disable background game recording'
        Desc  = 'Xbox Game Bar captures can keep the GPU encoder running.'
        Presets = @{ MaxBattery = '0'; Balanced = '0' } } | Out-Null
}

# ---------------------------------------------------------------------------
# Read / apply
# ---------------------------------------------------------------------------
function Get-BtRadio {
    if (-not $script:AsTask) {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        $null = [Windows.Devices.Radios.Radio,Windows.System.Devices,ContentType=WindowsRuntime]
        $script:AsTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
            $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
        } | Select-Object -First 1
    }
    $null = Wait-WinRt ([Windows.Devices.Radios.Radio]::RequestAccessAsync()) ([Windows.Devices.Radios.RadioAccessStatus])
    $radios = Wait-WinRt ([Windows.Devices.Radios.Radio]::GetRadiosAsync()) ([System.Collections.Generic.IReadOnlyList[Windows.Devices.Radios.Radio]])
    return $radios | Where-Object { $_.Kind -eq 'Bluetooth' } | Select-Object -First 1
}

function Wait-WinRt($Operation, [Type]$ResultType) {
    $task = $script:AsTask.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    $null = $task.Wait(-1)
    return $task.Result
}

function Read-Item($it) {
    try {
        switch ($it.Kind) {
            'Power' {
                $v = [ChillNative]::ReadDC($it.Sub, $it.Setting)
                if ($v -lt 0) { return $null }
                return [string]$v
            }
            'Reg' {
                $n = $it.Names[0]
                $p = Get-ItemProperty -Path $it.Path -Name $n -ErrorAction SilentlyContinue
                if ($null -eq $p) { return $it.AbsentAs }
                return [string]$p.$n
            }
            'Overlay' {
                $p = Get-ItemProperty -Path $PowerSchemesKey -Name 'ActiveOverlayDcPowerScheme' -ErrorAction SilentlyContinue
                if ($p -and $p.ActiveOverlayDcPowerScheme) { return ([string]$p.ActiveOverlayDcPowerScheme).ToLower() }
                if ([ChillNative]::ACLine() -eq 0) { $g = [ChillNative]::GetOverlay(); if ($g) { return $g.ToLower() } }
                return $Overlay.Balanced
            }
            'Refresh' {
                if ($it.Options.Count -eq 0) { return $null }
                return [string][ChillNative]::CurrentRefresh()
            }
            'Animation' { if ([ChillNative]::GetClientAnimation()) { return '1' } else { return '0' } }
            'Bluetooth' {
                $r = Get-BtRadio
                if (-not $r) { return $null }
                if ([string]$r.State -eq 'On') { return '1' } else { return '0' }
            }
            'GpuPref' {
                $p = Get-ItemProperty -Path $GpuPrefKey -Name $it.Exe -ErrorAction SilentlyContinue
                if ($null -eq $p) { return $UNSET }
                $m = [regex]::Match([string]$p.($it.Exe), 'GpuPreference=(\d+);?')
                if ($m.Success) { return $m.Groups[1].Value } else { return $UNSET }
            }
        }
    } catch {
        return $null
    }
    return $null
}

function Write-Reg([string]$Path, [string]$Name, [string]$Value) {
    if ($Value -eq $UNSET) {
        if (Test-Path $Path) { Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue }
        return
    }
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value ([int]$Value) -PropertyType DWord -Force | Out-Null
}

function Apply-Item($it, [string]$Value) {
    switch ($it.Kind) {
        'Power' {
            if (-not [ChillNative]::WriteDC($it.Sub, $it.Setting, [uint32]$Value)) { throw 'PowerWriteDCValueIndex failed' }
            $script:NeedReapply = $true
        }
        'Reg' {
            foreach ($n in $it.Names) { Write-Reg $it.Path $n $Value }
            if ($it.Broadcast) { $script:Broadcasts[$it.Broadcast] = $true }
        }
        'Overlay' {
            if (-not (Test-Path $PowerSchemesKey)) { New-Item -Path $PowerSchemesKey -Force | Out-Null }
            New-ItemProperty -Path $PowerSchemesKey -Name 'ActiveOverlayDcPowerScheme' -Value $Value -PropertyType String -Force | Out-Null
            if ([ChillNative]::ACLine() -eq 0) { [void][ChillNative]::SetOverlay($Value) }
        }
        'Refresh' {
            $rc = [ChillNative]::SetRefresh([int]$Value)
            if ($rc -lt 0) { throw "display driver rejected $Value Hz (code $rc)" }
            if ($rc -eq 1) { Write-Log "  $Value Hz will be used after a restart." }
        }
        'Animation' { [void][ChillNative]::SetClientAnimation($Value -eq '1') }
        'Bluetooth' {
            $r = Get-BtRadio
            if (-not $r) { throw 'no Bluetooth radio found' }
            $state = if ($Value -eq '1') { [Windows.Devices.Radios.RadioState]::On } else { [Windows.Devices.Radios.RadioState]::Off }
            $res = Wait-WinRt ($r.SetStateAsync($state)) ([Windows.Devices.Radios.RadioAccessStatus])
            if ([string]$res -ne 'Allowed') { throw "Windows refused ($res)" }
        }
        'GpuPref' {
            $old = ''
            $p = Get-ItemProperty -Path $GpuPrefKey -Name $it.Exe -ErrorAction SilentlyContinue
            if ($p) { $old = [string]$p.($it.Exe) }
            $rest = [regex]::Replace($old, 'GpuPreference=\d+;?', '')
            $new = if ($Value -eq $UNSET) { $rest } else { "GpuPreference=$Value;$rest" }
            if (-not (Test-Path $GpuPrefKey)) { New-Item -Path $GpuPrefKey -Force | Out-Null }
            if ($new) { New-ItemProperty -Path $GpuPrefKey -Name $it.Exe -Value $new -PropertyType String -Force | Out-Null }
            else      { Remove-ItemProperty -Path $GpuPrefKey -Name $it.Exe -ErrorAction SilentlyContinue }
        }
    }
}

function Get-ValueLabel($it, [string]$Value) {
    if ($null -eq $Value) { return 'n/a' }
    foreach ($o in $it.Options) { if ($o.Value -eq $Value) { return $o.Label } }
    if ($it.Type -eq 'Toggle') { if ($Value -eq $it.OnValue) { return 'On' } else { return 'Off' } }
    if ($Value -eq $UNSET)     { return 'Not set' }
    if ($it.Type -eq 'Slider') { return "$Value$($it.Unit)" }
    if ($it.Format -eq 'secs') { return Format-Secs ([int]$Value) }
    if ($it.Kind -eq 'Overlay') {
        if ($Value -eq $Overlay.BetterBattery) { return 'Better battery' }
        return "Custom ($Value)"
    }
    return "Custom ($Value)"
}

function Resolve-PresetValue($it, [string]$Value) {
    if ($Value -eq 'lowest60') {
        $rates = @($it.Options | ForEach-Object { [int]$_.Value })
        if ($rates -contains 60) { return '60' }
        $ok = @($rates | Where-Object { $_ -ge 48 } | Sort-Object)
        if ($ok.Count -gt 0) { return [string]$ok[0] }
        return $it.Current
    }
    return $Value
}

# --- backup ---------------------------------------------------------------
function Get-Backup {
    $h = [ordered]@{}
    if (Test-Path $BackupFile) {
        try {
            $j = Get-Content -Path $BackupFile -Raw | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) { $h[$p.Name] = [string]$p.Value }
        } catch { }
    }
    return $h
}

function Save-Backup($h) {
    if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }
    ([pscustomobject]$h) | ConvertTo-Json | Set-Content -Path $BackupFile -Encoding UTF8
}

# --- logging --------------------------------------------------------------
function Write-Log([string]$Text) {
    $line = "[{0:HH:mm:ss}] {1}" -f (Get-Date), $Text
    if ($script:LogBox) {
        $script:LogBox.AppendText($line + [Environment]::NewLine)
        $script:LogBox.ScrollToEnd()
    } else {
        Write-Host $line
    }
}

# --- engine ---------------------------------------------------------------
function Update-AllFromSystem {
    foreach ($it in $script:Items) {
        $v = Read-Item $it
        $it.Available = ($null -ne $v)
        $it.Current = $v
        $it.Pending = $v
    }
}

function Invoke-Changes {
    $todo = @($script:Items | Where-Object { $_.Available -and $null -ne $_.Pending -and $_.Pending -ne $_.Current })
    if ($todo.Count -eq 0) { Write-Log 'Nothing to change - already optimized.'; return 0 }

    $backup = Get-Backup
    foreach ($it in $todo) { if (-not $backup.Contains($it.Id)) { $backup[$it.Id] = $it.Current } }
    Save-Backup $backup

    $script:NeedReapply = $false
    $script:Broadcasts = @{}
    $ok = 0
    foreach ($it in $todo) {
        try {
            Apply-Item $it $it.Pending
            Write-Log ("OK    {0}: {1} -> {2}" -f $it.Title, (Get-ValueLabel $it $it.Current), (Get-ValueLabel $it $it.Pending))
            $ok++
        } catch {
            Write-Log ("FAIL  {0}: {1}" -f $it.Title, $_.Exception.Message)
        }
    }
    if ($script:NeedReapply) { try { [ChillNative]::ReapplyScheme() } catch { Write-Log "Could not re-activate power plan: $($_.Exception.Message)" } }
    foreach ($b in $script:Broadcasts.Keys) { [ChillNative]::BroadcastSettingChange($b) }
    Update-AllFromSystem
    Write-Log "Applied $ok of $($todo.Count) change(s). Browser changes take effect after restarting the browser."
    return $ok
}

function Set-PresetPending([string]$Name) {
    $n = 0
    foreach ($it in $script:Items) {
        if (-not $it.Available) { continue }
        if ($it.Presets.ContainsKey($Name)) {
            $v = Resolve-PresetValue $it $it.Presets[$Name]
            if ($null -ne $v) { $it.Pending = $v; $n++ }
        }
    }
    return $n
}

function Invoke-Restore {
    $backup = Get-Backup
    if ($backup.Count -eq 0) { Write-Log 'No backup found - nothing to restore.'; return }
    foreach ($i in $script:Items) { $i.Pending = $i.Current }
    foreach ($id in $backup.Keys) {
        $it = Find-Item $id
        if (-not $it -and $id -like 'gpu|*') { $it = New-GpuItem ($id.Substring(4)); $it.Current = Read-Item $it; $it.Available = $true }
        if (-not $it) { Write-Log "SKIP  $id (no longer available)"; continue }
        $it.Pending = $backup[$id]
    }
    [void](Invoke-Changes)
    Remove-Item -Path $BackupFile -Force -ErrorAction SilentlyContinue
    Write-Log 'Original settings restored and backup cleared.'
}

# ---------------------------------------------------------------------------
# CLI mode
# ---------------------------------------------------------------------------
Initialize-Items
Update-AllFromSystem

if ($script:CliMode) {
    if ($Restore) { Invoke-Restore }
    else {
        $presetKey = $Preset
        [void](Set-PresetPending $presetKey)
        [void](Invoke-Changes)
    }
    Start-Sleep -Seconds 3
    exit 0
}

# ---------------------------------------------------------------------------
# GUI
# ---------------------------------------------------------------------------
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$script:AppId = 'corum86.ChillMode'
try { [ChillNative]::SetProcessAppId($script:AppId) } catch { }
[ChillNative]::HideConsole()

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Chill Mode - Battery Optimizer" Width="1100" Height="860" MinWidth="880" MinHeight="600"
        WindowStartupLocation="CenterScreen" Background="#F3F4F6" FontFamily="Segoe UI" FontSize="13"
        TextOptions.TextFormattingMode="Display" UseLayoutRounding="True">
  <Window.Resources>
    <SolidColorBrush x:Key="Accent" Color="#0F8A6C"/>
    <SolidColorBrush x:Key="AccentDark" Color="#0B6B54"/>
    <SolidColorBrush x:Key="Ink" Color="#1F2328"/>
    <SolidColorBrush x:Key="Muted" Color="#5E6672"/>
    <SolidColorBrush x:Key="Line" Color="#E4E7EB"/>

    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Width="46" Height="24" Background="Transparent">
              <Border x:Name="Track" CornerRadius="12" Background="White" BorderBrush="#8A9099" BorderThickness="1.5"/>
              <Ellipse x:Name="Knob" Width="12" Height="12" Fill="#5E6672" HorizontalAlignment="Left" Margin="6,0,0,0"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="#0F8A6C"/>
                <Setter TargetName="Track" Property="BorderBrush" Value="#0F8A6C"/>
                <Setter TargetName="Knob" Property="Fill" Value="White"/>
                <Setter TargetName="Knob" Property="Width" Value="16"/>
                <Setter TargetName="Knob" Property="Height" Value="16"/>
                <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="Knob" Property="Margin" Value="0,0,4,0"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Track" Property="Opacity" Value="0.88"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.35"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Background" Value="White"/>
      <Setter Property="Foreground" Value="#1F2328"/>
      <Setter Property="BorderBrush" Value="#D0D5DB"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="HorizontalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.7"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#0F8A6C"/>
      <Setter Property="BorderBrush" Value="#0F8A6C"/>
      <Setter Property="Foreground" Value="White"/>
    </Style>
    <Style x:Key="Nav" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="FontWeight" Value="Normal"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Margin" Value="0,0,0,2"/>
      <Setter Property="Padding" Value="10,7"/>
    </Style>
    <Style TargetType="RadioButton">
      <Setter Property="Margin" Value="0,6,18,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="MinWidth" Value="230"/>
      <Setter Property="Padding" Value="8,5"/>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- Header -->
    <Border Grid.Row="0" Background="#12352D" Padding="24,18">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal">
          <Image x:Name="HeaderIcon" Width="52" Height="52" Margin="0,0,14,0" VerticalAlignment="Center"/>
          <StackPanel>
          <TextBlock Text="Chill Mode" FontSize="26" FontWeight="SemiBold" Foreground="White"/>
          <TextBlock Text="Every battery setting in one place. Power-plan values only change the 'On battery' side - plugged-in performance stays the same."
                     Foreground="#B9D7CE" TextWrapping="Wrap" Margin="0,4,0,0" MaxWidth="520" HorizontalAlignment="Left"/>
          </StackPanel>
        </StackPanel>
        <Grid Grid.Column="1" VerticalAlignment="Center">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <StackPanel Margin="0,0,28,0">
            <TextBlock Text="BATTERY" Foreground="#7FB3A3" FontSize="11" FontWeight="SemiBold"/>
            <TextBlock x:Name="StBattery" Foreground="White" FontSize="16" FontWeight="SemiBold" Text="-"/>
            <TextBlock x:Name="StSource" Foreground="#B9D7CE" FontSize="12" Text="-"/>
          </StackPanel>
          <StackPanel Grid.Column="1" Margin="0,0,28,0">
            <TextBlock Text="DISPLAY" Foreground="#7FB3A3" FontSize="11" FontWeight="SemiBold"/>
            <TextBlock x:Name="StDisplay" Foreground="White" FontSize="16" FontWeight="SemiBold" Text="-"/>
            <TextBlock x:Name="StPlan" Foreground="#B9D7CE" FontSize="12" Text="-"/>
          </StackPanel>
          <StackPanel Grid.Column="2" MaxWidth="260">
            <TextBlock Text="GPUs" Foreground="#7FB3A3" FontSize="11" FontWeight="SemiBold"/>
            <TextBlock x:Name="StGpu" Foreground="White" FontSize="12" TextWrapping="Wrap" Text="-"/>
          </StackPanel>
        </Grid>
      </Grid>
    </Border>

    <!-- Toolbar -->
    <Border Grid.Row="1" Background="White" BorderBrush="#E4E7EB" BorderThickness="0,0,0,1" Padding="24,12">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal">
          <Button x:Name="BtnMax" Style="{StaticResource Primary}" Padding="18,9" ToolTip="Apply every battery-saving setting right now">
            <TextBlock><Run Text="Optimize for battery" FontSize="14"/><Run Text="   one click" Foreground="#BFE8DC" FontWeight="Normal"/></TextBlock>
          </Button>
          <Button x:Name="BtnBalanced" Style="{StaticResource Btn}" Content="Balanced saver" ToolTip="Moderate savings with good responsiveness - applied immediately"/>
          <Button x:Name="BtnRestore" Style="{StaticResource Btn}" Content="Restore original" ToolTip="Put back every value Chill Mode changed"/>
          <Button x:Name="BtnRescan" Style="{StaticResource Btn}" Content="Re-scan"/>
        </StackPanel>
        <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock x:Name="PendingText" Foreground="#5E6672" VerticalAlignment="Center" Margin="0,0,12,0" Text="No pending changes"/>
          <Button x:Name="BtnDiscard" Style="{StaticResource Btn}" Content="Discard" IsEnabled="False"/>
          <Button x:Name="BtnApply" Style="{StaticResource Primary}" Content="Apply changes" IsEnabled="False" Margin="0"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- Body -->
    <Grid Grid.Row="2">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="210"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <Border Background="#EBEEF1" BorderBrush="#E4E7EB" BorderThickness="0,0,1,0" Padding="12,16">
        <StackPanel>
          <TextBlock Text="JUMP TO" Foreground="#5E6672" FontSize="11" FontWeight="SemiBold" Margin="10,0,0,8"/>
          <StackPanel x:Name="NavPanel"/>
          <TextBlock x:Name="BackupText" Foreground="#5E6672" FontSize="11" TextWrapping="Wrap" Margin="10,18,6,0"/>
        </StackPanel>
      </Border>
      <ScrollViewer x:Name="Scroller" Grid.Column="1" VerticalScrollBarVisibility="Auto" Padding="24,16">
        <StackPanel x:Name="SectionsPanel" MaxWidth="940"/>
      </ScrollViewer>
    </Grid>

    <!-- Log -->
    <Border Grid.Row="3" Background="#111827" Padding="16,8">
      <DockPanel>
        <TextBlock DockPanel.Dock="Top" Text="ACTIVITY" Foreground="#6B7280" FontSize="10" FontWeight="SemiBold" Margin="0,0,0,4"/>
        <TextBox x:Name="LogBox" Height="96" IsReadOnly="True" Background="Transparent" BorderThickness="0"
                 Foreground="#D1D5DB" FontFamily="Consolas" FontSize="12" VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap"/>
      </DockPanel>
    </Border>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$script:Win = [Windows.Markup.XamlReader]::Load($reader)
foreach ($n in 'StBattery', 'StSource', 'StDisplay', 'StPlan', 'StGpu', 'BtnMax', 'BtnBalanced', 'BtnRestore', 'BtnRescan',
               'PendingText', 'BtnDiscard', 'BtnApply', 'NavPanel', 'BackupText', 'Scroller', 'SectionsPanel', 'LogBox') {
    Set-Variable -Name "ui$n" -Value $script:Win.FindName($n) -Scope Script
}
$script:LogBox = $uiLogBox

$iconPath = Join-Path $PSScriptRoot 'assets\ChillMode.ico'
if (Test-Path $iconPath) {
    try {
        $iconUri = New-Object Uri $iconPath
        $script:Win.Icon = [Windows.Media.Imaging.BitmapFrame]::Create($iconUri)
        $decoder = New-Object Windows.Media.Imaging.IconBitmapDecoder($iconUri, 'None', 'OnLoad')
        $big = $decoder.Frames | Sort-Object { $_.PixelWidth } -Descending | Select-Object -First 1
        $script:Win.FindName('HeaderIcon').Source = $big
    } catch { }
}

$script:Win.Add_SourceInitialized({
    try {
        $hwnd = (New-Object Windows.Interop.WindowInteropHelper($script:Win)).Handle
        $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $cmd = "`"$psExe`" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$script:ScriptPath`""
        [ChillNative]::SetWindowAppProps($hwnd, $script:AppId, $cmd, "$iconPath,0", $script:AppName)
    } catch { }
})

$bc = New-Object Windows.Media.BrushConverter
function Brush([string]$Hex) { $bc.ConvertFromString($Hex) }
$script:Loading = $false
$script:SectionCards = @{}
$script:SectionBodies = @{}

# --- status header ----------------------------------------------------------
$script:GpuText = 'Unknown'
try { $script:GpuText = (@(Get-CimInstance -ClassName Win32_VideoController | ForEach-Object { $_.Name }) -join "`n") } catch { }

function Update-Status {
    try {
        $flag = [ChillNative]::BatteryFlag()
        $pct  = [ChillNative]::BatteryPct()
        $ac   = [ChillNative]::ACLine()
        if ($flag -eq 128 -or $pct -eq 255) { $uiStBattery.Text = 'No battery' }
        else { $uiStBattery.Text = "$pct%" }
        $src = if ($ac -eq 1) { 'Plugged in' } elseif ($ac -eq 0) { 'On battery' } else { 'Unknown source' }
        $mins = [ChillNative]::BatteryMinutes()
        if ($ac -eq 0 -and $mins -gt 0) { $src += (" - about {0}h {1:00}m left" -f [math]::Floor($mins / 60), ($mins % 60)) }
        $uiStSource.Text = $src
    } catch { }
    try { $uiStDisplay.Text = [ChillNative]::CurrentModeText() } catch { $uiStDisplay.Text = '-' }
    try {
        $id = [ChillNative]::ActiveSchemeId()
        $out = (powercfg /getactivescheme) -join ' '
        $m = [regex]::Match($out, '\(([^)]+)\)')
        $uiStPlan.Text = if ($m.Success) { "Plan: $($m.Groups[1].Value)" } else { "Plan: $id" }
    } catch { }
    $uiStGpu.Text = $script:GpuText
    $b = Get-Backup
    $uiBackupText.Text = if ($b.Count -gt 0) { "Backup holds the original value of $($b.Count) setting(s). Use 'Restore original' to undo." } else { 'No changes made yet. Originals are backed up automatically before the first change.' }
}

# --- rows -------------------------------------------------------------------
function New-Text([string]$Text, [double]$Size = 13, [string]$Color = '#1F2328', [string]$Weight = 'Normal') {
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $Text; $t.FontSize = $Size; $t.Foreground = Brush $Color
    $t.FontWeight = [Windows.FontWeights]::$Weight
    $t.TextWrapping = 'Wrap'
    return $t
}

function New-Row($it) {
    $row = New-Object Windows.Controls.Border
    $row.BorderBrush = Brush '#EEF0F2'
    $row.BorderThickness = '0,1,0,0'
    $row.Padding = '0,12,0,12'

    $grid = New-Object Windows.Controls.Grid
    foreach ($w in @('4', '*', 'Auto')) {
        $cd = New-Object Windows.Controls.ColumnDefinition
        $cd.Width = (New-Object Windows.GridLengthConverter).ConvertFromString($w)
        $grid.ColumnDefinitions.Add($cd)
    }
    $bar = New-Object Windows.Shapes.Rectangle
    $bar.Fill = Brush '#0F8A6C'; $bar.RadiusX = 2; $bar.RadiusY = 2; $bar.Visibility = 'Hidden'
    $grid.Children.Add($bar) | Out-Null

    $left = New-Object Windows.Controls.StackPanel
    $left.Margin = '14,0,16,0'
    [Windows.Controls.Grid]::SetColumn($left, 1)
    $left.Children.Add((New-Text $it.Title 14 '#1F2328' 'SemiBold')) | Out-Null
    if ($it.Desc) { $d = New-Text $it.Desc 12 '#5E6672'; $d.Margin = '0,2,0,0'; $left.Children.Add($d) | Out-Null }
    $status = New-Text '' 11.5 '#0F8A6C' 'SemiBold'
    $status.Margin = '0,4,0,0'; $status.Visibility = 'Collapsed'
    $grid.Children.Add($left) | Out-Null

    $ui = [pscustomobject]@{ Row = $row; Bar = $bar; Status = $status; Control = $null; Radios = @{}; ValueText = $null; RadioPanel = $null }

    switch ($it.Type) {
        'Toggle' {
            $cb = New-Object Windows.Controls.CheckBox
            $cb.Style = $script:Win.FindResource('Switch')
            $cb.VerticalAlignment = 'Center'
            $cb.Tag = $it
            $cb.Add_Click({ $i = $this.Tag; Set-Pending $i $(if ($this.IsChecked) { $i.OnValue } else { $i.OffValue }) })
            [Windows.Controls.Grid]::SetColumn($cb, 2)
            $grid.Children.Add($cb) | Out-Null
            $ui.Control = $cb
        }
        'Choice' {
            $combo = New-Object Windows.Controls.ComboBox
            $combo.VerticalAlignment = 'Center'
            $combo.Tag = $it
            foreach ($o in $it.Options) {
                $ci = New-Object Windows.Controls.ComboBoxItem
                $ci.Content = $o.Label; $ci.Tag = $o.Value
                $combo.Items.Add($ci) | Out-Null
            }
            $combo.Add_SelectionChanged({ if ($this.SelectedItem) { Set-Pending $this.Tag ([string]$this.SelectedItem.Tag) } })
            [Windows.Controls.Grid]::SetColumn($combo, 2)
            $grid.Children.Add($combo) | Out-Null
            $ui.Control = $combo
        }
        'Radio' {
            $wp = New-Object Windows.Controls.WrapPanel
            $wp.Margin = '0,4,0,0'
            foreach ($o in $it.Options) {
                $rb = New-Object Windows.Controls.RadioButton
                $rb.Content = $o.Label
                $rb.GroupName = $it.Id
                $rb.Tag = [pscustomobject]@{ Item = $it; Value = $o.Value }
                $rb.Add_Checked({ Set-Pending $this.Tag.Item $this.Tag.Value })
                $wp.Children.Add($rb) | Out-Null
                $ui.Radios[$o.Value] = $rb
            }
            $left.Children.Add($wp) | Out-Null
            $ui.RadioPanel = $wp
        }
        'Slider' {
            $sp = New-Object Windows.Controls.StackPanel
            $sp.Orientation = 'Horizontal'; $sp.VerticalAlignment = 'Center'
            $sl = New-Object Windows.Controls.Slider
            $sl.Minimum = $it.Min; $sl.Maximum = $it.Max; $sl.Width = 180
            $sl.TickFrequency = 5; $sl.IsSnapToTickEnabled = $true; $sl.SmallChange = 5; $sl.LargeChange = 10
            $sl.VerticalAlignment = 'Center'
            $sl.Tag = $it
            $vt = New-Text '' 13 '#1F2328' 'SemiBold'
            $vt.Width = 48; $vt.TextAlignment = 'Right'; $vt.VerticalAlignment = 'Center'
            $ui.ValueText = $vt
            $sl.Add_ValueChanged({
                $i = $this.Tag
                $v = [string][int][math]::Round($this.Value)
                $i.Ui.ValueText.Text = "$v$($i.Unit)"
                Set-Pending $i $v
            })
            $sp.Children.Add($sl) | Out-Null
            $sp.Children.Add($vt) | Out-Null
            [Windows.Controls.Grid]::SetColumn($sp, 2)
            $grid.Children.Add($sp) | Out-Null
            $ui.Control = $sl
        }
    }
    $left.Children.Add($status) | Out-Null
    $row.Child = $grid
    $it.Ui = $ui
    return $row
}

function Set-UIValue($it) {
    if (-not $it.Ui) { return }
    $script:Loading = $true
    try {
        $v = $it.Pending
        $ui = $it.Ui
        switch ($it.Type) {
            'Toggle' { $ui.Control.IsChecked = ($v -eq $it.OnValue) }
            'Choice' {
                $match = $null
                foreach ($ci in $ui.Control.Items) { if ([string]$ci.Tag -eq $v) { $match = $ci } }
                if (-not $match -and $null -ne $v) {
                    $match = New-Object Windows.Controls.ComboBoxItem
                    $match.Content = "Current: $(Get-ValueLabel $it $v)"; $match.Tag = $v
                    $ui.Control.Items.Add($match) | Out-Null
                }
                $ui.Control.SelectedItem = $match
            }
            'Radio' {
                if ($null -ne $v -and -not $ui.Radios.ContainsKey($v)) {
                    $rb = New-Object Windows.Controls.RadioButton
                    $rb.Content = "Current: $(Get-ValueLabel $it $v)"
                    $rb.GroupName = $it.Id
                    $rb.Tag = [pscustomobject]@{ Item = $it; Value = $v }
                    $rb.Add_Checked({ Set-Pending $this.Tag.Item $this.Tag.Value })
                    $ui.RadioPanel.Children.Add($rb) | Out-Null
                    $ui.Radios[$v] = $rb
                }
                foreach ($k in @($ui.Radios.Keys)) { $ui.Radios[$k].IsChecked = ($k -eq $v) }
            }
            'Slider' {
                $n = 0; [void][int]::TryParse([string]$v, [ref]$n)
                $ui.Control.Value = $n
                $ui.ValueText.Text = "$n$($it.Unit)"
            }
        }
        $ui.Row.IsEnabled = $it.Available
    } finally {
        $script:Loading = $false
    }
    Update-RowState $it
}

function Update-RowState($it) {
    $ui = $it.Ui
    if (-not $ui) { return }
    if (-not $it.Available) {
        $ui.Bar.Visibility = 'Hidden'
        $ui.Status.Text = 'Not available on this device'
        $ui.Status.Foreground = Brush '#8A9099'
        $ui.Status.Visibility = 'Visible'
        $ui.Row.Opacity = 0.6
        return
    }
    $ui.Row.Opacity = 1
    if ($it.Pending -ne $it.Current) {
        $ui.Bar.Visibility = 'Visible'
        $ui.Status.Text = "Will change: $(Get-ValueLabel $it $it.Current)  ->  $(Get-ValueLabel $it $it.Pending)"
        $ui.Status.Foreground = Brush '#0F8A6C'
        $ui.Status.Visibility = 'Visible'
    } else {
        $ui.Bar.Visibility = 'Hidden'
        $ui.Status.Visibility = 'Collapsed'
    }
}

function Update-PendingCount {
    $n = @($script:Items | Where-Object { $_.Available -and $_.Pending -ne $_.Current }).Count
    $uiPendingText.Text = if ($n -eq 0) { 'No pending changes' } elseif ($n -eq 1) { '1 pending change' } else { "$n pending changes" }
    $uiBtnApply.IsEnabled = ($n -gt 0)
    $uiBtnDiscard.IsEnabled = ($n -gt 0)
    $uiBtnApply.Content = if ($n -gt 0) { "Apply $n change(s)" } else { 'Apply changes' }
}

function Set-Pending($it, [string]$Value) {
    if ($script:Loading) { return }
    $it.Pending = $Value
    Update-RowState $it
    Update-PendingCount
}

function Update-AllUI {
    foreach ($it in $script:Items) { if ($it.Ui) { Set-UIValue $it } }
    Update-PendingCount
    Update-Status
}

# --- sections ----------------------------------------------------------------
function Add-GpuRow([string]$Path) {
    $it = New-GpuItem $Path
    if ($it.Ui) { return $it }
    $it.Current = Read-Item $it
    $it.Available = ($null -ne $it.Current)
    $it.Pending = $it.Current
    $body = $script:SectionBodies['graphics']
    $body.Children.Insert($body.Children.Count - 1, (New-Row $it))
    Set-UIValue $it
    return $it
}

function Build-Sections {
    $uiSectionsPanel.Children.Clear()
    $uiNavPanel.Children.Clear()
    foreach ($key in $Sections.Keys) {
        $card = New-Object Windows.Controls.Border
        $card.Background = Brush '#FFFFFF'
        $card.BorderBrush = Brush '#E4E7EB'
        $card.BorderThickness = '1'
        $card.CornerRadius = '10'
        $card.Padding = '22,18,22,8'
        $card.Margin = '0,0,0,16'

        $sp = New-Object Windows.Controls.StackPanel
        $sp.Children.Add((New-Text $Sections[$key][0] 18 '#1F2328' 'SemiBold')) | Out-Null
        $sub = New-Text $Sections[$key][1] 12.5 '#5E6672'
        $sub.Margin = '0,2,0,10'
        $sp.Children.Add($sub) | Out-Null

        if ($key -eq 'graphics') {
            $hint = New-Text 'Per-app GPU choice (Settings > System > Display > Graphics). "Power saving" runs the app on the integrated GPU so the dedicated GPU can power down completely.' 12 '#5E6672'
            $hint.Margin = '0,0,0,8'
            $sp.Children.Add($hint) | Out-Null
        }

        foreach ($it in $script:Items) {
            if ($it.Section -eq $key) { $sp.Children.Add((New-Row $it)) | Out-Null }
        }

        if ($key -eq 'graphics') {
            $add = New-Object Windows.Controls.Button
            $add.Style = $script:Win.FindResource('Btn')
            $add.Content = '+ Add another app...'
            $add.HorizontalAlignment = 'Left'
            $add.Margin = '0,10,0,10'
            $add.Add_Click({
                $dlg = New-Object Microsoft.Win32.OpenFileDialog
                $dlg.Filter = 'Programs (*.exe)|*.exe'
                $dlg.Title = 'Choose an app to run on the power-saving GPU'
                if ($dlg.ShowDialog($script:Win)) {
                    $it = Add-GpuRow $dlg.FileName
                    $it.Pending = '1'
                    Set-UIValue $it
                    Update-PendingCount
                }
            })
            $sp.Children.Add($add) | Out-Null
        }
        if ($key -eq 'display') {
            $link = New-Object Windows.Controls.Button
            $link.Style = $script:Win.FindResource('Btn')
            $link.Content = 'Open Windows display settings (Dynamic refresh rate, HDR, content-adaptive brightness)'
            $link.HorizontalAlignment = 'Left'
            $link.Margin = '0,10,0,10'
            $link.Add_Click({ Start-Process 'ms-settings:display-advanced' })
            $sp.Children.Add($link) | Out-Null
        }

        $card.Child = $sp
        $uiSectionsPanel.Children.Add($card) | Out-Null
        $script:SectionCards[$key] = $card
        $script:SectionBodies[$key] = $sp

        $nav = New-Object Windows.Controls.Button
        $nav.Style = $script:Win.FindResource('Nav')
        $nav.Content = $Sections[$key][0]
        $nav.Tag = $key
        $nav.Add_Click({
            $c = $script:SectionCards[$this.Tag]
            $pt = $c.TransformToAncestor($uiSectionsPanel).Transform((New-Object Windows.Point 0, 0))
            $uiScroller.ScrollToVerticalOffset($pt.Y)
        })
        $uiNavPanel.Children.Add($nav) | Out-Null
    }
}

function Invoke-WithBusy([scriptblock]$Action) {
    $script:Win.Cursor = [Windows.Input.Cursors]::Wait
    try { & $Action }
    catch { Write-Log "ERROR $($_.Exception.Message)" }
    finally { $script:Win.Cursor = $null }
    Update-AllUI
}

# --- wire up -----------------------------------------------------------------
Build-Sections

$uiBtnApply.Add_Click({ Invoke-WithBusy { [void](Invoke-Changes) } })
$uiBtnDiscard.Add_Click({
    foreach ($it in $script:Items) { $it.Pending = $it.Current }
    Update-AllUI
    Write-Log 'Pending changes discarded.'
})
$uiBtnMax.Add_Click({
    Invoke-WithBusy {
        Write-Log 'Applying preset: Optimize for battery'
        [void](Set-PresetPending 'MaxBattery')
        [void](Invoke-Changes)
    }
})
$uiBtnBalanced.Add_Click({
    Invoke-WithBusy {
        Write-Log 'Applying preset: Balanced saver'
        [void](Set-PresetPending 'Balanced')
        [void](Invoke-Changes)
    }
})
$uiBtnRestore.Add_Click({
    $r = [Windows.MessageBox]::Show($script:Win, 'Put back every setting Chill Mode changed to its original value?', 'Restore original', 'YesNo', 'Question')
    if ($r -eq 'Yes') { Invoke-WithBusy { Invoke-Restore } }
})
$uiBtnRescan.Add_Click({
    Invoke-WithBusy {
        Update-AllFromSystem
        Write-Log 'Re-read all settings from the system.'
    }
})

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(15)
$timer.Add_Tick({ Update-Status })
$timer.Start()

Update-AllUI
$avail = @($script:Items | Where-Object { $_.Available }).Count
Write-Log "$($script:AppName) $($script:AppVersion) ready - $avail of $($script:Items.Count) settings available on this device."

[void]$script:Win.ShowDialog()
$timer.Stop()
