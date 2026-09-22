# PIM subagents implementation plan

## Current implementation state

Phase 1 has been implemented in commit `7516ac3` — `feat(subagents): add backend execution and storage`. Phase 2 has been implemented. Phase 3 has been implemented in the current working tree. Targeted stopping, acknowledged automatic steering, and parent-session-aware cleanup are now available.

| Phase | State |
| --- | --- |
| 1 — backend execution and storage | Implemented and committed; automated verification passed. Live-provider manual checks remain pending. |
| 2 — PIM rendering and inspection | Implemented; automated verification passed. Live-provider manual checks remain pending. |
| 3 — stopping and cleanup | Implemented; automated verification passed. Live-provider manual checks remain pending. |

The last full `mise run verify` passed with 377 Lua tests and 19 TypeScript tests. Strict type checks, lint checks, formatting checks, and the health-check task also passed. Real Pi 0.85.1 loading and unavailable-child-tool rejection were tested without live provider calls.

Compact rendering, invocation discovery, transcript inspectors, `:PiAgentStop[!]`, and `:PiAgentClean[!]` have been added. Cleanup is explicit; no automatic transcript deletion is performed. Execution is stopped after implementation and verification. No commit has been created.

## Purpose

Agent-driven subagents are being added to PIM. Backend execution and storage have been implemented. PIM rendering, inspection, targeted stopping, and cleanup remain planned.

Each subagent will be defined dynamically by the calling agent. Named role definitions such as `scout`, `worker`, or `reviewer` will not be used. No bundled agents or filesystem-based agent definitions will be provided.

A small native Pi extension will be bundled with PIM for the work that must occur inside Pi. The feature will only function when Pi is being driven by PIM.

## Current project context

The Neovim client is written in Lua without plugin dependencies. The bundled TypeScript backend is executed by Pi.

Pi 0.85.1 or newer is required, including when subagents are disabled. The Pi API development dependencies are pinned to 0.85.1, and compatibility is tested against that version.

Relevant existing modules include:

- `lua/pim/init.lua` — lifecycle entry points.
- `lua/pim/config.lua` — validated user configuration.
- `lua/pim/rpc/client.lua` — RPC command and event routing.
- `lua/pim/rpc/process.lua` — Pi process creation and termination.
- `lua/pim/events.lua` — message and tool event handling.
- `lua/pim/render/tool.lua` — generic tool-call and result rendering.
- `lua/pim/ui/pickers.lua` — existing picker patterns.
- `lua/pim/ui/transcript.lua` — the main transcript model.
- `lua/pim/types.lua` — Lua language-server annotations.
- `plugin/pim.lua` — user command registration.
- `tests/fake_pi.lua` — RPC behavior used by the headless tests.

The existing RPC stream already supplies `tool_execution_start`, `tool_execution_update`, and `tool_execution_end`. Partial and final custom-tool details are therefore available to PIM. Native Pi TUI renderers are not available over RPC and must not be used for this feature.

Pi extension commands are checked before normal prompts. They can be executed while an agent is streaming. This behavior will be used for targeted child cancellation without aborting the parent agent.

## Architecture decision

The feature will be owned by PIM.

A bundled native Pi extension will be used as a backend adapter. It will be loaded automatically when subagents are enabled. No native Pi TUI support will be provided.

The implemented layout is:

```text
pim/
├── lua/pim/subagents/
│   └── init.lua
├── pi-extensions/
│   ├── subagents/
│   │   ├── index.ts
│   │   ├── backend.ts
│   │   ├── child-policy.ts
│   │   ├── protocol.ts
│   │   ├── runner.ts
│   │   └── transcript-store.ts
│   ├── tests/subagents/
│   ├── scripts/check-node.mjs
│   ├── .oxfmtrc.json
│   ├── .oxlintrc.json
│   ├── mise.toml
│   ├── package.json
│   ├── pnpm-lock.yaml
│   ├── pnpm-workspace.yaml
│   └── tsconfig.json
├── tests/
│   ├── health_spec.lua
│   ├── subagents_spec.lua
│   └── fixtures/subagents/
└── mise.toml
```

All TypeScript package configuration, dependencies, scripts, and tests are contained in `pi-extensions/`. No TypeScript package or Oxfmt config is kept at the repository root. Oxfmt is restricted to the backend package. Shared JSON fixtures remain in `tests/fixtures/subagents/` and are not formatted by Oxfmt.

Lua state, rendering, inspector, picker, and cleanup modules are still planned for the remaining phases. Focused modules should be retained.

### Implemented development tooling

- Node.js `24.21.0` (the selected latest LTS release) and pnpm `12.4.2` are pinned in `pi-extensions/mise.toml`.
- Node.js `24.21.0` or a newer `24.x` release is required by the backend development commands. Other major versions are rejected by the Node version guard.
- Strict checking is provided by `tsgo` from `@typescript/native-preview`, pinned to `7.0.0-dev.20260707.2`. TypeScript `7.0.2` is included for editor support.
- Oxlint `1.83.0` and Oxfmt `0.68.0` are pinned for linting and formatting. Lint warnings are rejected.
- Backend checks are delegated by the root `mise` tasks. Lua checking and formatting are retained.

Setup and validation are run from the repository root:

```sh
mise install
mise -C pi-extensions install
mise -C pi-extensions exec -- pnpm install --frozen-lockfile
mise run verify
```

Backend-only checks and formatting are available through:

```sh
mise -C pi-extensions run verify
mise -C pi-extensions run fmt
```

No development toolchain installation or compilation is required for PIM users. Runtime imports are supplied by Pi.

### Native extension responsibilities

The TypeScript extension will own:

- Registration of the LLM-callable `subagent` tool.
- Validation of dynamic child definitions.
- Child Pi process creation and termination.
- Single and parallel execution.
- Model, thinking-level, tool, prompt, and context configuration.
- Structured child event capture.
- Durable transcript-file writing.
- Output truncation and usage accounting.
- Active child-process registration for targeted stops.
- Compact, parent-facing tool content and structured details.

### PIM responsibilities

The Lua code will own:

- Bundled extension activation.
- PIM-only host identification.
- Compact rendering in the main transcript.
- Active and historical invocation indexing.
- Invocation selection.
- Dedicated transcript inspector buffers.
- User stop commands.
- Automatic steering after a user stop.
- Parent-session-aware transcript cleanup.

### PIM-only enforcement

The extension path will only be added by PIM. The spawned Pi process will also receive a private host marker such as:

```text
PIM_HOST=1
```

The extension will fail closed unless that marker is present. Tool activation will also be restricted to RPC mode. If mode cannot be checked safely during the extension factory call, registration should be deferred until `session_start`, where `ctx.mode` is available.

Child Pi processes must not inherit an active PIM subagent backend accidentally. The backend entry point (`index.ts`) is loaded only in the outer Pi process. Private PIM host and parent-session environment values are removed from child environments. The `subagent` tool is explicitly excluded from every child tool set.

A separate bundled guard (`child-policy.ts`) is explicitly loaded in every child, including isolated children. No subagent tool is registered by this guard. Requested tool availability and exact model resolution are checked before a provider request. The requested active tool set is applied, and calls to excluded tools are blocked.

## Activation and configuration

Subagents will be enabled by default. An opt-out will be provided:

```lua
require("pim").setup({
  subagents = {
    enabled = false,
  },
})
```

The implemented public settings are `subagents.enabled` and `subagents.orphan_grace_days` (default: `30`). The following limits are currently fixed in the backend:

- Maximum agents per invocation: `8`.
- Maximum concurrent child processes: `4`, shared across invocations in the extension instance.
- Graceful stop timeout before `SIGKILL`: `5000` milliseconds.
- Aggregate parent-visible text cap: `50 KiB` and `2000` lines. A `48 KiB` budget is divided among child outputs before the aggregate cap is applied.
- Per-child summary cap in result details: `1024` bytes.

Strict nested configuration validation has been extended. Unknown nested keys are reported with their full paths.

Cleanup is explicit and parent-session-aware. The orphan grace period starts when a missing parent file is first observed during cleanup. The observation is stored in a private `orphaned.json` file. Nonnegative whole days are accepted. Active, unsafe, and ambiguous records are retained even with force cleanup.

When subagents are disabled:

- No bundled extension argument should be added.
- No PIM host marker is needed for this feature.
- Subagent commands may either be omitted or return a clear disabled message.
- Existing PIM behavior must remain unchanged.

## Dynamic tool contract

One array will be used for both single and parallel execution:

```json
{
	"agents": [
		{
			"label": "parser review",
			"prompt": "Review the parser changes.",
			"systemPrompt": "Report concrete correctness defects.",
			"systemPromptMode": "append",
			"context": "Nested expressions were recently added.",
			"projectContext": true,
			"tools": ["read", "grep", "find", "ls"],
			"model": "anthropic/claude-sonnet-4-6",
			"thinkingLevel": "high",
			"cwd": "/project"
		}
	]
}
```

### Field rules

- `agents` will contain between one and eight entries.
- One entry will be treated as single execution.
- More than one entry will be treated as parallel execution.
- `label` will be required and will only be used for display and identification.
- `prompt` will be required and will become the child user prompt.
- `tools` will be required. An empty array may be accepted for a tool-free child.
- `model` will be required as an explicit provider/model identifier.
- `thinkingLevel` will be required explicitly.
- `systemPrompt` will be optional.
- `systemPromptMode` will be `append` or `replace` and will default to `append`.
- `context` will be optional additional caller-supplied text. It should be clearly separated from the task in the child prompt.
- `projectContext` will be optional and will default to `true`.
- `cwd` will be optional and will default to the parent working directory.

No model, thinking level, or tools will be inherited implicitly from the parent. Parent conversation history will never be inherited.

No behavior will be inferred from labels. A label such as `reviewer` will have no special meaning.

### System prompt behavior

In `append` mode, caller-supplied instructions will be appended to Pi's standard child system prompt.

In `replace` mode, Pi's standard system prompt will be replaced by the caller-supplied system prompt. Enabled project context may still be added according to Pi's normal command-line behavior. Empty replacement prompts should be rejected.

Task text and optional caller context are supplied through standard input rather than process arguments. Caller context is encoded as a JSON string and separated from the task. System prompts are supplied through private temporary files. Temporary directories use `0700`, files use `0600`, and removal is performed in `finally` cleanup.

### Project context behavior

When `projectContext` is true:

- Normal Pi project context may be loaded.
- Project resources must only be enabled when the parent project is trusted.
- The child should receive the same effective working directory unless `cwd` is supplied.
- `--approve` is supplied only when the parent is trusted and the canonical child working directory is unchanged. Otherwise, `--no-approve` is supplied. Trust is not transferred to a different `cwd`.

When `projectContext` is false:

- Context-file discovery must be disabled.
- Extension discovery must be disabled.
- Skill discovery must be disabled.
- Prompt-template discovery must be disabled.
- No parent conversation content may be supplied.

Pi settings required for model and credential resolution may still be used. The private child policy guard is explicitly loaded even when discovery is disabled. These controls are not an operating-system sandbox.

## Execution policy

### Single execution

A single child may receive any explicit tool names accepted by Pi. Unknown or unavailable tools should produce a clear child configuration failure.

### Parallel execution

The first release will permit only the known read-only built-in tools:

```text
read, grep, find, ls
```

Every parallel child's tool list must be validated against this allowlist before any child is started. `bash`, `edit`, `write`, and unknown extension tools must be rejected in parallel mode.

This restriction is required because separate Pi processes do not share Pi's in-process file mutation queue. Extension discovery is also disabled for parallel children so the read-only built-ins cannot be replaced by discovered extensions. The private child policy guard is still explicitly loaded.

Unrestricted parallel tools are deferred. They may later be added as an explicit unsafe mode.

### Child process behavior

Child processes should be started in Pi JSON mode with no child session persistence. Each child should receive:

- The explicit model.
- The explicit thinking level.
- The explicit tool allowlist.
- The selected system-prompt mode.
- The selected project-context mode.
- The selected working directory.
- One initial user prompt containing clearly delimited optional context and the required task.

Strict LF-delimited JSONL parsing must be used. Generic line readers that split Unicode separators must not be introduced.

Abort signals from the parent tool must terminate all associated child processes. A graceful termination should be attempted before forced termination. Process listeners, timers, and temporary files must always be released.

## Parent-facing result contract

A versioned details object should be returned in partial and final tool results:

```json
{
	"schemaVersion": 1,
	"invocationId": "...",
	"mode": "single",
	"status": "running",
	"transcriptDir": "...",
	"agents": [
		{
			"id": "...",
			"label": "parser review",
			"status": "running",
			"transcriptPath": "...",
			"summary": null,
			"usage": null,
			"stoppedBy": null
		}
	]
}
```

Expected child statuses include:

- `pending`
- `running`
- `completed`
- `failed`
- `stopped`
- `aborted`

Expected `stoppedBy` values include:

- `user`
- `parent_abort`
- `null`

User stops are recorded as `stopped` with `stoppedBy: "user"`. Parent cancellation is recorded as `aborted` with `stoppedBy: "parent_abort"`. Acknowledgement is sent after child termination and transcript persistence. One RPC steering message is queued by PIM for newly stopped children only.

The final assistant text from each successful child will be returned to the parent model. Failure diagnostics will be returned for failed children. Parent-visible text must be bounded and must state when content was truncated. Full event history will remain in dedicated transcript files.

Nested child usage must be returned through the tool result's `usage` field so Pi's session totals remain accurate.

A controlled user stop should not be represented as an extension crash. A result with `status: "stopped"` and `stoppedBy: "user"` should be returned instead.

## Transcript persistence

Structured JSONL files will be stored under a PIM data directory such as:

```text
~/.local/share/nvim/pim/subagents/<parent-session-id>/<invocation-id>/
```

`stdpath("data")` semantics should be mirrored or communicated explicitly between Lua and TypeScript. The resolved root path is passed through `PIM_SUBAGENT_ROOT` to avoid platform-specific path disagreement.

A suggested layout is:

```text
<invocation-id>/
├── invocation.json
├── <child-id>.jsonl
└── <child-id>.summary.json
```

One JSONL file is written per child. The invocation manifest includes the parent session ID, parent session file, tool call ID, timestamps, child files, and current statuses.

Each child JSONL line is an envelope with `timestamp` and `record` fields. Child Pi events and backend records such as `configuration`, `status`, `stderr`, and `final` are stored under `record`. Malformed and incomplete child output is recorded separately. Readers for Phase 2 must unwrap this envelope and retain incomplete final lines until more bytes are available.

`readRecords()` currently returns complete records, a malformed-line count, and a pending final fragment. An incremental on-disk inspector reader has not yet been implemented. Shared parameter and result fixtures are available in `tests/fixtures/subagents/` and are validated by the TypeScript tests.

Stored records should include:

- Invocation and child metadata.
- Child message events.
- Thinking events.
- Child tool calls and results.
- Status transitions.
- Usage updates.
- Stop metadata.
- Final output.

Directories should use mode `0700`. Files should use mode `0600`. Symlink traversal and unsafe identifiers must be prevented.

Writes should remain readable after interruption. JSONL append operations are preferred for events. Manifest replacement should be atomic where practical.

Large child events must not be copied into parent RPC details. This avoids PIM's maximum RPC-line limit and prevents parent session growth.

## Main transcript behavior

The parent `subagent` tool call will remain in the normal PIM transcript. Only compact aggregate information will be shown there.

Example:

```text
▸ tool(subagent): 2 agents
▸ result(subagent): 1 completed, 1 running
```

Child assistant messages, nested tool calls, and nested tool results will not be embedded in the main transcript.

A subagent-specific branch should be added to the tool renderer. Generic rendering must remain available for malformed details and unsupported schema versions.

Historical parent tool results must rebuild enough invocation metadata for their dedicated transcripts to be reopened.

## Inspector behavior

One read-only buffer will be created per invocation:

```text
pim://subagents/<invocation-id>
```

Parallel children will be grouped in that buffer as separate foldable sections. The buffer should show:

- Child label and current status.
- Prompt configuration summary.
- Assistant text.
- Thinking content, following PIM's existing thinking display conventions where practical.
- Nested tool calls.
- Nested tool results.
- Errors and stop reasons.
- Per-child usage.
- Aggregate usage.

The inspector will be opened on demand. It must not be opened automatically.

Open inspector buffers should be refreshed when matching parent `tool_execution_update` events arrive. The parent update can be used as a revision notification, after which new JSONL records can be read from disk. Full files should not be reparsed on every small update if a stable byte offset or record cursor can be retained.

Completed invocation buffers must remain inspectable after Pi or Neovim restarts.

## User commands

The following commands are planned:

- `:PiAgents` — list invocations associated with the current parent session.
- `:PiAgents!` — include retained historical invocations.
- `:PiAgentTranscript` — select and open an invocation transcript.
- `:PiAgentStop` — select one running child to stop.
- `:PiAgentStop!` — stop all running children in a selected invocation.
- `:PiAgentClean` — remove eligible orphaned transcript directories.
- `:PiAgentClean!` — remove all orphaned transcript directories immediately.

Direct user-driven child execution will not be provided. All child creation will remain agent-driven through the `subagent` tool.

## User stop and automatic steering

The existing PIM abort path must not be reused for targeted child stops. RPC `abort` would stop the entire parent run.

A private extension command will be registered. A name clearly reserved for PIM internals should be used. Its handler will locate active child processes by invocation and child ID and terminate the requested process or processes.

The stop flow will be:

1. A running child or invocation will be selected in PIM.
2. The private extension command will be sent through the existing RPC `prompt` command.
3. The extension command will execute immediately while the parent is streaming.
4. `SIGTERM` will be sent to the selected child process.
5. `SIGKILL` will be sent after the configured timeout if termination has not completed.
6. The child transcript and parent tool details will record `status: "stopped"` and `stoppedBy: "user"`.
7. After stop acknowledgement, PIM will send a normal RPC steering message.

The automatic steering text will follow this form:

```text
The user stopped subagent "<label>". Reassess the task and continue without relying on its completion.
```

For a stop-all operation, one aggregate steering message should be preferred over one message per child.

The steering message will be delivered according to Pi's normal steering semantics after the current parent turn finishes its tool calls. The stopped tool result and the steering message will therefore both be visible to the parent agent.

Repeated, late, or already-completed stop requests must be idempotent. A parent abort must be distinguished from a user stop and must not enqueue automatic steering.

## Invocation discovery and cleanup

`:PiAgents` will represent dynamic invocations, not reusable agent definitions.

Current-session invocation metadata should be sourced from live state and historical parent tool results. Retained historical metadata may be sourced from valid invocation manifests.

Transcript cleanup will be parent-session-aware:

- Transcript directories will be retained while their parent Pi session file exists.
- Missing parent session files will mark transcript directories as orphaned.
- Orphans will be retained for a configurable grace period.
- `:PiAgentClean` will report and remove eligible orphans.
- `:PiAgentClean!` will bypass the grace period for orphans.
- Active invocation directories must never be removed.
- Invalid or ambiguous manifests should be reported and skipped rather than deleted silently.

No cleanup should be performed merely because a session is not currently open.

## Implementation phases

Implementation will be completed in three phases. Each phase is intended to form one focused commit. Tests, documentation, and relevant health checks must be completed in the same phase as the behavior they cover; they must not be deferred to a final integration phase. After each phase is implemented, execution must stop. The listed validation must be run, and a short conventional commit message with a bulleted body must be provided to the user. The next phase must not begin until confirmation is received.

### Phase 1: backend execution and storage — implemented

All work in this phase was included in commit `7516ac3`. TypeScript tooling setup and its relocation into `pi-extensions/` were included in the same commit.

#### Activation and configuration — implemented

- `subagents.enabled = true` was added with strict nested validation.
- Process environment support was added to `lua/pim/rpc/process.lua`.
- The bundled backend is resolved through Neovim's runtime path. Its extension argument is added only when enabled.
- `PIM_HOST=1` and `PIM_SUBAGENT_ROOT` are supplied to the outer Pi process.
- Backend registration is deferred until `session_start` and restricted to PIM RPC mode.
- Missing bundles are reported before process creation. No backend arguments or host environment are added when disabled.
- Pi 0.85.1 is required regardless of the enabled setting. Bundle, storage, and version health checks were added.
- Activation, configuration, storage, trust, inputs, limits, and development commands were documented in README and `doc/pim.txt`.

Enabled, disabled, missing-extension, environment, command-construction, and health-check behavior are covered by automated tests.

#### Protocol and transcript store — implemented

- Strict tool parameters and schema-version-1 result details were defined.
- Safe child and invocation identifiers are generated. Unsafe identifiers and symlink storage paths are rejected.
- Directories use `0700`; files use `0600`.
- Child event envelopes are appended as LF-delimited JSONL. Manifests and summary files are replaced atomically.
- Output truncation is bounded by bytes and lines, with an explicit truncation notice.
- Complete records can be read despite malformed lines or an incomplete final record.
- Shared parameter and result fixtures were added for later Lua integration.

Schema validation, path safety, permissions, JSONL framing, manifest replacement, truncation, and interrupted records are covered by automated tests. The fixtures are checked against the protocol.

#### Single-agent execution — implemented

- One dynamic child definition is accepted without parent conversation history.
- Children are run in Pi JSON mode without child session persistence.
- Explicit model, thinking level, and tools are required. Model resolution and available tools are checked by the private child guard. Thinking levels may be clamped by Pi for the selected model.
- Tool-free execution, append and replace system prompts, caller context, and working-directory selection are supported.
- Task text is supplied through standard input. System prompts are supplied through private temporary files and removed afterward.
- Trust is transferred only to the same canonical directory. Context isolation flags are supplied when requested.
- Events, final output, errors, usage, and bounded structured details are persisted or returned as appropriate.
- Parent abort and session shutdown are handled. Graceful termination is followed by forced termination after the timeout. Cleanup is awaited on session shutdown.

Argument construction, prompt modes, trust, isolation, tool-free execution, unavailable tools, completion, provider failure, malformed output, truncation, and parent abort are covered by automated tests. Successful output and provider failures are simulated; live-provider manual checks remain pending.

#### Parallel read-only execution — implemented

- Two to eight definitions are accepted through the same array contract.
- At most four child processes are run across all invocations in the extension instance.
- Every parallel tool list is checked against `read`, `grep`, `find`, and `ls` before storage or execution begins.
- Extension discovery is disabled for parallel children to prevent built-in tool overrides.
- Per-child updates contain bounded metadata rather than transcript history.
- Final results are returned in input order. Unrelated children are not stopped by one child's failure.
- Aggregate output and nested usage are returned. Parent abort also prevents queued children from being started.

Concurrency limits, preflight rejection, mixed results, ordering, aggregate truncation, and abort escalation are covered by automated tests.

#### Development tooling — implemented

- All TypeScript configuration, dependencies, scripts, and tests were moved into `pi-extensions/`.
- Node.js 24 LTS and pnpm are pinned in the package-local `mise.toml`.
- Strict `tsgo` checking, Oxlint linting, and Oxfmt formatting were added to root verification through delegated package tasks.
- Formatting is restricted to the backend package. Shared fixtures and repository-root files are not formatted by Oxfmt.
- Type errors, lint violations, formatting differences, and unsupported development Node versions were confirmed to be rejected.

#### Phase 1 verification state

The last recorded full verification passed:

- 360 Lua tests.
- 14 TypeScript tests.
- Lua formatting and language-server checks.
- Strict `tsgo` checks, Oxlint, and Oxfmt checks.
- The `:checkhealth pim` task.
- Real Pi 0.85.1 extension loading and child-policy rejection tests without live provider calls.
- Frozen-lockfile dependency installation and Git whitespace checks.

Validation commands from the repository root:

```sh
mise run fmt:check
mise run lint
mise run typecheck
mise run test
mise -C pi-extensions run test
mise run verify
```

The following manual checks are still pending and must not be treated as passed:

- A completed single child through a live provider in PIM.
- Two parallel read-only children through a live provider in PIM.
- Parent abort during a live child run.
- Persisted transcripts from those live runs.
- Disabled-feature behavior in an interactive Neovim session.

No Phase 2 or Phase 3 implementation was included in this commit.

### Phase 2: PIM rendering and inspection — implemented

#### Invocation state and compact main rendering

- Lua protocol and state annotations were added.
- Invocations are indexed by parent tool-call and invocation IDs.
- Partial, final, and historical details update or restore the index.
- Valid subagent calls and results use compact count and status rendering.
- Malformed details and unsupported schema versions retain generic rendering.
- Session history replacement resets and rebuilds the invocation index.

#### Invocation picker and transcript inspector

- `:PiAgents[!]` and `:PiAgentTranscript` were registered.
- Current-session state and retained manifests are discovered separately.
- One read-only `pim://subagents/<invocation-id>` buffer is reused per invocation.
- Child JSONL records are rendered in separate foldable sections.
- Open inspectors refresh incrementally from retained byte offsets.
- Completed transcript files can be reopened after restart.
- Incomplete final lines are retained. Malformed records and missing or unsafe paths are surfaced without blocking later records.

#### Phase 2 completion

Automated tests cover compact and fallback rendering, live and historical state, current and retained discovery, command routing, parallel inspector sections, buffer reuse, incremental reads, incomplete lines, and malformed records. README and `doc/pim.txt` document the commands and inspection behavior.

The full `mise run verify` passed with 366 Lua tests and 14 TypeScript tests. Manual checks with live providers, live inspector updates, restart reopening, and missing files remain pending.

### Phase 3: stopping and cleanup — implemented

#### Targeted stop and steering

User-controlled child termination will be added.

Planned work:

- Active process handles will be indexed by invocation and child IDs.
- A private extension stop command will be registered.
- `:PiAgentStop[!]` will be added.
- Individual and aggregate stops will be supported.
- Graceful and forced termination will be implemented.
- User stops will be persisted and returned to the parent as controlled results.
- One automatic steering message will be queued after acknowledgement.
- Parent aborts will remain distinct and will not steer.

Validation should cover one-child stop, one child within a parallel invocation, stop-all, `SIGKILL` escalation, duplicate requests, races with natural completion, automatic steering, and parent-abort distinction.

#### Parent-session-aware cleanup

The feature lifecycle will be completed.

Planned work:

- Parent-session-aware orphan detection will be added.
- `:PiAgentClean[!]`, grace-period cleanup, and force cleanup will be added.
- Active invocations and invalid or ambiguous manifests will be protected.

Validation should cover parent-session retention, orphan detection, grace periods, force cleanup, active invocation protection, invalid or ambiguous manifests, and unsafe paths.

#### Phase 3 completion

Targeted stops are registered through the private `pim-internal-agent-stop` command. Child cancellation controllers are indexed by invocation and child IDs. Active and queued children can be stopped independently. Graceful termination is followed by forced termination when needed. A token-correlated acknowledgement is sent through the RPC extension status channel; one normal RPC steering message is then queued by PIM. Duplicate, completed, failed, timed-out, parent-aborted, and stale-session requests do not cause steering.

Cleanup is exposed through `:PiAgentClean[!]`. Existing parent sessions are retained. The configured grace period starts at the first observed orphan state. Active records, interrupted running records, unsafe paths, unexpected files, and invalid or ambiguous manifests are protected. No additional health check is required beyond the existing storage and bundle checks.

Automated verification passed with 377 Lua tests and 19 TypeScript tests, including real Pi command loading and no-op acknowledgement without a provider call. Manual live-provider checks below remain pending.

Automated tests for targeted stopping, steering, and cleanup must be included in this phase. README and `doc/pim.txt` documentation will cover `:PiAgentStop[!]`, `:PiAgentClean[!]`, stop acknowledgement, automatic steering, retention, cleanup settings, and safety limits. Any health checks required by stopping or cleanup will be added in this phase.

Required verification:

```sh
mise run verify
```

Manual validation should include targeted cancellation, stop-all steering, parent-abort distinction, and orphan cleanup after parent-session removal. The single-child, parallel-child, live inspection, and historical reopening checks from earlier phases should also be repeated as regression checks.

## Deferred work

The following work is explicitly excluded from the first implementation:

- Unrestricted parallel mutation.
- Git worktree isolation.
- Chained child workflows.
- Reusable role definitions.
- Filesystem agent-definition directories.
- Bundled agents.
- Native Pi TUI rendering.
- Direct user-driven child execution.
- Parent conversation inheritance.
- Nested subagents.
- Automatic opening of inspector buffers.

Unrestricted parallel tools may later be provided as an explicit unsafe mode. They must not silently replace the initial read-only policy.

## Completion criteria

The feature will be considered complete when:

- A calling agent can define and run one explicit child.
- A calling agent can define and run multiple read-only children in parallel.
- Child transcripts can be inspected live in a separate buffer.
- The main transcript remains compact.
- Completed transcripts remain inspectable after restart.
- One child or all children can be stopped without aborting the parent.
- A user stop is visible to the parent as both a controlled tool result and automatic steering.
- Transcript files are retained with their parent session and safely cleaned after becoming orphaned.
- The feature can be disabled without changing existing PIM behavior.
- All Lua and TypeScript verification tasks pass.
