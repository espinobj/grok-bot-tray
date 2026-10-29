# Grok Bot Tray - unofficial community helper. Not affiliated with or endorsed by xAI.
# Keeps the Grok Bot desktop app in the notification area (tray) and restarts it if it
# crashes, but waits quietly while the app is updating instead of relaunching mid-update.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class GBTWin {
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
  [StructLayout(LayoutKind.Sequential, Pack=4)] public struct PK { public Guid f; public uint p; }
  [StructLayout(LayoutKind.Explicit, Size=24)] public struct PV { [FieldOffset(0)] public ushort vt; [FieldOffset(8)] public IntPtr p; }
  [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IPS { int GetCount(out uint c); int GetAt(uint i, out PK k); int GetValue(ref PK k, out PV v); int SetValue(ref PK k, ref PV v); int Commit(); }
  [DllImport("shell32.dll")] static extern int SHGetPropertyStoreForWindow(IntPtr h, ref Guid g, [MarshalAs(UnmanagedType.Interface)] out IPS s);
  // Give the app window the pinned shortcut's AppUserModelID so it groups under the helper pin
  // (the app's own process ID, e.g. electron.app.Grok Bot, differs from its shortcut ID).
  static int SetStr(IPS s, uint pid, string val) {
    PK k = new PK(); k.f = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"); k.p = pid;
    PV v = new PV(); v.vt = 31; v.p = Marshal.StringToCoTaskMemUni(val);
    try { return s.SetValue(ref k, ref v); } finally { Marshal.FreeCoTaskMem(v.p); }
  }
  // v1.2.3: tag new app windows the moment they are created/shown (WinEvent hook), so a second
  // stock-icon button never flashes up. Also sets the relaunch icon to the helper icon.
  public static string HookAumid, HookIcon, HookCmd, HookProc; public static int HookCount;
  delegate void WinEventProc(IntPtr hook, uint ev, IntPtr h, int idObj, int idChild, uint thread, uint time);
  [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr mod, WinEventProc cb, uint pid, uint tid, uint flags);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint f);
  static WinEventProc cb; static IntPtr hook;
  static System.Collections.Generic.Dictionary<uint, bool> pids = new System.Collections.Generic.Dictionary<uint, bool>();
  public static bool StartHook() {
    if (hook != IntPtr.Zero) return true;
    cb = new WinEventProc(OnEvent);
    hook = SetWinEventHook(0x8000, 0x8002, IntPtr.Zero, cb, 0, 0, 0 /*OUTOFCONTEXT*/);
    return hook != IntPtr.Zero;
  }
  static void OnEvent(IntPtr hk, uint ev, IntPtr h, int idObj, int idChild, uint thread, uint time) {
    try {
      if (idObj != 0 || idChild != 0 || h == IntPtr.Zero || HookAumid == null) return;
      if (GetAncestor(h, 2 /*GA_ROOT*/) != h) return;
      uint pid; GetWindowThreadProcessId(h, out pid); bool mine;
      if (!pids.TryGetValue(pid, out mine)) {
        try { mine = string.Equals(System.Diagnostics.Process.GetProcessById((int)pid).ProcessName, HookProc, StringComparison.OrdinalIgnoreCase); } catch { mine = false; }
        if (pids.Count > 500) pids.Clear(); pids[pid] = mine;
      }
      if (mine && TagWindow(h) == 0) HookCount++;
    } catch { }
  }
  public static int TagWindow(IntPtr h) {
    Guid g = typeof(IPS).GUID; IPS s; int hr = SHGetPropertyStoreForWindow(h, ref g, out s); if (hr != 0) return hr;
    try {
      PK k = new PK(); k.f = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"); k.p = 5;
      PV cur; if (s.GetValue(ref k, out cur) == 0 && cur.vt == 31 && Marshal.PtrToStringUni(cur.p) == HookAumid) return 1;
      if (HookIcon != null && HookCmd != null) { SetStr(s, 2, HookCmd); SetStr(s, 4, "Grok Bot"); SetStr(s, 3, HookIcon + ",0"); }
      return SetStr(s, 5, HookAumid);
    } finally { Marshal.ReleaseComObject(s); }
  }
  public static int SetWindowAumid(IntPtr h, string id) {
    Guid g = typeof(IPS).GUID; IPS s; int hr = SHGetPropertyStoreForWindow(h, ref g, out s); if (hr != 0) return hr;
    try {
      PK k = new PK(); k.f = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"); k.p = 5;
      PV cur; if (s.GetValue(ref k, out cur) == 0 && cur.vt == 31 && Marshal.PtrToStringUni(cur.p) == id) return 1;
      PV v = new PV(); v.vt = 31; v.p = Marshal.StringToCoTaskMemUni(id);
      try { return s.SetValue(ref k, ref v); } finally { Marshal.FreeCoTaskMem(v.p); }
    } finally { Marshal.ReleaseComObject(s); }
  }
}
"@

# --- single instance: a second launch just asks the running helper to show the app ---
$showEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, 'Local\GrokBotTrayShow')
$mutex = New-Object System.Threading.Mutex($false, 'Local\GrokBotTrayWrapper')
if (-not $mutex.WaitOne(0)) { $showEvent.Set() | Out-Null; exit }

$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$logFile = Join-Path $dir 'tray.log'
function Log([string]$msg) {
  try {
    if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 512KB) { Move-Item $logFile "$logFile.1" -Force }
    Add-Content -Path $logFile -Value ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $msg)
  } catch {}
}

# --- config written by install.ps1 ---
$cfg = $null
try { $cfg = Get-Content (Join-Path $dir 'config.json') -Raw | ConvertFrom-Json } catch {}
if ($cfg -and $cfg.exe) { $exe = $cfg.exe }
elseif (Test-Path (Join-Path $dir 'exe.txt')) { $exe = (Get-Content (Join-Path $dir 'exe.txt') -Raw).Trim() }
else { Log 'No config.json; run install.ps1 first.'; exit 1 }
$pname = [IO.Path]::GetFileNameWithoutExtension($exe)
$installDir = Split-Path -Parent $exe
$Version = '0.0.0'
try { $Version = (Get-Content (Join-Path $dir 'VERSION') -Raw).Trim() } catch {}
$RepoSlug = 'espinobj/grok-bot-tray'
$RepoUrl = "https://github.com/$RepoSlug"
$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Grok Bot Tray.lnk'
$settingsFile = Join-Path $dir 'settings.json'
function Get-Settings {
  $st = $null; try { $st = Get-Content $settingsFile -Raw | ConvertFrom-Json } catch {}
  if (-not $st) { $st = [pscustomobject]@{} }
  if ($null -eq $st.autoUpdate) { $st | Add-Member -NotePropertyName autoUpdate -NotePropertyValue $true -Force }
  return $st
}
function Save-Settings($st) { try { $st | ConvertTo-Json | Set-Content $settingsFile -Encoding UTF8 } catch { Log "Saving settings failed: $_" } }
$script:settings = Get-Settings
Log "Helper v$Version started for $exe"

# --- tunables ---
$GraceCleanExitSec = 20    # after a clean exit (code 0), watch this long for an updater before relaunching
$GraceCrashSec     = 4     # after a crash, relaunch after this long (if no updater shows up)
$QuietAfterUpdateSec = 12  # updater gone and exe untouched this long = update finished
$WaitForSelfRestartSec = 45 # after an update, give the installer this long to start the app itself
$MaxUpdateMinutes  = 20    # never wait longer than this for an update
$MaxRelaunches = 3; $RelaunchWindowMin = 10

# --- state ---
$script:h = [IntPtr]::Zero
$script:main = $null           # System.Diagnostics.Process of the app's main process
$script:state = 'Running'      # Running | Exited | Updating | AfterUpdate | Stopped
$script:since = Get-Date
$script:exitCode = $null
$script:hideNext = $false
$script:quitting = $false
$script:launches = New-Object System.Collections.ArrayList
$script:lastSignalCheck = [DateTime]::MinValue
$script:exeStamp = $null

function Get-ExeStamp {
  try { $f = Get-Item -LiteralPath $exe; return "{0}|{1}|{2}" -f $f.Length, $f.LastWriteTimeUtc.Ticks, $f.VersionInfo.FileVersion } catch { return $null }
}
function Find-Win { foreach ($p in @(Get-Process -Name $pname -ErrorAction SilentlyContinue)) { if ($p.MainWindowHandle -ne 0) { return $p.MainWindowHandle } }; return [IntPtr]::Zero }
function Test-Running { [bool](Get-Process -Name $pname -ErrorAction SilentlyContinue) }

function Attach-Main {
  # The Electron main process is the one without a --type= switch.
  try {
    $q = "Name='" + ($pname + '.exe').Replace("'", "''") + "'"
    $mp = Get-CimInstance Win32_Process -Filter $q | Where-Object { $_.CommandLine -notmatch '--type=' } | Select-Object -First 1
    if ($mp) {
      $p = Get-Process -Id $mp.ProcessId -ErrorAction Stop
      $null = $p.Handle   # open a handle now so ExitCode is readable after it exits
      $script:main = $p
      $script:exeStamp = Get-ExeStamp
      return $true
    }
  } catch {}
  $script:main = $null
  return $false
}

function Get-UpdateSignal {
  # Returns a short reason string when an update/install looks in progress, else $null.
  try {
    $f = Get-Item -LiteralPath $exe -ErrorAction Stop
    if (((Get-Date) - $f.LastWriteTime).TotalSeconds -lt $QuietAfterUpdateSec) { return 'app exe was just written' }
    try { $fs = [IO.File]::Open($exe, 'Open', 'Read', 'Read'); $fs.Close() } catch { return 'app exe is locked for writing' }
  } catch { return 'app exe is missing' }
  try {
    foreach ($p in @(Get-CimInstance Win32_Process -Property Name, ExecutablePath, ProcessId)) {
      $n = $p.Name; $path = $p.ExecutablePath
      if ($n -ieq "$pname.exe") { continue }
      if ($path -and $path.StartsWith($installDir + '\', [StringComparison]::OrdinalIgnoreCase)) { return "$n is running from the app folder" }
      if ($n -ieq 'installer.exe' -and (-not $path -or $path -match '\\[^\\]+-updater\\')) { return "updater $n is running" }
      if ($n -imatch '^(Au_|Un_A|Un)\.exe$') { return "installer helper $n is running" }
      if ($n -ieq "Uninstall $pname.exe") { return "$n is running" }
      if ($n -like "$pname*Setup*.exe" -or $n -like "$pname*Installer*.exe") { return "$n is running" }
      if ($n -ieq 'Update.exe' -and $path -and $path -match 'Squirrel|' + [regex]::Escape($pname)) { return "Squirrel $n is running" }
    }
  } catch {}
  return $null
}

function Start-App([bool]$hidden) {
  $now = Get-Date
  while ($script:launches.Count -gt 0 -and ($now - $script:launches[0]).TotalMinutes -gt $RelaunchWindowMin) { $script:launches.RemoveAt(0) }
  if ($script:launches.Count -ge $MaxRelaunches) {
    Log "Not relaunching: $MaxRelaunches launches in $RelaunchWindowMin min. Waiting for the user."
    $script:state = 'Stopped'
    $ni.Text = 'Grok Bot (stopped - click to start)'
    $ni.ShowBalloonTip(5000, 'Grok Bot', 'Grok Bot keeps closing, so it was not restarted. Click the tray icon to start it.', 'Warning')
    return
  }
  [void]$script:launches.Add($now)
  $script:hideNext = $hidden
  $script:h = [IntPtr]::Zero
  Log "Starting app (hidden=$hidden)"
  try { Start-Process -FilePath $exe -WorkingDirectory $installDir } catch { Log "Start failed: $_" }
  $script:state = 'Running'; $script:since = $now; $script:main = $null
}

function Show-App {
  if ($script:state -eq 'Updating' -or $script:state -eq 'AfterUpdate') {
    $ni.ShowBalloonTip(3000, 'Grok Bot', 'Grok Bot is updating. It will come back when the update finishes.', 'Info'); return
  }
  if (-not (Test-Running)) { $script:launches.Clear(); Start-App $false; return }
  if ($script:h -eq 0 -or -not [GBTWin]::IsWindow($script:h)) { $script:h = Find-Win }
  if ($script:h -ne 0) { [GBTWin]::ShowWindow($script:h, 9) | Out-Null; [GBTWin]::SetForegroundWindow($script:h) | Out-Null }
  else { Start-Process -FilePath $exe -WorkingDirectory $installDir }   # app is single-instance; this surfaces it
}
function Hide-App {
  if ($script:h -eq 0 -or -not [GBTWin]::IsWindow($script:h)) { $script:h = Find-Win }
  if ($script:h -ne 0) { [GBTWin]::ShowWindow($script:h, 0) | Out-Null }
}
function Quit-All {
  $script:quitting = $true
  Log 'Quit requested from tray menu'
  if ($script:h -ne 0) { [GBTWin]::ShowWindow($script:h, 9) | Out-Null }
  foreach ($p in @(Get-Process -Name $pname -ErrorAction SilentlyContinue)) { try { $p.CloseMainWindow() | Out-Null } catch {} }
  $deadline = (Get-Date).AddSeconds(8)
  while ((Test-Running) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
  if ($script:main -and -not $script:main.HasExited) { & taskkill.exe /PID $script:main.Id /T | Out-Null; Start-Sleep 3 }
  if (Test-Running) { Get-Process -Name $pname -ErrorAction SilentlyContinue | Stop-Process -Force }
  $ni.Visible = $false
  [System.Windows.Forms.Application]::Exit()
}

function Sync-Grouping {
  # One taskbar button: tag the app window with the pin's AppUserModelID (window property only; app files untouched).
  if (-not $cfg -or -not $cfg.aumid -or $script:h -eq 0 -or -not [GBTWin]::IsWindow($script:h)) { return }
  if ($script:groupedH -eq $script:h) { return }
  try {
    $hr = [GBTWin]::TagWindow($script:h)
    if ($hr -ge 0) { $script:groupedH = $script:h; if ($hr -eq 0) { Log "Grouped the app window under the pin ($($cfg.aumid))" } }
    else { Log ("Grouping failed: 0x{0:X8}" -f $hr); $script:groupedH = $script:h }
  } catch { Log "Grouping failed: $_"; $script:groupedH = $script:h }
}
$script:groupedH = [IntPtr]::Zero

function Get-LnkIcon {
  # Shortcut icon: versioned file from config.json (avoids stale Explorer icon cache), else the tray icon.
  if ($cfg -and $cfg.icon -and (Test-Path -LiteralPath $cfg.icon)) { return [string]$cfg.icon }
  return (Join-Path $dir 'GrokBotTray.ico')
}

function Repair-Pin {
  # Updates can rewrite shortcuts. Point the taskbar pin back at the helper with the badged icon.
  if (-not $cfg -or -not $cfg.pinPath -or -not (Test-Path -LiteralPath $cfg.pinPath)) { return }
  try {
    $ws = New-Object -ComObject WScript.Shell
    $s = $ws.CreateShortcut($cfg.pinPath)
    $launcher = Join-Path $dir 'Grok Bot Tray.exe'
    $ico = Get-LnkIcon
    if ($s.TargetPath -ne $launcher -or $s.IconLocation -ne "$ico,0") {
      $s.TargetPath = $launcher; $s.WorkingDirectory = $dir; $s.IconLocation = "$ico,0"; $s.Save()
      Log 'Taskbar pin repointed at the helper after an update'
    }
  } catch { Log "Repair-Pin failed: $_" }
}

function Set-Startup([bool]$on) {
  try {
    if ($on) {
      $ws = New-Object -ComObject WScript.Shell
      $s = $ws.CreateShortcut($startupLnk)
      $s.TargetPath = Join-Path $dir 'Grok Bot Tray.exe'; $s.WorkingDirectory = $dir
      $s.IconLocation = (Get-LnkIcon) + ',0'; $s.Description = 'Grok Bot in the notification area (unofficial helper)'
      $s.Save(); Log 'Start with Windows: on'
    } else { Remove-Item -LiteralPath $startupLnk -Force -ErrorAction SilentlyContinue; Log 'Start with Windows: off' }
  } catch { Log "Set-Startup failed: $_"; $ni.ShowBalloonTip(4000, 'Grok Bot Tray', "Could not change the startup setting: $_", 'Error') }
}

function ConvertTo-Ver([string]$t) { $t = ($t -replace '^[vV]', '').Trim(); $v = $null; if ([version]::TryParse($t, [ref]$v)) { return $v }; return $null }
$AutoCheckDelaySec = 60; $AutoCheckEveryHours = 24
function Get-DevSource {
  # DEV/TEST ONLY: settings.json "devUpdateSource" = local package folder or .zip used instead of GitHub.
  $p = $script:settings.devUpdateSource
  if ($p -and (Test-Path -LiteralPath $p)) { return (Resolve-Path -LiteralPath $p).Path }
  return $null
}
function Expand-DevSource([string]$p, [string]$into) {
  if ($p -like '*.zip') { Expand-Archive -Path $p -DestinationPath $into -Force }
  else { New-Item -ItemType Directory -Force -Path $into | Out-Null; Copy-Item -LiteralPath $p -Destination $into -Recurse -Force }
  return @(Get-ChildItem $into -Directory)[0].FullName
}
function Get-Latest {
  $dev = Get-DevSource
  if ($dev) {
    try {
      $t = Join-Path $env:TEMP ('GrokBotTray-devpeek-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
      $pkg = Expand-DevSource $dev $t
      $v = ConvertTo-Ver ((Get-Content (Join-Path $pkg 'VERSION') -Raw).Trim())
      Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue
      Log "DEV update source in use: $dev (v$v)"
      if ($v) { return @{ Version = $v; Ref = 'dev'; Dev = $dev } }
    } catch { Log "DEV update source unreadable: $_" }
    return $null
  }
  # Newest of: latest release, tags, and vX.Y.Z branches. Returns @{ Version; Ref } or $null.
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $h = @{ 'User-Agent' = "GrokBotTray/$Version"; 'Accept' = 'application/vnd.github+json' }
  $names = @()
  try { $names += (Invoke-RestMethod -Uri "https://api.github.com/repos/$RepoSlug/releases/latest" -Headers $h -TimeoutSec 15).tag_name } catch {}
  try { $names += @((Invoke-RestMethod -Uri "https://api.github.com/repos/$RepoSlug/tags" -Headers $h -TimeoutSec 15) | ForEach-Object { $_ } | ForEach-Object { $_.name }) } catch {}
  try { $names += @((Invoke-RestMethod -Uri "https://api.github.com/repos/$RepoSlug/branches" -Headers $h -TimeoutSec 15) | ForEach-Object { $_ } | ForEach-Object { $_.name } | Where-Object { $_ -match '^v\d+\.\d+' }) } catch {}
  $best = $null
  foreach ($n in $names) { $v = ConvertTo-Ver $n; if ($v -and (-not $best -or $v -gt $best.Version)) { $best = @{ Version = $v; Ref = $n } } }
  return $best
}
function Get-LatestVersion { $l = Get-Latest; if ($l) { return $l.Version }; return $null }

function Install-Update($latest, [bool]$manual = $false) {
  if ($script:installing -and ((Get-Date) - $script:installing).TotalMinutes -lt 5) { Log 'Update already in progress'; return $false }
  # Download the ref zip, verify it, then hand off to a detached updater (it backs up, installs, rolls back on failure).
  if ($script:state -in 'Updating', 'AfterUpdate' -or (Get-UpdateSignal)) { Log 'Helper update postponed: Grok Bot itself is updating'; return $false }
  $want = $latest.Version.ToString()
  $ProgressPreference = 'SilentlyContinue'
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  try {
    $tmp = Join-Path $env:TEMP ("GrokBotTray-update-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    if ($latest.Dev) { $pkg = Expand-DevSource $latest.Dev (Join-Path $tmp 'x'); Log "Using DEV package $($latest.Dev)" }
    else {
      $zip = Join-Path $tmp 'pkg.zip'
      $url = "https://github.com/$RepoSlug/archive/$($latest.Ref).zip"
      Log "Downloading $url"
      Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 60 -Headers @{ 'User-Agent' = "GrokBotTray/$Version" }
      Expand-Archive -Path $zip -DestinationPath (Join-Path $tmp 'x') -Force
      $pkg = @(Get-ChildItem (Join-Path $tmp 'x') -Directory)[0].FullName
    }
    foreach ($f in 'VERSION', 'install.ps1', 'src\GrokBotTray.ps1', 'src\update.ps1', 'src\launcher.cs') {
      if (-not (Test-Path (Join-Path $pkg $f))) { throw "package is missing $f" }
    }
    $pv = (Get-Content (Join-Path $pkg 'VERSION') -Raw).Trim()
    if ($pv -ne $want) { throw "package VERSION is $pv, expected $want" }
    # Run the updater from the NEW package (copied out of the install dir so the backup/restore can replace files freely).
    $upd = Join-Path $tmp 'update.ps1'; Copy-Item (Join-Path $pkg 'src\update.ps1') $upd -Force
    Log "Package v$pv verified; starting updater"
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$upd`"", '-Src', "`"$pkg`"", '-Expected', $pv, '-Dest', "`"$dir`"")
    $script:installing = Get-Date
    if ($manual) { $ni.ShowBalloonTip(3000, 'Grok Bot Tray', "Updating the tray helper to v$pv...", 'Info') }
    return $true
  } catch {
    Log "Helper update failed before install: $_"
    # Automatic attempts only log (no alert); they retry on the next daily check.
    if ($manual) { $ni.ShowBalloonTip(4000, 'Grok Bot Tray', "Update failed: $_", 'Warning') }
    return $false
  }
}

function Invoke-AutoCheck {
  $script:settings | Add-Member -NotePropertyName lastCheck -NotePropertyValue (Get-Date).ToString('s') -Force
  Save-Settings $script:settings
  $latest = Get-Latest
  $cur = ConvertTo-Ver $Version
  if (-not $latest) { Log 'Auto-update check: GitHub not reachable'; return }
  Log "Auto-update check: installed $Version, latest $($latest.Version) ($($latest.Ref))"
  if ($cur -and $latest.Version -le $cur) { return }
  if ($script:settings.failedVersion -and $script:settings.failedVersion -eq $latest.Version.ToString()) { Log "Skipping v$($latest.Version): it failed and was rolled back before. Use Check for updates to retry."; return }
  [void](Install-Update $latest)
}

function Check-Updates {
  $cur = ConvertTo-Ver $Version
  $latest = Get-Latest
  if (-not $latest) { $ni.ShowBalloonTip(4000, 'Grok Bot Tray', 'Could not reach GitHub to check for updates.', 'Warning'); Log 'Update check failed'; return }
  Log "Update check: installed $Version, latest $($latest.Version)"
  if ($cur -and $latest.Version -le $cur) { $ni.ShowBalloonTip(4000, 'Grok Bot Tray', "You have the latest version (v$Version).", 'Info'); return }
  $r = [System.Windows.Forms.MessageBox]::Show("Grok Bot Tray v$($latest.Version) is available (you have v$Version).`n`nYes = install now`nNo = open the GitHub page`nCancel = later", 'Grok Bot Tray update', 'YesNoCancel', 'Information')
  if ($r -eq 'Yes') { [void](Install-Update $latest $true) } elseif ($r -eq 'No') { Start-Process $RepoUrl }
}

# --- tray icon (drawn at the exact small-icon size so the badge stays visible) ---
$ni = New-Object System.Windows.Forms.NotifyIcon
try { $ni.Icon = New-Object System.Drawing.Icon((Join-Path $dir 'GrokBotTray.ico'), [System.Windows.Forms.SystemInformation]::SmallIconSize) }
catch { Log "Icon load failed: $_"; $ni.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($exe) }
$ni.Text = 'Grok Bot'
$ni.Visible = $true
$cm = New-Object System.Windows.Forms.ContextMenuStrip
$hdr = $cm.Items.Add("Grok Bot Tray v$Version"); $hdr.Enabled = $false
$cm.Items.Add('-') | Out-Null
$cm.Items.Add('Show').add_Click({ Show-App }) | Out-Null
$cm.Items.Add('Hide').add_Click({ Hide-App }) | Out-Null
$cm.Items.Add('-') | Out-Null
$miStartup = New-Object System.Windows.Forms.ToolStripMenuItem('Start with Windows')
$miStartup.CheckOnClick = $false
$miStartup.add_Click({ Set-Startup (-not (Test-Path -LiteralPath $startupLnk)) })
$cm.Items.Add($miStartup) | Out-Null
$cm.Items.Add('Open log').add_Click({ if (-not (Test-Path $logFile)) { Log 'Log opened' }; Start-Process notepad.exe -ArgumentList ('"' + $logFile + '"') }) | Out-Null
$miAuto = New-Object System.Windows.Forms.ToolStripMenuItem('Auto-update')
$miAuto.add_Click({ $script:settings.autoUpdate = -not [bool]$script:settings.autoUpdate; Save-Settings $script:settings; Log "Auto-update: $($script:settings.autoUpdate)" })
$cm.Items.Add($miAuto) | Out-Null
$cm.Items.Add('Check for updates').add_Click({ Check-Updates }) | Out-Null
$cm.add_Opening({ $miStartup.Checked = Test-Path -LiteralPath $startupLnk; $miAuto.Checked = [bool]$script:settings.autoUpdate })
$cm.Items.Add('-') | Out-Null
$cm.Items.Add('Quit Grok Bot').add_Click({ Quit-All }) | Out-Null
$ni.ContextMenuStrip = $cm
$ni.add_MouseClick({ param($s, $e)
  if ($e.Button -eq 'Left') {
    if ($script:state -eq 'Stopped') { $script:launches.Clear(); Start-App $false; return }
    if ($script:h -ne 0 -and [GBTWin]::IsWindow($script:h) -and [GBTWin]::IsWindowVisible($script:h) -and -not [GBTWin]::IsIconic($script:h)) { Hide-App } else { Show-App }
  } })

if (Test-Running) { [void](Attach-Main) } else { Start-App $false }

$resFile = Join-Path $dir 'update-result.json'
function Show-UpdateResult {
  # The updater writes this after it has verified the new helper, so poll for it.
  if (-not (Test-Path $resFile)) { return }
  try {
    $res = Get-Content $resFile -Raw | ConvertFrom-Json
    if ($res.ok) { $ni.ShowBalloonTip(5000, 'Grok Bot Tray updated', "Now running v$Version. $($res.message).", 'Info') }
    else { $ni.ShowBalloonTip(6000, 'Grok Bot Tray update failed', "$($res.message). See Open log.", 'Warning') }
    Log "Update result: $($res.message)"
  } catch {}
  Remove-Item $resFile -Force -ErrorAction SilentlyContinue
}
$script:nextAutoCheck = (Get-Date).AddSeconds($AutoCheckDelaySec)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.add_Tick({
  try {
    if ($script:quitting) { return }
    if ($showEvent.WaitOne(0)) { $script:hideNext = $false; Show-App }
    $now = Get-Date
    Show-UpdateResult
    Sync-Grouping
    if ($now -ge $script:nextAutoCheck) {
      $script:nextAutoCheck = $now.AddHours($AutoCheckEveryHours)
      if ($script:settings.autoUpdate) {
        if ($script:state -in 'Updating', 'AfterUpdate') { $script:nextAutoCheck = $now.AddMinutes(10); Log 'Auto-update check postponed: Grok Bot is updating' }
        else { Invoke-AutoCheck }
      }
    }
    switch ($script:state) {
      'Running' {
        $alive = $false
        if ($script:main) { $alive = -not $script:main.HasExited } else { $alive = Test-Running; if ($alive) { [void](Attach-Main) } }
        if (-not $alive -and $script:main) {
          try { $script:exitCode = $script:main.ExitCode } catch { $script:exitCode = $null }
          $script:main = $null
          if (Test-Running) { [void](Attach-Main); return }   # another instance took over
          Log "App exited (code=$($script:exitCode)); watching for an update before doing anything"
          $script:state = 'Exited'; $script:since = $now; $script:h = [IntPtr]::Zero
          $ni.Text = 'Grok Bot (closed)'
          return
        }
        if (-not $alive) {
          if (($now - $script:since).TotalSeconds -gt 30) { $script:state = 'Exited'; $script:since = $now; $script:exitCode = $null }
          return
        }
        if ($script:h -eq 0 -or -not [GBTWin]::IsWindow($script:h)) {
          $w = Find-Win
          if ($w -ne 0) { $script:h = $w; if ($script:hideNext) { [GBTWin]::ShowWindow($w, 0) | Out-Null; $script:hideNext = $false } }
        }
        # minimize = hide to tray
        if ($script:h -ne 0 -and [GBTWin]::IsIconic($script:h) -and [GBTWin]::IsWindowVisible($script:h)) { [GBTWin]::ShowWindow($script:h, 0) | Out-Null }
        if ($ni.Text -ne 'Grok Bot') { $ni.Text = 'Grok Bot' }
      }
      'Exited' {
        if (Test-Running) { Log 'App is running again (started elsewhere); reattached'; [void](Attach-Main); $script:state = 'Running'; $script:since = $now; return }
        if (($now - $script:lastSignalCheck).TotalSeconds -lt 2) { return }
        $script:lastSignalCheck = $now
        $sig = Get-UpdateSignal
        $stamp = Get-ExeStamp
        if (-not $sig -and $script:exeStamp -and $stamp -and $stamp -ne $script:exeStamp) { $sig = 'app exe changed (new version)' }
        if ($sig) {
          Log "Update detected: $sig. Waiting for it to finish."
          $script:state = 'Updating'; $script:since = $now; $ni.Text = 'Grok Bot (updating...)'; return
        }
        $grace = if ($script:exitCode -eq 0) { $GraceCleanExitSec } else { $GraceCrashSec }
        if (($now - $script:since).TotalSeconds -ge $grace) { Start-App $true }
      }
      'Updating' {
        if (($now - $script:lastSignalCheck).TotalSeconds -lt 2) { return }
        $script:lastSignalCheck = $now
        $sig = Get-UpdateSignal
        if ($sig) {
          $script:quietSince = $null
          if (($now - $script:since).TotalMinutes -gt $MaxUpdateMinutes) { Log "Update still running after $MaxUpdateMinutes min ($sig); giving up waiting"; $script:state = 'AfterUpdate'; $script:since = $now.AddSeconds(-$WaitForSelfRestartSec) }
          return
        }
        if (-not $script:quietSince) { $script:quietSince = $now; return }
        if (($now - $script:quietSince).TotalSeconds -ge $QuietAfterUpdateSec) {
          Log 'Update finished.'
          Repair-Pin
          $script:quietSince = $null
          $script:state = 'AfterUpdate'; $script:since = $now
        }
      }
      'AfterUpdate' {
        if (Test-Running) { Log 'App restarted after the update; reattached'; [void](Attach-Main); $script:launches.Clear(); $script:state = 'Running'; $script:since = $now; $ni.Text = 'Grok Bot'; return }
        if (($now - $script:since).TotalSeconds -ge $WaitForSelfRestartSec) {
          if (Get-UpdateSignal) { $script:state = 'Updating'; $script:since = $now; return }
          $script:launches.Clear(); Start-App $false
        }
      }
      'Stopped' {
        if (Test-Running) { [void](Attach-Main); $script:state = 'Running'; $ni.Text = 'Grok Bot' }
      }
    }
  } catch { Log "Tick error: $_" }
})
if ($cfg -and $cfg.aumid) {
  [GBTWin]::HookAumid = [string]$cfg.aumid; [GBTWin]::HookProc = $pname
  [GBTWin]::HookCmd = '"' + (Join-Path $dir 'Grok Bot Tray.exe') + '"'; [GBTWin]::HookIcon = (Get-LnkIcon)
  try { if ([GBTWin]::StartHook()) { Log 'Window hook on: new Grok Bot windows group under the pin at once' } else { Log 'Window hook unavailable; grouping falls back to the timer' } } catch { Log "Window hook failed: $_" }
}
$timer.Start()
try { [System.Windows.Forms.Application]::Run() } catch { Log "Fatal: $_" } finally { $ni.Visible = $false; $ni.Dispose(); Log 'Helper stopped' }
