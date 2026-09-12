# Changelog

## Unreleased

- Added independent concurrent Responses and compaction failover requests, including correct active-request tracking, cancellation handling and safe forwarding of decoded auxiliary request bodies.
- Made repeat Deck launches wake the resident window immediately, restored it reliably without hiding the caller's terminal, and populated installed accounts and recent sessions in the first rendered frame.
- Moved warm-up schedule repair off the UI thread, added persistent watchdog health checks and preserved known future quota resets to avoid tight retry loops.

## 1.4.0 - 2026-09-11

- Added isolated pooled environments that rotate across selected accounts while retaining one Codex home, plus explicit sharing controls for skills, memories, instructions and individual MCP definitions.
- Added Global Rules and local `!account`, `!pool`, `!check` and `!usage` commands for session routing and active-route usage.
- Hardened live failover with manual account switching, safe Codex endpoint forwarding, quieter terminal output, reliable cleanup and bounded session-exit diagnostics.
- Made automatic warm-up scheduling an explicit opt-in, moved it to a clearly named windowless scheduled task and preserved working legacy schedules if migration fails.
- Kept large account collections responsive with concurrent bounded checks, single-pass rendering, lazy details, nonblocking output handling and batched cache writes.
- Improved quota health and reset freshness so exhausted weekly windows show their blocking reset without hiding otherwise successful usage data.
- Added encrypted configuration/account backup and restore, searchable selectors, compact usage summaries, remembered geometry and broader panel/widget polish.
- Fixed the Windows checks workflow falsely failing after a successful mock nonzero-exit assertion by clearing the expected native-process status in the test harness.
- Expanded regression coverage for pooled environments, failover, session controls, background scheduling, shell commands and installation.

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

## 1.0.0 â€” 2026-09-06

First public release of Codex Deck for Windows.

- Isolated Codex CLI account profiles and terminal session tracking.
- Dark panel, compact expandable account rows, floating widget, and tray controls.
- Manual checks, optional automatic checks, quota/reset displays, and optional account-picker usage details.
- Account config editor, global defaults, named account creation, and folder selection.
- Optional Usage Warmup with model discovery and guarded reset scheduling.
- Custom application icon, source installer, privacy exclusions, and Windows test workflow.
