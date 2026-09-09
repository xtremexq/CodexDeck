# Isolated accounts and pooled environments

New accounts start with independent Codex homes. No configuration, skills, instructions or memory is automatically inherited. Existing account files are preserved; legacy Deck-managed instruction hardlinks are detached on that account's next launch, preserving their contents. This is configuration isolation, not an operating-system security sandbox: Codex still runs as your Windows user.

## One environment, several quota accounts

The installer creates a first-listed `pool` entry unless that name already exists. It has its own configuration, skills, memory and conversation history, but no login of its own. Its default membership is every signed-in ordinary account, including accounts added later. Membership does not copy or share those accounts' environments.

Run `codex-auth pool` to choose a quota account and see member usage. Refresh the selected account with **R**, or choose the freshest eligible recommendation with **B**. Cached/unknown usage is not proof that a login remains valid. To start with a specific member:

```powershell
codex-auth pool -UseAccount account1
```

In **Settings > Environments**, save all-account or selected-account membership and Ordered/Best rotation. You can create several named pools. Equivalent PowerShell commands:

```powershell
codex-auth pool -Pool -PoolAccounts '*'
codex-auth work -Pool -PoolAccounts account1,account2 -PoolMode Ordered
```

Rotation uses the existing local failover proxy and only retries explicit quota rejections. It does not replay accepted streams or move account-bound response history to another account. Some conversations therefore require starting a new conversation after exhaustion. `-Failover Off` limits a pooled launch to its chosen member. See [failover details](ACCOUNT-TOOLS.md).

## Selectively share resources

Open **Settings > Environments**. Choose an owner, select recipients, browse the owner's resources, then select resources and press **Share**. The owner can be a pool or an ordinary account. Close recipient terminals before changing sharing. **Unshare** restores their previous private resource where one existed.

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

`-Targets '*'` shares with all other entries that exist **now**, not future accounts. This differs intentionally from wildcard pool membership: adding an account always leaves its environment isolated. Sharing chains and overlapping whole-folder/individual-skill bindings are rejected. Batch operations preflight all selections, but an unexpected disk error can leave earlier selections applied; inspect **Show sharing** before retrying.

To opt into a one-time bootstrap when creating an account, use `codex-auth account3 -InheritFrom account1` (or `default`). This copies supported configuration resources, never credentials; subsequent edits are independent.

## Backups and removal

Encrypted configuration backups include pooled-entry membership metadata. They do not include shared directories, sharing bindings, or private-resource backups. Back up those resources separately and reapply sharing explicitly after restore. An exported instruction copy is restored as private instructions.

Rename/delete is blocked while an entry participates in sharing or is explicitly named in another pool. Unshare and update membership first. Unsharing preserves the owner's files and restores the recipient's pre-sharing copy; edits made while a directory was shared remain with the owner.
