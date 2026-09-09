# Isolated accounts and pooled environments

New accounts start with independent Codex homes. No configuration, skills, instructions or memory is automatically inherited. Existing account files are preserved; legacy Deck-managed instruction hardlinks are detached on that account's next launch, preserving their contents. This is configuration isolation, not an operating-system security sandbox: Codex still runs as your Windows user.

## One environment, several quota accounts

The installer creates a first-listed `pool` entry unless that name already exists. It has its own configuration, skills, memory and conversation history, but no login of its own. Its defaults are every signed-in ordinary account (including accounts added later), Ordered rotation, and no resource sharing. Membership does not copy or share those accounts' environments.

Run `codex-auth pool` to open a Codex session immediately using the pool's configured membership and rotation. Ordered starts with the first member; Best requires fresh usage checks in the regular dashboard. To start with a specific member:

```powershell
codex-auth pool -UseAccount account1
```

In **Settings > Environments**, choose all signed-in accounts, all free accounts, all Plus-or-higher accounts, or selected accounts. Only the last choice shows the account list. The first three choices include matching accounts added later. Choose Ordered/Best rotation, then use **Save settings** from any settings tab. Backup and About retain their separate actions. You can create several named pools. Equivalent PowerShell commands:

```powershell
codex-auth pool -Pool -PoolAccounts '*'
codex-auth work -Pool -PoolAccounts account1,account2 -PoolMode Ordered
```

Rotation uses the existing local failover proxy and only retries rejected 429 requests. It does not replay accepted streams. Full local history and encrypted stateless reasoning/compaction can move to a fallback account; server-stored response IDs, uploaded file IDs and item references remain account-bound. Those conversations may require a new conversation after exhaustion. `-Failover Off` limits a pooled launch to its chosen member. See [failover details](ACCOUNT-TOOLS.md).

## Selectively share resources

Open **Settings > Environments**. Choose **Share from**, select one of that owner's resources, and check its recipients. Changing the owner reloads the resource list; returning to an owner preserves pending edits. **Save settings** applies those edits together with settings from the other tabs. Unchecking restores the recipient's previous private resource where one existed. The owner can be a pool or an ordinary account. Close recipient terminals before saving sharing changes.

Supported resources:

| Resource | Behavior |
| --- | --- |
| `skills` or `skills/name` | Live shared directory; edits from any recipient affect the owner and other recipients |
| `memories`, `rules`, `prompts` | Live shared directory with the same edit behavior |
| `AGENTS.md` | Owner-controlled copy refreshed on launch; recipient edits cause a conflict instead of being overwritten |
| `mcp:server-name` | Owner's server definition applied at launch without rewriting recipient configuration |

MCP definitions may contain environment values or static secrets: share only with recipients you trust. OAuth credentials are not copied; recipient authorization may still be necessary. Memory sharing covers files in `memories`, not Codex's runtime databases or every kind of learned state. Credentials, sessions/history, databases, complete configuration files and plugins are deliberately not shareable through this interface.

```powershell
codex-auth share -Source pool -Targets account1,account2 -Resources skills,memories,mcp:github
codex-auth sharing
codex-auth unshare -Targets account1 -Resources memories
```

`-Targets '*'` shares with all other entries that exist **now**, not future accounts. This differs intentionally from wildcard pool membership: adding an account always leaves its environment isolated. Sharing chains and overlapping whole-folder/individual-skill bindings are rejected. Batch operations preflight all selections, but an unexpected disk error can leave earlier selections applied; inspect `codex-auth sharing` before retrying.

To opt into a one-time bootstrap when creating an account, use `codex-auth account3 -InheritFrom account1` (or `default`). This copies supported configuration resources, never credentials; subsequent edits are independent.

## Global Rules

Choose **Configs > Global Rules**, press **G** in the terminal dashboard, or run `codex-auth -GlobalRules`. Save plain text instructions; leave the editor blank to disable them. Rules are stored in `deck/global-rules.md`, and saving keeps a backup of the previous text.

Every conversation launched through Deck or `codex-auth` loads these rules as startup developer instructions, regardless of account, pool or working folder. Existing account/profile developer instructions are preserved. Account and project `AGENTS.md` files remain untouched. Rules become part of the conversation context; they are not resent as new user messages on every turn. Already-running Codex processes keep their launch-time rules; relaunch to load edits. Resuming through a new launch loads the current rules too. Running plain `codex` bypasses Deck's launcher.

This uses [Codex's developer instructions setting](https://learn.chatgpt.com/docs/config-file/config-reference). Global rules are separate from account configuration backups; back up `deck/global-rules.md` if needed.

## Backups and removal

Encrypted configuration backups include pooled-entry membership metadata. They do not include shared directories, sharing bindings, or private-resource backups. Back up those resources separately and reapply sharing explicitly after restore. An exported instruction copy is restored as private instructions.

Rename/delete is blocked while an entry participates in sharing or is explicitly named in another pool. Unshare and update membership first. Unsharing preserves the owner's files and restores the recipient's pre-sharing copy; edits made while a directory was shared remain with the owner.
