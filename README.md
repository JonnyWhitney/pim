# pim

Use pi from Neovim. pim starts pi in RPC mode and shows the conversation
in a Markdown buffer. Write prompts in a Neovim buffer.

pim uses Lua only. It has no plugin dependencies. It targets Neovim nightly,
Markdown Treesitter, and the pi RPC interface.

## Requirements

- Neovim nightly. Other Neovim releases are not supported.
- Pi 0.84.4 or newer. Put `pi` on `$PATH`, or set `pi_cmd` to identify it.

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

| Command | Action |
| --- | --- |
| `:PiStart` | Open the UI. Start pi if it is stopped. |
| `:PiToggle` | Show or hide the pi windows. |
| `:PiSend [text]` | Send text. Without text, send the input buffer. |
| `:PiAbort` | Clear queued prompts, restore them to input history, and stop the current agent run. |
| `:PiResume` | Select a session for the current directory. |
| `:PiTree` | Browse the active session tree. Prompts are disabled while it is open. |
| `:PiTrust` | Manage project trust for the current working directory. |
| `:PiNewSession` | Start a new session. |
| `:PiFork` | Fork from an earlier prompt and edit that prompt in a new session. |
| `:PiClone` | Copy the active branch into a new session. |
| `:PiModel` | Select a model. |
| `:PiThinking` | Select a supported thinking level. |
| `:PiRestart` | Restart pi and resume the current session. |
| `:PiStop[!]` | Stop pi and close the pi windows. `!` skips confirmation. |
| `:PiLog` | Open the event log. Set `debug = true` for raw JSONL traffic. |

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

## Keymaps

All keymaps apply only to pim buffers. You can change them in `setup()`.

| Keys | Buffer | Action |
| --- | --- | --- |
| `<CR><CR>` in Normal mode | Input | Send the prompt. |
| `<localleader><CR>` | Input | Send a follow-up after the current run ends. |
| `<C-c>` | pi buffers | Stop the shell command or agent run. |
| `<Tab>` | Transcript | Toggle the fold at the cursor. |
| `<Up>` and `<Down>` | Input | Move through prompt history at the first or last line. |
| `/` at prompt start | Input | Complete pi slash commands. |
| `@` at word start | Input | Complete file paths. |

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
  completion = {
    respect_gitignore = true,
    exclude = { "**/node_modules/**" },
  },
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

| Group | Default link |
| --- | --- |
| `PimUserHeader` | `Identifier` |
| `PimAssistantHeader` | `Statement` |
| `PimCustomHeader` | `Special` |
| `PimDivider` | `Comment` |

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

Type `/` as the first prompt character to complete pi slash commands. This
includes extension commands, prompt templates, and skills.

Type `@` at the start of a word to complete a file path. In a Git repository,
File paths are obtained with `git ls-files`. Outside Git, or after a failed Git
query, files are discovered recursively without another executable. Paths are
relative to the working directory. Directory symlinks are not followed.
Unreadable or disappearing entries are skipped. Git ignore rules are not applied
by this fallback. `@file` references are expanded by pi on the server.

Neovim's built-in omni menu is opened automatically by `/` and `@` in these
contexts. Suggestions are matched by prefix, not fuzzily. These mappings and
completion settings are applied only to the pim input buffer.
Use `CTRL-X CTRL-O` to start either completion manually.

Git ignore filtering is enabled by default with `completion.respect_gitignore`.
Standard rules from `.gitignore`, `.git/info/exclude`, and global exclusions are
applied. Tracked files remain eligible even when matched by those rules.
With `respect_gitignore = false`, ignored files and directory contents are
included. No implicit exclusions are added for build outputs.

Explicit `completion.exclude` globs are always applied, including to tracked
files and recursive discovery outside Git or after a failed Git query. Root and
nested `node_modules` directories and their contents are excluded by default.
A supplied list replaces the defaults; an empty list disables glob exclusions.

A glob is a path pattern with wildcards. Complete paths relative to the current
working directory (not necessarily the Git root) are matched case-sensitively
with `/` separators. `*` is matched within one path component; `**/` is matched
across zero or more directory levels. For example:

- `*.log`: root-level logs only.
- `**/*.log`: logs at any depth.
- `**/build/**`: build directories at any depth.
- `config/private.json`: one exact relative path.

Neovim's built-in glob syntax is used. Shell expansion, Git-style negation, and
ordered re-inclusion are not supported. File paths, rather than directory
placeholders, are offered. Quoted references and paths containing whitespace
are not supported by the reference syntax.

```lua
-- Only Git ignore filtering is disabled; node_modules remains excluded.
require("pim").setup({ completion = { respect_gitignore = false } })

-- The default pattern is repeated so it is retained with custom exclusions.
require("pim").setup({ completion = {
  exclude = { "**/node_modules/**", "**/build/**", "*.log" },
} })

-- Both filters are disabled.
require("pim").setup({ completion = { respect_gitignore = false, exclude = {} } })
```

Complete candidate lists are cached for ten seconds by directory and completion
settings. Setting changes are applied on the next request. Caches are cleared
when completion is reset. Omni enumeration remains synchronous, with a
two-second Git timeout. Large trees can therefore delay the native popup.
No candidate limit is imposed. Explicit exclusions are applied as filters, not
traversal pruning, so excluded directories may still be scanned.
These settings affect picker candidates only. Manually entered `@file` references
are not blocked, and file access is not protected by these exclusions.

### Discovery validation

`mise run test completion` covers recursive discovery, failed Git queries,
symlinks, simulated unreadable/disappearing entries, cancellation, and cache
ownership. A temporary tree with 2,049 files is checked for complete enumeration
and event-loop progress between batches.

The shared `pim.completion.data.request_files(cwd, callback, is_current)` API is
provided for asynchronous consumers. Git is run asynchronously; recursive
fallback is scheduled in batches of at most 128 entries. A cancellation function
is returned. The optional `is_current` predicate must be supplied by consumers
to reject changed buffers or completion contexts. Directory and settings changes
are checked internally. Cancelled or stale results are neither delivered nor
cached. This API is not yet connected to a second completion menu.

Individual filesystem calls, Git output decoding, sorting, and result copying
are not time-bounded. Slow filesystems and very large result sets may still cause
delays; the entire candidate list is held in memory.

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

```sh
mise run verify    # Run formatting, lint, tests, and health checks.
mise run test      # Run the headless test suite.
mise run test bash # Run tests with "bash" in the name.
mise run check     # Run :checkhealth pim in a clean instance.
mise run fmt       # Format Lua files with Stylua.
mise run fmt:check # Check Lua file format.
mise run lint      # Type check with lua-language-server.
```

Tests use `tests/fake_pi.lua`. This program simulates pi RPC responses. The
`hostile` scenario sends invalid JSON, incomplete lines, and large payloads.
