# Changelog

## v1.1.0 - 2026-10-28
- Tray menu shows the installed version as a header (`Grok Bot Tray v1.1.0`), read from the new `VERSION` file.
- New **Start with Windows** toggle in the tray menu (adds/removes the Startup shortcut).
- New **Open log** item (opens `tray.log`).
- New **Check for updates** item: checks GitHub for a newer version and offers to open the repo page.
- New icon that is obviously different from stock Grok Bot at 16-32 px: blue frame, blue-tinted logo, orange corner badge (tray, launcher, pin, shortcuts).
- Installer copies `VERSION` and prints the installed version.

## v1.0.0 - 2026-10-28
- First public release: tray icon, minimize/close to tray, auto-start, badged icon, taskbar pin repointing, update-aware restart, per-user install/uninstall.
