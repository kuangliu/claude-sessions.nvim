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
- [diffview.nvim](https://github.com/kuangliu/diffview.nvim) (optional — the
  right-side diff pane renders without it as a plain selection-only panel)

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
| `<C-e>` | `n`, `t`     | Select the next changed file in the diff panel (first press starts the sweep at the first file, later presses advance from the selection and wrap past the last) |
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
cursor (kills the process, same as terminal-mode `<C-d>`); `r` renames
the session under the cursor in place on its row — insert mode starts after
the name, Enter applies it, Esc cancels (an empty name restores the default
`claude`, and a custom name survives closing and creating sessions); `q` closes the
panel without touching the sessions. The panel follows the nvim-tree window:
it attaches when the tree opens (while a session is displayed), goes away when
the tree closes (`<Leader>f` toggle, `q` in the tree), and comes back when the
tree reopens. It also refreshes on create/close/switch, and closes when the
last displayed session closes.

## Diff panel

While a session window is displayed and the workspace has uncommitted changes,
a diff panel is split above the session panel (below nvim-tree): one three-line
entry per changed file — the basename, the `+`/`-` counts with a proportional
bar of blocks (untracked files show `??` in yellow), a blank separator. `j/k`
(or `<Down>/<Up>`) move the cursor; the file landed on draws the selection
block, and the selection is **pinned** — it holds when the cursor moves out of
the panel, so the review keeps running while you read or work elsewhere.
`<CR>`/`l` open the file under the cursor in the diff pane and move the cursor
onto it (its `]]`/`[[`/`<CR>`/`q` take over).
`<C-e>` — global, the way `<C-s>` cycles sessions — focuses the panel
and selects a changed file: the FIRST press starts the sweep at the first
file, and every press after advances from the selection and wraps back past
the last — whichever window held focus. Landing on a file
(an explicit `j/k` or a `<C-e>` — not the panel's opening) is what
**renders its working-tree-vs-HEAD diff via
[diffview.nvim](https://github.com/kuangliu/diffview.nvim)** — the same
GitHub-style unified view (word-diffed, treesitter-highlighted, gitsigns-style
gutter bars, `]]`/`[[` jump hunks, `<CR>` opens the source file, `q` closes
the pane). Moving the cursor out of the panel does not exit the diff — it
stays until the panel closes, the workspace goes clean, or you press `q` on
the pane itself. The diff takes over the editor window: your file steps aside
(cursor and window options remembered) and comes back when the pane exits;
with nothing but the sessions layout on screen the pane splits beside the
terminal instead. Soft dependency: without diffview installed the panel still tracks
changes and moves the selection — just with no right-side diff.

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
