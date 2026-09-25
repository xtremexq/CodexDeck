<p align="center">
  <img src="suite/deck/assets/codex-deck.png" width="88" alt="Codex Deck">
</p>
<h1 align="center">Codex Deck</h1>
<p align="center"><strong>Your Codex CLI accounts, usage, and conversations in one place.</strong><br>
A Windows terminal dashboard and desktop companion for an existing Codex CLI installation.</p>
<p align="center">
  <a href="https://github.com/xtremexq/CodexDeck/actions/workflows/test.yml"><img src="https://github.com/xtremexq/CodexDeck/actions/workflows/test.yml/badge.svg" alt="Windows checks"></a>
  <img src="https://img.shields.io/badge/Windows-PowerShell%205.1-0078D4" alt="Windows PowerShell 5.1">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-69dec0" alt="MIT license"></a>
</p>
<p align="center"><a href="#install">Install</a> · <a href="#terminal-dashboard">Terminal</a> · <a href="#desktop-companion">Desktop</a> · <a href="#commands">Commands</a> · <a href="#help">Help</a></p>

<p align="center"><img src="docs/terminal.png" width="1040" alt="Synthetic Codex Deck terminal dashboard with five profiles, quota bars, reset times, and keyboard shortcuts"></p>
<p align="center"><em>Terminal dashboard · synthetic example accounts</em></p>

## What Deck adds

- **See usage without hopping between accounts.** `codex-auth` opens a keyboard-driven dashboard with cached quota, reset, and session data. `codex-deck` opens a desktop panel or floating widget. Refresh on demand, or opt into desktop polling.
- **Keep accounts separate.** Each profile gets its own Codex home, sign-in, configuration, and history. A pool can use quotas from accounts you choose while keeping one environment; sharing skills, memories, instructions, or MCP definitions is explicit.
- **Stay in control when a limit is reached.** Use `!account` to change the active account during a conversation. Optional automatic failover retries supported quota-rejected requests with another account in your selected pool. [How failover works and where it stops](docs/ACCOUNT-TOOLS.md#live-failover-opt-in).
- **Manage the conversation as it runs.** Optional live context inspection lets you review and edit the next request. Auto-compaction, local efficiency analytics, and `!delay` / `!schedule` are available when you need them.
- **Add only the extras you choose.** Warm-up, integrations, and an installable skill catalog are opt-in. Warm-up sends real requests and consumes quota.

Deck is [MIT-licensed](LICENSE), free, and open source. There is no paid tier. It uses your separately installed Codex CLI and does not replace or patch it.

<p align="center"><img src="docs/desktop-preview.png" width="476" alt="Synthetic Codex Deck desktop panel with account usage, Deck Analysis, and auto-compaction controls"></p>
<p align="center"><em>Desktop panel · synthetic example account</em></p>

## Less account juggling. More time to build.

Codex Deck brings your accounts, usage limits, and sessions into one view so you can get back to building.

**If Deck saves you time, help keep it moving forward.**

Your support funds bug fixes, testing, and improvements that make Deck easier to use every day.

**[Support Codex Deck →](https://xtremexq.github.io/CodexDeck/support/)** · Give once or monthly through GitHub Sponsors.

Always optional; Deck is free and open source.

## Install

**Requires Windows, Windows PowerShell 5.1, and Codex CLI available as `codex`.** The desktop companion uses WPF and the Windows system tray. Linux and macOS are not supported. No administrator account is required.

Download the ZIP asset from [the latest release](https://github.com/xtremexq/CodexDeck/releases/latest), extract it, then run the installer in that folder:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-CodexDeck.ps1
```

Or install from source:

```powershell
git clone https://github.com/xtremexq/CodexDeck.git
cd CodexDeck
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-CodexDeck.ps1
```

The [main-branch ZIP](https://github.com/xtremexq/CodexDeck/archive/refs/heads/main.zip) also works with the same installer. Release assets include a SHA-256 checksum.

Open a **new terminal** and run:

```powershell
codex-auth
```

Press **N** to create a profile and sign in. Already have local profiles under `.codex-loop/accounts`? They appear automatically. You can also create or open one directly with `codex-auth account1`.

The installer adds command wrappers to your user PATH and preserves existing account data. Codex CLI is installed separately and is not modified. The execution-policy flag applies only to the installer process.

## Accounts, pools, and skills

New accounts remain isolated by default. The default **pool** environment can use your selected accounts' quotas while keeping one Codex home. Open **Settings → Environments** to configure membership and explicitly share skills, memory files, instructions, or individual MCP definitions between selected entries. **Settings → Skills** manages Deck-provided workflows without merging private skill folders. See [environments and selective sharing](docs/ENVIRONMENTS.md).

For optional skills, **Settings → Integrations** can install the Agentic Awesome Skills catalog index. **Settings → Skills** then lets you search it and install only chosen skills. Three UIZZE UI skills are included; the CLI also supports `deck-skills search`, `show`, `install`, `refresh`, and `update`. See [skills and catalog](docs/SKILL-CATALOG.md).

## Terminal dashboard

### A few keys cover the everyday work

| Key | Action |
| --- | --- |
| **↑ / ↓** | Select an account |
| **Page Up / Page Down**, **Home / End** | Navigate a longer list |
| **Enter** | Launch Codex; return to the dashboard when it exits |
| **B** | Select the best account with recently checked usable quota |
| **C** | Toggle auto-compaction; hold **C** to adjust its threshold with ↑/↓ and Enter |
| **R** | Refresh the selected account |
| **A** | Queue fresh checks for signed-in accounts |
| **/** | Search account names |
| **H** | Browse and resume local sessions |
| **F2** | Rename the selected account |
| **L** | Log in to the selected account |
| **N** | Create a new profile and log in |
| **D** | Open the desktop companion |
| **S** | Open desktop Settings |
| **Y** | Open Analytics |
| **U / T / W / P** | Run a warm-up, set daily times, select an account, or pause warm-ups |
| **G** | Edit rules that apply globally |
| **I** | Read or edit the selected account or pool's global `AGENTS.md` instructions |
| **E** | Read or edit the selected account or pool's memory files |
| **K** | Open the selected account or pool's skills folder |
| **M** | Toggle email masking; masking starts enabled |
| **Esc** | Clear the search, or quit when no search is active |
| **Q** | Quit the dashboard |

Cached usage appears immediately and opening the dashboard performs no account checks. Press **R** to refresh the selected signed-in account or **A** to queue all signed-in accounts, with up to three checks running at once. Run `codex-auth -a` to open the dashboard and queue that same all-account refresh immediately; `-a` is only accepted with the otherwise plain command. Checks stay in the background and do not block navigation. Opening the dashboard also does not send a warm-up prompt.

**Settings → General → Codex-auth dashboard theme** offers five layouts. **Default** keeps the original dashboard; **Focus** emphasizes the selected account; **Cards** shows compact quota cards; **Ledger** compares accounts in a table; **Split** places the account roster beside its details. The four additional layouts group shortcuts by task. Changing the setting updates an open dashboard after its next settings refresh.

**Bars show quota remaining.** Primary is the five-hour window, or another plan-specific window such as a free account's longer allowance. Weekly is shown separately when available. `?` means the value is unknown; it does not mean zero. Reset timestamps use your local time. **Reset passed** means the displayed value needs a fresh check.

The selected account's details show its model, reasoning effort, last check and attached terminal sessions. A connected session means a terminal launched through `codex-auth`; it does not necessarily mean Codex is generating a response.

For a non-interactive view, use **`codex-auth status`**. It prints cached data without network requests. Redirecting the bare command's input or output also selects snapshot mode.

Auto-compaction is opt-in. Press **C** before entering an account or pool, or click **Auto-compact** in the desktop panel; both controls share the same saved launch state and update one another while open. The choice applies to terminals opened next, not conversations already running. You can also run `codex-auth account16 -AutoCompact` or `codex-auth pool -AutoCompact` directly. Hold **C** in the dashboard to focus the saved threshold, adjust it by 5% with **↑/↓**, and press **Enter** to save it. For a one-time command-line override, include the percent sign: `codex-auth account16 -AutoCompact 50%`. The threshold is the percentage of model context still free, so the 55% default triggers when 45% is used; a 75% override triggers when 25% is used.

**Settings → Advanced → Compaction** selects the implementation. **Native** is the default: Deck converts the free-context percentage into Codex's native token threshold for the selected model's effective context window, then launches the normal Codex TUI. It works through ordinary accounts, pools, configured quota failover, manual `!account` switching, resumed conversations and one-shot `exec` commands because the setting travels with the complete Deck launch. **Custom** preserves Deck's existing observer workflow: when context reaches the threshold, Deck requests a visible `DECK_HANDOFF`, compacts the thread, and sends the handoff back quoted with “Please go on.” Its multiline handoff setting appears only while Custom is selected. `-Direct` still keeps an exact account without routing.

Run `!autocompact` inside any newly launched managed interactive conversation to compact on demand, even when automatic compaction is off. This includes account and pool launches, `codex-auth resume`, desktop Deck launches, and sessions using failover. In Custom mode, Deck requests the configured handoff from the active agent, compacts after the handoff, and replays it to continue. In Native mode, Codex compacts the thread after the current turn finishes. The command applies to the active conversation and does not change the saved automatic threshold. Conversations opened before this command was installed need to be resumed in a new managed terminal first.

## Desktop companion

Run **`codex-deck`**, or press **D** in the terminal dashboard.

- The panel has one compact action row: **+** adds an account, **Deck Analysis** opens efficiency analytics, **Auto-compact** controls future terminal launches, and **Configs** keeps the account/global configuration menu. Open an account terminal from its row menu.
- The **accounts / online / terminals** bar is a read-only status surface. Both views always list all profiles; use the adjacent plan filter to show all, Free, or Plus and higher accounts.
- Click the status bar below the list to check every visible account.
- Switch between the **panel** and **widget**, then expand account rows for more detail.
- **Settings** controls appearance, visible fields, managed skills and plugin marketplaces, email masking, automatic checks and warm-up.
- The panel appears in the taskbar; the widget and Settings stay out of it. Use **Minimize** to minimize the panel.
- Closing the window normally hides it to the tray. **Quit** stops the Deck UI and ordinary live checks without closing your Codex terminals; explicitly enabled background warm-up continues invisibly through the clearly named **CodexDeck Warmup Scheduling** Windows task.

Desktop automatic checks are off by default. Enable them in Settings if you want continued polling. Terminal startup checks and desktop polling are separate controls.

### Live context and trajectory (opt-in)

Enable **Live Context viewer** under **Settings → Advanced → Live Context Manager** to get a local trajectory of sessions across Deck accounts: requests, messages, tool calls and results, token-usage records, compactions, subagent/session metadata, and live sessions. Open it from the tray's **Open Live Context** action. The left menu orders sessions by most recent rollout file update across all accounts and refreshes that order every 30 seconds while open. The newest managed conversation is selected first, live context refreshes automatically, active rollouts are tailed in bounded pages, and raw paths are not exposed to the browser frontend.

The **Live context manager** is a second opt-in in the same Advanced section. Its separate **Automatically open Live Context when opening accounts** setting is off by default. Enable it to open a slim companion for each interactive account or pool launch; use `!context` in a managed Codex conversation to open that terminal's companion on demand. Each companion is bound to its terminal's unique session marker and routing proxy. It shows the model request seen by Deck as individual instruction, tool-definition, message, tool-call, and tool-result cards from the first request onward. Click a card's preview to read its full text. Use the red **−** to suppress a card, edit or trim its visible text, restore one change or all changes, search/filter the window, and watch the next-request token estimate update. Tool calls and outputs are paired by default, while system, developer, tool definitions, reasoning, and encrypted items are protected unless the advanced override is explicitly enabled. Encrypted reasoning has no available plaintext, and a request that references server-side history cannot reveal that earlier content; the companion labels these limits. The larger Trajectory studio remains one click away for the emitted timeline through the final response.

The companion is deliberately lightweight: it reads the live proxy snapshot instead of rescanning rollout history, lazy-renders long card lists, and polls a tiny revision/status response when nothing changed. A full context payload and DOM update happen only for a new model request or one of your edits. **Follow new** in its footer scrolls to new context items by default and can be switched off. The compact status area shows estimated free model context and this terminal's auto-compact mode above the quota divider, followed by cached primary and secondary quota use. Token figures are rough text/JSON size estimates, not exact model usage.

A newly opened terminal shows an empty context until its first model request. When `/new` or `/resume` changes conversations in the same terminal, the companion switches to the new thread on its first model request and keeps each thread's edits separate. Until that request, it displays the last captured context because Codex's TUI does not send Deck a conversation-change event.

Context overlays apply at the shared request boundary, so they remain active across ordinary accounts, pools, quota failover, manual account switching, Responses requests, and native or custom compaction requests. A change affects the next request; it cannot alter one already in flight or undo actions the model has already taken. `-Direct` deliberately bypasses Deck's route, so its completed rollout remains viewable but it has no authoritative live-edit boundary.

### Efficiency analytics (separate feature)

**Efficiency analytics is an independent feature**, enabled by default but separately switchable under **Settings → Advanced → Analytics**. Open it with **Deck Analysis** in the panel, the tray menu, or **Y** in the terminal dashboard. When Trajectory is disabled, interactive `codex-auth` launches Efficiency automatically. It scans the 1,000 most recently updated local rollouts across all accounts by default; the limit remains configurable from 10 to 5,000 and a notice appears in the panel when reached. It reports exact token totals where Codex recorded them, cache use, repeated commands and paths, oversized tool results, tool frequency, compactions, and token distribution by account, project, and model. It then ranks concrete opportunities to reduce repeated discovery or noisy output.

The analytics feature does not enable, depend on, or modify Trajectory or the context manager. The two additions share only a low-level local rollout parser/index so Deck does not perform the same filesystem work twice.

### Optional warm-up

Warm-up and its background task are off by default; a fresh install does not create the task. Choose eligible accounts and timing in **Settings → Checks & Warmup**, press **Enable background scheduling**, then save. This creates a per-user Windows task named **CodexDeck Warmup Scheduling**. It wakes a short-lived windowless worker at sign-in, configured daily times, and the next known reset. The worker checks selected account types and specific accounts, warms only eligible ones, refreshes warmed accounts to capture their real next reset times, records a concise local log, reschedules itself, and exits.

The account-type dropdown can select **All account types**, **Free**, **Go**, and **Plus or higher**; Free, Go, and Plus-or-higher can be combined. Specific accounts remain optional overrides. Free and Go accounts follow their plan's primary allowance window and use Codex's account-default model, while Plus-or-higher accounts follow the five-hour window and use the configured warm-up model.

In the terminal dashboard, **W** toggles the selected account and **P** pauses or resumes all warm-ups. In the GUI, right-click an account for the same controls or use Settings for account types, specific accounts, model and reset timing. Deck can be completely closed once background scheduling is enabled. Press **Disable background scheduling** and save to remove its task. Worker status and the bounded text log live in `.codex-loop/deck/warmup-worker.json` and `warmup-worker.log`.

**Warm-up consumes real quota.** A successful prompt does not guarantee that a new usage timer starts. Leave it disabled if you only want monitoring.

## Commands

```powershell
codex-auth                       # Interactive terminal dashboard
codex-auth -a                    # Open dashboard and check all signed-in accounts
codex-auth status                # Cached snapshot; no network
codex-auth list                  # List local profiles
codex-auth account1              # Launch an account
codex-auth account1 -AutoCompact 50% # Use the selected auto-compact mode at 50% context remaining
codex-auth account1 -Resume      # Pick a conversation from this account
codex-auth account1 -Resume 00000000-0000-4000-8000-000000000001 # Resume one conversation by ID
codex-auth resume 00000000-0000-4000-8000-000000000001 # Find its account and resume through Deck
codex-auth 2                     # Shorthand for account2
codex-auth work-main             # Use a named profile
codex-auth account1 login        # Sign in to that profile
codex-auth account1 login status # Ask Codex for login status
codex-auth account1 -del         # Move an inactive profile to recovery
codex-deck                       # Open the desktop companion
codex-check                      # Fetch a usage report
codex-check -Account account1    # Check one account
codex-check -Json                # Machine-readable usage report
codex-check -NoColor             # Plain-text usage report
```

Inside a signed-in `codex-auth` conversation, Codex's local `!` shell prefix gives you these controls. The command text runs locally; `!autocompact` then initiates the selected compaction workflow:

| Command | Action |
| --- | --- |
| `!account`, then `!account account2` | List selectable accounts, then switch future requests to one |
| `!pool`, then `!pool 2` | List the current pool and choose a member |
| `!usage` / `!check` | Check the active account / run the complete `codex-check` report |
| `!context` / `!deck` | Open the enabled live context companion / desktop panel |
| `!autocompact` | Compact the active conversation using the selected Native or Custom implementation |
| `!delay 15m go on` | Send `go on` to this still-open conversation after 15 minutes |
| `!schedule 6h go on` | Resume this conversation in a new visible terminal after six hours and send `go on` |

Delayed messages require the current terminal to remain open. Scheduled messages use a one-time Windows task that removes itself after running; Windows must be signed in when it delivers, and the original account and working folder must still exist. Durations accept whole-number seconds, minutes, hours, or days (`600s`, `10m`, `6h`, `1d`); quote messages containing shell-sensitive characters. See [timed message details](docs/ACCOUNT-TOOLS.md#timed-local-messages).

Codex does not expose a third-party bare-slash extension point, so these controls use `!` rather than appearing in the `/` menu. `!account` works even when automatic failover is off. The original account retains the conversation, `CODEX_HOME`, and files; only subsequent API requests switch routes.

Each profile has a separate `CODEX_HOME`. New profiles can inherit local configuration, rules and skills; authentication remains separate. Deletion keeps a recovery copy and refuses an account with a tracked connected terminal.

### Optional managed integrations

**Settings → Integrations** installs or updates RTK, Headroom MCP, CodeGraph, Browser Harness, and the optional AAS catalog index. Fresh Deck installs do not install the AAS index or any AAS skill. **Check & update** checks for a new version only when requested, and **Roll back** reactivates an earlier retained version when available. Deck recognizes an existing Browser Harness installation without replacing it; its update button requires a second click after showing the available version. The context optimizer selector appears only for installed RTK or Headroom.

Deck stores managed packages under `.codex-loop/integrations/packages/<tool>/<version>` and injects their hook/MCP configuration only at launch. It does not rewrite account `config.toml` or `AGENTS.md`, so account and pool isolation remains intact. RTK and Headroom are exclusive context optimizer choices; CodeGraph can run with either. Prefix a single shell command with `NO_RTK=1 ` to bypass RTK rewriting for that command.

After installing CodeGraph, use its **Project access** panel in Integrations to add project folders and choose the tool profile. CodeGraph attaches only when a conversation starts in one of those folders or its subfolders, including a folder chosen with `codex -C` or `--cd`. The list supports add, browse, remove, right-click open, and copy-path actions. Start `codex-auth accountX` from a chosen project folder, or enable **Settings → General → Always ask where to open the terminal** for desktop launches. Existing conversations retain the integrations they started with.

The default Global Rules contain usage-efficiency guidance. The debug-swarm rule appears only when that skill is installed for the account. **Settings → Skills** uses one account list for access and per-account editing, installs Codex plugin marketplaces and plugin skills directly, and includes the optional AAS browser below the managed list. When Browser Harness is detected, the same tab shows its skill switch. Custom Global Rules remain editable. Browser Harness remains in its existing `uv` tool environment, and Deck preserves user-owned Browser Harness skills.

Deck keeps credentials, configuration, databases and histories isolated. Once a week, background storage maintenance leaves active account homes untouched, removes curated-plugin staging directories older than 24 hours from inactive homes, and hard-links verified-identical sandbox executables and managed plugin-cache files of at least 1 MiB. Each account retains its expected paths and Windows sandbox boundary; only immutable duplicate file contents share disk blocks. The result is recorded in `.codex-loop/deck/storage-maintenance.json`, and skipped active homes are retried later.

## Local data and privacy

Deck has no hosted backend. Usage checks use local Codex authentication to contact upstream services, with a Codex app-server fallback. These integrations depend on the installed CLI and upstream behavior.

Paths below are relative to your Windows user profile:

| Path | What lives there |
| --- | --- |
| `.codex-loop/accounts/` | Per-account sign-ins, configuration and Codex data |
| `.codex-loop/deleted-accounts/` | Recoverable removed profiles |
| `.codex-loop/deck/` | Preferences, usage caches, session and exit records, and warm-up history |
| `.local/bin/` | Installed command wrappers |

Email masking affects the display, not the saved cache. Recovery copies can contain sign-ins. Keep live installation data and account exports out of GitHub; see [SECURITY.md](SECURITY.md).

## Update or remove

To update a Git installation:

```powershell
git pull --ff-only
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-CodexDeck.ps1
```

Close the terminal dashboard and quit desktop Deck before updating, then reopen them afterward. The installer preserves account/state directories, backs up replaced files and skips unchanged payloads.

To remove Deck, first turn off the automatic warm-up master switch (or run `Unregister-ScheduledTask -TaskName 'CodexDeck Warmup Scheduling' -Confirm:$false`), then quit it and remove its installed scripts and command wrappers. Keep `.codex-loop/accounts` if you want to retain your profiles and history. Only remove `.local/bin` from PATH if no other tools use it. There is no automatic account-data deletion during uninstall.

## Help

| Problem | Try this |
| --- | --- |
| `codex-auth` is not found | Open a new terminal; check that `.local/bin` is on your user PATH |
| `codex` is not found | Install Codex CLI separately and confirm `codex --version` works |
| The dashboard only prints once | Run it in an interactive terminal without input/output redirection |
| No profiles appear | Press **N**, or run `codex-auth account1`; clear any search filter |
| Usage is old or unavailable | Press **R**; check `codex-auth account1 login status` and `codex-check -Account account1` |
| The desktop window disappeared | Check the tray overflow or run `codex-deck` |
| Automatic desktop checks are idle | Enable them in Settings and check which profiles are visible |

[Report a bug](https://github.com/xtremexq/CodexDeck/issues) with the command, expected behavior and sanitized error output. Do not attach live account files.

## For contributors

Source is in `suite/`; command wrappers are in `bin/`. Run `Test-Repository.ps1` before contributing to check script syntax, encoding, and repository hygiene.

See [CONTRIBUTING.md](CONTRIBUTING.md) for checks and screenshot generation, [CHANGELOG.md](CHANGELOG.md) for release history, and [LICENSE](LICENSE) for the MIT license.

### Account tools

Best-account selection, local session history, account rename, manual reset-credit details, and opt-in live failover are documented in [Account tools](docs/ACCOUNT-TOOLS.md).

## Disclaimer

Codex Deck is an independent project, not affiliated with or endorsed by OpenAI. Codex and other product names belong to their respective owners. You need your own Codex CLI installation and accounts; Deck does not provide quota or change account limits. Usage information may be delayed or unavailable. The software is provided “as is,” without warranty, under the [MIT license](LICENSE).
