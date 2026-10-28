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
Log "Helper started for $exe"

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

function Repair-Pin {
  # Updates can rewrite shortcuts. Point the taskbar pin back at the helper with the badged icon.
  if (-not $cfg -or -not $cfg.pinPath -or -not (Test-Path -LiteralPath $cfg.pinPath)) { return }
  try {
    $ws = New-Object -ComObject WScript.Shell
    $s = $ws.CreateShortcut($cfg.pinPath)
    $launcher = Join-Path $dir 'Grok Bot Tray.exe'
    $ico = Join-Path $dir 'GrokBotTray.ico'
    if ($s.TargetPath -ne $launcher -or $s.IconLocation -ne "$ico,0") {
      $s.TargetPath = $launcher; $s.WorkingDirectory = $dir; $s.IconLocation = "$ico,0"; $s.Save()
      Log 'Taskbar pin repointed at the helper after an update'
    }
  } catch { Log "Repair-Pin failed: $_" }
}

# --- tray icon (drawn at the exact small-icon size so the badge stays visible) ---
$ni = New-Object System.Windows.Forms.NotifyIcon
try { $ni.Icon = New-Object System.Drawing.Icon((Join-Path $dir 'GrokBotTray.ico'), [System.Windows.Forms.SystemInformation]::SmallIconSize) }
catch { Log "Icon load failed: $_"; $ni.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($exe) }
$ni.Text = 'Grok Bot'
$ni.Visible = $true
$cm = New-Object System.Windows.Forms.ContextMenuStrip
$cm.Items.Add('Show').add_Click({ Show-App }) | Out-Null
$cm.Items.Add('Hide').add_Click({ Hide-App }) | Out-Null
$cm.Items.Add('-') | Out-Null
$cm.Items.Add('Quit Grok Bot').add_Click({ Quit-All }) | Out-Null
$ni.ContextMenuStrip = $cm
$ni.add_MouseClick({ param($s, $e)
  if ($e.Button -eq 'Left') {
    if ($script:state -eq 'Stopped') { $script:launches.Clear(); Start-App $false; return }
    if ($script:h -ne 0 -and [GBTWin]::IsWindow($script:h) -and [GBTWin]::IsWindowVisible($script:h) -and -not [GBTWin]::IsIconic($script:h)) { Hide-App } else { Show-App }
  } })

if (Test-Running) { [void](Attach-Main) } else { Start-App $false }

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.add_Tick({
  try {
    if ($script:quitting) { return }
    if ($showEvent.WaitOne(0)) { $script:hideNext = $false; Show-App }
    $now = Get-Date
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
$timer.Start()
try { [System.Windows.Forms.Application]::Run() } catch { Log "Fatal: $_" } finally { $ni.Visible = $false; $ni.Dispose(); Log 'Helper stopped' }
