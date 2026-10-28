# Changelog

## v1.2.0 - 2026-10-28
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
