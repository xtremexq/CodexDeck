# Account tools

These features are included in release 1.2.0.

## Best account

Press **B** in the terminal dashboard to select the recommended account, then Enter to launch it. Use `codex-auth -Best` to launch directly, or **Configs > Recommend best account** in the desktop companion.

Recommendations require successful usage checks from the last five minutes. Refresh first if none qualify. The account with the highest remaining percentage in its most constrained window wins; average remaining percentage and earliest reset break ties. Exhausted, unknown and stale windows are excluded. Percentages are a heuristic: different subscription plans can have different absolute capacities. Nothing switches an existing session automatically.

## Local session history

Press **H** in the dashboard or run `codex-auth -History`. Search with `/`, page with N/P, refresh with R, and enter a row number to resume using its original account and working folder. An optional account/folder/provider/session-ID filter can be passed as the positional argument.

The browser combines session metadata from the managed accounts' `sessions` directories. It reads only the first metadata line (up to 1 MiB), skips malformed files and filesystem links, and does not index conversation contents. Archived sessions and sessions outside managed accounts are not included. The original working directory must still exist to resume.

## Rename

Press **F2** in the dashboard or run `codex-auth old -RenameTo new`. Pause automatic warm-up and quit the desktop companion first, finish dashboard refreshes, and close connected terminals for that account. The account folder, warm-up selection, pins and cached account records are migrated together, with rollback if writing state fails. Case-only renames are not supported. Avoid simultaneous maintenance in another dashboard.

## Manual reset credits

Usage refreshes also attempt to read available manual reset credits. Expanded desktop details and terminal details show the available count and earliest reported expiration. Expired and redeemed credits are excluded; unavailable information says **Not reported**, never an invented zero. A failed credit lookup does not discard quota results. Cached information is marked after five minutes. This displays credits; it does not redeem them.

## Live failover (opt-in)

Press **Settings → Failover** in the terminal dashboard, enter a comma-separated account pool, then choose **Ordered** or **Best**. Empty input cancels. Or launch directly:

```powershell
codex-auth -Failover Ordered -FailoverAccounts account1,account2,account3
codex-auth -Failover Best -FailoverAccounts account1,account2,account3
```

Failover is **Off** by default. In desktop **Settings > Failover**, enable **Automatically enable failover for codex-auth launches**, choose Ordered or Best, then choose all signed-in, all free, all Plus-or-higher, or selected accounts. Press **S** in the terminal dashboard to open desktop Settings directly. New conversation launches inherit this setting; already-running sessions do not change. Login and administrative commands stay direct. Use `codex-auth account1 -Failover Off` to bypass it once. Without the saved toggle, enable failover explicitly per launch. Dynamic groups are stored as `*`, `*free`, or `*paid` and resolve again at every launch, so later accounts are included automatically. Explicit pools contain 1-200 distinct existing ChatGPT accounts. For `codex-auth accountX`, X remains the starting account and the saved group or pool supplies its fallbacks. For an explicit failover launch without a positional account, the selected mode chooses the starting account. Numbers such as `1,2` also work. Ordered starts with the first account and tries the remaining accounts in list order. Best starts with the freshest eligible recommendation and re-reads cached usage to rank the remaining pool after a quota rejection. An explicitly named starting account is honored even without fresh usage; fresh checks are required for Best fallbacks. Refresh usage in the dashboard first; Best excludes checks older than five minutes. It never probes or selects accounts outside your pool. A single-account pool is valid but has no fallback.

Use Node.js 22.16+ on PATH for current Codex clients' zstd-compressed requests. Ordinary accounts use Codex's built-in OpenAI provider with a temporary `openai_base_url`; pools use their existing custom Responses provider without owning a login. The proxy uses a random loopback port and per-launch capability URL. It runs only for that launch and stops when its parent exits. Credentials are read from the selected accounts' local auth files, never copied between accounts or logged. Login through the OS keychain alone is not supported. Expired or invalid logins stop with an authentication error; log in again separately.

Only HTTP 429 responses explicitly marked `usage_limit_reached`, `rate_limit_exceeded`, or `insufficient_quota`, before response streaming, trigger a switch. Each pool account is attempted at most once per proxy request. Quota-rejected accounts remain excluded for the rest of the launch. Authentication errors, server errors, network failures, and errors inside an accepted stream do not cause proxy retries or account switching. The proxy declines WebSockets so the built-in client falls back to HTTP; that client retains its own retry behavior. Pooled custom-provider launches disable client HTTP/stream retries. Saved provider configuration is unchanged.

Deck does not write failover banners or background switch notices over Codex's full-screen terminal. Codex supports a local shell prefix, so use `!account`, `!pool`, `!usage`, and `!check`; they execute locally without submitting anything to the model. Every signed-in ordinary conversation gets a manual-only loopback route, so `!account` can switch from `codex-auth account5` even while automatic failover is Off. It prints the numbered session-account list; named environments also show their current pool. `!pool` prints that pool directly. Because Codex local shell commands do not expose interactive stdin, switch with a second command such as `!account account7`, `!pool 2`, or `!pool account7`. `!check` reproduces the complete `codex-check` report. `!usage` first resolves the session's active route and checks only that account, so it follows manual switches. Codex does not expose a third-party bare-slash extension point, so these cannot appear as `/account` entries in its built-in menu. Earlier Deck-managed `$account`, `$pool`, `$check`, and `$usage` skills are removed during update because skills necessarily create a model turn. Local session history, settings and tools remain attached to the starting account/environment; only subsequent API requests change routes. Desktop Settings saves the default and pool; desktop terminal launches and the terminal dashboard use the same preference. Refreshing usage remains an explicit command or dashboard operation.

Ordinary failover launches retain the `openai` provider identity, keeping normal account conversations visible to the native resume picker. Sessions previously recorded under `deck_failover` can be opened by ID through `codex-auth -History`. The native picker may also filter by working folder. Pool history belongs to the pool home; selecting quota members or sharing resources does not merge their conversation histories.

### Compatibility limits

This is an experimental HTTP Responses mode. Full local history and encrypted stateless reasoning/compaction items can switch accounts after a rejected 429. Server-stored response references, uploaded file IDs and item references remain account-bound: the proxy stops with an explanation instead of discarding context. History produced by the active account remains usable after a switch. Provider-relative GET/POST endpoints used by Codex extensions are forwarded once with the active account; only Responses and compaction requests can fail over, preventing ambiguous auxiliary operations from being replayed. Deck control routes and unsupported HTTP methods are rejected; concurrent conversation requests are rejected explicitly, while auxiliary and model-list requests can run alongside a conversation.

Use only pool accounts appropriate for the same project and conversation: a retried request sends its context to the next account. No prompts, responses, credentials or proxy capability URLs are written to Deck logs. The client can still record its own session/configuration diagnostics. Tests use synthetic credentials and local mock responses; live service compatibility can change independently of Deck.
