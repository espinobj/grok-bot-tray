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
Copy-Item "$PSScriptRoot\..\src\policy.ps1" "$T\helper\policy.ps1" -Force
Copy-Item "$env:LOCALAPPDATA\GrokBotTray\GrokBotTray.ico" "$T\helper\" -ErrorAction SilentlyContinue
@{exe="$T\app\DummyApp.exe"} | ConvertTo-Json | Set-Content "$T\helper\config.json"
# -STA matches the launcher. Without it the script relaunches itself and $h is the short-lived parent.
$h=Start-Process powershell.exe -ArgumentList "-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$T\helper\GrokBotTray.ps1`"" -PassThru
$script:fails = 0
function Expect([string]$name, $actual, $expected) {
  $ok = "$actual" -eq "$expected"
  "{0} {1}: actual={2} expected={3}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $actual, $expected
  if (-not $ok) { $script:fails++ }
}
$log="$T\helper\tray.log"
function W($s){ Start-Sleep $s }
W 6; $r1 = [bool](Get-Process DummyApp -ErrorAction SilentlyContinue); Expect '1 launched' $r1 True
# --- update simulation: clean exit, updater runs 25s, rewrites the exe midway
Set-Content "$T\app\exit.txt" 0
Start-Process "$T\fake-updater\installer.exe" -ArgumentList '--sleep 25'
W 3; $r2 = [bool](Get-Process DummyApp -ErrorAction SilentlyContinue); Expect '2 during update app running' $r2 False
W 10; Copy-Item "$T\app\DummyApp.exe" "$T\app\DummyApp.new"; Remove-Item "$T\app\DummyApp.exe"; W 2; Move-Item "$T\app\DummyApp.new" "$T\app\DummyApp.exe"; (Get-Item "$T\app\DummyApp.exe").LastWriteTime=Get-Date
W 5; $r3 = [bool](Get-Process DummyApp -ErrorAction SilentlyContinue); Expect '3 mid-update app running' $r3 False
W 80; $r4 = [bool](Get-Process DummyApp -ErrorAction SilentlyContinue); Expect '4 after update app running' $r4 True
# --- installer-style self restart check: clean exit + updater that starts app itself
Set-Content "$T\app\exit.txt" 0
Start-Process "$T\fake-updater\installer.exe" -ArgumentList '--sleep 8'
W 10; Start-Process "$T\app\DummyApp.exe"
W 20; $r5 = @(Get-Process DummyApp -ErrorAction SilentlyContinue).Count; Expect '5 self-restarted count' $r5 1
# --- crash
Set-Content "$T\app\exit.txt" 3
W 10; $r6 = [bool](Get-Process DummyApp -ErrorAction SilentlyContinue); Expect '6 after crash app running' $r6 True
# --- plain clean quit with no updater -> stay closed (v1.2.5 does not relaunch)
Set-Content "$T\app\exit.txt" 0
W 8; $r7 = [bool](Get-Process DummyApp -ErrorAction SilentlyContinue); Expect '7 8s after clean quit running' $r7 False
W 20; $r8 = [bool](Get-Process DummyApp -ErrorAction SilentlyContinue); Expect '8 28s after clean quit running' $r8 False
Stop-Process -Id $h.Id -Force; Get-Process DummyApp -ErrorAction SilentlyContinue | Stop-Process -Force
"== log"; Get-Content $log
if ($script:fails) { "FAILED $($script:fails)"; exit 1 } else { 'ALL EXPECTATIONS PASSED' }
