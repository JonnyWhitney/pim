# pim

Use pi from Neovim. pim starts pi in RPC mode and shows the conversation
in a Markdown buffer. Write prompts in a Neovim buffer.

The Neovim client is written in Lua and has no plugin dependencies. A bundled
TypeScript subagent backend is executed by Pi. Neovim nightly, Markdown
Treesitter, and the Pi RPC interface are supported.

## Requirements

- Neovim nightly. Other Neovim releases are not supported.
- Pi 0.85.1 or newer. The backend is tested against Pi 0.85.1.
  `pi` must be on `$PATH` or set through `pi_cmd`.

## Install

For lazy.nvim:

```lua
{
  "JonnyWhitney/pim",
  cmd = {
    "PiStart",
    "PiToggle",
    "PiResume",
    "PiTree",
    "PiTrust",
    "PiFork",
    "PiClone",
    "PiModel",
    "PiThinking",
    "PiAgents",
    "PiAgentTranscript",
    "PiAgentStop",
    "PiAgentClean",
    "PiLog",
  },
  -- opts = { ... }, -- See Configuration. setup() is optional.
}
```

## Start pi

Run `:PiStart` to open the UI and start pi. The transcript is above the input
buffer. pim puts the cursor in the input buffer in Normal mode.

To start Neovim in the pi UI, add this alias:

```sh
alias pim='nvim -c PiStart'
```

pim reuses an empty initial tab. If you close one pi window, `:PiStart`
restores that window. It does not create a second pi layout.

`:PiStop` asks for confirmation, then stops pi and deletes the pim windows
and buffers, including the input draft. `:PiStop!` does not ask for
confirmation. `:PiToggle` hides or shows the windows, keeps the buffers and
input draft, and does not stop pi.

The session file remains after you close the UI. `:PiStart` resumes that
session. Unsaved changes can prevent Neovim from closing, as with `:quit`.

pim stores complete tool-call arguments in the transcript as readable JSON.
Fold headers show the file path for built-in file tools and a command summary
for Bash. Edit results show a diff, write results show syntax-highlighted file
content, and Bash results keep the complete command separate from its output.
PIM can show the proposed operation while a permission dialog is open. This
preview is display-only and does not add a message to the model context.
Tool calls are folded by default, including during execution. Results, including
edit diffs, and `!` output are left open. Thinking is folded by default.
Each default can be changed through `transcript.folds`; thinking can also be
hidden. Folds can be toggled with `<Tab>` or native Neovim fold commands.
Manual choices are preserved per window during updates. Defaults are reapplied
when history is reloaded or a buffer or window is recreated.

## Commands

| Command          | Action                                                                               |
| ---------------- | ------------------------------------------------------------------------------------ |
| `:PiStart`       | Open the UI. Start pi if it is stopped.                                              |
| `:PiToggle`      | Show or hide the pi windows.                                                         |
| `:PiSend [text]` | Send text. Without text, send the input buffer.                                      |
| `:PiAbort`       | Clear queued prompts, restore them to input history, and stop the current agent run. |
| `:PiResume`      | Select a session for the current directory.                                          |
| `:PiTree`        | Browse the active session tree. Prompts are disabled while it is open.               |
| `:PiTrust`       | Manage project trust for the current working directory.                              |
| `:PiNewSession`  | Start a new session.                                                                 |
| `:PiFork`        | Fork from an earlier prompt and edit that prompt in a new session.                   |
| `:PiClone`       | Copy the active branch into a new session.                                           |
| `:PiModel`       | Select a model.                                                                      |
| `:PiThinking`    | Select a supported thinking level.                                                   |
| `:PiAgents[!]`   | Select a current-session invocation. `!` includes retained history.                  |
| `:PiAgentTranscript` | Select and open a current-session subagent transcript.                          |
| `:PiAgentStop[!]` | A child is selected and stopped. `!` stops an invocation.                            |
| `:PiAgentClean[!]` | Orphaned transcripts are cleaned. `!` bypasses the grace period.                    |
| `:PiRestart`     | Restart pi and resume the current session.                                           |
| `:PiStop[!]`     | Stop pi and close the pi windows. `!` skips confirmation.                            |
| `:PiLog`         | Open the event log. Set `debug = true` for raw JSONL traffic.                        |

### Tree explorer

`:PiTree` replaces the transcript with the active session tree and disables
prompts. Use `j` and `k` to select an entry. Use `p` to preview it, `r` to
fork a selected user prompt, and `c` to clone the active branch. In a preview,
`q` returns to the tree. In the tree, `<CR>` or `q` restores the transcript.
Branch-summary and compaction entries are hidden. Their visible descendants
are shown under the nearest visible ancestor. Summary content is omitted from
previews and transcripts. Saved sessions and internal tree links are preserved.

pim blocks new, switch, fork, and clone session actions while Pi is streaming,
compacting, running Bash, or retrying. An agent run remains busy until Pi sends
`agent_settled`, including queued continuations.

### Project trust

`:PiTrust` works when pi is running or stopped. It manages trust for Neovim's
current working directory. The picker resolves symlinks and shows the saved
decision. A decision from an ancestor directory is shown as inherited.

The picker has these choices:

- **Trust** saves trust for the current directory.
- **Trust parent folder** saves trust for its immediate parent and removes a
  direct decision for the current directory.
- **Do not trust** saves a rejection for the current directory.

pim reads and writes `$PI_CODING_AGENT_DIR/trust.json`. It uses
`~/.pi/agent/trust.json` when the environment variable is not set. It refuses
to overwrite invalid trust data. If pi is running, use `:PiRestart` after you
save a decision. The running process does not reload trust data.

## Subagents

Subagents are created by the calling model through the `subagent` tool. No named
roles or agent-definition files are loaded. Activation is automatic in PIM RPC
mode only. No native Pi terminal interface is provided. Activation can be disabled:

```lua
require("pim").setup({ subagents = { enabled = false } })
```

When disabled, no backend argument or private host environment is added. A missing
bundle is reported at startup and by `:checkhealth pim`. No package installation
or TypeScript compilation is required for users; imports are supplied by Pi.

One `agents` array is used for single and parallel execution:

```json
{
	"agents": [
		{
			"label": "parser review",
			"prompt": "Review the parser changes.",
			"tools": ["read", "grep", "find", "ls"],
			"model": "anthropic/claude-sonnet-4-6",
			"thinkingLevel": "high"
		}
	]
}
```

`label`, `prompt`, `tools`, `model` (exact provider/model), and `thinkingLevel`
are required. An empty tool list is supported. Thinking levels are `off`,
`minimal`, `low`, `medium`, `high`, `xhigh`, and `max`; levels may be clamped by Pi
for the selected model. No model, tools, thinking level, or conversation history
is inherited from the parent.

Optional fields are `systemPrompt`, `systemPromptMode` (`append` by default or
`replace`), `context`, `projectContext` (`true` by default), and `cwd` (the parent
directory by default). A nonempty prompt is required for replacement mode. Caller
context is separated from the task. Task text is supplied through standard input.
System prompts are supplied through private temporary files and removed afterward.

Project resources are approved only when the parent project is trusted and the
canonical working directory is unchanged. Trust is not transferred to another
`cwd`. With `projectContext = false`, context files, extension discovery, skills,
and prompt-template discovery are disabled. Model settings and credentials remain
available. A private child policy guard is explicitly loaded even in isolation.
These controls are not an operating-system sandbox.

Up to eight children are accepted per call. At most four child processes are run
across all calls. Parallel tools are restricted to built-in `read`, `grep`, `find`,
and `ls`; extension discovery is disabled to prevent overrides. All parallel
lists are validated before execution. A single child can use any available Pi
tool except `subagent`. Unavailable tools and unresolved models are reported as
child failures. Unrelated children are not stopped by one child's failure.

Parent abort terminates all children with SIGTERM, followed by SIGKILL after
5000 ms if needed. Child results and nested usage are returned in input order.
Parent output is capped at 50 KiB and 2000 lines in aggregate, with a smaller
per-child share for parallel calls. Truncation is marked. Details contain only
bounded summaries and transcript references, not child event history.

Full events, thinking, tool calls, usage, configuration, and final output are
stored under `stdpath("data")/pim/subagents/<parent-session-id>/<invocation-id>/`.
Each invocation contains `invocation.json`, `<child-id>.jsonl`, and
`<child-id>.summary.json`. Directories are private (`0700`), and files are private
(`0600`). Symlink storage paths are rejected. The manifest is replaced atomically;
complete JSONL records remain readable after interruption. These files may contain
sensitive prompts and outputs. No automatic cleanup is performed.

The main transcript shows only child counts and aggregate statuses. Use
`:PiAgents` or `:PiAgentTranscript` to select and open a read-only inspector.
`:PiAgents!` also scans retained invocations from other parent sessions. One
`pim://subagents/<invocation-id>` buffer is reused per invocation. Parallel
children are shown in separate foldable sections. Open inspectors refresh from
new JSONL records during live tool updates. Completed transcripts can be opened
after restart. Incomplete final JSONL lines are retained until completed.
Malformed records are reported and skipped, so later valid records still render.
Missing or unsafe transcript paths are shown as unavailable.

### Stopping and cleanup

- `:PiAgentStop` — one active child is selected and stopped.
- `:PiAgentStop!` — an invocation is selected; all active and queued children are stopped.
- `:PiAgentClean` — eligible orphaned transcripts are removed and counts are reported.
- `:PiAgentClean!` — the grace period is bypassed for orphaned transcripts only.

Targeted stops are sent through a private extension command, not parent abort.
`SIGTERM` is followed by `SIGKILL` after 5000 ms when needed. Stopped children
are recorded as `stopped` with `stoppedBy: "user"`. After termination and
transcript acknowledgement, one steering message is queued for the parent.
For stop-all, the stopped labels are combined in that message. Duplicate,
already-completed, failed, or unacknowledged requests are not used for steering.
Parent aborts remain `aborted` with `stoppedBy: "parent_abort"` and do not steer.

Transcripts are retained while the parent session file exists. A missing parent
file is first recorded in a private `orphaned.json` file during cleanup. The
grace period starts at that observation, not at the last child update:

```lua
require("pim").setup({ subagents = { orphan_grace_days = 30 } })
```

A nonnegative whole number of days is required; `0` removes eligible orphans
on the first cleanup. No cleanup is run automatically. Active invocations,
including stored `pending` or `running` states after an interruption, are
retained even with `!`. Invalid manifests, missing parent-file references,
symlinks, unexpected files, and ambiguous paths are reported and skipped.
Interrupted active records require manual review; activity is not inferred
from age. These checks are not a sandbox against concurrent filesystem changes.

## Keymaps

All keymaps apply only to pim buffers. You can change them in `setup()`.

| Keys                      | Buffer     | Action                                                 |
| ------------------------- | ---------- | ------------------------------------------------------ |
| `<CR><CR>` in Normal mode | Input      | Send the prompt.                                       |
| `<localleader><CR>`       | Input      | Send a follow-up after the current run ends.           |
| `<C-c>`                   | pi buffers | Stop the shell command or agent run.                   |
| `<Tab>`                   | Transcript | Toggle the fold at the cursor.                         |
| `<Up>` and `<Down>`       | Input      | Move through prompt history at the first or last line. |
| `/` at prompt start       | Input      | Complete pi slash commands.                            |
| `@` at word start         | Input      | Complete file paths.                                   |

In Insert mode, `<CR>` inserts a new line. pim does not change `Esc`.

If pi rejects a prompt, pim restores the prompt when the input is empty.
If you enter new text first, press `<Up>` to recall the rejected prompt.

When you abort an agent run, pim first clears queued steering and follow-up
prompts. It restores the first queued prompt to an empty input buffer and keeps
each queued prompt as a separate history entry. If the input has a newer draft,
pim preserves it and adds the queued prompts to history. Bash abort remains
direct and does not change the agent queue.

## Shell commands

Start a prompt with `!` to run a shell command in pi. Start it with `!!` to
exclude the command output from the next agent context.

```text
!ls -la   Run the command. Add the output to the next prompt context.
!!ls -la  Run the command. Do not add the output to the prompt context.
```

pim shows command output in a fold. `<C-c>` stops a running command. Set
`bash_passthrough = false` to send `!` and `!!` prompts to the agent unchanged.

## Configuration

`setup()` is optional. `:PiStart` uses the default settings.

```lua
require("pim").setup({
  pi_cmd = "pi", -- String or list. pim adds --mode rpc.
  args = {}, -- Additional pi command-line arguments.
  keymaps = {
    submit = "<CR><CR>",
    submit_followup = "<localleader><CR>",
    abort = "<C-c>",
    toggle_fold = "<Tab>",
  },
  input = { min_height = 3, max_height = 15 },
  streaming_submit = "steer", -- Or "followUp".
  bash_passthrough = true, -- Run prompts that start with ! or !! as shell commands.
  transcript = {
    dividers = true,
    header_highlights = { -- Or false to retain only Markdown header colors.
      user = "PimUserHeader",
      assistant = "PimAssistantHeader",
      custom = "PimCustomHeader",
    },
    folds = {
      tool_calls = "folded",
      tool_results = "open",
      thinking = "folded", -- "folded", "open", or "hidden".
      bash_output = "open",
    },
  },
  set_title = false, -- Allow extensions to set the terminal title.
  debug = false, -- Record raw RPC traffic for :PiLog.
})
```

Invalid setting values cause an error. Unknown setting keys cause a warning that includes the full key path.

### Message boundaries

Chat headers are colored by role. Divider lines are displayed on the blank
separator before chat headers, not around internal tool blocks. No divider text
is added to copied Markdown. The Markdown filetype, headings, and code fences
are retained in transcripts and tree previews.

Dividers can be disabled with `transcript.dividers = false`. Extra header colors
can be disabled with `transcript.header_highlights = false`. Ordinary Markdown
highlighting is retained in both cases.

These default highlight links are supplied without overwriting user definitions:

| Group                | Default link |
| -------------------- | ------------ |
| `PimUserHeader`      | `Identifier` |
| `PimAssistantHeader` | `Statement`  |
| `PimCustomHeader`    | `Special`    |
| `PimDivider`         | `Comment`    |

Each `header_highlights` value can be set to an existing Neovim highlight-group
name. Partial overrides are merged with the defaults. Alternatively, the pim
groups can be customized directly. For example, a user-header color can be
applied now and reapplied after colorscheme changes:

```lua
local function set_pim_colors()
  vim.api.nvim_set_hl(0, "PimUserHeader", { fg = "#7dcfff", bold = true })
end
vim.api.nvim_create_autocmd("ColorScheme", { callback = set_pim_colors })
set_pim_colors()
```

The winbar shows the pi provider, model, thinking level, configuration
directory, and context usage. Context usage has the form `ctx:12k/100k (12%)`
and refreshes after each completed assistant response. pim uses
`$PI_CODING_AGENT_DIR`. If it is unset, pim shows `~/.pi/agent`.

## Completion

Slash commands are supplied through the optional Blink provider below.
Extension commands, prompt templates, and skills are included. No completion
plugin is required to use pim. Without Blink, no Pim completion is installed.
Manually entered `@file` references are still expanded by pi on the server.

### Optional Blink integration

A Blink source is bundled with pim. No separate source plugin is needed.
The provider must be registered explicitly; installing Blink alone is not enough.

The `pim` provider is registered through ordinary Blink source options:

```lua
sources = {
  default = { "lsp", "omni", "path", "buffer", "pim" },
  providers = {
    pim = { name = "pim", module = "pim.completion.blink" },
  },
},
```

pim must be available on the runtime path when Blink is configured. With
lazy.nvim, `"JonnyWhitney/pim"` can be added to Blink's existing `dependencies`
list. Other dependencies, such as `blink.lib` for development Blink, must be kept.

Existing providers and filetype overrides are retained. For example:

```lua
sources = {
  default = { "lsp", "omni", "path", "buffer", "lazydev", "pim" },
  providers = {
    pim = { name = "pim", module = "pim.completion.blink" },
    lazydev = { name = "LazyDev", module = "lazydev.integrations.blink" },
    omni = {
      enabled = function()
        local omnifunc = vim.bo.omnifunc
        return omnifunc ~= "" and omnifunc ~= "v:lua.vim.lsp.omnifunc"
      end,
    },
  },
  per_filetype = {
    minifiles = { inherit_defaults = false },
  },
},
```

`lazydev` is included here only to match that existing setup. It is not required
by pim. Other source lists can be supplied instead. A complete configuration
example is also provided in [`examples/blink.lua`](examples/blink.lua).

The former `pim.completion.blink.setup(sources)` helper has been removed.
Only slash commands are supplied by pim's Blink provider. Suggestions are
restricted to the initial command token on the first line of the open pim input
buffer. Arguments, later lines, ordinary Markdown, and transcripts are excluded.
Other configured providers remain eligible, with or without matching commands.
Command descriptions and source labels are retained. Duplicate `/` characters
are prevented by text edits. Both full-token and cursor-position replacement
are supported through `completion.keyword.range`.

File completion must be supplied by a separate source, such as Blink's `path`
provider. Recursive project-file search, including `@config`, is no longer
supplied by pim. An initial `/` may be matched by both command and path sources.

Menus, documentation, ghost text, selection, and keybindings are left to Blink.
Your `preselect = false` and `auto_insert = false` settings can be retained.
No native completion popup, omni mappings, or completion-option overrides are
installed by pim. Existing `omnifunc` settings and mappings are left untouched.
Command metadata is refreshed and reset with the session, independently of Blink.

The development checkout `v1.10.0-239-g473c928` has been tested with its
`blink.lib` dependency and Rust matcher. Only documented provider interfaces
are used. Other Blink releases have not yet been verified for this integration.

### Migration

- The `pim.completion.blink.setup(sources)` helper has been removed. Standard
  provider registration is shown above.
- Native omni completion and automatic `/` and `@` mappings have been removed.
  The generic Blink `omni` source may still be needed by other buffers.
- Pim file completion, recursive discovery, caches, and file APIs have been removed.
  File completion must be configured through a separate Blink source.
- `completion.respect_gitignore` and `completion.exclude` have been removed.
  The `completion` table should be removed from `require("pim").setup()` options.
- Prompt submission and pi's handling of manually entered references are unchanged.

### Validation

`mise run test completion` covers command metadata, context boundaries, edits,
and input lifecycle without Blink. Existing completion settings and mappings
are checked for preservation. File scans and subprocesses must not be started
by typing references. Real-Blink checks are separate; an installed checkout
must be supplied. No plugins are downloaded by these tests:

```sh
# Released Blink, using its Lua fuzzy matcher.
mise run test:blink /path/to/blink.cmp '' lua

# The inspected development setup, using its built Rust matcher.
mise run test:blink \
  ~/.local/share/nvim/lazy/blink.cmp \
  ~/.local/share/nvim/lazy/blink.lib rust
```

Both plugin load orders can be checked by appending `blink-first`. Automatic
command triggers, full-token and cursor-position edits, deletion, metadata,
empty matches, provider coexistence, lifecycle, and filetype overrides are
covered in a clean child Neovim instance.

## Extension dialogs

pim sends extension UI requests through `vim.ui.select` and `vim.ui.input`.
UI plugins can change the appearance of these dialogs.

An `editor` request opens a scratch split. Press `<CR><CR>` to submit or `q` to
cancel. The winbar shows extension status entries and the first line of each
extension widget.

When pi sends an unknown UI request, pim sends a cancellation response.
This prevents a newer extension from waiting without a response.

## Troubleshooting

```text
:checkhealth pim  Check Neovim, pi, and the session directory.
:PiLog                Show pim events and pi messages.
```

Use `debug = true` to record every raw JSONL line in `:PiLog`. The event log
remains available after `:PiStop`. pim clears it immediately before it starts
a new pi process. `:PiNewSession` and `:PiToggle` do not clear it.

- **pi does not start:** Check `pi_cmd`. Keep the tab open and run `:PiRestart`
  after you correct the setting.
- **pi stops:** The winbar shows the exit code. `:PiRestart` resumes the current
  session.
- **A setting has no effect:** Check `:messages` for an unknown-key warning.
- **pi does not respond:** pim reports a command timeout after 30 seconds.
  Shell commands do not have this timeout.
- **A message is missing:** pim drops an unterminated message after 8 MiB.
  Check `:PiLog` and verify that `pi_cmd` starts pi.

The built-in `vim.ui.select` dialog cannot close automatically after a timeout.
This affects appearance only. A UI plugin can provide automatic closing.
Queued steer and follow-up messages are virtual lines. You cannot yank them.

## Development

Node.js 24.21.0, the latest LTS release, and pnpm 12.4.2 are pinned through
`pi-extensions/mise.toml`. Node.js 24.21.0 or a newer 24.x release is required
for backend development. These tool versions are scoped to `pi-extensions/`.
Other Node.js majors are rejected by the backend development commands.
Pi API development dependencies remain pinned to 0.85.1.

The extension and its TypeScript tests are checked with `tsgo` from
`@typescript/native-preview`. TypeScript 7.0.2 is included for editor support.
Oxlint 1.83.0 and Oxfmt 0.68.0 are pinned for linting and formatting. These tools
are development-only; no Node.js toolchain is required by the Neovim client.

The TypeScript package, lockfile, configs, scripts, dependencies, and tests are
contained in `pi-extensions/`. Oxfmt is restricted to that package. No Oxfmt
configuration is applied to the repository root or the Lua client. Shared JSON
fixtures remain in `tests/fixtures/subagents/` and are not formatted by Oxfmt.
Root `mise` tasks delegate backend checks to the package.

```sh
mise install                         # Install Lua development tools.
mise -C pi-extensions install        # Install backend development tools.
mise -C pi-extensions exec -- pnpm install --frozen-lockfile
mise run verify                      # Run all Lua and backend checks.
mise run test                        # Run the headless Lua test suite.
mise run test bash                   # Run Lua tests with "bash" in the name.
mise -C pi-extensions run test       # Run backend tests, including Pi 0.85.1 loading checks.
mise run check                       # Run :checkhealth pim in a clean instance.
mise run fmt                         # Format Lua with Stylua and the backend with Oxfmt.
mise run fmt:check                   # Check both formats without changing files.
mise run lint                        # Run lua-language-server and Oxlint; warnings fail.
mise run typecheck                   # Run strict tsgo checking on the backend and its tests.
mise -C pi-extensions run verify     # Run backend checks only.
mise -C pi-extensions run fmt        # Format the backend package only.
```

Tests use `tests/fake_pi.lua`. This program simulates pi RPC responses. The
`hostile` scenario sends invalid JSON, incomplete lines, and large payloads.
