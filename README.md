# Grok Bot Tray (unofficial)

**Current stable release: v1.2.3** (branch `v1.2.3`; see [CHANGELOG.md](CHANGELOG.md)).


> **Unofficial community tool.** Not affiliated with, endorsed by, or supported by xAI. "Grok" and "Grok Bot" are names of their owner. This helper never modifies Grok Bot's own files.

A small per-user helper for Windows that keeps the **Grok Bot** desktop app in the notification area (system tray):

- Left-click the tray icon to show or hide Grok Bot. Minimizing hides it to the tray.
- Starts with Windows (optional) and keeps Grok Bot running if it crashes.
- **Update-aware:** when Grok Bot closes to install an update, the helper waits for the installer to finish instead of relaunching the app mid-update, then reattaches (or starts it if the installer didn't).
- Uses its own green bot icon (`assets/icon.png.b64`, a base64-encoded PNG) so you can tell the helper apart from the regular app, in the tray, on the launcher and on a taskbar pin.

No admin rights needed. Everything lives in `%LOCALAPPDATA%\GrokBotTray`.

## Install

1. Download the latest zip from [Releases](../../releases) (or **Code > Download ZIP**) and unzip it anywhere.
2. Double-click `install.cmd`, or run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install.ps1
   ```

The installer finds Grok Bot automatically (per-user or all-users install). Options:

| Option | What it does |
| --- | --- |
| `-AppPath "C:\path\to\Grok Bot.exe"` | Use this path instead of auto-detecting |
| `-NoStartup` | Don't start the helper when you sign in |
| `-NoPinUpdate` | Leave an existing Grok Bot taskbar pin alone |
| `-DesktopShortcut` | Add a "Grok Bot Tray" desktop shortcut |
| `-NoLaunch` | Install without starting the helper |

What it sets up:

- `%LOCALAPPDATA%\GrokBotTray` with the helper script, a tiny launcher exe (compiled on your PC with the C# compiler built into Windows), the helper icon (built from `assets/icon.png.b64`, a base64-encoded PNG, 16-256 px), and `config.json`.
- A **Grok Bot Tray** shortcut in the Start menu, and one in your Startup folder.
- If Grok Bot is already pinned to the taskbar, that pin is backed up and pointed at the helper with the badged icon. The pin keeps Grok Bot's app ID, and the helper tags the open Grok Bot window with that same ID (a window property only; app files are never changed), so the window groups under the pin as one taskbar button.

Re-running `install.ps1` upgrades in place.

## Tray menu

Right-click the tray icon:

| Item | What it does |
|---|---|
| **Grok Bot Tray vX.Y.Z** | Shows the installed helper version (from the `VERSION` file) |
| Show / Hide | Bring Grok Bot up or hide it to the tray |
| Start with Windows | Checkmark toggle; adds or removes the Startup-folder shortcut |
| Open log | Opens `%LOCALAPPDATA%\GrokBotTray\tray.log` in Notepad |
| Auto-update | Checkmark toggle (on by default): check GitHub at start and daily, install newer versions automatically |
| Check for updates | Asks GitHub for the newest version and offers Install now (or open this page) |
| Quit Grok Bot | Closes Grok Bot and the helper |

Left-click shows or hides Grok Bot. See [CHANGELOG.md](CHANGELOG.md) for what changed in each version.

## Auto-update

With **Auto-update** on, the helper checks GitHub about a minute after it starts and then every 24 hours. When a newer `vX.Y.Z` release, tag or branch exists it downloads that version, verifies the package, backs up your install to `%LOCALAPPDATA%\GrokBotTray.bak`, runs `install.ps1 -Upgrade` (keeping shortcuts, pin and the Start with Windows choice) and restarts the helper. If the new helper doesn't start within 30 seconds, the backup is restored and that version is skipped on later automatic checks. It waits if Grok Bot itself is updating. Details go to `tray.log`.

### Testing updates locally (developers only)

Add `"devUpdateSource": "C:\\path\\to\\package-folder-or.zip"` to `%LOCALAPPDATA%\GrokBotTray\settings.json` and restart the helper. Update checks then read that package instead of GitHub. The folder or zip must contain one top-level folder holding `VERSION`, `install.ps1` and `src\`. Remove the setting when done.

## Uninstall

Double-click `uninstall.cmd` (in the download, or in `%LOCALAPPDATA%\GrokBotTray` via `uninstall.ps1`), or run:

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

It stops the helper, restores your original taskbar pin, removes its shortcuts and deletes `%LOCALAPPDATA%\GrokBotTray`. Grok Bot itself is not touched. Use `-KeepFiles` to keep the folder.

## How update detection works

When Grok Bot's main process exits, the helper records the exit code and then looks for signs of an update before doing anything:

- an updater/installer process (e.g. `installer.exe` in a `*-updater` folder, `elevate.exe` or `Uninstall Grok Bot.exe` from the app folder, NSIS helpers like `Au_.exe`, Squirrel `Update.exe`, or a `Grok Bot*Setup*.exe`);
- `Grok Bot.exe` missing, locked for writing, recently rewritten, or showing a new version.

If it sees any of these, it waits until they've been gone for a few seconds, gives the installer time to restart Grok Bot itself, and only starts it if nothing did. After a clean exit with no update it waits about 20 seconds before restarting the app (hidden in the tray); after a crash about 4 seconds. If the app closes 3 times within 10 minutes it stops restarting it and shows a notification. Activity is logged to `%LOCALAPPDATA%\GrokBotTray\tray.log`.

## Limitations

- Windows 10 or 11 only, and it needs Windows PowerShell 5.1 and .NET Framework 4 (both built in).
- Hiding works by hiding Grok Bot's main window; if a future app version changes how its window works, show/hide may need an update.
- Windows doesn't let programs pin to the taskbar. If you didn't have Grok Bot pinned, open Start, right-click **Grok Bot Tray** and choose **Pin to taskbar**.
- Explorer caches icons. If an old icon sticks around after install, sign out and back in.
- If Grok Bot's own "open at login" setting is on, both start at sign-in; that's fine, the helper just attaches to the running app.
- Update detection is heuristic. A very long update (over 20 minutes) is treated as finished.
- "Quit Grok Bot" in the tray menu asks the app to close, then ends it if it doesn't close within a few seconds.

## Testing

`tests\simulate-update.ps1` builds a dummy app and runs the helper against it through an update, an installer-driven restart, a crash and a clean quit, then prints the log. It uses separate names, so it won't interfere with a running helper.

## License

[MIT](LICENSE)
