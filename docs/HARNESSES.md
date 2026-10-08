# Harnesses and account sign-in

Open **Settings → Harnesses**. Codex CLI is always enabled. Enable Antigravity, Claude Code, or OpenCode, then save. Each enabled harness offers **Install / update**, **How to use**, documentation, an optional absolute executable path, and **Edit all settings** for a selected account. The settings editor opens the complete native configuration file, including models, permissions, tools and MCP settings.

Install / update uses the official installers for Claude and Antigravity and the official npm packages for Codex and OpenCode. The npm installs require Node.js/npm on PATH. Installation runs in the background and reports failure in the tab. Closing Settings cancels an active install worker. CLI installations are shared between accounts; settings and sign-ins are isolated.

Use **New account → Harness / login provider** in the desktop companion. In the terminal dashboard, press **N** and choose an enabled harness. Right-click an account and choose **Log in** to authenticate again. Existing account names retain their original identity; creating a new provider account requires a new name.

| Harness | Primary account provider | Native settings and sign-in |
| --- | --- | --- |
| Codex CLI | ChatGPT | `accounts/<name>/config.toml`, `auth.json`; ChatGPT login required |
| Claude Code | Claude | `accounts/<name>/claude`; `CLAUDE_CONFIG_DIR` isolates settings, credentials and history; Claude subscription login required |
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

Deck translates `login` and `logout` for Claude/OpenCode. Other arguments pass to the selected native CLI. Use `codex-auth work auth status`, `codex-auth open auth list`, or the CLI's `--help`. Use Antigravity's native `/logout` inside an open terminal. OpenCode's Gemini connection and additional providers use whatever login methods the installed OpenCode version supports; choosing a provider in Deck does not add a web subscription adapter.

Codex quota checks, account pools, warm-up, compaction, conversation-owner lookup, and Deck failover currently apply to Codex/ChatGPT accounts. Other accounts show their harness and native usage status in the dashboards and launch their own CLI. Native session/history commands remain available. Disabling a harness prevents new launches; close its existing terminals separately.

## Antigravity isolation and updates

New Antigravity accounts work under the current Windows user. Deck sets an account-specific `USERPROFILE`, `HOME`, `APPDATA` and `LOCALAPPDATA`, and selects the native SSH/remote authentication path with `SSH_CONNECTION`. The CLI stores Google OAuth credentials in `<profile>/.gemini/antigravity-cli/antigravity-oauth-token`, along with isolated settings, history and caches. It does not copy the default account's sign-in. Login prints a Google authorization URL; open it, select the intended Google account and paste the returned authorization code in the native terminal. `/logout` applies to that isolated profile.

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

Runner credentials are encrypted with Windows DPAPI in the account's `runner-credential.clixml`. Portable Deck backups include harness metadata and Claude/OpenCode/Antigravity file-profile settings and authentication, but exclude this machine-bound runner credential and the Windows keyring. After restoring a runner-mode account, configure its runner again and sign in if necessary. Native conversations and caches are not included in these configuration backups.

## Account identity and routing

The primary login provider identifies the account. Native model/provider configuration inside an opened harness remains available independently. Deck's existing ChatGPT failover proxy continues to operate for Codex accounts.

Cross-provider conversation routing and adapters for ChatGPT, Claude and Gemini web subscription usage are future work. This change does not implement or enable those adapters. Harness account metadata keeps login identity separate so later routing work can build on it.

Official references: [Codex configuration](https://developers.openai.com/codex/config-reference/), [Claude settings](https://code.claude.com/docs/en/settings), [Antigravity CLI installation](https://antigravity.google/docs/cli/install), [OpenCode configuration](https://opencode.ai/docs/config/) and [authentication commands](https://opencode.ai/docs/cli/#auth).
