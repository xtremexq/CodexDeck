---
name: debug-swarm
description: Orchestrate parallel, evidence-first debugging with independent Codex CLI workers launched through Codex Deck accounts or pools. Use only when the user explicitly asks for a debug swarm, multiple independent investigators, subagents, or one worker per target. Never infer this workflow from task size or expected benefit.
---

# Debug Swarm

Coordinate independent Codex CLI sessions and synthesize their findings. Activate this skill only for an explicit user request for a debug swarm or parallel independent Codex workers; never activate it proactively because parallel investigation could help. When the user says "subagents" in this workflow, interpret that as separate Codex terminal workers launched through `codex-auth`, not in-process delegation, unless they explicitly request the latter.

## Establish the contract

- Preserve the user's account or pool, model, reasoning effort, concurrency cap, mutation boundary, and stopping condition exactly.
- Inspect repository instructions and working-tree state before assigning work. Existing changes belong to the user.
- Split the problem into non-overlapping investigation units with one named owner each. Prefer components, providers, failure classes, or code paths that can be investigated independently.
- Default workers to diagnosis only. The coordinating session owns synthesis and code changes unless the user explicitly authorizes worker edits.
- Never give a worker permission broader than the parent task. Keep credentials and production access scoped to the minimum required.

## Launch real workers

Use actual Codex terminal processes. Do not use an in-process subagent or delegation API for this workflow. `codex-auth <account>` is itself a long-running interactive Codex session, not an account-selection command that returns to the shell. Never chain it with `codex exec`, `;`, `&&`, or another launch command. A shell sitting inside bare `codex-auth` without the assigned task is **not a started worker**.

Treat foreground and background as user-visible execution modes:

- **Foreground** always means one desktop-visible terminal window or tab per worker that the user can watch and interact with. A tool-attached PTY is headless from the user's perspective and never satisfies a foreground request.
- **Background** means a headless or tool-attached process. Retain its process/session ID and output or log path so it can be checked later.
- Honor the requested mode exactly. Do not silently substitute a tool PTY for a foreground terminal.

For an exact-account diagnostic worker, pass Codex CLI arguments as one explicit array. Use `-Direct` if you want native Codex `exec` without Deck routing. For Deck-supervised auto-compaction, use `-AutoCompact` with the same argument array; Deck translates supported conversation flags (including model, effort/config, sandbox, approval, directory, prompt) into its supervised app-server session. PowerShell otherwise interprets Codex's `-C` as a second binding of the wrapper's `-CodexArgs` parameter, so `codex-auth account15 exec -C ...` fails before Codex starts:

```powershell
$workerArgs = @('exec', '-C', $projectRoot, '-m', $model,
    '-c', "model_reasoning_effort=`"$effort`"", '-c', 'agents.enabled=false',
    '-c', 'windows.sandbox="unelevated"',
    '-s', 'read-only', $prompt)
& codex-auth $account -Direct -Failover Off -CodexArgs $workerArgs
```

If the user requests Deck auto-compaction for workers, replace that launch line with `& codex-auth $account -AutoCompact -Failover Off -CodexArgs $workerArgs`. Add `-Direct` when exact-account isolation is required; without `-Direct`, Deck retains manual in-session account switching. For pools, use `& codex-auth $pool -AutoCompact -CodexArgs $workerArgs` (and `-UseAccount $account` when an initial member is specified); the supervised session routes via Deck's HTTP-only provider and can use pool failover. Preflight one worker before a wave and verify actual completion: a startup banner, WebSocket 426, or idle prompt is not a finished investigation. `-AutoCompact` is opt-in per worker; if the user chooses native `exec`, Codex's own auto-compaction remains available. Supervised `exec` needs its prompt as an argument (stdin is reserved for supervision); unsupported exec-only flags fail explicitly. Keep a background tool-attached worker attached to its PTY/session.

For foreground workers on Windows, launch the same command in `wt.exe -w new new-tab --title <job> -d <project> pwsh.exe -NoExit -EncodedCommand <encoded script>`. Launch it as a normal visible desktop process; if `Start-Process` is needed, never pass `-WindowStyle Hidden`. Tee each worker's output to a distinct log or status file, print a clear completion/exit-code line, and leave the tab open. `wt.exe` returning confirms only that the window was requested, so verify from the log/status signal that Codex accepted the task and reached its first tool call or response.

If the user explicitly wants the bare interactive command, start `codex-auth <account>` in the requested execution mode, wait for its Codex prompt, and send the investigation brief **into that same terminal session**. Do not launch a second Codex command from the parent shell. An interactive worker remains open after answering, so inspect its response to determine completion; for a clear process exit and immediate completion signal, prefer the explicit-array `exec` form above.

After each launch, verify within a short bounded interval that the assigned task actually reached Codex: observe the `exec` startup/output or the interactive prompt accepting the brief, confirm progress beyond startup (for example a tool call), and record the process and Codex session IDs. A `426` WebSocket error, idle dashboard/prompt, authentication failure, or quota error is **not** a started investigation. Close only that owned failed process tree, and do not count it toward completed investigations. Preserve output or a resumable session ID so completion and final reports can be checked later. Do not leave ten unverified terminals idle.

- Use the user's requested concurrency, never more than 10 simultaneous workers. If more tasks remain, run waves and report the remaining count.
- For a small model such as Luna, give each worker one narrow target and a compact evidence-led brief. Keep non-negotiable safety constraints and report format; omit repeated background prose and unrelated provider history. Do not assume high reasoning effort removes context or tool-use limits.
- Have each worker identify the likely cause and recommend one code-level fix that addresses it and helps prevent recurrence. Use enough evidence to separate verified facts from guesses. If the cause is still unclear, state the quickest check that would settle it. Avoid generic mitigations presented as fixes and speculative redesigns.
- If no model or effort is specified, inherit the coordinating session's choices. Do not silently substitute another explicitly requested model.
- Keep diagnostic workers' filesystem access read-only. When live requests are needed to debug a target, give that worker restricted outbound network access to the specific provider, diagnostics, API, redirect, and media hosts it must reach. Add hosts as evidence reveals them; do not grant unrestricted network or writable filesystem access to make a request succeed. Verify a representative read-only request from inside the worker before treating live evidence as available.
- On Windows, use `-c 'windows.sandbox="unelevated"'` and `-s read-only` for repository-only diagnostic workers to avoid repeated UAC setup prompts. These legacy sandbox settings, including an account config's `sandbox_mode`, can override a custom permission profile and leave shell HTTP blocked. For a worker that needs live requests, configure and verify an effective per-worker read-only filesystem profile with the required host allowlist through its actual Direct or Deck-supervised launch path; do not simply add a network setting to the example command above. Keep account-wide config unchanged. If the launcher cannot preserve both restrictions, fix the launch path or report the blocker instead of claiming live provider verification.
- Start workers concurrently when useful, retain each terminal/session identifier, and maintain a clear task-to-session mapping.
- If the user says to stop after launch, report what is running and end the turn without polling.

Every worker brief must state:

- its single investigation target and relevant evidence;
- the project root and applicable repository instructions;
- whether live network or production diagnostics are needed, and the specific hosts and read-only requests allowed for this target;
- no file edits, commits, cleanup, or state changes in diagnosis-only mode;
- no child agents, subagents, delegation, or background model processes;
- the likely cause with supporting evidence and uncertainty, exact patch locations and steps, and overlap with other targets when relevant;

Ask for a concise, decision-first report: cause, supporting evidence, best fix, and any blocker. Keep only detail needed to apply the fix.

Do not put secrets in the final worker report. Passing a user-authorized read-only credential to a worker is allowed only when that worker needs it; instruct the worker not to print it.

## Resume and synthesize

When the user returns, poll the retained terminal sessions rather than starting duplicate investigations. Replace a failed worker only when doing so stays within the concurrency cap and requested scope.

Review reports as evidence, not authority:

1. Confirm claimed files, symbols, diagnostics, and reproduction paths in the repository.
2. Merge duplicate root causes and surface disagreements.
3. Distinguish code defects from upstream outages, stale telemetry, environment failures, and title/input-specific absence.
4. Identify the best durable fix for each confirmed cause, addressing shared causes before leaf symptoms. If evidence is insufficient, gather the smallest useful missing evidence before changing code.
5. When the parent task authorizes implementation, apply all supported in-scope fixes, preserve unrelated work, and validate the result. Do not stop at worker reports or a patch plan and wait for a new request. For provider/resolver work, cover at least five distinct titles or inputs across every supported media/input type where practical.
6. When the parent task is diagnosis-only, return the concrete fixes and remaining evidence gaps without editing the codebase.

Be explicit about what was directly verified, what remains inferred, and what still requires post-fix validation. Do not present a plausible mitigation as a confirmed root-cause fix.
