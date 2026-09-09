# Usage Bar for CodeX

A native macOS menu-bar app for Codex quota and local project usage. Version **1.5 (build 10)**.

![CodeX Usage Bar icon](AppIcon.png)

## Download and install

Download the macOS ZIP from [the latest release](../../releases/latest), unzip it, and drag **CodeX Usage Bar.app** into Applications. Quit an older copy before replacing it. The universal build supports Apple Silicon and Intel Macs running macOS 13 or later.

The community build is ad-hoc signed and is not Apple-notarized. macOS may require approval in System Settings → Privacy & Security after the first launch attempt.

## Features

- Weekly remaining quota in the menu bar, plus five-hour and weekly quota windows and reset times in the menu.
- Requests live quota when the menu opens and every 10 minutes.
- Shows a refreshing indicator and explicitly marks refresh failures; local or previous values are not labeled as live.
- Shows a USD credit balance after quota exhaustion only when the returned data includes a finite balance.
- Local seven-day project token estimates, with project summaries refreshed at most once per hour.
- Optional native notifications to follow Codex launch and quit.
- Chinese and English interface, selected from the system language.

## Requirements and live quota

The current implementation expects the Codex executable at `/Applications/ChatGPT.app/Contents/Resources/codex`, with an existing signed-in Codex account. It starts that executable in app-server mode and requests `account/rateLimits/read` over standard input/output. Installations at a different path need a source adjustment; a standalone CLI installation alone is insufficient for live refresh in this version.

Live quota depends on the installed Codex version, authentication and network connectivity. If the request fails, the app clearly marks the failure and may display local records or the last successful result.

## Data and privacy

Project estimates and fallback quota snapshots are read from local Codex JSONL session records under `~/.codex`. The app does not modify or delete those records and includes no telemetry or analytics upload service. Preferences and folder bookmarks are stored locally.

**Live refresh is not offline:** the Codex app-server may contact OpenAI using its existing account session. The app does not request an API key or browser cookies, and it does not make model-generation calls. Project estimates cover records on this Mac and are not a billing report.

## Build from source

Install Xcode with the macOS SDK, then run:

```sh
zsh build.sh
open "build/CodeX Usage Bar.app"
```

The script compiles both arm64 and x86_64, packages the app and applies an ad-hoc signature. The GitHub build is unsandboxed so it can read local Codex records and launch app-server. The complete application source is in `CodexQuotaMenu.swift`, combining the local app entry point and menu controller.

To check live quota from a terminal:

```sh
"build/CodeX Usage Bar.app/Contents/MacOS/CodexQuotaMenu" --check-usage
```

This prints account quota percentages locally. Do not include account output or session records in public bug reports.

## Uninstall

Disable the Codex-follow options, quit the app and move it to the Trash. It has no updater or separately installed daemon.

## License and author

MIT License. Created by Qingdian Dai with assistance from OpenAI Codex. Independent third-party software, not affiliated with or endorsed by OpenAI.
