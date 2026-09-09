# Account tools

These features are included in release 1.2.0.

## Best account

Press **B** in the terminal dashboard to select the recommended account, then Enter to launch it. Use `codex-auth -Best` to launch directly, or **Configs > Recommend best account** in the desktop companion.

Recommendations require successful usage checks from the last five minutes. Refresh first if none qualify. The account with the highest remaining percentage in its most constrained window wins; average remaining percentage and earliest reset break ties. Exhausted, unknown and stale windows are excluded. Percentages are a heuristic: different subscription plans can have different absolute capacities. Nothing switches an existing session automatically.

## Local session history

Press **H** in the dashboard or run `codex-auth -History`. Search with `/`, page with N/P, refresh with R, and enter a row number to resume using its original account and working folder. An optional account/folder/provider/session-ID filter can be passed as the positional argument.

The browser combines session metadata from the managed accounts' `sessions` directories. It reads only the first metadata line (up to 1 MiB), skips malformed files and filesystem links, and does not index conversation contents. Archived sessions and sessions outside managed accounts are not included. The original working directory must still exist to resume.

## Rename

Press **F2** in the dashboard or run `codex-auth old -RenameTo new`. Quit the desktop companion and tray scheduler first, finish dashboard refreshes, and close connected terminals for that account. The account folder, warm-up selection, pins and cached account records are migrated together, with rollback if writing state fails. Case-only renames are not supported. Avoid simultaneous maintenance in another dashboard.

## Manual reset credits

Usage refreshes also attempt to read available manual reset credits. Expanded desktop details and terminal details show the available count and earliest reported expiration. Expired and redeemed credits are excluded; unavailable information says **Not reported**, never an invented zero. A failed credit lookup does not discard quota results. Cached information is marked after five minutes. This displays credits; it does not redeem them.

## Live failover (opt-in)

Press **Settings → Failover** in the terminal dashboard, enter a comma-separated account pool, then choose **Ordered** or **Best**. Empty input cancels. Or launch directly:

```powershell
codex-auth -Failover Ordered -FailoverAccounts account1,account2,account3
codex-auth -Failover Best -FailoverAccounts account1,account2,account3
```

Failover is **Off** by default. In desktop **Settings > Failover**, enable **Automatically enable failover for codex-auth launches**, choose Ordered or Best, and save a comma-separated fallback pool. Press **S** in the terminal dashboard to open desktop Settings directly. New conversation launches inherit this setting; already-running sessions do not change. Login and administrative commands stay direct. Use `codex-auth account1 -Failover Off` to bypass it once. Without the saved toggle, enable failover explicitly per launch. The pool contains 1-200 distinct existing ChatGPT accounts. For `codex-auth accountX`, X remains the starting account and the saved pool supplies its fallbacks. For an explicit failover launch without a positional account, the selected mode chooses the starting account. Numbers such as `1,2` also work. Ordered starts with the first account and tries the remaining accounts in list order. Best starts with the freshest eligible recommendation and re-reads cached usage to rank the remaining pool after a quota rejection. An explicitly named starting account is honored even without fresh usage; fresh checks are required for Best fallbacks. Refresh usage in the dashboard first; Best excludes checks older than five minutes. It never probes or selects accounts outside your pool. A single-account pool is valid but has no fallback.

Use Node.js 22.16+ on PATH for current Codex clients' zstd-compressed requests. Ordinary accounts use Codex's built-in OpenAI provider with a temporary `openai_base_url`; pools use their existing custom Responses provider without owning a login. The proxy uses a random loopback port and per-launch capability URL. It runs only for that launch and stops when its parent exits. Credentials are read from the selected accounts' local auth files, never copied between accounts or logged. Login through the OS keychain alone is not supported. Expired or invalid logins stop with an authentication error; log in again separately.

Only HTTP 429 responses explicitly marked `usage_limit_reached` or `insufficient_quota`, before response streaming, trigger a switch. Each pool account is attempted at most once per proxy request. Quota-rejected accounts remain excluded for the rest of the launch. Generic rate limiting, authentication errors, server errors, network failures, and errors inside an accepted stream do not cause proxy retries or account switching. The proxy declines WebSockets so the built-in client falls back to HTTP; that client retains its own retry behavior. Pooled custom-provider launches disable client HTTP/stream retries. Saved provider configuration is unchanged.

Switches print the active account in the terminal. Local session history, settings and tools remain attached to the starting account; the other pool accounts are marked as in use to protect them from rename/removal. Desktop Settings saves the default and pool; desktop terminal launches and the terminal dashboard use the same preference. Refreshing usage remains an explicit dashboard operation.

Ordinary failover launches retain the `openai` provider identity, keeping normal account conversations visible to the native resume picker. Sessions previously recorded under `deck_failover` can be opened by ID through `codex-auth -History`. The native picker may also filter by working folder. Pool history belongs to the pool home; selecting quota members or sharing resources does not merge their conversation histories.

### Compatibility limits

This is an experimental HTTP Responses mode. Full local history and encrypted stateless reasoning/compaction items can switch accounts after a rejected 429. Server-stored response references, uploaded file IDs and item references remain account-bound: the proxy stops with an explanation instead of discarding context. History produced by the active account remains usable after a switch. Unsupported endpoints and concurrent conversation requests are rejected explicitly; model-list requests can run alongside a conversation.

Use only pool accounts appropriate for the same project and conversation: a retried request sends its context to the next account. No prompts, responses, credentials or proxy capability URLs are written to Deck logs. The client can still record its own session/configuration diagnostics. Tests use synthetic credentials and local mock responses; live service compatibility can change independently of Deck.
