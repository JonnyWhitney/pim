# pim

Use pi from Neovim. pim starts pi in RPC mode and shows the conversation
in a Markdown buffer. Write prompts in a Neovim buffer.

pim uses Lua only. It has no plugin dependencies. It targets Neovim nightly,
Markdown Treesitter, and the pi RPC interface.

## Requirements

- Neovim nightly. Other Neovim releases are not supported.
- The `pi` command on `$PATH`, or a `pi_cmd` setting that identifies pi.

## Install

For lazy.nvim:

```lua
{
  "JonnyWhitney/pim",
  cmd = { "PiStart", "PiToggle", "PiResume", "PiFork", "PiClone", "PiModel", "PiThinking", "PiLog" },
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

`:PiStop` asks for confirmation, then stops pi and closes the pi windows.
`:PiStop!` does not ask for confirmation. `:PiToggle` hides or shows the
windows and does not stop pi.

The session file remains after you close the UI. `:PiStart` resumes that
session. Unsaved changes can prevent Neovim from closing, as with `:quit`.

## Commands

| Command | Action |
| --- | --- |
| `:PiStart` | Open the UI. Start pi if it is stopped. |
| `:PiToggle` | Show or hide the pi windows. |
| `:PiSend [text]` | Send text. Without text, send the input buffer. |
| `:PiAbort` | Stop the current agent run. |
| `:PiResume` | Select a session for the current directory. |
| `:PiNewSession` | Start a new session. |
| `:PiFork` | Fork from an earlier prompt and edit that prompt in a new session. |
| `:PiClone` | Copy the active branch into a new session. |
| `:PiModel` | Select a model. |
| `:PiThinking` | Select a supported thinking level. |
| `:PiRestart` | Restart pi and resume the current session. |
| `:PiStop[!]` | Stop pi and close the pi windows. `!` skips confirmation. |
| `:PiLog` | Open the event log. Set `debug = true` for raw JSONL traffic. |

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
    tools_collapsed = true, -- Fold tool output after the tool ends.
    show_thinking = "folded", -- "folded", "open", or "hidden".
  },
  set_title = false, -- Allow extensions to set the terminal title.
  debug = false, -- Record raw RPC traffic for :PiLog.
})
```

Invalid setting values cause an error. Unknown setting keys cause a warning.
The warning includes a suggested key when one is available.

The winbar shows the pi provider, model, thinking level, and configuration
directory. pim uses `$PI_CODING_AGENT_DIR`. If it is unset, pim shows
`~/.pi/agent`.

## Completion

Type `/` as the first prompt character to complete pi slash commands. This
includes extension commands, prompt templates, and skills.

Type `@` at the start of a word to complete a file path. In a Git repository,
pim uses `git ls-files`. Outside a Git repository, it uses Neovim file
completion. pi expands `@file` references on the server.

Use `CTRL-X CTRL-O` to start either completion manually.

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

Use `debug = true` to record every raw JSONL line in `:PiLog`.

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
