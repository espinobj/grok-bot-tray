<#
.SYNOPSIS
  Installs Grok Bot Tray for the current user (no admin needed).
  Unofficial community tool. Not affiliated with, endorsed by, or supported by xAI.
.PARAMETER AppPath
  Full path to "Grok Bot.exe". Auto-detected when omitted.
.PARAMETER NoStartup
  Do not start the helper when you sign in to Windows.
.PARAMETER NoPinUpdate
  Leave an existing Grok Bot taskbar pin alone.
.PARAMETER DesktopShortcut
  Also put a "Grok Bot Tray" shortcut on the desktop.
#>
[CmdletBinding()]
param(
  [string]$AppPath,
  [switch]$NoStartup,
  [switch]$NoPinUpdate,
  [switch]$DesktopShortcut,
  [switch]$NoLaunch,
  [switch]$Upgrade   # used by the auto-updater: keep the current Start-with-Windows choice
)
$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot 'src'
$dest = Join-Path $env:LOCALAPPDATA 'GrokBotTray'
$name = 'Grok Bot Tray'
function Say($m) { Write-Host "[Grok Bot Tray] $m" }

# ---------- find Grok Bot ----------
function Find-GrokBot {
  $c = New-Object System.Collections.Generic.List[string]
  $keys = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
          'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
          'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
  foreach ($k in $keys) {
    foreach ($e in @(Get-ItemProperty $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like 'Grok Bot*' })) {
      foreach ($v in @($e.DisplayIcon, $e.UninstallString, $e.InstallLocation)) {
        if (-not $v) { continue }
        $p = ($v -replace '"', '') -replace ',\s*\d+$', ''
        $p = ($p -split ' /')[0].Trim()
        if ($p -like '*.exe') { $p = Split-Path -Parent $p }
        $c.Add((Join-Path $p 'Grok Bot.exe'))
      }
    }
  }
  $c.Add((Join-Path $env:LOCALAPPDATA 'Programs\Grok Bot\Grok Bot.exe'))
  $c.Add((Join-Path $env:ProgramFiles 'Grok Bot\Grok Bot.exe'))
  if (${env:ProgramFiles(x86)}) { $c.Add((Join-Path ${env:ProgramFiles(x86)} 'Grok Bot\Grok Bot.exe')) }
  foreach ($p in $c) { if (Test-Path -LiteralPath $p) { return (Resolve-Path -LiteralPath $p).Path } }
  return $null
}
if (-not $AppPath) { $AppPath = Find-GrokBot }
if (-not $AppPath -or -not (Test-Path -LiteralPath $AppPath)) { throw 'Could not find "Grok Bot.exe". Install Grok Bot first, or pass -AppPath "C:\path\to\Grok Bot.exe".' }
Say "Grok Bot found at $AppPath"

# ---------- helpers: shortcut AppUserModelID + icon builder ----------
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public static class GBTInstall {
  [DllImport("user32.dll", CharSet=CharSet.Unicode)]
  public static extern int PrivateExtractIcons(string file, int idx, int cx, int cy, IntPtr[] h, int[] id, int n, int flags);
  [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);

  [StructLayout(LayoutKind.Sequential, Pack=4)] public struct PROPERTYKEY { public Guid fmtid; public uint pid; }
  [StructLayout(LayoutKind.Explicit, Size=24)] public struct PROPVARIANT { [FieldOffset(0)] public ushort vt; [FieldOffset(8)] public IntPtr p; }
  [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IPropertyStore {
    int GetCount(out uint c); int GetAt(uint i, out PROPERTYKEY k);
    int GetValue(ref PROPERTYKEY k, out PROPVARIANT v); int SetValue(ref PROPERTYKEY k, ref PROPVARIANT v); int Commit();
  }
  [DllImport("shell32.dll", CharSet=CharSet.Unicode)]
  static extern int SHGetPropertyStoreFromParsingName(string path, IntPtr pbc, int flags, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore ps);
  static PROPERTYKEY AumidKey() { var k = new PROPERTYKEY(); k.fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"); k.pid = 5; return k; }

  public static string GetAumid(string lnk) {
    IPropertyStore ps; Guid iid = typeof(IPropertyStore).GUID;
    if (SHGetPropertyStoreFromParsingName(lnk, IntPtr.Zero, 0, ref iid, out ps) != 0) return null;
    try { var k = AumidKey(); PROPVARIANT v; ps.GetValue(ref k, out v); return v.vt == 31 ? Marshal.PtrToStringUni(v.p) : null; }
    finally { Marshal.ReleaseComObject(ps); }
  }
  public static void SetAumid(string lnk, string aumid) {
    IPropertyStore ps; Guid iid = typeof(IPropertyStore).GUID;
    int hr = SHGetPropertyStoreFromParsingName(lnk, IntPtr.Zero, 2 /*GPS_READWRITE*/, ref iid, out ps);
    if (hr != 0) Marshal.ThrowExceptionForHR(hr);
    try {
      var k = AumidKey(); var v = new PROPVARIANT(); v.vt = 31; v.p = Marshal.StringToCoTaskMemUni(aumid);
      try { Marshal.ThrowExceptionForHR(ps.SetValue(ref k, ref v)); Marshal.ThrowExceptionForHR(ps.Commit()); }
      finally { Marshal.FreeCoTaskMem(v.p); }
    } finally { Marshal.ReleaseComObject(ps); }
  }
}
"@

function Get-AppIconBitmap([string]$exe, [int]$size) {
  $h = New-Object IntPtr[] 1; $id = New-Object int[] 1
  $n = [GBTInstall]::PrivateExtractIcons($exe, 0, $size, $size, $h, $id, 1, 0)
  if ($n -ge 1 -and $h[0] -ne [IntPtr]::Zero) {
    $ic = [System.Drawing.Icon]::FromHandle($h[0]); $bmp = New-Object System.Drawing.Bitmap($ic.ToBitmap()); [void][GBTInstall]::DestroyIcon($h[0]); return $bmp
  }
  $ic = [System.Drawing.Icon]::ExtractAssociatedIcon($exe)
  return New-Object System.Drawing.Bitmap($ic.ToBitmap(), $size, $size)
}

function New-BadgedFrame([string]$exe, [int]$size) {
  # v1.1.0: clearly different from the stock icon even at 16 px:
  # blue-tinted app logo inside a thick blue rounded frame, plus an orange corner badge.
  $src = Get-AppIconBitmap $exe $size
  $bmp = New-Object System.Drawing.Bitmap($size, $size)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'; $g.InterpolationMode = 'HighQualityBicubic'
  $blueC = [System.Drawing.Color]::FromArgb(255, 0, 120, 215)
  $blue = New-Object System.Drawing.SolidBrush($blueC)
  $b = [Math]::Max(2, [Math]::Round($size * 0.14))          # frame thickness (2 px at 16)
  $g.FillRectangle($blue, 0, 0, $size, $size)               # solid blue tile
  # tint the logo blue-ish so it reads as "not the stock icon"
  $cm = New-Object System.Drawing.Imaging.ColorMatrix
  $cm.Matrix00 = 0.55; $cm.Matrix11 = 0.75; $cm.Matrix22 = 1.0; $cm.Matrix33 = 1.0
  $cm.Matrix40 = 0.0; $cm.Matrix41 = 0.1; $cm.Matrix42 = 0.3
  $ia = New-Object System.Drawing.Imaging.ImageAttributes; $ia.SetColorMatrix($cm)
  $inner = $size - 2 * $b
  $g.FillRectangle([System.Drawing.Brushes]::White, $b, $b, $inner, $inner)
  $g.DrawImage($src, (New-Object System.Drawing.Rectangle($b, $b, $inner, $inner)), 0, 0, $src.Width, $src.Height, 'Pixel', $ia)
  # orange corner badge, bottom-right
  $d = [Math]::Round($size * $(if ($size -le 24) { 0.5 } else { 0.42 }))
  $x = $size - $d; $y = $size - $d
  $orange = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 255, 140, 0))
  $g.FillEllipse([System.Drawing.Brushes]::White, $x, $y, $d, $d)
  $r = [Math]::Max(1, [Math]::Round($d * 0.14))
  $g.FillEllipse($orange, $x + $r, $y + $r, $d - 2 * $r, $d - 2 * $r)
  $g.Dispose(); $blue.Dispose(); $orange.Dispose(); $src.Dispose()
  return $bmp
}

function Write-Ico([System.Drawing.Bitmap[]]$frames, [string]$path) {
  $blobs = @()
  foreach ($b in $frames) {
    $ms = New-Object IO.MemoryStream
    if ($b.Width -ge 256) { $b.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png) }
    else {
      # classic 32-bit DIB frame (best compatibility with System.Drawing.Icon and Explorer)
      $w = $b.Width; $hgt = $b.Height
      $maskStride = [int]([Math]::Ceiling($w / 32.0) * 4)
      $bw = New-Object IO.BinaryWriter($ms)
      $bw.Write([int]40); $bw.Write([int]$w); $bw.Write([int]($hgt * 2)); $bw.Write([int16]1); $bw.Write([int16]32)
      $bw.Write([int]0); $bw.Write([int]($w * $hgt * 4 + $maskStride * $hgt)); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0)
      for ($yy = $hgt - 1; $yy -ge 0; $yy--) { for ($xx = 0; $xx -lt $w; $xx++) { $c = $b.GetPixel($xx, $yy); $bw.Write([byte]$c.B); $bw.Write([byte]$c.G); $bw.Write([byte]$c.R); $bw.Write([byte]$c.A) } }
      $bw.Write((New-Object byte[] ($maskStride * $hgt)))
      $bw.Flush()
    }
    $blobs += , $ms.ToArray()
  }
  $fs = [IO.File]::Create($path); $bw = New-Object IO.BinaryWriter($fs)
  $bw.Write([int16]0); $bw.Write([int16]1); $bw.Write([int16]$frames.Count)
  $offset = 6 + 16 * $frames.Count
  for ($i = 0; $i -lt $frames.Count; $i++) {
    $s = $frames[$i].Width; $sz = if ($s -ge 256) { 0 } else { $s }
    $bw.Write([byte]$sz); $bw.Write([byte]$sz); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([int16]1); $bw.Write([int16]32); $bw.Write([int]$blobs[$i].Length); $bw.Write([int]$offset)
    $offset += $blobs[$i].Length
  }
  foreach ($bl in $blobs) { $bw.Write($bl) }
  $bw.Close()
}

# ---------- stop a running helper (never touches Grok Bot itself) ----------
Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
  Where-Object { $_.CommandLine -match 'GrokBotTray\.ps1' -and $_.ProcessId -ne $PID } |
  ForEach-Object { Say "Stopping running helper (PID $($_.ProcessId))"; Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500

# ---------- copy files ----------
New-Item -ItemType Directory -Force -Path $dest | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $dest 'backup') | Out-Null
Copy-Item (Join-Path $src 'GrokBotTray.ps1') $dest -Force
Copy-Item (Join-Path $src 'launcher.cs') $dest -Force
Copy-Item (Join-Path $src 'update.ps1') $dest -Force
Copy-Item (Join-Path $PSScriptRoot 'uninstall.ps1') $dest -Force
Copy-Item (Join-Path $PSScriptRoot 'VERSION') $dest -Force
foreach ($old in 'exe.txt', 'GrokBotTray.vbs') { Remove-Item (Join-Path $dest $old) -Force -ErrorAction SilentlyContinue }

# ---------- icon ----------
$ico = Join-Path $dest 'GrokBotTray.ico'
# v1.2.3: shortcuts use a versioned copy so Explorer's icon cache can't keep showing an old image.
$lnkIcoName = 'icon-v' + ((Get-Content (Join-Path $PSScriptRoot 'VERSION') -Raw).Trim() -replace '[^0-9A-Za-z]', '') + '.ico'
$lnkIco = Join-Path $dest $lnkIcoName
$iconB64 = Join-Path $PSScriptRoot 'assets\icon.png.b64'   # PNG stored as base64 text
function New-IconFrame([int]$size) {
  # v1.2.2: green bot artwork (assets\icon.png.b64), clearly different from the stock Grok Bot icon.
  if (-not (Test-Path $iconB64)) { return New-BadgedFrame $AppPath $size }
  $ms = New-Object System.IO.MemoryStream(,[Convert]::FromBase64String((Get-Content $iconB64 -Raw)))
  $src = [System.Drawing.Image]::FromStream($ms)
  $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'; $g.InterpolationMode = 'HighQualityBicubic'
  $g.Clear([System.Drawing.Color]::Transparent); $g.DrawImage($src, 0, 0, $size, $size)
  $g.Dispose(); $src.Dispose(); $ms.Dispose(); return $bmp
}
$frames = @(16, 20, 24, 32, 40, 48, 64, 128, 256 | ForEach-Object { New-IconFrame $_ })
Write-Ico $frames $ico
if ($env:GBT_ICON_PREVIEW) { foreach ($f in $frames) { if ($f.Width -in 16, 24, 32) { $f.Save((Join-Path $env:GBT_ICON_PREVIEW ("tray-$($f.Width).png"))) } } }
$frames | ForEach-Object { $_.Dispose() }
Get-ChildItem $dest -Filter 'icon-v*.ico' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $lnkIcoName } | Remove-Item -Force -ErrorAction SilentlyContinue
Copy-Item $ico $lnkIco -Force
Say 'Built helper icon'

# ---------- launcher exe ----------
$launcher = Join-Path $dest "$name.exe"
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw 'The .NET Framework 4 C# compiler (csc.exe) was not found; it ships with Windows 10 and 11.' }
$out = & $csc /nologo /target:winexe /optimize+ "/win32icon:$ico" "/out:$launcher" (Join-Path $dest 'launcher.cs') 2>&1
if ($LASTEXITCODE -ne 0) { throw "Launcher build failed: $out" }
Say 'Built launcher'

# ---------- shortcuts ----------
$ws = New-Object -ComObject WScript.Shell
function Set-Lnk([string]$path, [string]$aumid) {
  $s = $ws.CreateShortcut($path)
  $s.TargetPath = $launcher; $s.WorkingDirectory = $dest; $s.IconLocation = "$lnkIco,0"; $s.Description = 'Grok Bot in the notification area (unofficial helper)'
  $s.Save()
  if ($aumid) { try { [GBTInstall]::SetAumid($path, $aumid) } catch { Write-Warning "Could not set AppUserModelID on $path : $_" } }
}

# Find the app's AppUserModelID from its own shortcuts so a pinned helper groups with the app window.
$pinDir = Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
$appLnks = @()
foreach ($d in @($pinDir, (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'), (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'))) {
  if (Test-Path $d) { $appLnks += @(Get-ChildItem $d -Filter *.lnk -Recurse -ErrorAction SilentlyContinue) }
}
$aumid = $null; $pinPath = $null
foreach ($l in $appLnks) {
  $t = $ws.CreateShortcut($l.FullName).TargetPath
  if ($t -ieq $AppPath -or $t -ieq $launcher) {
    $a = [GBTInstall]::GetAumid($l.FullName)
    if ($l.DirectoryName -ieq $pinDir) { $pinPath = $l.FullName; if ($a) { $aumid = $a } }
    elseif (-not $aumid -and $a -and $a -notlike 'electron.app.*') { $aumid = $a }
  }
}
if ($aumid) { Say "App ID: $aumid" } else { Say 'App ID not found; a pinned helper will show as its own taskbar button.' }

$startMenu = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$name.lnk"
Set-Lnk $startMenu $aumid
$startup = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup\$name.lnk"
if ($Upgrade -and -not (Test-Path $startup)) { $NoStartup = $true }
if ($NoStartup) { Remove-Item $startup -Force -ErrorAction SilentlyContinue } else { Set-Lnk $startup $null }
$desk = Join-Path ([Environment]::GetFolderPath('Desktop')) "$name.lnk"
if ($DesktopShortcut -or (Test-Path $desk)) { Set-Lnk $desk $aumid }

if ($pinPath -and -not $NoPinUpdate) {
  $bk = Join-Path $dest 'backup\taskbar-pin.lnk'
  if ($ws.CreateShortcut($pinPath).TargetPath -ieq $AppPath -and -not (Test-Path $bk)) { Copy-Item $pinPath $bk }
  Set-Lnk $pinPath $aumid
  Say 'Taskbar pin now opens the helper and shows the helper icon'
} elseif (-not $pinPath) {
  Say 'Tip: to pin it, open Start, find "Grok Bot Tray", right-click it and choose Pin to taskbar.'
  $pinPath = $null
}

# ---------- config ----------
[ordered]@{ exe = $AppPath; aumid = $aumid; pinPath = $(if ($NoPinUpdate) { $null } else { $pinPath }); icon = $lnkIco; installed = (Get-Date).ToString('s') } |
  ConvertTo-Json | Set-Content -Path (Join-Path $dest 'config.json') -Encoding UTF8

# refresh Explorer's icon cache so the new icon shows without signing out
try { Start-Process -FilePath (Join-Path $env:WINDIR 'System32\ie4uinit.exe') -ArgumentList '-show' -WindowStyle Hidden -Wait } catch {}

if (-not $NoLaunch) { Start-Process -FilePath $launcher; Say 'Helper started. Look for the green bot icon in the notification area.' }
Say "Installed v$((Get-Content (Join-Path $PSScriptRoot 'VERSION') -Raw).Trim()) to $dest"
