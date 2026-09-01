-- The diff pane: when the sidebar diff panel selects a file (an explicit
-- j/k or <C-e> — the panel's opening never selects), the file's
-- working-tree-vs-HEAD diff is rendered here via diffview.nvim's engine — the
-- same GitHub-style unified view the review shows (full-file, word-diffed,
-- treesitter-lifted, gitsigns gutter bars, hunk navigation).
--
-- The adapter owns only the plumbing around the engine: resolve the HEAD and
-- working copies, build the view rows, paint them into a scratch buffer, and
-- show it diffview-style — the pane TAKES OVER the editor window: the user's
-- file steps aside (buffer, cursor and window options remembered), the diff
-- renders at the editor's own full width, and when the pane exits the file
-- comes back exactly as it left. Only when no editor window exists (nothing
-- on screen but the sessions layout) does the pane fall back to a vsplit
-- beside the session terminal. diffview stays a soft dependency: with it
-- absent show() is a no-op and the panel behaves exactly as before.

local U = require('claude_sessions.util')

local M = {}

M.win = nil
M.buf = nil
-- The editor window the pane took over, as { buf, cursor, opts } — what the
-- take-over found there and what restore hands back. Nil when the pane lives
-- in its own split (no editor window was on screen to take over).
M.replaced = nil
-- The render-in-flight flag (set/cleared by M.show): the diff panel's focus
-- passes read it and stand down — see the close pass's gate and M.show's gate
-- comment.
M.busy = false
-- The pane's last render target, { abspath, root }: a show() of the same pair
-- while the pane is up skips the engine pipeline — the focus-flip arrival pass
-- re-selects the landed entry on every flip, and a restart lands file one the
-- pane may already show. Two git spawns, a working-file read and a two-sided
-- treesitter parse are too heavy to run twice per keystroke.
local last_target = nil

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

-- The pane's look: util's plain-text look, plus the signcolumn the
-- gitsigns-style add/del bars draw in. One table spells the whole look —
-- plain_diff_window applies it, and the take-over captures/restores exactly
-- these keys, so the pane's look can never leak onto the user's window.
local PANE_LOOK = U.plain_look({ signcolumn = 'yes:1' })

-- Pane window look: the diff is plain text like the sidebar panels (nothing
-- decorates its edges), no numbers — the header row carries the counts.
local function plain_diff_window(win)
  U.apply_winopts(win, PANE_LOOK)
end

--- Hand the taken-over editor window back: the pane's window options come
--- off, the user's buffer and cursor return. `win` invalid (a manual :close
--- took the window with the diff still in it): open the buffer in a fresh
--- split instead — anchored on the tree when there is one, the pane's home
--- territory — so the restore holds whatever way the pane ended. Clears
--- M.replaced either way; a no-op when nothing was taken over.
local function restore_replaced(win)
  local saved = M.replaced
  M.replaced = nil
  if not (saved and U.valid_buf(saved.buf)) then return end
  if not U.valid_win(win) then
    U.focus(U.tree_window())
    pcall(vim.cmd, 'vsplit')
    win = vim.api.nvim_get_current_win()
  end
  for opt, val in pairs(saved.opts) do
    pcall(function() vim.wo[win][opt] = val end)
  end
  vim.api.nvim_win_set_buf(win, saved.buf)
  pcall(vim.api.nvim_win_set_cursor, win, saved.cursor)
end

--- The pane is gone: forget the window and hand a taken-over editor window
--- back — `win` nil (or already dead) means the window died on its own and
--- restore rehomes the file. One spelling of the teardown, shared by the
--- WinClosed pass and M.close.
local function release(win)
  M.win = nil
  restore_replaced(win)
end

-- Build the view buffer once: a named nofile scratch in diffview's shape —
-- the same look view.lua gives its view buffers (and the b-vars render.render
-- writes are what the hunk-jump scan below reads). The buffer survives across
-- shows (bufhidden=hide), so its birth state lives here: the keymaps, and the
-- one WinClosed that forgets/rehomes when the pane window dies on its own —
-- per pane buffer, not per show (per-show would stack one autocmd per reopen
-- cycle on this long-lived buffer).
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
  vim.api.nvim_create_autocmd('WinClosed', {
    buffer = buf,
    callback = function() release(nil) end,
  })
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

--- The editor window the pane takes over: a real (non-floating) window whose
--- buffer is a NORMAL one — no terminal, no qf/help, nothing of the sessions
--- layout (the tree, the panels and the session terminals are nofile/terminal
--- buffers, all failing this gate). The LARGEST such window wins: the main
--- editor area, when several code windows share the row. Nil when the screen
--- holds nothing but the sessions layout.
local function editor_window()
  local best, best_area = nil, -1
  for _, w in ipairs(U.real_windows()) do
    local b = vim.api.nvim_win_get_buf(w)
    if U.valid_buf(b) and vim.bo[b].buftype == '' then
      local area = vim.api.nvim_win_get_width(w) * vim.api.nvim_win_get_height(w)
      if area > best_area then best, best_area = w, area end
    end
  end
  return best
end

--- Show the pane buffer's window: reuse the pane's own window when it is
--- still up; else TAKE OVER an editor window (the user's file steps aside —
--- buffer, cursor and window options remembered in M.replaced; restore is
--- release's job); else — nothing but the sessions layout on screen — split
--- one off the session terminal's window (the right side is the terminal's —
--- the pane splits it in place, keeping the layout the sessions plugin owns),
--- seeded at the terminal's own width (`columns * 0.4`, the sessions config's
--- vertical size), so the pane and the terminal read as one pair.
local function show_window(buf)
  if active() then
    if vim.api.nvim_win_get_buf(M.win) ~= buf then
      vim.api.nvim_win_set_buf(M.win, buf)
    end
    return
  end
  local editor = editor_window()
  local win, handback = nil, nil
  if editor then
    -- The take-over: capture what the window holds, then swap the diff in.
    -- No split, no resize, no focus flip — the sidebar's thirds and the
    -- terminal's pinned width are untouched, and the render's focus dance
    -- (M.show's busy flag) simply has nothing to gate here.
    local opts = {}
    for opt in pairs(PANE_LOOK) do
      opts[opt] = vim.wo[editor][opt]
    end
    M.replaced = {
      buf = vim.api.nvim_win_get_buf(editor),
      cursor = vim.api.nvim_win_get_cursor(editor),
      opts = opts,
    }
    win = editor
  else
    -- Host for the split: a displayed session window keeps the pane beside the
    -- terminal — BETWEEN the tree and the terminal (tree → pane → terminal, the
    -- sidebar's file list reading straight into its diff), not the far right
    -- the global `splitright` would put it. `splitright = false` while the
    -- split lands puts the pane on the terminal's left; the one-split flip is
    -- restored before anything else can read it. No session on screen: plain
    -- vsplit from where we are.
    local host = U.window_with_filetype('claude')
    local prev = vim.api.nvim_get_current_win()
    U.focus(host)
    -- Seed the width like the terminal's own: `columns * 0.4` (the sessions
    -- config's vertical size), so the pane and the terminal read as one pair.
    local splitright = vim.o.splitright
    vim.o.splitright = false
    vim.cmd('40vsplit')
    vim.o.splitright = splitright
    win = vim.api.nvim_get_current_win()
    vim.cmd('vertical resize ' .. math.max(20, math.floor(vim.o.columns * 0.4)))
    handback = prev -- the split stole focus; hand it back once landed
  end
  -- One landing for both placements: the pane's buffer, its plain look, at
  -- the top.
  vim.api.nvim_win_set_buf(win, buf)
  plain_diff_window(win)
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  if handback then
    U.focus(handback) -- hand focus back to whoever held it
  end
  M.win = win
end

--- Render the diff of `abspath` (a repo-relative path, as the diff panel's
--- rows carry) against `root`, and show it in the pane. No-op without the
--- engine (diffview absent) or a root. Reuses the pane window and buffer
--- across calls, so stepping files re-renders in place.
function M.show(abspath, root)
  if not (engine() and abspath and root) then return end
  -- Same-target skip: the pane already shows this file's diff — a focus
  -- arrival re-selects the landed entry on every flip, and a step/restart
  -- lands a file the pane may already be showing. The skip leaves the pane
  -- (and its cursor) exactly as this show would have.
  if active() and last_target and last_target.abspath == abspath
      and last_target.root == root then
    return
  end
  -- The render can flip focus twice (the split path's host move to the
  -- terminal and hand-back; the take-over path flips none and the flag simply
  -- gates nothing there): the diff panel's focus-flip pass sees those as
  -- arrivals/departures — a departure spelled DURING a render would close the
  -- pane the render is about to fill, and the flip-back's arrival would
  -- re-render it, arriving/departing forever. One flag stands between them:
  -- the panel's close pass reads busy and stands down (the render's own
  -- flip-back is the settled state, not a departure).
  M.busy = true
  last_target = { abspath = abspath, root = root }
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
--- A taken-over editor window is NOT closed — it is the user's window: its
--- buffer, cursor and window options go back the way the take-over found
--- them, and only the pane's scratch buffer dies.
function M.close()
  if not M.replaced and active() then
    pcall(vim.api.nvim_win_close, M.win, true)
  end
  release(M.win)
  if U.valid_buf(M.buf) then
    vim.api.nvim_buf_delete(M.buf, { force = true })
  end
  M.win, M.buf = nil, nil
  last_target = nil -- the pane's context ended: the next show re-renders
end

return M