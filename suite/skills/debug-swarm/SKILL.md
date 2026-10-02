---
name: debug-swarm
description: Orchestrate parallel, evidence-first debugging with independent Codex CLI workers launched through Codex Deck accounts or pools. Use only when the user explicitly asks for a debug swarm, multiple independent investigators, subagents, or one worker per target. Never infer this workflow from task size or expected benefit.
---

# Debug Swarm

Coordinate independent Codex CLI sessions and synthesize their findings. Activate this skill only for an explicit user request for a debug swarm or parallel independent Codex workers; never activate it proactively because parallel investigation could help. When the user says "subagents" in this workflow, interpret that as separate Codex terminal workers launched through `codex-auth`, not in-process delegation, unless they explicitly request the latter.

## Establish the contract

- Preserve the user's account or pool, model, reasoning effort, concurrency cap, mutation boundary, and stopping condition exactly.
- Inspect repository instructions and working-tree state before assigning work. Existing changes belong to the user.
- Split the problem into non-overlapping investigation units with one named owner each. Rows sharing an extractor belong to one owner. Name a shared-runtime owner (normally the coordinator) so a cross-family defect has somewhere to go.
- Default workers to diagnosis only. The coordinating session owns synthesis and code changes unless the user explicitly authorizes worker edits.
- Never give a worker permission broader than the parent task. Keep credentials and production access scoped to the minimum required.

## Resolve launch capabilities

Before opening terminals, build all worker specifications in one pass: task, owner, account, model, effort, execution mode, effective permissions, network needs, test/build commands, auto-compact mode and threshold, and log/status/report paths. Reuse the bundled argument builder rather than rediscovering wrapper syntax or account settings for each worker. Leave account-wide settings unchanged.

- Separate **code ownership** from **execution permissions**. A worker restricted to one family's source files still needs to start child processes, write normal test/build artifacts, and make authorized live requests. Diagnosis-only means no implementation edits; authorized tests may need temporary artifacts.
- Carry the parent's effective permission and approval policy explicitly into the launch. In an authorized `danger-full-access` session, preserve that mode for repair workers; do not silently replace it with `read-only`, `workspace-write`, or `windows.sandbox="unelevated"`. If the parent requires a restricted profile, preserve its path/host restrictions through the actual launcher and verify its capabilities. Never bypass a parent restriction to make a test succeed.
- Legacy account sandbox settings can override a permission profile. Do not combine named/custom permission profiles with copied legacy sandbox overrides. `sandbox_workspace_write.network_access=true` alone does not prove that HTTP or child-process spawning works.
- The first worker's first tool batch must exercise the required capabilities **inside its actual Codex session**: a focused test or lightweight command using the same subprocess runner, a permitted artifact write when needed, and a representative authorized network request when needed. Include any user-mandated first command in this batch; reuse its capability evidence instead of duplicating it. If compilation/build is required, exercise its subprocess path too. A successful request or test in the parent shell is insufficient.
- `spawn EPERM`, `spawnSync EPERM`, sandbox access failures, authentication failures, and unsupported launch flags are **launch/environment blockers**, not provider failures. Stop the affected launch wave, correct only the owned launch configuration within existing authorization, and retry the capability check once. Do not spend each worker's investigation on an unusable environment or label it externally blocked by a provider.

The helper [scripts/New-WorkerLaunch.ps1](scripts/New-WorkerLaunch.ps1) returns a `codex-auth` splatting hashtable without starting a process. Use it for exact-account workers with standard sandbox modes. For a required custom permission profile or pool, retain explicit-array launching and the same capability checks; do not flatten those restrictions into a standard mode.

## Launch real workers

Use actual Codex terminal processes. Do not use an in-process subagent or delegation API for this workflow. `codex-auth <account>` is itself a long-running interactive Codex session, not an account-selection command that returns to the shell. Never chain it with `codex exec`, `;`, `&&`, or another launch command. A shell sitting inside bare `codex-auth` without the assigned task is **not a started worker**.

Treat foreground and background as user-visible execution modes:

- **Foreground** always means one desktop-visible terminal window or tab per worker that the user can watch and interact with. A tool-attached PTY is headless from the user's perspective and never satisfies a foreground request.
- **Background** means a headless or tool-attached process. Retain its process/session ID and output or log path so it can be checked later.
- Honor the requested mode exactly. Do not silently substitute a tool PTY for a foreground terminal.

For an exact-account worker, use `-Direct -Failover Off` with one explicit `-CodexArgs` array. PowerShell otherwise interprets Codex's `-C` as a second binding of the wrapper's `-CodexArgs` parameter, so `codex-auth account15 exec -C ...` fails before Codex starts. This example uses the already established parent policy and an explicit requested 50% auto-compact threshold:

```powershell
$launch = & "$skillRoot/scripts/New-WorkerLaunch.ps1" `
    -Account $account -ProjectRoot $projectRoot -Model $model -Effort $effort `
    -Mode Repair -ParentSandboxMode $parentSandboxMode `
    -ApprovalPolicy $parentApprovalPolicy -ParentNetworkAccess $parentNetworkAccess `
    -NeedsNetwork -AutoCompactFreePercent 50 -Prompt $prompt `
    -OutputLastMessage $reportPath
& codex-auth @launch
```

`-AutoCompact` is opt-in per `exec` worker. Read the selected Native/Custom mode once from Deck settings. To request 50% context remaining explicitly, prepend `'50%'` as the **first** element of `CodexArgs` and pass `-AutoCompact`; the helper does both. Record the actual mode and threshold in each worker's launch status. Adding a flag to later workers does not change already running workers. Native uses Codex's token threshold; Custom uses Deck supervision. Custom requires the prompt as an argument and rejects `--json`, `--worktree`, and `--add-dir`. The helper uses arguments compatible with both modes and does not emit `--json`. For pools, use `& codex-auth $pool -AutoCompact -CodexArgs $workerArgs` (and `-UseAccount $account` when specified).

Preflight one worker before the wave, waiting only for task acceptance and the required capability check, not the entire investigation. Then launch the remaining workers in one batch. A banner, process ID, WebSocket 426, or idle prompt proves neither capability nor completion. Keep background tool-attached workers attached to their PTY/session.

For foreground workers on Windows, launch the same command in `wt.exe -w new new-tab --title <job> -d <project> pwsh.exe -NoExit -EncodedCommand <encoded script>`. Launch it as a normal visible desktop process; `Start-Process pwsh.exe -WindowStyle Normal -ArgumentList ...` is also valid. Write a distinct transcript/log, have the worker write a capability status file from inside its session, print a completion/exit-code line, and leave the terminal open. If native output bypasses `Tee-Object`, use `Start-Transcript` plus the worker's status and final `-o` report; do not repeatedly relaunch because a tee is empty. A window request is not evidence that Codex accepted the task.

If the user explicitly wants the bare interactive command, start `codex-auth <account>` in the requested execution mode, wait for its Codex prompt, and send the investigation brief **into that same terminal session**. Do not launch a second Codex command from the parent shell. An interactive worker remains open after answering, so inspect its response to determine completion; for a clear process exit and immediate completion signal, prefer the explicit-array `exec` form above.

After each launch, verify within a short bounded interval that the assigned task actually reached Codex: observe the `exec` startup/output or the interactive prompt accepting the brief, confirm progress beyond startup (for example a tool call), and record the process and Codex session IDs. A `426` WebSocket error, idle dashboard/prompt, authentication failure, or quota error is **not** a started investigation. Close only that owned failed process tree, and do not count it toward completed investigations. Preserve output or a resumable session ID so completion and final reports can be checked later. Do not leave ten unverified terminals idle.

- Use the user's requested concurrency. When unspecified, cap the swarm at 10 simultaneous workers. Respect any separate repository extraction/build limits; a worker count does not increase those limits.
- For a small model such as Luna, give each worker one narrow target and a compact evidence-led brief. Keep non-negotiable safety constraints and report format; omit repeated background prose and unrelated provider history. Do not assume high reasoning effort removes context or tool-use limits.
- Have each worker identify the likely cause and recommend one code-level fix that addresses it and helps prevent recurrence. Use enough evidence to separate verified facts from guesses. If the cause is still unclear, state the quickest check that would settle it. Avoid generic mitigations presented as fixes and speculative redesigns.
- If no model or effort is specified, inherit the coordinating session's choices. Do not silently substitute another explicitly requested model.
- Scope live requests to the target's authorized diagnostics, API, redirect, and media hosts. Preserve any parent host allowlist. Pass needed read-only credentials through transient environment variables; never save them in launch scripts, prompts, status files, fixtures, or reports, and never dump the environment.
- Start workers concurrently when useful, retain each terminal/session identifier, and maintain a clear task-to-session mapping.
- If the user says to stop after launch, report what is running and end the turn without polling.

Every worker brief must state:

- its single investigation target and relevant evidence;
- the project root and applicable repository instructions;
- whether live network or production diagnostics are needed, and the specific hosts and read-only requests allowed for this target;
- its capability preflight commands and status path, authorized edit paths or diagnosis-only boundary, focused tests/build commands, and shared-runtime owner;
- no implementation edits in diagnosis-only mode; no commits, pushes, deployment, cleanup, or unrelated state changes unless separately authorized;
- no child agents, subagents, delegation, or background model processes;
- the likely cause with supporting evidence and uncertainty, exact patch locations and steps, and overlap with other targets when relevant;

Ask for a concise, decision-first report: cause, supporting evidence, best fix, and any blocker. Keep only detail needed to apply the fix.

Do not put secrets in the final worker report. Passing a user-authorized read-only credential to a worker is allowed only when that worker needs it; instruct the worker not to print it.

## Provider investigation contract

For provider/resolver workers, include these rules in the brief, even for a small model:

- Run the repository coordinator first when requested. Map player/diagnostic aliases to installed rows and implementation families before interpreting an empty result; do not silently enable a disabled row or substitute another provider.
- **Zero recent events is not a stopping condition.** The coordinator may select audit work only from incident events. An empty bundle, alias mismatch, missing trace fields, or an audit with zero rows must trigger a separate bounded live title/input matrix using the installed extractor and media validation path. Include the user's failing seed and at least five distinct titles spanning every supported media type, or the stronger repository requirement. Record selected row, failed phase, extraction candidates, validation/recovery attempt, and final availability for every case. Missing telemetry means unknown recovery, not success or an upstream blocker.
- Distinguish extractor failure, local serialization/probe failure, upstream HTTP rejection, and legitimate title absence. A missing symbol causing local HTTP 502 is a **shared code defect** even if live extraction succeeds. Reproduce it, identify the file/symbol and focused regression, and route it to the named owner. Continue independent cases that the defect does not block. If family workers cannot edit shared files, the coordinator owns the authorized fix; ownership is not an external blocker.
- Classify verified HTTP 429/backoff as upstream rate limiting and verified no-source responses as catalogue misses. Do not force code changes without evidence or bypass provider ownership, access controls, or rate limits. Report a launch blocker separately from the provider result; an unrun test is not a passing test.
- A repair requires a sanitized contract fixture, focused regression tests, relevant shared regressions, TypeScript/build when required, and the title matrix. Validate the same installed pack and changed contract; never include credentials or raw production responses. Keep discovery/recovery bounded and honor the repository's aggregate concurrency limit.

Use concrete report outcomes such as `launch-blocked`, `shared-code-defect`, `provider-code-defect`, `upstream-limited`, `catalogue-miss`, `verified-working`, or `unreproduced`, with the evidence and remaining action. Avoid an undifferentiated "externally blocked" result that hides local launch or code failures.

## Resume and synthesize

When the user returns, poll the retained terminal sessions rather than starting duplicate investigations. Replace a failed worker only when doing so stays within the concurrency cap and requested scope.

Review reports as evidence, not authority:

1. Confirm claimed files, symbols, diagnostics, and reproduction paths in the repository.
2. Merge duplicate root causes and surface disagreements.
3. Distinguish code defects from upstream outages, stale telemetry, environment failures, and title/input-specific absence.
4. Identify the best durable fix for each confirmed cause, addressing shared causes before leaf symptoms. Route shared defects to their named owner rather than leaving all family workers blocked. Fix launch configuration failures before trusting live results or test claims. If evidence is insufficient, gather the smallest useful missing evidence before changing code.
5. When the parent task authorizes implementation, apply all supported in-scope fixes, preserve unrelated work, and validate the result. Do not stop at worker reports or a patch plan and wait for a new request. For provider/resolver work, cover at least five distinct titles or inputs across every supported media/input type where practical.
6. When the parent task is diagnosis-only, return the concrete fixes and remaining evidence gaps without editing the codebase.

Be explicit about what was directly verified, what remains inferred, and what still requires post-fix validation. Do not present a plausible mitigation as a confirmed root-cause fix.
