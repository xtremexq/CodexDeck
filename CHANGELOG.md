# Changelog

## 1.6.0 - 2026-09-22

- Made enabled inspection features discoverable on every interactive account/dashboard launch: context-managed sessions now open an exact-session slim live editor with revision-only idle polling and lazy cards, while Deck otherwise opens Trajectory or standalone Efficiency, selects the newest managed context, tails active rollouts, and never blocks Codex on inspector failures.
- Simplified both desktop layouts to always show all account profiles, subject only to the existing plan filter, and converted the former connected/all switch into a non-interactive account/connection/terminal status surface.
- Collapsed the desktop panel's two action rows into one fast toolbar for adding accounts, opening Deck Analysis, toggling the shared next-launch auto-compact state, and opening Configs. The dashboard **C** control and panel toggle now stay synchronized, while efficiency analytics defaults on for new settings.
- Added an opt-in local trajectory studio with streamed session timelines plus a separately enabled live context manager that can suppress, restore, or edit the next request's model-visible projection across Deck routing, failover and compaction without rewriting raw history.
- Added independently configurable, PrismoDev-inspired efficiency analytics for exact recorded tokens, cache use, repeated commands and paths, oversized tool results, compactions, tools, accounts, projects and models; it shares only the low-level rollout index with Trajectory.
- Changed the default auto-compaction threshold to 55% context remaining and strengthened the custom handoff prompt to preserve the references, paths and function names needed to continue without re-investigation.
- Added `codex-auth resume <conversation-id>` to locate a conversation's owning account or pool and resume it through the complete Deck launch path, including configured routing, failover and optional auto-compaction.
- Added hold-to-adjust in 5% steps for the terminal dashboard's **C** shortcut and one-time percentage overrides such as `codex-auth account1 -AutoCompact 50%`. Auto-compact percentages now consistently mean free context remaining, so 55% triggers at 45% used.
- Made Codex's native token-threshold compaction the default auto-compact implementation for accounts, pools, resumed conversations, manual account switching, configured failover and `exec`; Settings can switch back to Deck's existing custom handoff/compact/replay workflow, whose handoff controls are hidden in Native mode.
- Kept auto-compact dashboard sessions in the same CLI conversation history as direct `codex-auth accountX` launches by preserving the ordinary account's provider identity across both the hosted app-server and native TUI, and by observing new threads without resuming them under a separate client.
- Updated the Windows workflow to the Node 24-based `actions/checkout` release and made the expected invalid-argument stderr assertion reliable under GitHub Actions PowerShell.
- Made native auto-compact percentage parsing safe under PowerShell 7 when the percentage is the only trailing argument, and added PowerShell 7 wrapper coverage.
- Stopped ordinary running sessions from manufacturing a cached local 429 after usage was restored; each explicit new prompt now makes one bounded live probe and clears stale quota state on success.
- Allowed manually retrying a quota-rejected account in a running session after its usage resets; a fresh request verifies eligibility and rejected accounts rotate away again.
- Made quota exclusions expire at the reported or cached reset time, with a bounded fallback probe, so an open session can recover and run remote compaction after usage becomes available again.
- Added globally available, centrally maintained Deck skills with per-account/pool controls, safe user-skill collision handling, launch-time synchronization, and the bundled `debug-swarm` workflow for independent Codex terminal investigations.
- Made terminal-dashboard usage checks explicitly opt-in with **R**/**A**, kept bulk checks responsive, and prevented wrapper/app-server child processes from surviving completed or timed-out workers.
- Kept desktop account rows and the launch dropdown on one merged live cache/account snapshot while eliminating repeated WPF control rebuilding and session-process handle churn.

## 1.5.0 - 2026-09-14

- Replaced the paid-only warm-up checkbox with a multi-select account-type dropdown for all, Free, Go and Plus-or-higher plans, including plan-aware quota windows and account-default models for Free/Go warm-ups.
- Reduced duplicated multi-account storage with guarded stale plugin-sync cleanup and hard-link deduplication for identical sandbox runtimes and managed plugin caches, while preserving per-account credentials, databases, configuration and histories.
- Clarified the primary pool in the account picker, kept it first without selecting it by default, and stopped treating it like a directly authenticated quota account.
- Added local `!deck` launching from Codex conversations plus terminal-dashboard shortcuts for each account or pool's memory files, global `AGENTS.md` instructions and skills folder.
- Added independent concurrent Responses and compaction failover requests, including correct active-request tracking, cancellation handling and safe forwarding of decoded auxiliary request bodies.
- Made repeat Deck launches wake the resident window immediately, made the desktop launcher fully windowless, and populated installed accounts and recent sessions in the first rendered frame.
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
