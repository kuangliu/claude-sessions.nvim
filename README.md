# claude-sessions.nvim

Multi-session manager for [Claude Code](https://claude.com/claude-code) in Neovim.

Each session is a [toggleterm](https://github.com/akinsho/toggleterm.nvim) vertical
terminal (right split, 40% width) that keeps its `claude` process running while
its window is closed. Sessions never change the display layout — every window
opens via the same right-side split.

## Requirements

- [toggleterm.nvim](https://github.com/akinsho/toggleterm.nvim) (auto-loaded
  when a session is created)
- `claude` CLI on `$PATH`

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'kuangliu/claude-sessions.nvim',
  event = 'VeryLazy',
}
```

## Keymaps

| Key    | Mode          | Action                                                              |
| ------ | ------------- | ------------------------------------------------------------------- |
| `<C-a>` | `n`, `t`     | Create a new Claude Code session and open it on the right           |
| `<C-s>` | `n`, `t`     | No session displayed → show the last closed one; else switch to the next session |
| `<C-d>` | `t`           | Close the current session (kills the process, removes it from the list) |

## Session panel

While a session window is displayed, a session-list panel is split below
nvim-tree, styled after Claude Code's session picker: two lines per session
separated by a blank line — a state symbol before the session name (`✓` idle,
a spinning braille frame while busy, a red `◉` while blocked) and the state
word (`idle`/`busy`/`blocked`) indented under the name — with a blue `ᐅ`
marker in the gutter of the displayed session, whose two-line entry also
carries a full-width block background. States are colored like Claude Code's
picker: red for `waiting` (shown as blocked — the agent is parked on a
permission prompt), green idle, yellow working/busy (a custom name from `r`
replaces the default, shown bold like the picker's). `j/k` (or
`<Down>/<Up>`) move
through the list and switch sessions live as they go; `<CR>`/`l`/`o` open the
session under the cursor and focus it; `<C-d>` closes the session under the
cursor (kills the process, same as terminal-mode `<C-d>` or `dd`); `r` renames the
session under the cursor (empty input restores the default `claude`, and a
custom name survives closing and creating sessions); `q` closes the
panel without touching the sessions. The panel follows the nvim-tree window:
it attaches when the tree opens (while a session is displayed), goes away when
the tree closes (`<Leader>f` toggle, `q` in the tree), and comes back when the
tree reopens. It also refreshes on create/close/switch, and closes when the
last displayed session closes.

## Auto-reload

While a session's agent is working, file buffers it changes on disk are
reloaded automatically (a `checktime` on the plugin's poll timer), so Claude
Code's edits appear in open buffers without `:e` or `autoread` — plus one
catch-up reload when the agent goes idle. Reloads are skipped for buffers with
uncommitted edits — work in progress is never clobbered. Disable with
`auto_reload = false`:

```lua
{
  'kuangliu/claude-sessions.nvim',
  event = 'VeryLazy',
  config = function()
    require('claude_sessions').setup({ auto_reload = false })
  end,
}
```

## Statusline

`require('claude_sessions').statusline_indicator()` returns one dot per
session — `•` for the session whose window is open, `◦` for the rest — for use
in lualine:

```lua
{ require('claude_sessions').statusline_indicator }
```

Session terminal buffers are tagged with `vim.b.claude_session_name`
(e.g. `"claude"`, or a custom name from the panel's `r`) so statusline path components can show a friendly name
instead of the raw `term://` buffer name.

## Notes

- Session buffers use `filetype = 'claude'` so lualine's toggleterm extension
  (which matches `ft == 'toggleterm'`) does not replace the statusline inside
  sessions; the filetype is re-applied on `FileType` if toggleterm resets it.
- Sessions that exit on their own (`/exit`, crash) are removed from the list
  automatically.
- The background poll loop (busy indicator + auto-reload) only runs while
  sessions exist, and only actively renders while a session is busy — an idle
  editor pays nothing.
