# Changelog

## 1.1.0 — 2026-09-08

- Bare `codex-auth` now opens an interactive terminal dashboard with cached usage, background refresh, quota bars, search and keyboard navigation.
- Launch Codex, log in, create profiles and open desktop Deck from the dashboard.
- Added `codex-auth status` and automatic snapshot mode for redirected input/output.
- Display free-plan quota windows, local reset times, connected sessions and masked emails.
- Preserve responsiveness with bounded background checks, timeout cleanup and redraws only when the display changes.
- Skip unchanged installer payloads, including assets held open by the desktop companion.
- Rebuilt the README with current terminal and desktop previews; refreshed contributor instructions and excluded encrypted account exports from Git.

## 1.0.0 â€” 2026-09-06

First public release of Codex Deck for Windows.

- Isolated Codex CLI account profiles and terminal session tracking.
- Dark panel, compact expandable account rows, floating widget, and tray controls.
- Manual checks, optional automatic checks, quota/reset displays, and optional account-picker usage details.
- Account config editor, global defaults, named account creation, and folder selection.
- Optional Usage Warmup with model discovery and guarded reset scheduling.
- Custom application icon, source installer, privacy exclusions, and Windows test workflow.
