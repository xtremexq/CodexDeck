# AI Router

AIDeck Router is a separate Chrome extension for API provider accounts, model routes and failover. It works standalone. Deck supplies an optional server when terminals, desktop API clients, account-specific proxies or native harness controls need it.

## Install and connect

1. Install Node.js 22 or newer and deploy this Deck build using the normal Deck installer.
2. Open **Settings → AI Router** and click **Install / update server**. Leave the source field blank to use the bundled payload, or select an `aideck-router` source folder. Installation downloads runtime dependencies and starts the hidden server.
3. Choose **Start server at Windows sign-in** if desired. **Enable server** resumes a stopped server; **Stop server** disables it. Enabled servers restart after a crash.
4. Load the AIDeck Router **extension** folder through `chrome://extensions` → Developer mode → Load unpacked. The built standalone extension needs no Node installation.
5. In extension Settings → Connection, choose **Connect to Deck**, request pairing against `http://127.0.0.1:5147`, and keep the dashboard open.
6. In Deck Settings → AI Router, approve the matching code within five minutes. Approval grants the extension owner access to this router. The saved connection is reused automatically.
7. Add API provider accounts and model routes in the extension. Create scoped integration keys for the routes your clients should use. Pairing creates a bridge key scoped to the enabled routes at approval; create a new key if you later expose more routes.

The HTTP API base is `http://127.0.0.1:5147/v1`. Compatible clients use it with an integration key and a route alias. Native API-mode harness configuration remains explicit; Deck does not redirect subscription-login traffic automatically.

## Separate workspaces

Standalone provider keys live in Chrome extension local storage. Server keys use an encrypted vault with a Windows DPAPI-protected master key. Accounts, routes, keys and approved extension callers are separate for the two modes; switching modes does not copy them or silently choose another account.

In Deck mode, the extension's AI Deck page reads native account metadata and opens account creation, login or terminal actions through `codex-auth`. Native logins are separate from provider API keys. Codex native pooling/failover remains Codex-only; Router API routes can fail over across configured provider accounts.

## Files and maintenance

The managed runtime is under the installed suite's `deck/ai-router`: `app` contains server code/dependencies, `data` contains configuration and the vault, and `service.json` stores enable/startup settings. Updating replaces application files and preserves data.

Stop the server before backing up its entire data directory. DPAPI-encrypted backups require the original Windows identity. The existing Deck account backup does not export the Router vault. Keep provider credentials and saved owner connections private.

If startup does not become ready, inspect `server-error.log` and `supervisor-error.log` in that directory. Another application using port 5147 prevents startup. Pairing requires a fresh request after the server restarts; a connection already approved remains saved.

Provider API calls consume API billing/quotas. ChatGPT, Claude and Gemini consumer website allowances are not routed. Other extensions must deliberately call Router's approved messaging API; standard desktop clients need a configurable API URL.
