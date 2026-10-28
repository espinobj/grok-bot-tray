# Grok Bot Tray self-updater (unofficial). Launched detached by the helper.
# Backs up the install, runs the new installer in upgrade mode, checks the new helper
# starts within the timeout, and rolls back if it does not.
param(
  [Parameter(Mandatory)][string]$Src,       # extracted package folder (has install.ps1, VERSION)
  [Parameter(Mandatory)][string]$Expected,  # version expected after install
  [string]$Dest = (Join-Path $env:LOCALAPPDATA 'GrokBotTray'),
  [int]$TimeoutSec = 30
)
$ErrorActionPreference = 'Continue'
$log = Join-Path $Dest 'tray.log'
function Log([string]$m) { try { Add-Content -Path $log -Value ("{0:yyyy-MM-dd HH:mm:ss} [updater] {1}" -f (Get-Date), $m) } catch {} }
function Get-Helpers { @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" | Where-Object { $_.CommandLine -match 'GrokBotTray\.ps1' }) }
function Write-Result($ok, $msg) {
  [ordered]@{ ok = $ok; version = $Expected; message = $msg; at = (Get-Date).ToString('s') } | ConvertTo-Json |
    Set-Content -Path (Join-Path $Dest 'update-result.json') -Encoding UTF8
}

$bak = "$Dest.bak"
$old = try { (Get-Content (Join-Path $Dest 'VERSION') -Raw).Trim() } catch { '?' }
Log "Updating v$old -> v$Expected from $Src"
try {
  if (Test-Path $bak) { Remove-Item $bak -Recurse -Force }
  Copy-Item $Dest $bak -Recurse -Force -ErrorAction Stop
  Log "Backed up to $bak"
} catch { Log "Backup failed, aborting: $_"; Write-Result $false "backup failed: $_"; exit 1 }

$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Src 'install.ps1') -Upgrade 2>&1
foreach ($l in $out) { Log "install: $l" }

$ok = $false
$deadline = (Get-Date).AddSeconds($TimeoutSec)
while ((Get-Date) -lt $deadline) {
  Start-Sleep 2
  $v = try { (Get-Content (Join-Path $Dest 'VERSION') -Raw).Trim() } catch { '' }
  $started = Select-String -Path $log -Pattern ([regex]::Escape("Helper v$Expected started")) -Quiet -ErrorAction SilentlyContinue
  if ($v -eq $Expected -and (Get-Helpers).Count -gt 0 -and $started) { $ok = $true; break }
}
if ($ok) { Log "Update to v$Expected OK"; Write-Result $true "Updated from v$old"; exit 0 }

Log "New helper did not start within $TimeoutSec s; rolling back to v$old"
Get-Helpers | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep 1
& robocopy.exe $bak $Dest /MIR /R:2 /W:1 /NFL /NDL /NJH /NJS | Out-Null
$st = Get-Content (Join-Path $Dest 'settings.json') -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
if (-not $st) { $st = [pscustomobject]@{ autoUpdate = $true } }
$st | Add-Member -NotePropertyName failedVersion -NotePropertyValue $Expected -Force
$st | ConvertTo-Json | Set-Content (Join-Path $Dest 'settings.json') -Encoding UTF8
Write-Result $false "Update to v$Expected failed; rolled back to v$old"
Start-Process -FilePath (Join-Path $Dest 'Grok Bot Tray.exe')
Log "Rolled back to v$old"
exit 2
