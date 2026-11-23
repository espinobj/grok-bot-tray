# Pure decisions for Grok Bot Tray. No WinForms, no process launches.
# Dot-sourced by GrokBotTray.ps1 and by tests/policy.tests.ps1.

function Test-GbtCleanExit([object]$ExitCode) {
  # A deliberate window close is exit code 0 only. $null is unknown, not a clean close.
  # Do not use `-eq 0`: PowerShell treats '' -eq 0 as true.
  if ($null -eq $ExitCode) { return $false }
  if ($ExitCode -is [int] -or $ExitCode -is [long]) { return ([int64]$ExitCode -eq 0) }
  $n = 0
  if (-not [int]::TryParse(([string]$ExitCode).Trim(), [ref]$n)) { return $false }
  return ($n -eq 0)
}

function Test-GbtScanFresh {
  param([int64]$SignalStartedTicks, [datetime]$ExitSeenAt)
  # A scan counts only if it started at or after the exit. An in-flight scan from
  # before the exit must not be used to decide "no update, go ahead and relaunch".
  if ($SignalStartedTicks -le 0) { return $false }
  if ($ExitSeenAt -eq [datetime]::MinValue) { return $false }
  return ($SignalStartedTicks -ge $ExitSeenAt.ToUniversalTime().Ticks)
}

function Get-GbtExitDecision {
  <#
    What to do after the tracked app process has exited and nothing is running.
    reattach | wait | updating | stay-closed | relaunch-hidden
    Code 0 with no update stays closed (the window must not come back on its own).
    Any other code relaunches, but only after a post-exit update scan.
  #>
  param(
    [object]$ExitCode,
    [int]$ElapsedSec,
    [string]$Signal,
    [string]$FileSignal,
    [bool]$ExeChanged,
    [bool]$RunningNow,
    [bool]$ScanFresh,
    [int]$GraceCleanSec = 20,
    [int]$GraceCrashSec = 4
  )
  if ($RunningNow) { return 'reattach' }
  # File symptoms (missing, locked, just written) and a changed stamp do not need the
  # process scan. Installer-process signals do, so those wait until the scan is fresh.
  if ($ExeChanged -or $FileSignal) { return 'updating' }
  if (-not $ScanFresh) { return 'wait' }
  if ($Signal) { return 'updating' }
  $grace = if (Test-GbtCleanExit $ExitCode) { $GraceCleanSec } else { $GraceCrashSec }
  if ($ElapsedSec -lt $grace) { return 'wait' }
  if (Test-GbtCleanExit $ExitCode) { return 'stay-closed' }
  return 'relaunch-hidden'
}

function Get-GbtLaunchDecision {
  <#
    Whether Start-App may call Start-Process.
    skip-quitting | skip-in-flight | skip-already-running | skip-recent | start
  #>
  param(
    [bool]$Quitting,
    [bool]$InFlight,
    [bool]$TrackedAlive,
    [bool]$AnyRunning,
    [int]$SecondsSinceLaunch = -1,
    [int]$MinGapSec = 3
  )
  if ($Quitting) { return 'skip-quitting' }
  if ($InFlight) { return 'skip-in-flight' }
  if ($TrackedAlive -or $AnyRunning) { return 'skip-already-running' }
  if ($SecondsSinceLaunch -ge 0 -and $SecondsSinceLaunch -lt $MinGapSec) { return 'skip-recent' }
  return 'start'
}

function Get-GbtMissingDecision {
  <#
    Running state, but we have no tracked process object.
    running | exited | give-up | wait
    give-up does not relaunch. The old 30s path did, and that started a second copy.
  #>
  param(
    [bool]$TrackedAlive,
    [bool]$AnyRunning,
    [bool]$ExitPending,
    [int]$ElapsedSec,
    [int]$GiveUpSec = 30
  )
  if ($TrackedAlive -or $AnyRunning) { return 'running' }
  if ($ExitPending) { return 'exited' }
  if ($ElapsedSec -gt $GiveUpSec) { return 'give-up' }
  return 'wait'
}

function Get-GbtUpdateSignal {
  <#
    Same rules as the helper's historical update check.
    $Processes items have Name (Win32 style, includes .exe) and Path (may be empty).
    Returns a short reason, or $null.
  #>
  param(
    [Parameter(Mandatory)][string]$Exe,
    [Parameter(Mandatory)][string]$InstallDir,
    [Parameter(Mandatory)][string]$ProcessName,
    [int]$QuietSec = 12,
    [object[]]$Processes = @()
  )
  $prefix = $InstallDir.TrimEnd('\') + '\'
  if (-not (Test-Path -LiteralPath $Exe)) { return 'app exe is missing' }
  try {
    $f = Get-Item -LiteralPath $Exe -ErrorAction Stop
    if (((Get-Date) - $f.LastWriteTime).TotalSeconds -lt $QuietSec) { return 'app exe was just written' }
  } catch { return 'app exe is missing' }
  $opened = $null
  try { $opened = [System.IO.File]::Open($Exe, 'Open', 'Read', 'Read') }
  catch { return 'app exe is locked for writing' }
  finally { if ($opened) { $opened.Dispose() } }

  $appExe = "$ProcessName.exe"
  foreach ($p in @($Processes)) {
    if ($null -eq $p) { continue }
    $n = [string]$p.Name
    $path = [string]$p.Path
    if (-not $n) { continue }
    if ($n -ieq $appExe) { continue }
    if ($path -and $path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return "$n is running from the app folder" }
    if ($n -ieq 'installer.exe' -and (-not $path -or $path -match '\\[^\\]+-updater\\')) { return "updater $n is running" }
    if ($n -imatch '^(Au_|Un_A|Un)\.exe$') { return "installer helper $n is running" }
    if ($n -ieq "Uninstall $ProcessName.exe") { return "$n is running" }
    if ($n -like "$ProcessName*Setup*.exe" -or $n -like "$ProcessName*Installer*.exe") { return "$n is running" }
    if ($n -ieq 'Update.exe' -and $path -and ($path -match ('Squirrel|' + [regex]::Escape($ProcessName)))) { return "Squirrel $n is running" }
  }
  return $null
}
