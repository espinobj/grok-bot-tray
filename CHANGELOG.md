# Changelog

## v1.2.4 - 2026-11-01 (current stable release)

Tested on Windows 11 / Windows PowerShell 5.1 (BlackKnight), including a 48-hour watch of the Application event log: no hangs attributable to the tray helper (all Grok Bot hangs recorded in that window were Windows DNS Client / DNSResolver waits, unrelated to the helper).

- Fix: Grok Bot could hang ("AppHangXProcB1", waiting on another process) every few hours after v1.2.3. The v1.2.3 window hook did COM property-store calls and process lookups inside the hook callback on the helper's UI thread, for every window create/destroy/show on the system. Now:
  - The hook listens only to window create and show (`WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS`), only for Grok Bot process IDs and top-level windows, and does nothing but queue the window handle.
  - A background worker thread tags each window once (already-tagged windows are skipped). A watchdog abandons any tagging call that takes over 5 seconds and starts a fresh worker, so a slow call cannot stall anything.
  - The 1-second timer only queues untagged windows as a backup.
- Fix: all show/hide calls on Grok Bot's window use `ShowWindowAsync`, so the helper never waits on Grok Bot's window.
- Change: the tray menu item is now **Quit tray helper**. It closes only the helper and never closes or kills Grok Bot (v1.2.3 and earlier force-killed Grok Bot if it did not close within 8 seconds). The self-updater also only stops the helper.

## v1.2.3 - 2026-10-28

- Fix: after upgrading, the taskbar pin could keep showing the old icon because Explorer caches icons by file path. Shortcuts (pin, Start menu, Startup, desktop) now use a versioned icon file (`icon-v123.ico`, recorded in `config.json`); older `icon-v*.ico` files are removed. The tray keeps using `GrokBotTray.ico`.
- Fix: while Grok Bot was opening, a second stock-icon taskbar button flashed up until the helper's 1-second timer tagged the window. The helper now uses a WinEvent hook (window create/show) to tag Grok Bot windows the instant they appear, and also sets the window's relaunch icon/command to the helper. The timer remains as a fallback.

## v1.2.2 - 2026-10-28

Tested on Windows 11 / Windows PowerShell 5.1 (BlackKnight).

- Fix: clicking the taskbar pin opened a second, separate Grok Bot taskbar button. The pin uses the app's shortcut ID (`com.anysphere.sand`), but the running window reports the app's process ID (`electron.app.Grok Bot`), so Windows treated them as two apps. The helper now tags the Grok Bot window with the pin's ID (window property only, app files untouched), so there is one taskbar button. Re-applied automatically whenever the app restarts or opens a new window.
- New icon: green bot artwork (`assets/icon.png.b64`, a base64-encoded PNG), cropped tight with a transparent background, built into a 16-256 px .ico for the tray, launcher exe, pin and shortcuts. The old badged icon is only a fallback if the artwork is missing.

## v1.2.1 - 2026-10-28

Tested on Windows 11 / Windows PowerShell 5.1: automatic upgrade, rollback of a deliberately broken package (one notification), and no retry of a failed version.

- Fix: the updater's "did the new helper start?" check always failed (`.Count` on a single CIM object is empty in Windows PowerShell 5.1), so every auto-update was rolled back. Now uses `@(...).Count`.
- Updater also writes `%TEMP%\GrokBotTray-update.log`, and rollback no longer overwrites `tray.log`, so failures are diagnosable.
- Fix: rollback now restores every file (it could leave the new VERSION behind), logs the restored version, and keeps tray.log.
- Fix: the "updated" notification now appears (it was missed when the new helper started before the updater finished).
- Hardening: only one updater can run at a time; the start check only counts log lines written after the update began; automatic update failures are logged without alerts (manual Check for updates still reports them); updater log size capped; TLS 1.2 forced for downloads.
- Dev-only `devUpdateSource` setting to test updates from a local package (see README).
- A failed version is retried only from Check for updates, never automatically, so there is at most one failure notification per version.

## v1.2.0 - 2026-10-28 (superseded: its updater check always failed and rolled back)
- **Auto-update**: checks GitHub about a minute after the helper starts and every 24 hours. If a newer version exists it downloads it, checks the package (VERSION matches, installer and scripts present), backs up `%LOCALAPPDATA%\GrokBotTray` to `GrokBotTray.bak`, runs the installer in `-Upgrade` mode and restarts the helper. If the new helper has not started within 30 seconds it rolls back and skips that version on later automatic checks.
- Never updates while Grok Bot itself is updating.
- Tray menu: new **Auto-update** toggle (on by default, saved in `settings.json`); **Check for updates** now offers **Install now**.
- Notification after an update (or a failed, rolled-back one). Everything is written to `tray.log`.
- `install.ps1 -Upgrade` keeps your Start with Windows choice, shortcuts and taskbar pin.

## v1.1.0 - 2026-10-28
- Tray menu shows the installed version as a header (`Grok Bot Tray v1.1.0`), read from the new `VERSION` file.
- New **Start with Windows** toggle in the tray menu (adds/removes the Startup shortcut).
- New **Open log** item (opens `tray.log`).
- New **Check for updates** item: checks GitHub for a newer version and offers to open the repo page.
- New icon that is obviously different from stock Grok Bot at 16-32 px: blue frame, blue-tinted logo, orange corner badge (tray, launcher, pin, shortcuts).
- Installer copies `VERSION` and prints the installed version.

## v1.0.0 - 2026-10-28
- First public release: tray icon, minimize/close to tray, auto-start, badged icon, taskbar pin repointing, update-aware restart, per-user install/uninstall.
