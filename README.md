<p align="center">
  <img src="suite/deck/assets/codex-deck.png" width="88" alt="Codex Deck">
</p>
<h1 align="center">Codex Deck</h1>
<p align="center"><strong>One command. Every account.</strong><br>
A terminal dashboard and desktop companion for multiple Codex CLI accounts on Windows.</p>
<p align="center">
  <a href="https://github.com/xtremexq/CodexDeck/actions/workflows/test.yml"><img src="https://github.com/xtremexq/CodexDeck/actions/workflows/test.yml/badge.svg" alt="Windows checks"></a>
  <img src="https://img.shields.io/badge/Windows-PowerShell%205.1-0078D4" alt="Windows PowerShell 5.1">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-69dec0" alt="MIT license"></a>
</p>
<p align="center"><a href="#install">Install</a> · <a href="#terminal-dashboard">Terminal</a> · <a href="#desktop-companion">Desktop</a> · <a href="#commands">Commands</a> · <a href="#help">Help</a></p>

<p align="center"><img src="docs/terminal.png" width="1040" alt="Terminal dashboard showing accounts, remaining quota bars, reset times, sessions and keyboard shortcuts"></p>

## Your accounts, together

New accounts remain isolated by default. The first-listed **pool** environment can use your selected accounts' quotas while keeping one Codex home. Open **Settings > Environments** to configure membership and explicitly share skills, memory files, instructions or individual MCP definitions between selected entries. **Settings > Skills** manages Deck-provided workflows that are globally available to accounts and pools without merging their private skill folders. See [environments, Deck skills and selective sharing](docs/ENVIRONMENTS.md) for details.

**Skill catalog:** Settings > Integrations can install or update the Agentic Awesome Skills index. Settings > Skills then searches it and installs only chosen skills into codex-auth accounts and pools. Three UIZZE UI skills are included. The CLI also supports `deck-skills search`, `show`, `install`, `refresh`, and `update`. See [skills and catalog](docs/SKILL-CATALOG.md).

Run **`codex-auth`** to see your local accounts and their cached usage immediately. Check fresh limits in the background, find the profile you need, and launch Codex from the same terminal. Keep the floating desktop widget nearby when you want usage visible while you work.

| Terminal dashboard | Desktop companion |
| --- | --- |
| Search and navigate accounts with the keyboard | Switch between a control panel and floating widget |
| See quota bars, plans, reset times and attached sessions | Keep usage nearby with tray access and optional always-on-top |
| Refresh one account or queue every account | Run manual checks or enable automatic polling |
| Launch Codex, log in, or create a profile | Choose a launch folder and enable Deck skills per account or pool |
| Print a cached snapshot for scripts | Configure optional, quota-consuming warm-up requests |

## Less account juggling. More time to build.

Codex Deck brings your accounts, usage limits, and sessions into one view so you can get back to building.

**If Deck saves you time, help keep it moving forward.**

Your support funds bug fixes, testing, and improvements that make Deck easier to use every day.

**[Support Codex Deck →](https://xtremexq.github.io/CodexDeck/support/)** · Give once or monthly through GitHub Sponsors.

Always optional; Deck is free and open source.

## Install

**Requires Windows, Windows PowerShell 5.1, and Codex CLI available as `codex`.** The desktop companion uses WPF and the Windows system tray. Linux and macOS are not supported. No administrator account is required.

Download **[CodexDeck-1.7.1.zip](https://github.com/xtremexq/CodexDeck/releases/download/v1.7.1/CodexDeck-1.7.1.zip)** from [the latest release](https://github.com/xtremexq/CodexDeck/releases/latest), extract it, then run the installer in that folder:

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

The installer adds command wrappers to your user PATH and preserves existing account data. Codex CLI is installed separately. The execution-policy flag applies only to the installer process.

## Terminal dashboard

### A few keys cover the everyday work

| Key | Action |
| --- | --- |
| **↑ / ↓** | Select an account |
| **Page Up / Page Down**, **Home / End** | Navigate a longer list |
| **Enter** | Launch Codex; return to the dashboard when it exits |
| **C** | Toggle auto-compaction; hold **C** to adjust its threshold with ↑/↓ and Enter |
| **R** | Refresh the selected account |
| **A** | Queue fresh checks for every account |
| **/** | Search account names |
| **L** | Log in to the selected account |
| **N** | Create a new profile and log in |
| **D** | Open the desktop companion |
| **V** | Open the opt-in trajectory viewer and live context manager |
| **Y** | Open the independently opt-in efficiency analytics |
| **G** | Edit rules that apply globally |
| **I** | Read or edit the selected account or pool's global `AGENTS.md` instructions |
| **E** | Read or edit the selected account or pool's memory files |
| **K** | Open the selected account or pool's skills folder |
| **M** | Toggle email masking; masking starts enabled |
| **Esc** | Clear the search, or quit when no search is active |
| **Q** | Quit the dashboard |

Cached usage appears immediately and opening the dashboard performs no account checks. Press **R** to refresh the selected signed-in account or **A** to queue all signed-in accounts, with up to three checks running at once. Run `codex-auth -a` to open the dashboard and queue that same all-account refresh immediately; `-a` is only accepted with the otherwise plain command. Checks stay in the background and do not block navigation. Opening the dashboard also does not send a warm-up prompt.

**Settings → Appearance → Codex-auth dashboard theme** offers five layouts. **Default** keeps the original dashboard; **Focus** emphasizes the selected account; **Cards** shows compact quota cards; **Ledger** compares accounts in a table; **Split** places the account roster beside its details. The four new layouts group shortcuts by task. Changing the setting updates an open dashboard after its next settings refresh.

**Bars show quota remaining.** Primary is the five-hour window, or another plan-specific window such as a free account's longer allowance. Weekly is shown separately when available. `?` means the value is unknown; it does not mean zero. Reset timestamps use your local time. **Reset passed** means the displayed value needs a fresh check.

The selected account's details show its model, reasoning effort, last check and attached terminal sessions. A connected session means a terminal launched through `codex-auth`; it does not necessarily mean Codex is generating a response.

For a non-interactive view, use **`codex-auth status`**. It prints cached data without network requests. Redirecting the bare command's input or output also selects snapshot mode.

Auto-compaction is opt-in. Press **C** before entering an account or pool, or click **Auto-compact** in the desktop panel; both controls share the same saved launch state and update one another while open. The choice applies to terminals opened next, not conversations already running. You can also run `codex-auth account16 -AutoCompact` or `codex-auth pool -AutoCompact` directly. Hold **C** in the dashboard to focus the saved threshold, adjust it by 5% with **↑/↓**, and press **Enter** to save it. For a one-time command-line override, include the percent sign: `codex-auth account16 -AutoCompact 50%`. The threshold is the percentage of model context still free, so the 55% default triggers when 45% is used; a 75% override triggers when 25% is used.

**Settings → Compaction** selects the implementation. **Native** is the default: Deck converts the free-context percentage into Codex's native token threshold for the selected model's effective context window, then launches the normal Codex TUI. It works through ordinary accounts, pools, configured quota failover, manual `!account` switching, resumed conversations and one-shot `exec` commands because the setting travels with the complete Deck launch. **Custom** preserves Deck's existing observer workflow: when context reaches the threshold, Deck requests a visible `DECK_HANDOFF`, compacts the thread, and sends the handoff back quoted with “Please go on.” Its multiline handoff setting appears only while Custom is selected. `-Direct` still keeps an exact account without routing.

## Desktop companion

<p align="center"><img src="docs/desktop-preview.png" width="476" alt="Codex Deck desktop control panel with an account and expanded usage details"></p>

Run **`codex-deck`**, or press **D** in the terminal dashboard.

- The panel has one compact action row: **+** adds an account, **Deck Analysis** opens efficiency analytics, **Auto-compact** controls future terminal launches, and **Configs** keeps the account/global configuration menu. Open an account terminal from its row menu.
- The **accounts / online / terminals** bar is a read-only status surface. Both views always list all profiles; use the adjacent plan filter to show all, Free, or Plus and higher accounts.
- Click the status bar below the list to check every visible account.
- Switch between the **panel** and **widget**, then expand account rows for more detail.
- **Settings** controls appearance, visible fields, Deck skills, email masking, automatic checks and warm-up.
- The panel appears in the taskbar; the widget and Settings stay out of it. Use **Minimize** to minimize the panel.
- Closing the window normally hides it to the tray. **Quit** stops the Deck UI and ordinary live checks without closing your Codex terminals; explicitly enabled background warm-up continues invisibly through the clearly named **CodexDeck Warmup Scheduling** Windows task.

Desktop automatic checks are off by default. Enable them in Settings if you want continued polling. Terminal startup checks and desktop polling are separate controls.

### Trajectory and live context control (opt-in)

Enable **Trajectory** in Settings to get a fast local timeline of sessions across Deck accounts: requests, messages, tool calls and results, token-usage records, compactions, subagent/session metadata, and live sessions. You can open it from the tray menu or the terminal dashboard's **V** shortcut. The left menu orders sessions by most recent rollout file update across all accounts and refreshes that order every 30 seconds while open. The newest managed conversation is selected first, live context refreshes automatically, active rollouts are tailed in bounded pages, and raw paths are not exposed to the browser frontend.

The **Live context manager** is a second opt-in inside the Trajectory settings. Its separate **Automatically open Live Context when opening accounts** setting is off by default. Enable it to open a slim companion for each interactive account or pool launch; use `!context` in a managed Codex conversation to open that terminal's companion on demand. Each companion is bound to its terminal's unique session marker and routing proxy. It shows the complete model-visible context as individual message, tool-call, and tool-result cards from the first request onward. Use the red **−** to suppress a card, edit or trim its exact visible text, restore one change or all changes, search/filter the window, and watch the next-request token estimate update. Tool calls and outputs are paired by default, while system, developer, reasoning, and encrypted items are protected unless the advanced override is explicitly enabled. The larger Trajectory studio remains one click away for the complete emitted timeline through the final response.

The companion is deliberately lightweight: it reads the exact live proxy snapshot instead of rescanning rollout history, lazy-renders long card lists, and polls a tiny revision/status response when nothing changed. A full context payload and DOM update happen only for a new model request or one of your edits. **Follow new** in its footer scrolls to new context items by default and can be switched off. The compact status row shows cached primary and secondary quota use, estimated free model context, and this terminal's auto-compact mode and threshold.

A newly opened terminal shows an empty context until its first model request. When `/new` or `/resume` changes conversations in the same terminal, the companion switches to the new thread on its first model request and keeps each thread's edits separate. Until that request, it displays the last captured context because Codex's TUI does not send Deck a conversation-change event.

Context overlays apply at the shared request boundary, so they remain active across ordinary accounts, pools, quota failover, manual account switching, Responses requests, and native or custom compaction requests. A change affects the next request; it cannot alter one already in flight or undo actions the model has already taken. `-Direct` deliberately bypasses Deck's route, so its completed rollout remains viewable but it has no authoritative live-edit boundary.

### Efficiency analytics (separate feature)

**Efficiency analytics is an independent feature**, enabled by default but separately switchable in Settings. Open it with **Deck Analysis** in the panel, the tray menu, or **Y** in the terminal dashboard. When Trajectory is disabled, interactive `codex-auth` launches Efficiency automatically. Its PrismoDev-inspired analysis scans the 1,000 most recently updated local rollouts across all accounts by default; the limit remains configurable from 10 to 5,000 and a notice appears in the panel when reached. It reports exact token totals where Codex recorded them, cache use, repeated commands and paths, oversized tool results, tool frequency, compactions, and token distribution by account, project, and model. It then ranks concrete opportunities to reduce repeated discovery or noisy output.

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

Inside any signed-in `codex-auth` conversation, use Codex's local shell
prefix: `!account`, `!pool`, `!usage`, `!delay`, `!schedule`, `!check`, `!context`, or `!deck`. These commands run locally
and do not submit a prompt or consume a model turn. Account first lets you choose
the session's selectable accounts or, in a named environment, its current pool
by printing numbered lists. Pool prints the current-pool list directly. Switch with a second local
command such as `!pool 2` or `!pool account7`. Usage checks
only the account currently routing the session; Check runs the complete local
`codex-check` report, and Deck opens the desktop companion.
Use `!delay 15m go on` to queue `go on` into the same live conversation after 15 minutes. The terminal stays open and usable while its hidden timer waits. Use `!schedule 6h go on` to create a one-time Windows task that opens a new visible PowerShell terminal, resumes this conversation under its owning account, and submits `go on`. The task removes itself when it runs. Durations accept whole-number seconds, minutes, hours, or days (`600s`, `10m`, `6h`, `1d`); quoted messages can include spaces. Scheduling requires a signed-in Windows session at delivery time. The original working folder and account must still exist.
Codex does not expose a third-party bare-slash extension point, so these commands
use `!` and cannot appear as `/account` entries in the built-in command menu.
Ordinary launches use a manual-only loopback route so `!account` works even when
automatic failover is Off. Their `CODEX_HOME`, saved conversation, and files stay
with the account used to launch the session; only subsequent API requests switch.

Each profile has a separate `CODEX_HOME`. New profiles can inherit local configuration, rules and skills; authentication remains separate. Deletion keeps a recovery copy and refuses an account with a tracked connected terminal.

### Optional managed integrations

**Settings → Integrations** can enable one context optimizer—**RTK** or **Headroom MCP**—and independently enable **CodeGraph** repository intelligence and **Browser Harness** browser automation. It also installs or updates the optional **AAS catalog index**. Fresh Deck installs do not install the AAS index or any AAS skill. Saving an enabled tool installs a missing package on demand. **Check & update** checks for a new version only when requested, and **Roll back** reactivates an earlier retained RTK, Headroom, or CodeGraph version. Deck recognizes an existing Browser Harness installation without replacing it; its update button requires a second click after showing the available version.

Deck stores these tools under `.codex-loop/integrations/packages/<tool>/<version>` and injects their hook/MCP configuration only at launch. It does not rewrite account `config.toml` or `AGENTS.md`, so account and pool isolation remains intact. The selected integrations follow every Deck conversation path, including dashboard/account launches, pools, failover, routing and both auto-compaction modes. RTK and Headroom are deliberately exclusive because both optimize context; CodeGraph can run with either. Prefix a single shell command with `NO_RTK=1 ` to bypass RTK rewriting for that command.

When the CodeGraph MCP server starts for a Codex conversation, it automatically indexes that conversation's starting folder. Its tools are called by the agent when useful; it does not change the account's project. If every account starts in your home folder, CodeGraph will index that home folder for each launch. Start `codex-auth accountX` from the project's folder, or enable **Settings → Appearance → Always ask where to open the terminal** and choose the project folder for each desktop launch. The **CodeGraph tool profile** controls how many tools the agent sees, not which folder is indexed.

The default Global Rules contain usage-efficiency guidance. The debug-swarm rule appears only when that skill is installed for the account; Browser Harness guidance appears only when its account-sharing switch is enabled and the tool and skill are available. Custom Global Rules remain editable. Browser Harness remains in its existing `uv` tool environment, and Deck preserves any user-owned Browser Harness skill. An account with its own Browser Harness skill can use that skill regardless of Deck's sharing switch.

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
