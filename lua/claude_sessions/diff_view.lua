-- The right-side diff pane: when the sidebar diff panel selects a file (an
-- explicit j/k — the panel's opening never selects), the file's
-- working-tree-vs-HEAD diff is rendered here via diffview.nvim's engine — the
-- same GitHub-style unified view the review shows (full-file, word-diffed,
-- treesitter-lifted, gitsigns gutter bars, hunk navigation).
--
-- The adapter owns only the plumbing around the engine: resolve the HEAD and
-- working copies, build the view rows, paint them into a scratch buffer, and
-- place that buffer in a vsplit on the right (next to the session terminal,
-- which owns the right side). diffview stays a soft dependency: with it absent
-- show() is a no-op and the panel behaves exactly as before.

local U = require('claude_sessions.util')

local M = {}

M.win = nil
M.buf = nil
-- The render-in-flight flag (set/cleared by M.show): the diff panel's focus
-- passes read it and stand down — see the close pass's gate and M.show's gate
-- comment.
M.busy = false

-- Soft dependency: the engine modules, or nil when diffview.nvim is not
-- installed. Resolved once; every entry gates on it.
local ok, render, git
ok, render = pcall(require, 'diffview.render')
if ok then
  git = require('diffview.git')
end

-- Engine available? One gate for every entry.
local function engine()
  return ok and render and git
end

--- Is the pane window (still) up?
local function active()
  return U.valid_win(M.win)
end

-- Build the view buffer once: a named nofile scratch in diffview's shape —
-- the same look view.lua gives its view buffers (and the b-vars render.render
-- writes are what the hunk-jump scan below reads).
local function create_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].filetype = 'diffview'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].buflisted = false
  vim.bo[buf].swapfile = false
  pcall(vim.api.nvim_buf_set_name, buf, 'claude-sessions://' .. buf)
  vim.keymap.set('n', 'q', function() M.close() end,
    { buffer = buf, nowait = true, silent = true, desc = 'claude sessions: close diff pane' })
  return buf
end

--- Jump to the next/previous change hunk (]]/[[). A hunk is a contiguous run
--- of add/del rows, header and separator rows break it — the same scan the
--- view's jump spells against diffview_rows, read off the pane's own buffer.
local function jump_hunk(d)
  local buf = vim.api.nvim_get_current_buf()
  local rows = vim.b[buf].diffview_rows
  local offset = vim.b[buf].diffview_offset or 0
  local total = vim.api.nvim_buf_line_count(buf)
  local function is_change(i)
    local r = rows and i > 0 and rows[i]
    return r and (r.kind == 'add' or r.kind == 'del') or false
  end
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local i
  if cur <= offset then
    i = (d > 0) and (offset + 1) or nil
  else
    i = cur + d
  end
  -- start inside a hunk: skip past the whole hunk first, so ]] lands on the
  -- NEXT hunk rather than the next line of this one
  if is_change(cur - offset) then
    while i and is_change(i - offset) do i = i + d end
  end
  while i and i > offset and i <= total do
    if is_change(i - offset) then
      -- backward: land on the hunk's FIRST line, symmetric with forward
      if d < 0 then
        while is_change(i - 1 - offset) do i = i - 1 end
      end
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return
    end
    i = i + d
  end
end

--- <CR>: open the source file of the row under the cursor, at that row's
--- new-side line (removed rows have none — the nearest earlier context/add
--- line then stands in).
local function jump_to_source()
  local buf = vim.api.nvim_get_current_buf()
  local abspath = vim.b[buf].diffview_abspath
  if not abspath then return end
  local rows = vim.b[buf].diffview_rows
  local offset = vim.b[buf].diffview_offset or 0
  local target
  for i = vim.api.nvim_win_get_cursor(0)[1] - offset, 1, -1 do
    local r = rows and rows[i]
    if r and r.newln then target = r.newln; break end
  end
  -- The pane's window swaps to the real file (diffview's own <CR> swaps the
  -- diff window's content the same way); the pane's WINDOW stays — the next
  -- selection re-renders its diff over the file, so the layout never churns.
  -- M.win is still the window, so the next show() reuses it in place.
  vim.cmd('edit ' .. vim.fn.fnameescape(abspath))
  if target then
    vim.api.nvim_win_set_cursor(0, { target, 0 })
  end
end

-- The pane's keymaps: q closes it, ]]/[[ jump hunks, <CR> opens the source.
local function set_keymaps(buf)
  vim.keymap.set('n', ']]', function() jump_hunk(1) end,
    { buffer = buf, nowait = true, silent = true, desc = 'claude sessions: next change' })
  vim.keymap.set('n', '[[', function() jump_hunk(-1) end,
    { buffer = buf, nowait = true, silent = true, desc = 'claude sessions: prev change' })
  vim.keymap.set('n', '<CR>', jump_to_source,
    { buffer = buf, nowait = true, silent = true, desc = 'claude sessions: open source' })
end

-- Pane window look: the diff is plain text like the sidebar panels (nothing
-- decorates its edges), no numbers — the header row carries the counts.
local function plain_diff_window(win)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'yes:1' -- the gitsigns-style add/del bars live here
  vim.wo[win].foldcolumn = '0'
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false
  vim.wo[win].cursorcolumn = false
  vim.wo[win].statuscolumn = ''
end

--- Show the pane buffer's window: reuse the pane's own window when it is
--- still up, else split one off the session terminal's window (the right
--- side is the terminal's — the pane splits it in place, keeping the layout
--- the sessions plugin owns), else plain vsplit. Seeded at the terminal's own
--- width (`columns * 0.4`, the sessions config's vertical size), so the pane
--- and the terminal read as one pair.
local function show_window(buf)
  if active() then
    vim.api.nvim_win_set_buf(M.win, buf)
    return
  end
  -- Host for the split: a displayed session window keeps the pane beside the
  -- terminal — BETWEEN the tree and the terminal (tree → pane → terminal, the
  -- sidebar's file list reading straight into its diff), not the far right
  -- the global `splitright` would put it. `splitright = false` while the
  -- split lands puts the pane on the terminal's left; the one-split flip is
  -- restored before anything else can read it. No session on screen: plain
  -- vsplit from where we are.
  local host = U.window_with_filetype('claude')
  local prev = vim.api.nvim_get_current_win()
  if host then
    pcall(vim.api.nvim_set_current_win, host)
  end
  -- Seed the width like the terminal's own: `columns * 0.4` (the sessions
  -- config's vertical size), so the pane and the terminal read as one pair.
  local splitright = vim.o.splitright
  vim.o.splitright = false
  vim.cmd('40vsplit')
  vim.o.splitright = splitright
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  plain_diff_window(win)
  vim.cmd('vertical resize ' .. math.max(20, math.floor(vim.o.columns * 0.4)))
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  if host then
    pcall(U.focus, prev) -- hand focus back to whoever held it
  end
  -- The pane can go away on its own (a layout edit, q's own close); forget it
  -- so the next show() rebuilds cleanly.
  vim.api.nvim_create_autocmd('WinClosed', {
    buffer = buf,
    callback = function() M.win = nil end,
  })
  M.win = win
end

--- Render the diff of `abspath` (a repo-relative path, as the diff panel's
--- rows carry) against `root`, and show it in the pane. No-op without the
--- engine (diffview absent) or a root. Reuses the pane window and buffer
--- across calls, so stepping files re-renders in place.
function M.show(abspath, root)
  if not (engine() and abspath and root) then return end
  -- The render flips focus twice (the host split moves to the terminal and
  -- hands it back): the diff panel's focus-flip pass sees those as arrivals/
  -- departures — a departure spelled DURING a render would close the pane the
  -- render is about to fill, and the flip-back's arrival would re-render it,
  -- arriving/departing forever. One flag stands between them: the panel's
  -- close pass reads busy and stands down (the render's own flip-back is the
  -- settled state, not a departure).
  M.busy = true
  local toplevel = root
  local rel = git.relpath(toplevel, abspath)

  local old_raw = git.git_show_raw(toplevel, 'HEAD:' .. rel) -- nil for untracked files
  local new_raw = git.read_file_raw(toplevel .. '/' .. rel) -- nil for deleted files
  local rows, counts
  if git.is_binary(toplevel, rel, toplevel .. '/' .. rel) then
    rows = { render.row('Binary file differs (not shown)', 'del', nil, 1) }
    counts = { add = 0, del = 1 }
  else
    rows, counts = render.build_view(old_raw, new_raw)
    rows = render.collapse_context(rows)
  end

  local buf = M.buf
  if not (U.valid_buf(buf)) then
    buf = create_buf()
    set_keymaps(buf)
    M.buf = buf
  end
  render.render(buf, toplevel .. '/' .. rel, rel, rows, counts)
  -- treesitter lifting reads raw content again; spell the sides once more
  render.apply_treesitter(buf, toplevel .. '/' .. rel, rows, old_raw, new_raw)
  show_window(buf)

  -- Land the cursor on the first change (the header's end runs into it), so
  -- the pane opens on the file's edits rather than its top. The flag clears
  -- here — the ONE pass after show_window's own focus flip-back, so the
  -- panel's focus passes see the render's switches as behind them.
  vim.schedule(function()
    M.busy = false
    if not (U.valid_win(M.win) and U.valid_buf(buf)) then return end
    local rows2 = vim.b[buf].diffview_rows
    local off2 = vim.b[buf].diffview_offset or 0
    for i = 1, #(rows2 or {}) do
      local r = rows2[i]
      if r.kind == 'add' or r.kind == 'del' then
        pcall(vim.api.nvim_win_set_cursor, M.win, { off2 + i, 0 })
        return
      end
    end
  end)
end

--- Tear the pane down (window + buffer). The sidebar panels are untouched.
function M.close()
  if active() then
    pcall(vim.api.nvim_win_close, M.win, true)
  end
  if U.valid_buf(M.buf) then
    vim.api.nvim_buf_delete(M.buf, { force = true })
  end
  M.win, M.buf = nil, nil
end

return M
