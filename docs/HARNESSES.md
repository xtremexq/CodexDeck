# Harnesses and account sign-in

Open **Settings → Harnesses**. Codex CLI is always enabled. Enable Antigravity, Claude Code, or OpenCode, then save. Each enabled harness shows its installed path and offers **Install CLI** or **Update CLI**, **How to use**, documentation, an optional absolute executable path, and **Edit all settings** for a selected account. Installer work stays in the background, shows elapsed progress, stops after 10 minutes and can be cancelled by closing Settings. The settings editor opens the complete native configuration file, including models, permissions, tools and MCP settings.

Install / update uses the official installers for Claude and Antigravity and the official npm packages for Codex and OpenCode. The npm installs require Node.js/npm on PATH. Installation runs in the background and reports failure in the tab. Closing Settings cancels an active install worker. CLI installations are shared between accounts; settings and sign-ins are isolated.

Use **New account → Harness / login provider** in the desktop companion. In the terminal dashboard, press **N** and choose an enabled harness. Right-click an account and choose **Log in** to authenticate again. Existing account names retain their original identity. Harness profiles share Deck's account-name space in the desktop companion.

| Harness | Primary account provider | Native settings and sign-in |
| --- | --- | --- |
| Codex CLI | ChatGPT | `accounts/<name>/config.toml`, `auth.json`; ChatGPT login required |
| Claude Code | Claude | `accounts/<name>/claude`; isolates Claude config, home-level config, credentials, settings, history, plugins, memory and skills; Claude subscription login required |
| Antigravity | Gemini | New accounts: `accounts/<name>/antigravity/profile/.gemini`; native remote/SSH file authentication. Existing runner accounts retain their separate Windows identity |
| OpenCode | ChatGPT, Claude, Gemini, or Custom | Separate `accounts/<name>/opencode` config, data, state and cache directories; native provider authentication |

Existing Deck accounts without `deck-account.json` continue as Codex/ChatGPT accounts. Deck stores the harness/provider binding in this metadata file. It does not copy the default provider's credentials when adding an account.

```powershell
codex-auth work -NewAccount -Harness Claude -Provider Claude
codex-auth google -NewAccount -Harness Antigravity -Provider Gemini
codex-auth open -NewAccount -Harness OpenCode -Provider ChatGPT
codex-auth other -NewAccount -Harness OpenCode -Provider Custom

codex-auth work           # open Claude Code for this account
codex-auth work login     # native claude auth login
codex-auth open login     # native opencode auth login --provider openai
```

`claude-auth` opens a Claude-only dashboard and launcher. It maps short names such as `account1` to isolated Deck folders named `claude-account1`, so the existing Codex `account1` remains untouched. The dashboard and `claude-auth list` show whether each profile has its own native credential file. The first `claude-auth account1` or `claude-auth account1 login` creates the local profile and opens Claude's native browser sign-in. Complete sign-in with a Claude account you own; Deck does not register service accounts. Later, run `claude-auth account1` to launch that profile, or `claude-auth account1 login` to sign in again. Press **N** in the Claude dashboard to add another profile.

`agy-auth` provides the same account workflow for Antigravity. It maps `account1` to an isolated `antigravity-account1` profile. The first `agy-auth account1` or `agy-auth account1 login` creates the profile and starts Google sign-in; complete the URL/code flow in the terminal. Run `agy-auth account1` to launch it, `agy-auth account1 login` to sign in again, and **N** in its dashboard to add another. New profiles use a file-backed remote-auth path inside their profile, so they do not share the current Windows user's Credential Manager entry or require extra Windows users.

Use **R** in the Claude dashboard, `claude-auth account1 check`, or **A** / `claude-auth -a` to refresh native sign-in state for one or every profile. These checks run `claude auth status` inside that profile's isolated home and validate the reported configuration directory. They report whether Claude is signed in; they do not fetch plan quota.

```powershell
claude-auth                 # Claude-only account dashboard
claude-auth account1        # create on first use and start native sign-in; then launch Claude
claude-auth account2 login  # create account2 on first use and sign in
claude-auth account1 check  # check native sign-in state
claude-auth -a              # check every Claude profile
claude-auth -GlobalRules    # edit Claude global instructions/settings defaults
claude-auth list            # list Claude profiles

agy-auth                    # Antigravity-only account dashboard
agy-auth account1           # create on first use and start isolated Google sign-in
agy-auth account2 login     # create account2 on first use and sign in
agy-auth account1 check     # check for the isolated profile credential file
agy-auth -a                 # check every Antigravity profile
agy-auth -GlobalRules       # edit Antigravity global rules/settings defaults
agy-auth list               # list Antigravity profiles
```

Claude settings are configured separately from Codex Global Rules. Choose **Configs → Claude Global Defaults**, press **G** in the Claude dashboard, or run `claude-auth -GlobalRules` / `claude-auth -ClaudeDefaults`. The editor saves shared Claude instructions and a native settings JSON object under `deck/claude/`; these values apply only to Deck's Claude launches. Per-account `CLAUDE.md` and `settings.json` stay inside each profile. Account settings and explicit one-session `--settings` values take precedence over matching Deck defaults. Deck combines settings lists using Claude's list-merge behavior. Merged values are passed through Claude's `--settings` flag, which takes priority over project settings for the same keys during that session; managed Claude settings remain authoritative. Global instructions are appended to session instructions and do not alter Codex Global Rules.

In the Claude dashboard, **I** edits the selected profile's `CLAUDE.md`, **E** opens that profile's Claude auto-memory folder, and **K** opens its native `skills` folder. Claude writes auto-memory there as it works. Deck's bundled skill catalog and Codex memory editor are not wired into Claude; Claude uses the files in these native folders instead.

Antigravity's **G** shortcut opens **Antigravity Global Defaults**. Always-on global rules are copied into each isolated profile's native `~/.gemini/antigravity-cli/rules/` folder; per-account instructions use `~/.gemini/AGENTS.md`. Global native settings defaults merge under account settings on the next launch. **I** edits the account's `AGENTS.md`; **K** opens its native `~/.gemini/config/skills/` folder. Antigravity's `/learn` command can save global or workspace rules and skills. Deck does not run Antigravity warm-ups.

Antigravity checks are local profile checks: `agy-auth account1 check` and dashboard **R/A** report whether the isolated OAuth credential file is present or the profile needs sign-in. File presence cannot prove Google still accepts the token. Use `/usage` inside that account's Antigravity CLI to refresh service authentication and inspect model quotas. Deck does not scrape that interactive quota panel or issue background requests.

Claude's five-hour session allowance resets every five hours. Its weekly allowance resets on a fixed day and time assigned to the Claude account; that weekly schedule does not start when you first use the account. Check the exact remaining usage and next reset under Claude's `/usage` or Settings → Usage. Claude documents `claude auth status` for machine-readable authentication state, but does not document a supported CLI quota response for this dashboard. Deck therefore checks sign-in only. It does not run Claude warm-ups, because a warm-up would send a real request and spend Claude plan usage.

Deck translates `login` and `logout` for Claude/OpenCode. Other arguments pass to the selected native CLI. Use `codex-auth work auth status`, `codex-auth open auth list`, or the CLI's `--help`. Use Antigravity's native `/logout` inside an open terminal. OpenCode's Gemini connection and additional providers use whatever login methods the installed OpenCode version supports; choosing a provider in Deck does not add a web subscription adapter.

Codex quota checks, account pools, warm-up, compaction, conversation-owner lookup, Auth Helper, and Deck failover currently apply to Codex/ChatGPT accounts. Claude has isolated native history, auto-memory, plugins, skills, account instructions and settings, plus the sign-in check and Claude-specific global defaults above. Claude plan usage remains in its own `/usage` view. Disabling a harness prevents new launches; close its existing terminals separately.

## Antigravity isolation and updates

New Antigravity accounts work under the current Windows user. Deck sets an account-specific `USERPROFILE`, `HOME`, `APPDATA` and `LOCALAPPDATA`, and selects the native SSH/remote authentication path with `SSH_CONNECTION`. The CLI stores Google OAuth credentials in `<profile>/.gemini/antigravity-cli/antigravity-oauth-token`, along with isolated settings, rules, history and caches. It does not copy the default account's sign-in. Login prints a Google authorization URL; open it, select the intended Google account and paste the returned authorization code in the native terminal. `/logout` applies to that isolated profile.

No executable is patched. Deck reapplies the environment on every launch, including after an update. A read-only compatibility check verifies that the Windows amd64 binary still connects its CLI token store to SSH detection, per-profile home lookup, and guarded file operations for token loading, saving, refresh metadata and logout. If these checks fail, launch stops before authentication; use a compatible binary or the runner fallback. The remote/file path is internal implementation behavior, so future vendor changes can require a Deck compatibility update. The installed binary's startup and file reads have been tested in separate temporary profiles; live Google login and simultaneous authenticated AI calls have not been tested.

File-based OAuth credentials inherit the account folder's Windows permissions and are included only in Deck's password-encrypted configuration backups. They are not protected by the Windows keyring. Native tools launched by AGY inherit its redirected profile and remote environment.

## Optional Antigravity runner fallback

Existing accounts with runner metadata keep their Windows-user mode. **Configure runner (optional)** switches an account to that mode; it requires a separate existing Windows user. Deck does not provision Windows users. Existing file-profile data is retained when switching modes, but is not used by the runner.

Select an existing GeminiLoop slot (`account1` through `account5`) if its runner manager is installed, or provide credentials for an existing Windows user. One runner identity can belong to only one Deck account. The runner must have access to the project folder. The current Windows user cannot serve as an isolated runner.

You can change or restore the runner with **Configure runner** beside the selected account in Harnesses, or:

```powershell
codex-auth google -ConfigureRunner
```

The runner opens an interactive terminal under that Windows identity. Deck's Antigravity installer copies the native binary to `C:\Users\Public\CodexDeck\harnesses\agy.exe` so runner users can read it. A custom executable must also be readable by that user. Editing the runner's configuration from Deck requires permission to its profile; Antigravity's `/config` is available in the runner terminal.

Runner credentials are encrypted with Windows DPAPI in the account's `runner-credential.clixml`. Portable Deck backups include harness metadata, isolated profile settings, global defaults and Antigravity/Claude/OpenCode file-profile authentication, but exclude this machine-bound runner credential and the Windows keyring. After restoring a runner-mode account, configure its runner again and sign in if necessary. Native conversations and caches are not included in these configuration backups.

## Account identity and routing

The primary login provider identifies the account. Native model/provider configuration inside an opened harness remains available independently. Deck's existing ChatGPT failover proxy continues to operate for Codex accounts.

Cross-provider conversation routing and adapters for ChatGPT, Claude and Gemini web subscription usage are future work. This change does not implement or enable those adapters. Harness account metadata keeps login identity separate so later routing work can build on it.

Official references: [Codex configuration](https://developers.openai.com/codex/config-reference/), [Claude settings and precedence](https://code.claude.com/docs/en/settings), [Claude CLI authentication status](https://code.claude.com/docs/en/cli-reference), [Claude account usage limits](https://support.claude.com/en/articles/11647753-how-do-usage-and-length-limits-work), [Antigravity authentication](https://antigravity.google/docs/cli/install), [Antigravity global rules](https://antigravity.google/docs/rules/), [Antigravity usage quotas](https://antigravity.google/docs/cli/commands/usage), [OpenCode configuration](https://opencode.ai/docs/config/) and [authentication commands](https://opencode.ai/docs/cli/#auth).
