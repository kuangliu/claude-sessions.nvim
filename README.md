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

## Auto-reload

While a session is running, file buffers that its `claude` process changes on
disk are reloaded automatically (a throttled `checktime` on the plugin's poll
timer), so Claude Code's edits appear in open buffers without `:e` or
`autoread`. Reloads are skipped for buffers with uncommitted edits — work in
progress is never clobbered. Disable with `auto_reload = false`:

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
(e.g. `"claude #1"`) so statusline path components can show a friendly name
instead of the raw `term://` buffer name.

## Notes

- Session buffers use `filetype = 'claude'` so lualine's toggleterm extension
  (which matches `ft == 'toggleterm'`) does not replace the statusline inside
  sessions; the filetype is re-applied on `FileType` if toggleterm resets it.
- Sessions that exit on their own (`/exit`, crash) are removed from the list
  automatically.
