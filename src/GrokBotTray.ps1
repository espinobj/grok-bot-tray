# Grok Bot Tray - unofficial community helper. Not affiliated with or endorsed by xAI.
# Keeps the Grok Bot desktop app in the notification area (tray). Minimizing hides the
# window. Closing the window (the app exits with code 0) leaves it quit until the tray
# icon is clicked, so a deliberate close never brings the window back. Crashes are
# restarted. An update is waited out instead of relaunching mid-update.
$ErrorActionPreference = 'Stop'
# WinForms (the tray menu especially) is only reliable on an STA thread. The launcher
# passes -STA; if the script is started without it, relaunch once before taking the
# single-instance mutex so this process is not mistaken for the running helper.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
  if ($env:GBT_STA_RELAUNCH -eq '1') { Write-Error 'Grok Bot Tray needs STA PowerShell (powershell.exe -STA).'; exit 1 }
  $env:GBT_STA_RELAUNCH = '1'
  $ps = (Get-Process -Id $PID).Path
  $arg = "-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
  Start-Process -FilePath $ps -ArgumentList $arg -WindowStyle Hidden
  exit 0
}
$policy = Join-Path $PSScriptRoot 'policy.ps1'
if (-not (Test-Path -LiteralPath $policy)) { Write-Error "Missing $policy"; exit 1 }
. $policy
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
  // v1.2.4: the WinEvent hook callback only queues the window handle. All property-store (COM)
  // work happens once per window on a background worker thread, so the helper's UI thread never
  // makes a cross-process call that could stall, and a slow call never holds up Grok Bot.
  public static string HookAumid, HookIcon, HookCmd, HookExe; public static int HookCount, StuckCount;
  delegate void WinEventProc(IntPtr hook, uint ev, IntPtr h, int idObj, int idChild, uint thread, uint time);
  [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr mod, WinEventProc cb, uint pid, uint tid, uint flags);
  [DllImport("user32.dll")] static extern bool UnhookWinEvent(IntPtr h);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint f);
  [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr h, int c);
  // v1.2.5: the hook callback runs on its own thread (see HookPump), not the UI thread.
  [DllImport("user32.dll")] static extern int GetMessage(out MSG m, IntPtr h, uint min, uint max);
  [DllImport("user32.dll")] static extern bool PeekMessage(out MSG m, IntPtr h, uint min, uint max, uint remove);
  [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG m);
  [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref MSG m);
  [DllImport("user32.dll")] static extern bool PostThreadMessage(uint tid, uint msg, IntPtr w, IntPtr l);
  [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
  [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int x; public int y; }
  static WinEventProc cb; static IntPtr hookCreate, hookShow;
  static System.Threading.Thread hookPump; static uint hookTid; static volatile bool hookStop; static volatile int hookState;
  static System.Threading.ManualResetEvent hookStarted;
  static readonly object gate = new object();
  static System.Collections.Generic.HashSet<uint> pids = new System.Collections.Generic.HashSet<uint>();
  static System.Collections.Generic.HashSet<uint> otherPids = new System.Collections.Generic.HashSet<uint>();
  [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint a, bool i, uint pid);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern bool QueryFullProcessImageName(IntPtr h, uint f, System.Text.StringBuilder b, ref uint n);
  // Kernel-only lookup (no window messages): is this process the Grok Bot exe? Runs on the worker.
  static bool IsAppPid(uint pid) {
    lock (gate) { if (pids.Contains(pid)) return true; if (otherPids.Contains(pid)) return false; }
    bool mine = false; IntPtr ph = OpenProcess(0x1000 /*QUERY_LIMITED_INFORMATION*/, false, pid);
    if (ph != IntPtr.Zero) { try { var b = new System.Text.StringBuilder(1024); uint n = 1024;
      if (QueryFullProcessImageName(ph, 0, b, ref n)) mine = HookExe != null && string.Equals(System.IO.Path.GetFileName(b.ToString()), HookExe, StringComparison.OrdinalIgnoreCase);
    } finally { CloseHandle(ph); } }
    lock (gate) { if (mine) pids.Add(pid); else { if (otherPids.Count > 2000) otherPids.Clear(); otherPids.Add(pid); } }
    return mine;
  }
  // Same kernel lookup, for the background update scan. Does not send window messages.
  public static string ImagePath(int pid) {
    if (pid <= 0) return null;
    IntPtr ph = OpenProcess(0x1000, false, (uint)pid);
    if (ph == IntPtr.Zero) return null;
    try {
      var b = new System.Text.StringBuilder(1024); uint n = 1024;
      if (!QueryFullProcessImageName(ph, 0, b, ref n)) return null;
      return b.ToString();
    } finally { CloseHandle(ph); }
  }
  static System.Collections.Generic.HashSet<long> tagged = new System.Collections.Generic.HashSet<long>();
  static System.Collections.Generic.HashSet<long> queuedSet = new System.Collections.Generic.HashSet<long>();
  static System.Collections.Concurrent.BlockingCollection<IntPtr> queue = new System.Collections.Concurrent.BlockingCollection<IntPtr>();
  static System.Threading.Thread worker; static long busySince; static long busyHwnd;
  // Grok Bot process IDs, refreshed by the background watch (no process lookups inside the hook).
  public static void SetPids(int[] list) { lock (gate) { pids.Clear(); otherPids.Clear(); if (list == null) return; foreach (int p in list) pids.Add((uint)p); } }
  public static bool IsTagged(IntPtr h) { lock (gate) { return tagged.Contains(h.ToInt64()); } }
  public static void Enqueue(IntPtr h) {
    if (h == IntPtr.Zero) return; long k = h.ToInt64();
    lock (gate) { if (tagged.Contains(k) || queuedSet.Contains(k)) return; queuedSet.Add(k); }
    queue.Add(h);
  }
  public static bool StartHook() {
    if (hookPump != null) return hookState == 1;
    hookStarted = new System.Threading.ManualResetEvent(false);
    hookPump = new System.Threading.Thread(HookPump);
    hookPump.IsBackground = true; hookPump.Name = "GrokBotTray hook";
    hookPump.SetApartmentState(System.Threading.ApartmentState.STA);
    hookPump.Start();
    hookStarted.WaitOne(5000);
    return hookState == 1;
  }
  // Message loop for the out-of-context WinEvent hook. Callbacks stay off the UI thread
  // so a burst of window events cannot delay the tray menu. Unhook on this thread only.
  static void HookPump() {
    MSG prime; PeekMessage(out prime, IntPtr.Zero, 0, 0, 0); // creates this thread's message queue
    hookTid = GetCurrentThreadId();
    try {
      StartWorker();
      cb = new WinEventProc(OnEvent);
      // EVENT_OBJECT_CREATE (0x8000) and EVENT_OBJECT_SHOW (0x8002) only; WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS.
      hookCreate = SetWinEventHook(0x8000, 0x8000, IntPtr.Zero, cb, 0, 0, 0x0000 | 0x0002);
      hookShow = SetWinEventHook(0x8002, 0x8002, IntPtr.Zero, cb, 0, 0, 0x0000 | 0x0002);
      hookState = (hookCreate != IntPtr.Zero && hookShow != IntPtr.Zero) ? 1 : -1;
    } catch { hookState = -1; }
    hookStarted.Set();
    if (hookState != 1 || hookStop) { UnhookAll(); return; }
    MSG msg;
    while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0) { TranslateMessage(ref msg); DispatchMessage(ref msg); }
    UnhookAll();
  }
  static void UnhookAll() {
    if (hookCreate != IntPtr.Zero) { UnhookWinEvent(hookCreate); hookCreate = IntPtr.Zero; }
    if (hookShow != IntPtr.Zero) { UnhookWinEvent(hookShow); hookShow = IntPtr.Zero; }
  }
  public static void StopHook() {
    hookStop = true;
    uint tid = hookTid;
    if (tid != 0) PostThreadMessage(tid, 0x0012 /*WM_QUIT*/, IntPtr.Zero, IntPtr.Zero);
    var t = hookPump;
    if (t != null && t != System.Threading.Thread.CurrentThread) { try { t.Join(2000); } catch { } }
  }
  static void OnEvent(IntPtr hk, uint ev, IntPtr h, int idObj, int idChild, uint thread, uint time) {
    try {
      if (idObj != 0 || idChild != 0 || h == IntPtr.Zero || HookAumid == null) return;
      uint pid; GetWindowThreadProcessId(h, out pid);
      lock (gate) { if (otherPids.Contains(pid)) return; }   // known non-Grok Bot process: drop
      if (GetAncestor(h, 2 /*GA_ROOT*/) != h) return;   // top-level windows only
      Enqueue(h);   // Grok Bot or not-yet-known process: the worker checks it
    } catch { }
  }
  public static void StartWorker() {
    worker = new System.Threading.Thread(Work); worker.IsBackground = true; worker.Name = "GrokBotTray tagger";
    worker.SetApartmentState(System.Threading.ApartmentState.STA); worker.Start();
  }
  static void Work() {
    foreach (IntPtr h in queue.GetConsumingEnumerable()) {
      long k = h.ToInt64();
      lock (gate) { queuedSet.Remove(k); if (tagged.Contains(k)) continue; }
      if (!IsWindow(h)) continue;
      uint wp; GetWindowThreadProcessId(h, out wp); if (!IsAppPid(wp)) continue;
      lock (gate) { tagged.Add(k); }   // once per window, even if the call fails
      System.Threading.Interlocked.Exchange(ref busyHwnd, k);
      System.Threading.Interlocked.Exchange(ref busySince, DateTime.UtcNow.Ticks);
      try { if (TagWindow(h) == 0) System.Threading.Interlocked.Increment(ref HookCount); } catch { }
      System.Threading.Interlocked.Exchange(ref busySince, 0);
      if (worker != System.Threading.Thread.CurrentThread) return;   // replaced by the watchdog while stuck
    }
  }
  // Timeout guard: if one call takes longer than maxSec, abandon that worker (it is a background
  // thread and the window stays marked as done) and start a fresh one for the rest of the queue.
  public static bool Watchdog(int maxSec) {
    long t = System.Threading.Interlocked.Read(ref busySince);
    if (t == 0 || (DateTime.UtcNow.Ticks - t) < TimeSpan.FromSeconds(maxSec).Ticks) return false;
    System.Threading.Interlocked.Exchange(ref busySince, 0); StuckCount++; StartWorker(); return true;
  }
  public static void TrimTagged() { lock (gate) { tagged.RemoveWhere(k => !IsWindow(new IntPtr(k))); } }
  static int TagWindow(IntPtr h) {
    Guid g = typeof(IPS).GUID; IPS s; int hr = SHGetPropertyStoreForWindow(h, ref g, out s); if (hr != 0) return hr;
    try {
      PK k = new PK(); k.f = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"); k.p = 5;
      PV cur; if (s.GetValue(ref k, out cur) == 0 && cur.vt == 31 && Marshal.PtrToStringUni(cur.p) == HookAumid) return 1;
      if (HookIcon != null && HookCmd != null) { SetStr(s, 2, HookCmd); SetStr(s, 4, "Grok Bot"); SetStr(s, 3, HookIcon + ",0"); }
      return SetStr(s, 5, HookAumid);
    } finally { Marshal.ReleaseComObject(s); }
  }
}
// Shared with the background watch thread. The UI thread only reads it.
public sealed class GBTBox {
  public bool WantSignal;
  public bool WantMain;
  public int MainPid;
  public long Hwnd;
  public bool Running;
  public string Signal;
  public long SignalStartedTicks;
  public long SignalReadyTicks;
  public string ScanError;
  public int Loops;
  public int WatchdogSeen;
  public int[] Pids = new int[0];
  public readonly System.Threading.ManualResetEvent Stop = new System.Threading.ManualResetEvent(false);
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
$GraceCleanExitSec = 20    # after a clean exit (code 0), watch this long for an updater; then leave it closed
$GraceCrashSec     = 4     # after a crash, relaunch after this long (once a post-exit update scan is in)
$QuietAfterUpdateSec = 12  # updater gone and exe untouched this long = update finished
$WaitForSelfRestartSec = 45 # after an update, give the installer this long to start the app itself
$MaxUpdateMinutes  = 20    # never wait longer than this for an update
$MaxRelaunches = 3; $RelaunchWindowMin = 10
$HideAfterRelaunchSec = 8  # keep a crash relaunch hidden while the app tries to show its window

# --- state ---
$script:h = [IntPtr]::Zero
$script:main = $null           # System.Diagnostics.Process of the app's main process
$script:state = 'Running'      # Running | Exited | Updating | AfterUpdate | Closed | Stopped
$script:since = Get-Date
$script:exitCode = $null
$script:exitSeenAt = $null     # local time the tracked process exited; update scans must start after this
$script:exitPending = $false   # tracked process exited, a sibling may still be shutting down
$script:hideNext = $false
$script:hideUntil = [datetime]::MinValue
$script:quitting = $false
$script:startGate = $false
$script:lastStart = [datetime]::MinValue
$script:lastSurface = [datetime]::MinValue
$script:lastDirect = [datetime]::MinValue
$script:launches = New-Object System.Collections.ArrayList
$script:exeStamp = $null
$script:box = $null
$script:loggedTags = 0
$script:loggedStuck = 0
$script:loggedScanError = ''
$script:scannerNoted = $false

function Get-ExeStamp {
  try { $f = Get-Item -LiteralPath $exe; return "{0}|{1}|{2}" -f $f.Length, $f.LastWriteTimeUtc.Ticks, $f.VersionInfo.FileVersion } catch { return $null }
}
function Test-ExeChanged {
  if (-not $script:exeStamp) { return $false }
  $stamp = Get-ExeStamp
  if (-not $stamp) { return $false }
  return ($stamp -ne $script:exeStamp)
}
function Find-Win { foreach ($p in @(Get-Process -Name $pname -ErrorAction SilentlyContinue)) { if ($p.MainWindowHandle -ne 0) { return $p.MainWindowHandle } }; return [IntPtr]::Zero }
function Test-AppRunning { return [bool](Get-Process -Name $pname -ErrorAction SilentlyContinue) }

function Get-SignalAgeSec {
  $ready = [int64]0
  try { if ($script:box) { $ready = [int64]$script:box.SignalReadyTicks } } catch { return 9999 }
  if ($ready -le 0) { return 9999 }
  return (([datetime]::UtcNow.Ticks - $ready) / [timespan]::TicksPerSecond)
}
function Test-ScanFresh {
  if (-not $script:exitSeenAt -or -not $script:box) { return $false }
  $started = [int64]0
  try { $started = [int64]$script:box.SignalStartedTicks } catch { return $false }
  return (Test-GbtScanFresh -SignalStartedTicks $started -ExitSeenAt $script:exitSeenAt)
}

# Adopt the main PID the background watch found. Get-Process -Id is cheap; the CIM
# query that picks the Electron process without --type= runs on the watch thread.
function Try-AdoptMain {
  if (-not $script:box) { return $false }
  $id = 0
  try { $id = [int]$script:box.MainPid } catch { return $false }
  if ($id -le 0) { $script:box.WantMain = $true; return $false }
  try {
    $p = Get-Process -Id $id -ErrorAction Stop
    try { $null = $p.Handle } catch {}
    if ($p.HasExited) { $script:box.MainPid = 0; $script:box.WantMain = $true; return $false }
    $script:main = $p
    $script:exeStamp = Get-ExeStamp
    return $true
  } catch {
    $script:box.MainPid = 0
    $script:box.WantMain = $true
    return $false
  }
}

function Enter-Running([string]$why) {
  if ($why) { Log $why }
  $script:state = 'Running'
  $script:since = Get-Date
  $script:exitPending = $false
  $script:exitCode = $null
  if ($ni -and $ni.Text -ne 'Grok Bot') { $ni.Text = 'Grok Bot' }
}
function Enter-Exited([datetime]$now) {
  Log "App exited (code=$($script:exitCode)); watching for an update before doing anything"
  $script:state = 'Exited'
  $script:since = $now
  $script:exitSeenAt = $now
  $script:exitPending = $false
  $script:h = [IntPtr]::Zero
  if ($script:box) { $script:box.WantSignal = $true }
  if ($ni) {
    if (Test-GbtCleanExit $script:exitCode) { $ni.Text = 'Grok Bot (closed - click to open)' }
    else { $ni.Text = 'Grok Bot (closed)' }
  }
}
function Enter-Closed([string]$why) {
  Log $why
  $script:state = 'Closed'
  $script:exitPending = $false
  $script:h = [IntPtr]::Zero
  if ($ni) { $ni.Text = 'Grok Bot (closed - click to open)' }
}

function Resolve-Window([switch]$Search) {
  if ($script:h -ne 0 -and [GBTWin]::IsWindow($script:h)) { return $true }
  $script:h = [IntPtr]::Zero
  $raw = [int64]0
  try { if ($script:box) { $raw = [int64]$script:box.Hwnd } } catch {}
  if ($raw -ne 0) {
    $w = New-Object IntPtr ([int64]$raw)
    if ([GBTWin]::IsWindow($w)) { $script:h = $w; return $true }
  }
  if ($Search) {
    $w2 = Find-Win
    if ($w2 -ne 0) { $script:h = $w2; return $true }
  }
  return $false
}
function Show-MainWindow {
  if (-not (Resolve-Window -Search)) { return $false }
  [GBTWin]::ShowWindowAsync($script:h, 9) | Out-Null
  [GBTWin]::SetForegroundWindow($script:h) | Out-Null
  return $true
}
function Update-Window([datetime]$now) {
  if (-not (Resolve-Window)) { return }
  $forceHide = $script:hideNext -or ($now -lt $script:hideUntil)
  if ($forceHide) {
    if ([GBTWin]::IsWindowVisible($script:h)) { [GBTWin]::ShowWindowAsync($script:h, 0) | Out-Null }
    $script:hideNext = $false
    return
  }
  # minimize = hide to tray
  if ([GBTWin]::IsIconic($script:h) -and [GBTWin]::IsWindowVisible($script:h)) { [GBTWin]::ShowWindowAsync($script:h, 0) | Out-Null }
}

function Request-Surface {
  # The app is single-instance; a second launch asks the running one to show its window.
  # Debounced so a click cannot stack processes while the window handle is still unknown.
  $now = Get-Date
  if (($now - $script:lastSurface).TotalSeconds -lt 5) { return }
  $script:lastSurface = $now
  Log 'App is running but has no window yet; asking it to show'
  try { Start-Process -FilePath $exe -WorkingDirectory $installDir | Out-Null } catch { Log "Show request failed: $_" }
}

function Start-App([bool]$hidden, [bool]$automatic) {
  # $automatic is crash recovery only. A manual open (tray click, Show) does not count
  # toward the relaunch limit and is never hidden.
  $tracked = $false
  if ($script:main) { try { $tracked = -not $script:main.HasExited } catch { $tracked = $false } }
  $any = Test-AppRunning
  $recent = -1
  if ($script:lastStart -gt [datetime]'2000-01-01') { $recent = [int]((Get-Date) - $script:lastStart).TotalSeconds }
  $decision = Get-GbtLaunchDecision -Quitting $script:quitting -InFlight $script:startGate -TrackedAlive $tracked -AnyRunning $any -SecondsSinceLaunch $recent
  if ($decision -eq 'skip-already-running') {
    Log 'Start skipped: app is already running; reattaching'
    if (-not $tracked) { [void](Try-AdoptMain) }
    Enter-Running $null
    if (-not $hidden) { if (-not (Show-MainWindow)) { Request-Surface } }
    return
  }
  if ($decision -ne 'start') { Log "Start skipped ($decision)"; return }
  if ($automatic) {
    $t = Get-Date
    while ($script:launches.Count -gt 0 -and ($t - $script:launches[0]).TotalMinutes -gt $RelaunchWindowMin) { $script:launches.RemoveAt(0) }
    if ($script:launches.Count -ge $MaxRelaunches) {
      Log "Not relaunching: $MaxRelaunches launches in $RelaunchWindowMin min. Waiting for the user."
      $script:state = 'Stopped'
      $script:exitPending = $false
      $ni.Text = 'Grok Bot (stopped - click to start)'
      $ni.ShowBalloonTip(5000, 'Grok Bot', 'Grok Bot keeps closing, so it was not restarted. Click the tray icon to start it.', 'Warning')
      return
    }
  }
  $script:startGate = $true
  try {
    Log "Starting app (hidden=$hidden)"
    $p = Start-Process -FilePath $exe -WorkingDirectory $installDir -PassThru
    try { $null = $p.Handle } catch {}   # keep ExitCode readable after it exits
    $script:main = $p
    if ($script:box) { $script:box.MainPid = $p.Id; $script:box.WantMain = $false }
    $script:lastStart = Get-Date
    $script:hideNext = $hidden
    if ($hidden) { $script:hideUntil = $script:lastStart.AddSeconds($HideAfterRelaunchSec) } else { $script:hideUntil = [datetime]::MinValue }
    $script:h = [IntPtr]::Zero
    $script:exitCode = $null
    $script:exitPending = $false
    $script:state = 'Running'
    $script:since = $script:lastStart
    $script:exeStamp = Get-ExeStamp
    if ($automatic) { [void]$script:launches.Add($script:lastStart) }
    if ($ni -and $ni.Text -ne 'Grok Bot') { $ni.Text = 'Grok Bot' }
  } catch {
    Log "Start failed: $_"
    $script:state = 'Closed'
    $script:exitPending = $false
    if ($ni) { $ni.Text = 'Grok Bot (closed - click to open)' }
  } finally { $script:startGate = $false }
}

function Show-App {
  if ($script:state -eq 'Updating' -or $script:state -eq 'AfterUpdate') {
    $ni.ShowBalloonTip(3000, 'Grok Bot', 'Grok Bot is updating. It will come back when the update finishes.', 'Info'); return
  }
  if ($script:state -eq 'Exited' -and $script:box) {
    $sig = [string]$script:box.Signal
    if ($sig -and (Get-SignalAgeSec) -le 3) {
      $ni.ShowBalloonTip(3000, 'Grok Bot', 'Grok Bot is updating. It will come back when the update finishes.', 'Info'); return
    }
  }
  $script:hideNext = $false
  $script:hideUntil = [datetime]::MinValue
  $alive = $false
  if ($script:main) { try { $alive = -not $script:main.HasExited } catch { $alive = $false } }
  if (-not $alive) { $alive = Test-AppRunning }
  if (-not $alive) { $script:launches.Clear(); Start-App $false $false; return }
  Enter-Running $null
  if (-not (Show-MainWindow)) { Request-Surface }
}
function Hide-App {
  if (-not (Resolve-Window -Search)) { return }
  [GBTWin]::ShowWindowAsync($script:h, 0) | Out-Null
}
function Quit-All {
  # v1.2.4: quits only the helper. Grok Bot keeps running and is never closed or killed.
  $script:quitting = $true
  Log 'Quit requested from tray menu (helper only; Grok Bot left running)'
  try { [GBTWin]::StopHook() } catch {}
  if ($script:h -ne 0 -and [GBTWin]::IsWindow($script:h)) { [GBTWin]::ShowWindowAsync($script:h, 9) | Out-Null }   # never leave it hidden
  $ni.Visible = $false
  [System.Windows.Forms.Application]::Exit()
}

function Note-Grouping {
  # Logging only. PID refresh, enqueue, trim, and the tagging watchdog run on the watch thread.
  if ($cfg -and $cfg.aumid -and [GBTWin]::HookCount -ne $script:loggedTags) {
    $script:loggedTags = [GBTWin]::HookCount
    Log "Grouped Grok Bot window(s) under the pin ($($cfg.aumid)); total $($script:loggedTags)"
  }
  $seen = 0
  try { if ($script:box) { $seen = [int]$script:box.WatchdogSeen } } catch {}
  if ($seen -gt $script:loggedStuck) {
    $script:loggedStuck = $seen
    Log 'Window tagging call took over 5 s; skipped that window and started a fresh worker'
  }
  if (-not $script:scannerNoted) {
    $loops = 0
    try { if ($script:box) { $loops = [int]$script:box.Loops } } catch {}
    if ($loops -gt 0) { $script:scannerNoted = $true; Log 'Background watch on (process and update checks off the UI thread)' }
    elseif ($script:scanner -and $script:scanner.HadErrors) {
      $script:scannerNoted = $true
      $err = @($script:scanner.Streams.Error) | Select-Object -First 1
      Log "Background watch failed: $err"
    }
  }
  if ($script:box -and $script:box.ScanError -and $script:box.ScanError -ne $script:loggedScanError) {
    $script:loggedScanError = [string]$script:box.ScanError
    Log "Background scan: $($script:loggedScanError)"
  }
}

function Start-Scanner {
  # Process list, main-PID lookup, and the update-signal walk. Never on the UI thread:
  # a full process scan (and CIM) is what made the tray menu stall.
  $script:box = New-Object GBTBox
  $rs = [runspacefactory]::CreateRunspace()
  $rs.ApartmentState = 'MTA'
  $rs.Open()
  $ps = [powershell]::Create()
  $ps.Runspace = $rs
  $watch = {
    param($box, $exePath, $installDir, $pname, $quiet, $policyPath)
    $ErrorActionPreference = 'Continue'
    try { . $policyPath } catch { $box.ScanError = "policy load: $_"; return }
    $lastTrim = [datetime]::UtcNow
    while (-not $box.Stop.WaitOne(0)) {
      try {
        $procs = @(Get-Process -Name $pname -ErrorAction SilentlyContinue)
        $ids = New-Object System.Collections.Generic.List[int]
        $hwnd = [int64]0
        foreach ($p in $procs) {
          try {
            [void]$ids.Add([int]$p.Id)
            $hw = [int64]$p.MainWindowHandle
            if ($hwnd -eq 0 -and $hw -ne 0) { $hwnd = $hw }
          } catch {}
        }
        $arr = [int[]]$ids.ToArray()
        $box.Pids = $arr
        $box.Running = ($ids.Count -gt 0)
        $box.Hwnd = $hwnd
        try { [GBTWin]::SetPids($arr) } catch { $box.ScanError = "pids: $_" }
        foreach ($p in $procs) {
          try {
            $w = $p.MainWindowHandle
            if ($w -ne 0 -and -not [GBTWin]::IsTagged($w)) { [GBTWin]::Enqueue($w) }
          } catch {}
        }
        foreach ($p in $procs) { try { $p.Dispose() } catch {} }
        if ($box.WantMain -and $box.MainPid -le 0) {
          try {
            $q = "Name='" + ($pname + '.exe').Replace("'", "''") + "'"
            $mp = @(Get-CimInstance Win32_Process -Filter $q | Where-Object { $_.CommandLine -notmatch '--type=' }) | Select-Object -First 1
            if ($mp) { $box.MainPid = [int]$mp.ProcessId }
          } catch { $box.ScanError = "main process: $_" }
        }
        if ($box.WantSignal) {
          $started = [datetime]::UtcNow.Ticks
          $snaps = New-Object System.Collections.Generic.List[object]
          foreach ($gp in [System.Diagnostics.Process]::GetProcesses()) {
            try {
              $path = $null
              try { $path = [GBTWin]::ImagePath([int]$gp.Id) } catch {}
              $snaps.Add([pscustomobject]@{ Name = ($gp.ProcessName + '.exe'); Path = $path })
            } catch {}
            finally { try { $gp.Dispose() } catch {} }
          }
          try {
            $box.Signal = Get-GbtUpdateSignal -Exe $exePath -InstallDir $installDir -ProcessName $pname -QuietSec $quiet -Processes $snaps.ToArray()
            $box.SignalStartedTicks = $started
            $box.SignalReadyTicks = [datetime]::UtcNow.Ticks
          } catch { $box.ScanError = "update signal: $_" }
        }
        try { [void][GBTWin]::Watchdog(5) } catch {}
        try { $box.WatchdogSeen = [GBTWin]::StuckCount } catch {}
        if (([datetime]::UtcNow - $lastTrim).TotalMinutes -ge 10) { $lastTrim = [datetime]::UtcNow; try { [GBTWin]::TrimTagged() } catch {} }
        $box.Loops = $box.Loops + 1
      } catch { $box.ScanError = "$_" }
      if ($box.Stop.WaitOne(1000)) { break }
    }
  }
  [void]$ps.AddScript($watch.ToString()).AddArgument($script:box).AddArgument($exe).AddArgument($installDir).AddArgument($pname).AddArgument([int]$QuietAfterUpdateSec).AddArgument((Join-Path $PSScriptRoot 'policy.ps1'))
  $script:scanner = $ps
  $script:scannerRs = $rs
  $script:scannerHandle = $ps.BeginInvoke()
}
function Get-UpdateSignalNow {
  # One-shot update check for the helper's own updater. Not used by the 1-second tick.
  # The tick reads the background watch instead, so the tray menu never waits on this.
  $snaps = New-Object System.Collections.Generic.List[object]
  foreach ($gp in [System.Diagnostics.Process]::GetProcesses()) {
    try {
      $path = $null
      try { $path = [GBTWin]::ImagePath([int]$gp.Id) } catch {}
      [void]$snaps.Add([pscustomobject]@{ Name = ($gp.ProcessName + '.exe'); Path = $path })
    } catch {}
    finally { try { $gp.Dispose() } catch {} }
  }
  return (Get-GbtUpdateSignal -Exe $exe -InstallDir $installDir -ProcessName $pname -QuietSec $QuietAfterUpdateSec -Processes $snaps.ToArray())
}
function Stop-Scanner {
  try { if ($script:box) { [void]$script:box.Stop.Set() } } catch {}
  try {
    if ($script:scannerHandle) {
      if (-not $script:scannerHandle.AsyncWaitHandle.WaitOne(5000)) {
        try { [void]$script:scanner.Stop() } catch {}
        [void]$script:scannerHandle.AsyncWaitHandle.WaitOne(2000)
      }
      if ($script:scannerHandle.IsCompleted) { try { [void]$script:scanner.EndInvoke($script:scannerHandle) } catch {} }
    }
  } catch {}
  try { if ($script:scanner) { $script:scanner.Dispose() } } catch {}
  try { if ($script:scannerRs) { $script:scannerRs.Close(); $script:scannerRs.Dispose() } } catch {}
}

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
  if ($script:state -in 'Updating', 'AfterUpdate' -or (Get-UpdateSignalNow)) { Log 'Helper update postponed: Grok Bot itself is updating'; return $false }
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
    foreach ($f in 'VERSION', 'install.ps1', 'src\GrokBotTray.ps1', 'src\policy.ps1', 'src\update.ps1', 'src\launcher.cs') {
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
try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch {}
try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch {}
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
$cm.add_Opening({
  try { $miStartup.Checked = Test-Path -LiteralPath $startupLnk; $miAuto.Checked = [bool]$script:settings.autoUpdate } catch {}
})
$cm.Items.Add('-') | Out-Null
$cm.Items.Add('Quit tray helper').add_Click({ Quit-All }) | Out-Null
# Right-click is the menu's own mouse-up path. A MouseClick handler races that path and
# drops or dismisses the menu, so left-click is MouseUp only and ignores the right button.
$ni.ContextMenuStrip = $cm
$ni.add_MouseUp({
  param($s, $e)
  try {
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    [void](Resolve-Window)
    $visible = $script:h -ne 0 -and [GBTWin]::IsWindow($script:h) -and [GBTWin]::IsWindowVisible($script:h) -and -not [GBTWin]::IsIconic($script:h)
    if ($visible) { Hide-App } else { Show-App }
  } catch { Log "Click error: $_" }
})

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
    if ($showEvent.WaitOne(0)) { $script:hideNext = $false; $script:hideUntil = [datetime]::MinValue; Show-App }
    $now = Get-Date
    Show-UpdateResult
    Note-Grouping
    if ($script:box) { $script:box.WantSignal = ($script:state -in 'Exited', 'Updating', 'AfterUpdate') }
    if ($now -ge $script:nextAutoCheck) {
      $script:nextAutoCheck = $now.AddHours($AutoCheckEveryHours)
      if ($script:settings.autoUpdate) {
        if ($script:state -in 'Updating', 'AfterUpdate') { $script:nextAutoCheck = $now.AddMinutes(10); Log 'Auto-update check postponed: Grok Bot is updating' }
        else { Invoke-AutoCheck }
      }
    }
    switch ($script:state) {
      'Running' {
        $trackedAlive = $false
        if ($script:main) { try { $trackedAlive = -not $script:main.HasExited } catch { $trackedAlive = $false } }
        if ($script:main -and -not $trackedAlive) {
          try { $script:exitCode = $script:main.ExitCode } catch { $script:exitCode = $null }
          $script:main = $null
          if ($script:box) { $script:box.MainPid = 0; $script:box.WantMain = $true }
          # A stub can exit 0 while the real Electron process is still starting. Reattach
          # if anything is left; otherwise this exit code is the one we act on.
          if (Test-AppRunning) {
            if (Try-AdoptMain) { Enter-Running 'App process changed; reattached' } else { $script:exitPending = $true }
            return
          }
          Enter-Exited $now
          return
        }
        if ($script:exitPending) {
          if ($script:box.Running -or (Test-AppRunning)) {
            if (Try-AdoptMain) { Enter-Running 'App is running again; reattached' }
            return
          }
          Enter-Exited $now
          return
        }
        if (-not $script:main) {
          $any = [bool]$script:box.Running
          if ($any) { [void](Try-AdoptMain); return }
          $elapsed = [int]($now - $script:since).TotalSeconds
          $miss = Get-GbtMissingDecision -TrackedAlive $false -AnyRunning $false -ExitPending $false -ElapsedSec $elapsed
          if ($miss -eq 'wait') { return }
          if (($now - $script:lastDirect).TotalSeconds -ge 5) {
            $script:lastDirect = $now
            if (Test-AppRunning) { [void](Try-AdoptMain); return }
          } else { return }
          Enter-Closed 'App was not running; leaving it closed until the tray icon is clicked'
          return
        }
        Update-Window $now
        if ($ni.Text -ne 'Grok Bot') { $ni.Text = 'Grok Bot' }
      }
      'Exited' {
        if ($script:box.Running -or ($script:main -and -not $script:main.HasExited)) {
          [void](Try-AdoptMain)
          if ($script:main -and -not $script:main.HasExited) { Enter-Running 'App is running again (started elsewhere); reattached' }
          return
        }
        $elapsed = [int]($now - $script:since).TotalSeconds
        $fileSig = Get-GbtUpdateSignal -Exe $exe -InstallDir $installDir -ProcessName $pname -QuietSec $QuietAfterUpdateSec -Processes @()
        $fresh = Test-ScanFresh
        if (-not $fresh -and $elapsed -ge 30) { $fresh = $true }   # a dead watch must not block crash recovery forever
        $decision = Get-GbtExitDecision -ExitCode $script:exitCode -ElapsedSec $elapsed -Signal ([string]$script:box.Signal) -FileSignal $fileSig -ExeChanged (Test-ExeChanged) -RunningNow $false -ScanFresh $fresh -GraceCleanSec $GraceCleanExitSec -GraceCrashSec $GraceCrashSec
        if ($decision -eq 'wait') { return }
        if ($decision -eq 'updating') {
          $why = $fileSig
          if (-not $why) { $why = [string]$script:box.Signal }
          if (-not $why) { $why = 'app exe changed (new version)' }
          Log "Update detected: $why. Waiting for it to finish."
          $script:state = 'Updating'; $script:since = $now; $script:quietSince = $null; $ni.Text = 'Grok Bot (updating...)'
          return
        }
        if (Test-AppRunning) { $script:box.WantMain = $true; if (Try-AdoptMain) { Enter-Running 'App is running again (started elsewhere); reattached' }; return }
        if ($decision -eq 'stay-closed') { Enter-Closed 'Clean exit (code=0) and no update; leaving Grok Bot closed until the tray icon is clicked'; return }
        if ($decision -eq 'relaunch-hidden') { Start-App $true $true }
      }
      'Updating' {
        $age = Get-SignalAgeSec
        if ($age -gt 3) {
          if (($now - $script:since).TotalMinutes -gt $MaxUpdateMinutes) { Log "Update still running after $MaxUpdateMinutes min; giving up waiting"; $script:state = 'AfterUpdate'; $script:since = $now.AddSeconds(-$WaitForSelfRestartSec) }
          return
        }
        $sig = [string]$script:box.Signal
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
        if ($script:box.Running -or ($script:main -and -not $script:main.HasExited)) {
          if (-not $script:main -or $script:main.HasExited) { [void](Try-AdoptMain) }
          if ($script:main -and -not $script:main.HasExited) { Log 'App restarted after the update; reattached'; $script:launches.Clear(); Enter-Running $null }
          return
        }
        if (($now - $script:since).TotalSeconds -ge $WaitForSelfRestartSec) {
          $sig = [string]$script:box.Signal
          if ($sig -and (Get-SignalAgeSec) -le 3) { $script:state = 'Updating'; $script:since = $now; $script:quietSince = $null; return }
          $script:launches.Clear(); Start-App $false $false
        }
      }
      'Closed' {
        if ($script:box.Running) { [void](Try-AdoptMain); if ($script:main -and -not $script:main.HasExited) { Enter-Running 'App is running again (started elsewhere); reattached' } }
      }
      'Stopped' {
        if ($script:box.Running) { [void](Try-AdoptMain); if ($script:main -and -not $script:main.HasExited) { Enter-Running 'App is running again (started elsewhere); reattached' } }
      }
    }
  } catch { Log "Tick error: $_" }
})
try { Start-Scanner } catch { Log "Background watch failed to start: $_" }
if (-not $script:box) { $script:box = New-Object GBTBox }
if ($cfg -and $cfg.aumid) {
  [GBTWin]::HookAumid = [string]$cfg.aumid; [GBTWin]::HookExe = [IO.Path]::GetFileName($exe)
  [GBTWin]::HookCmd = '"' + (Join-Path $dir 'Grok Bot Tray.exe') + '"'; [GBTWin]::HookIcon = (Get-LnkIcon)
  try { if ([GBTWin]::StartHook()) { Log 'Window hook on (its own thread; tagging on a worker thread)' } else { Log 'Window hook unavailable; grouping falls back to the background watch' } } catch { Log "Window hook failed: $_" }
}
if (Test-AppRunning) { if ($script:box) { $script:box.WantMain = $true }; $script:state = 'Running'; $script:since = Get-Date; Log 'App already running; will attach' }
else { Start-App $false $false }
$timer.Start()
try { [System.Windows.Forms.Application]::Run() } catch { Log "Fatal: $_" } finally {
  try { $timer.Stop() } catch {}
  try { [GBTWin]::StopHook() } catch {}
  try { Stop-Scanner } catch {}
  $ni.Visible = $false; $ni.Dispose(); Log 'Helper stopped'
}
