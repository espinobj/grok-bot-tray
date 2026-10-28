<#
.SYNOPSIS
  Removes Grok Bot Tray for the current user. Grok Bot itself is not touched.
  Unofficial community tool. Not affiliated with, endorsed by, or supported by xAI.
#>
[CmdletBinding()] param([switch]$KeepFiles)
$ErrorActionPreference = 'Continue'
$dest = Join-Path $env:LOCALAPPDATA 'GrokBotTray'
$name = 'Grok Bot Tray'
function Say($m) { Write-Host "[Grok Bot Tray] $m" }

Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
  Where-Object { $_.CommandLine -match 'GrokBotTray\.ps1' -and $_.ProcessId -ne $PID } |
  ForEach-Object { Say "Stopping helper (PID $($_.ProcessId))"; Stop-Process -Id $_.ProcessId -Force }

$cfg = $null; try { $cfg = Get-Content (Join-Path $dest 'config.json') -Raw | ConvertFrom-Json } catch {}
$bk = Join-Path $dest 'backup\taskbar-pin.lnk'
if ($cfg -and $cfg.pinPath -and (Test-Path $bk)) { Copy-Item $bk $cfg.pinPath -Force; Say 'Restored the original Grok Bot taskbar pin' }
elseif ($cfg -and $cfg.pinPath -and (Test-Path $cfg.pinPath) -and $cfg.exe) {
  $ws = New-Object -ComObject WScript.Shell; $s = $ws.CreateShortcut($cfg.pinPath)
  $s.TargetPath = $cfg.exe; $s.WorkingDirectory = (Split-Path $cfg.exe); $s.IconLocation = "$($cfg.exe),0"; $s.Save()
  Say 'Pointed the taskbar pin back at Grok Bot'
}
foreach ($p in (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$name.lnk"),
               (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup\$name.lnk"),
               (Join-Path ([Environment]::GetFolderPath('Desktop')) "$name.lnk")) {
  if (Test-Path $p) { Remove-Item $p -Force; Say "Removed $(Split-Path $p -Leaf) from $(Split-Path (Split-Path $p) -Leaf)" }
}
try { Start-Process -FilePath (Join-Path $env:WINDIR 'System32\ie4uinit.exe') -ArgumentList '-show' -WindowStyle Hidden -Wait } catch {}
if (-not $KeepFiles -and (Test-Path $dest)) {
  Start-Sleep 1
  if ($PSScriptRoot -ieq $dest) {
    Start-Process cmd.exe -ArgumentList "/c timeout /t 2 >nul & rmdir /s /q `"$dest`"" -WindowStyle Hidden
  } else { Remove-Item $dest -Recurse -Force; Remove-Item "$dest.bak" -Recurse -Force -ErrorAction SilentlyContinue }
  Say "Removed $dest"
}
Say 'Uninstalled. Grok Bot itself was not changed.'
