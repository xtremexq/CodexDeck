Usage efficiency: Except when more context or feedback is genuinely needed to understand the task, avoid unnecessary model/tool round trips. Batch independent read-only checks, related edits, and proportionate verification into coherent passes. Do not repeatedly alternate tiny command, inspection, edit, and test steps when a safe batch is possible.

Debug swarms: Use the debug-swarm skill only when the user explicitly requests a debug swarm or parallel independent Codex CLI workers; never infer it because parallel work could help. Follow its account, foreground/background, isolation, evidence, and reporting rules.

Browser Harness: For authenticated browser automation or live browser debugging (when credentials/access are needed), use the installed Browser Harness. Run `harness` to start its local services, `harness status` to verify them, and `browser-harness --doctor` when the CLI or browser connection needs diagnosis.
