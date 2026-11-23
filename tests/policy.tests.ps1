# State-machine tests for Grok Bot Tray. No Windows UI required.
# Run: pwsh -NoProfile -File tests/policy.tests.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\src\policy.ps1')
$script:fail = 0
function Assert([bool]$cond, [string]$name) {
  if ($cond) { Write-Host "PASS $name" }
  else { Write-Host "FAIL $name"; $script:fail++ }
}
function Decide($code, $elapsed, $extra) {
  $p = @{ ExitCode = $code; ElapsedSec = $elapsed; ScanFresh = $true; RunningNow = $false; ExeChanged = $false; Signal = ''; FileSignal = '' }
  if ($extra) { foreach ($k in $extra.Keys) { $p[$k] = $extra[$k] } }
  return (Get-GbtExitDecision @p)
}

Assert ((Test-GbtCleanExit 0) -eq $true) 'int 0 is a clean exit'
Assert ((Test-GbtCleanExit '0') -eq $true) 'string 0 is a clean exit'
Assert ((Test-GbtCleanExit $null) -eq $false) 'null is not a clean exit'
Assert ((Test-GbtCleanExit 134) -eq $false) '134 is not a clean exit'
Assert ((Test-GbtCleanExit -805306369) -eq $false) 'negative code is not a clean exit'
Assert ((Test-GbtCleanExit '') -eq $false) 'empty string is not a clean exit'

Assert ((Decide 0 19 @{}) -eq 'wait') 'clean exit inside 20s grace waits'
Assert ((Decide 0 20 @{}) -eq 'stay-closed') 'clean exit at 20s stays closed'
Assert ((Decide 0 45 @{}) -eq 'stay-closed') 'clean exit after grace stays closed'
Assert ((Decide 0 25 @{ RunningNow = $true }) -eq 'reattach') 'running app is reattached, not relaunched'
Assert ((Decide 134 3 @{}) -eq 'wait') 'crash inside 4s grace waits'
Assert ((Decide 134 4 @{}) -eq 'relaunch-hidden') 'crash 134 relaunches hidden'
Assert ((Decide -805306369 4 @{}) -eq 'relaunch-hidden') 'other non-zero exit relaunches'
Assert ((Decide $null 3 @{}) -eq 'wait') 'unknown code uses the crash grace'
Assert ((Decide $null 4 @{}) -eq 'relaunch-hidden') 'unknown code relaunches, it is not a deliberate close'
Assert ((Decide 0 100 @{ Signal = 'app exe is missing' }) -eq 'updating') 'clean exit with an update signal waits'
Assert ((Decide 134 30 @{ Signal = 'updater installer.exe is running' }) -eq 'updating') 'crash during an update does not relaunch'
Assert ((Decide 0 100 @{ FileSignal = 'app exe is locked for writing'; ScanFresh = $false }) -eq 'updating') 'file signal does not wait for the process scan'
Assert ((Decide 0 100 @{ ExeChanged = $true; ScanFresh = $false }) -eq 'updating') 'changed exe does not wait for the process scan'
Assert ((Decide 134 30 @{ ScanFresh = $false }) -eq 'wait') 'no crash relaunch before the post-exit scan'
Assert ((Decide 0 100 @{ ScanFresh = $false }) -eq 'wait') 'no stay-closed decision before the post-exit scan'

Assert ((Get-GbtLaunchDecision -Quitting $true) -eq 'skip-quitting') 'no launch while quitting'
Assert ((Get-GbtLaunchDecision -InFlight $true) -eq 'skip-in-flight') 'no second launch in the same start'
Assert ((Get-GbtLaunchDecision -TrackedAlive $true) -eq 'skip-already-running') 'no second launch while the tracked process is alive'
Assert ((Get-GbtLaunchDecision -AnyRunning $true) -eq 'skip-already-running') 'no second launch while any app process is running'
Assert ((Get-GbtLaunchDecision -SecondsSinceLaunch 1) -eq 'skip-recent') 'no second launch in the first 3s'
Assert ((Get-GbtLaunchDecision -SecondsSinceLaunch 3) -eq 'start') 'a launch 3s later is allowed'
Assert ((Get-GbtLaunchDecision) -eq 'start') 'a cold start is allowed'
Assert ((Get-GbtLaunchDecision -TrackedAlive $true -SecondsSinceLaunch 0) -eq 'skip-already-running') 'a live process wins over the recent-start gap'

Assert ((Get-GbtMissingDecision -ElapsedSec 30) -eq 'wait') '30s with no process still waits'
Assert ((Get-GbtMissingDecision -ElapsedSec 31) -eq 'give-up') 'an unseen process is not relaunched'
Assert ((Get-GbtMissingDecision -AnyRunning $true -ElapsedSec 100) -eq 'running') 'a visible process is not given up'
Assert ((Get-GbtMissingDecision -ExitPending $true -ElapsedSec 1) -eq 'exited') 'a captured exit is kept when siblings are gone'

$seen = Get-Date
Assert ((Test-GbtScanFresh -SignalStartedTicks 0 -ExitSeenAt $seen) -eq $false) 'no scan is not fresh'
Assert ((Test-GbtScanFresh -SignalStartedTicks ($seen.ToUniversalTime().Ticks - 1) -ExitSeenAt $seen) -eq $false) 'a scan that started before the exit is stale'
Assert ((Test-GbtScanFresh -SignalStartedTicks $seen.ToUniversalTime().Ticks -ExitSeenAt $seen) -eq $true) 'a scan that started at the exit is fresh'

$root = Join-Path ([IO.Path]::GetTempPath()) ('gbt-policy-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $root | Out-Null
try {
  $exe = Join-Path $root 'Grok Bot.exe'
  $install = Join-Path $root 'app'
  New-Item -ItemType Directory -Force -Path $install | Out-Null
  Set-Content -LiteralPath $exe -Value 'x' -Encoding ascii
  (Get-Item -LiteralPath $exe).LastWriteTime = (Get-Date).AddMinutes(-5)
  $none = Get-GbtUpdateSignal -Exe $exe -InstallDir $install -ProcessName 'Grok Bot' -QuietSec 12 -Processes @(
    [pscustomobject]@{ Name = 'Grok Bot.exe'; Path = (Join-Path $install 'Grok Bot.exe') }
    [pscustomobject]@{ Name = 'notepad.exe'; Path = 'C:\Windows\notepad.exe' }
  )
  Assert ($null -eq $none) 'the app itself and unrelated processes are not an update'
  $missing = Get-GbtUpdateSignal -Exe (Join-Path $root 'missing.exe') -InstallDir $install -ProcessName 'Grok Bot' -Processes @()
  Assert ($missing -eq 'app exe is missing') 'a missing exe is an update signal'
  (Get-Item -LiteralPath $exe).LastWriteTime = Get-Date
  $written = Get-GbtUpdateSignal -Exe $exe -InstallDir $install -ProcessName 'Grok Bot' -QuietSec 12 -Processes @()
  Assert ($written -eq 'app exe was just written') 'a freshly written exe is an update signal'
  (Get-Item -LiteralPath $exe).LastWriteTime = (Get-Date).AddMinutes(-5)
  $updater = Get-GbtUpdateSignal -Exe $exe -InstallDir $install -ProcessName 'Grok Bot' -QuietSec 12 -Processes @(
    [pscustomobject]@{ Name = 'installer.exe'; Path = 'C:\Users\me\AppData\Local\GrokBot-updater\installer.exe' }
  )
  Assert ($updater -eq 'updater installer.exe is running') 'installer.exe in an -updater folder is an update'
  $helper = Get-GbtUpdateSignal -Exe $exe -InstallDir $install -ProcessName 'Grok Bot' -QuietSec 12 -Processes @(
    [pscustomobject]@{ Name = 'Au_.exe'; Path = '' }
  )
  Assert ($helper -eq 'installer helper Au_.exe is running') 'NSIS Au_.exe is an update'
  $fromDir = Get-GbtUpdateSignal -Exe $exe -InstallDir $install -ProcessName 'Grok Bot' -QuietSec 12 -Processes @(
    [pscustomobject]@{ Name = 'helper.exe'; Path = ($install.TrimEnd('\') + '\helper.exe') }
  )
  Assert ($fromDir -eq 'helper.exe is running from the app folder') 'another exe in the app folder is an update'
  $squirrel = Get-GbtUpdateSignal -Exe $exe -InstallDir $install -ProcessName 'Grok Bot' -QuietSec 12 -Processes @(
    [pscustomobject]@{ Name = 'Update.exe'; Path = 'C:\Users\me\AppData\Local\SquirrelTemp\Update.exe' }
  )
  Assert ($squirrel -eq 'Squirrel Update.exe is running') 'Squirrel Update.exe is an update'
  $plainInstaller = Get-GbtUpdateSignal -Exe $exe -InstallDir $install -ProcessName 'Grok Bot' -QuietSec 12 -Processes @(
    [pscustomobject]@{ Name = 'installer.exe'; Path = 'C:\Windows\installer.exe' }
  )
  Assert ($null -eq $plainInstaller) 'installer.exe outside an updater folder is ignored'
} finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }

$tray = Join-Path $PSScriptRoot '..\src\GrokBotTray.ps1'
$launcher = Join-Path $PSScriptRoot '..\src\launcher.cs'
$tokens = $null; $errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $tray), [ref]$tokens, [ref]$errors)
Assert (@($errors).Count -eq 0) 'GrokBotTray.ps1 parses'
if (@($errors).Count) { $errors | ForEach-Object { Write-Host $_ } }
$tokens = $null; $errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path (Join-Path $PSScriptRoot 'simulate-update.ps1')), [ref]$tokens, [ref]$errors)
Assert (@($errors).Count -eq 0) 'simulate-update.ps1 parses'
$text = Get-Content -Raw -LiteralPath $tray
Assert ($text.Contains('Get-GbtExitDecision')) 'script uses the exit decision'
Assert ($text.Contains('Get-GbtLaunchDecision')) 'script uses the launch decision'
Assert ($text.Contains('Start-App $true $true')) 'crash relaunch is marked automatic'
Assert ($text -notmatch 'Get-UpdateSignal[^N]') 'old UI-thread update scan is gone'
$launch = Get-Content -Raw -LiteralPath $launcher
Assert ($launch.Contains('-STA')) 'launcher requests STA'

if ($script:fail) { Write-Host "FAILED $($script:fail)"; exit 1 }
Write-Host 'ALL POLICY TESTS PASSED'
