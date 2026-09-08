# Changelog

## 1.3.0 - 2026-09-08

- Added a themed support invitation on the first Settings visit and every 35 days thereafter, opening About.
- Hid Save settings on Backup and About.
- Redesigned the support page with optional GitHub sponsorships and clearer project information.
- Added panel minimize, removed redundant actions, and hid widget/Settings taskbar entries.
- Restyled Settings and grouped Details, including reset credits enabled by default.
- Fixed the codex-check batch encoding error and expanded compaction proxy regression coverage.
- Refreshed the README and desktop preview.

## 1.2.0 - 2026-09-08

- Fixed Windows CI failover startup with explicit BOM-free UTF-8.
- Combined Checks and Warmup settings, added clickable view/check status bars, and removed the terminal F shortcut.
- Added a dedicated support page linked from README and About.
- Added opt-in live failover, saved desktop defaults, explicit account pools, ordered/best selection and bounded pre-stream quota retries.
- Added best-account recommendations, unified local session history, account rename and manual reset-credit details.
- Fixed slow history loading for large session collections and metadata headers; H opens history and S opens desktop Settings from the terminal dashboard.
- Updated the desktop companion, settings, encrypted backup/restore, account picker, warm-up controls and synthetic preview.
- Expanded regression coverage for account tools, failover, desktop behavior and installation.

## 1.1.0 — 2026-09-08

- Bare `codex-auth` now opens an interactive terminal dashboard with cached usage, background refresh, quota bars, search and keyboard navigation.

- Launch Codex, log in, create profiles and open desktop Deck from the dashboard.

- Added `codex-auth status` and automatic snapshot mode for redirected input/output.

- Display free-plan quota windows, local reset times, connected sessions and masked emails.

- Preserve responsiveness with bounded background checks, timeout cleanup and redraws only when the display changes.

- Skip unchanged installer payloads, including assets held open by the desktop companion.

- Rebuilt the README with current terminal and desktop previews; refreshed contributor instructions and excluded encrypted account exports from Git.

## Unreleased (local only)

- Keep large account lists responsive with single-pass list rendering, retained rows per view, shared account menus, lazy expanded details, batched cache writes, and nonblocking worker output handling.
- Independent quota health and reset freshness; successful usage remains visible after failed checks.
- Concurrent checks with an eight-worker cap, post-list cooldown and immediate per-account checks.
- Searchable warm-up account selection and compact single-line picker usage.
- Smaller content-aware panel/widget bounds, remembered geometry and expansion, and corrected scrollbars.
- Themed entry actions, recovery deletion, pinning and widget account filtering.
- Centered status bars, cleaned-up hover behavior and settings styling.
- AES-256-GCM password-encrypted configuration/account export and validated import; Backup and About tabs.
- Fifty proposed features in docs/FEATURE-IDEAS.md.

## 1.0.0 â€” 2026-09-06

First public release of Codex Deck for Windows.

- Isolated Codex CLI account profiles and terminal session tracking.
- Dark panel, compact expandable account rows, floating widget, and tray controls.
- Manual checks, optional automatic checks, quota/reset displays, and optional account-picker usage details.
- Account config editor, global defaults, named account creation, and folder selection.
- Optional Usage Warmup with model discovery and guarded reset scheduling.
- Custom application icon, source installer, privacy exclusions, and Windows test workflow.
