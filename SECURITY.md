# Security

Do not attach account folders, auth.json, config.toml, session history, logs, or Deck caches to public issues. Screenshots may expose email addresses, paths, or account names; mask or redact them first.

Report vulnerabilities using the repository's **Security → Report a vulnerability** option. If private reporting is unavailable, open an issue requesting a private contact channel without exploit details or credentials.

Credentials are managed locally by Codex CLI in `%USERPROFILE%\.codex-loop\accounts`. Deck reads those credentials to query account usage. Deck's cache contains account metadata, including email and usage; it is not a credential vault. Protect the entire installation's runtime data.

Usage queries contact OpenAI services. Optional warmup invokes Codex and consumes real quota. Automatic checks and warmup start disabled. Upstream CLI and usage endpoint changes can affect compatibility.

Only the latest release is supported. Distributed PowerShell scripts are unsigned; review the source before running them.
