# Simulates an app update, an installer-driven restart, a crash and a clean quit against a dummy app.
# Uses its own mutex names, so it can run next to a real helper. Run: powershell -ExecutionPolicy Bypass -File tests\simulate-update.ps1
$ErrorActionPreference='Stop'
$T="$env:TEMP\gbt-test"; Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$T\app","$T\fake-updater","$T\helper" | Out-Null
$csc="$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
& $csc /nologo /target:winexe "/out:$T\app\DummyApp.exe" "$PSScriptRoot\dummy.cs" | Out-Null
Copy-Item "$T\app\DummyApp.exe" "$T\fake-updater\installer.exe"
$ps=(Get-Content "$PSScriptRoot\..\src\GrokBotTray.ps1" -Raw).Replace('Local\GrokBotTrayShow','Local\GBTTestShow').Replace('Local\GrokBotTrayWrapper','Local\GBTTestWrap')
Set-Content "$T\helper\GrokBotTray.ps1" $ps
Copy-Item "$env:LOCALAPPDATA\GrokBotTray\GrokBotTray.ico" "$T\helper\" -ErrorAction SilentlyContinue
@{exe="$T\app\DummyApp.exe"} | ConvertTo-Json | Set-Content "$T\helper\config.json"
$h=Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$T\helper\GrokBotTray.ps1`"" -PassThru
$log="$T\helper\tray.log"
function W($s){ Start-Sleep $s }
W 6; "== 1 launched: " + [bool](Get-Process DummyApp -ErrorAction SilentlyContinue)
# --- update simulation: clean exit, updater runs 25s, rewrites the exe midway
Set-Content "$T\app\exit.txt" 0
Start-Process "$T\fake-updater\installer.exe" -ArgumentList '--sleep 25'
W 3; "== 2 during update app running: " + [bool](Get-Process DummyApp -ErrorAction SilentlyContinue)
W 10; Copy-Item "$T\app\DummyApp.exe" "$T\app\DummyApp.new"; Remove-Item "$T\app\DummyApp.exe"; W 2; Move-Item "$T\app\DummyApp.new" "$T\app\DummyApp.exe"; (Get-Item "$T\app\DummyApp.exe").LastWriteTime=Get-Date
W 5; "== 3 mid-update app running: " + [bool](Get-Process DummyApp -ErrorAction SilentlyContinue)
W 80; "== 4 after update app running: " + [bool](Get-Process DummyApp -ErrorAction SilentlyContinue)
# --- installer-style self restart check: clean exit + updater that starts app itself
Set-Content "$T\app\exit.txt" 0
Start-Process "$T\fake-updater\installer.exe" -ArgumentList '--sleep 8'
W 10; Start-Process "$T\app\DummyApp.exe"
W 20; "== 5 self-restarted count: " + @(Get-Process DummyApp -ErrorAction SilentlyContinue).Count
# --- crash
Set-Content "$T\app\exit.txt" 3
W 10; "== 6 after crash app running: " + [bool](Get-Process DummyApp -ErrorAction SilentlyContinue)
# --- plain clean quit with no updater -> relaunch after grace
Set-Content "$T\app\exit.txt" 0
W 8; "== 7 8s after clean quit running: " + [bool](Get-Process DummyApp -ErrorAction SilentlyContinue)
W 20; "== 8 28s after clean quit running: " + [bool](Get-Process DummyApp -ErrorAction SilentlyContinue)
Stop-Process -Id $h.Id -Force; Get-Process DummyApp -ErrorAction SilentlyContinue | Stop-Process -Force
"== log"; Get-Content $log
