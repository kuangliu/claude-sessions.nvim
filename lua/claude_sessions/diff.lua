-- The diff panel of the tree sidebar: split below the nvim-tree window, so it
-- sits between the tree and the session-list panel (which splits below the
-- tree as well). It tracks files modified but not committed: three lines per
-- file —
--   ' aa.py'          (the basename only — directories dropped)
--   '   +37 -58  ▪▪▪▪▪▪□□□□□'
--   ''
-- the name on the first row (default text color), the counts and a bar of
-- blocks on the second (`+37` in green, `-58` in red; the bar sized by the
-- change — green for added, red for removed; untracked files show `??` in
-- yellow with no bar). Data comes from `git diff --numstat HEAD` (staged +
-- unstaged) and `git status --porcelain` (untracked), each on a job, so
-- refreshes never block the editor.
--
-- Lifecycle mirrors the session-list panel: opened while a session window is
-- displayed and an nvim-tree window exists to split below; closed when the
-- tree or the last displayed session closes. A CLEAN workspace draws no panel
-- at all: open() splits only when `git status` reports changes, and a refresh
-- that finds none closes it again — the tree and the session list take the
-- rows back (U.calibrate_sidebar).
--
-- Selection is a PIN, not focus: the entry the panel last landed on — an
-- explicit j/k or <C-e>, or a focus arrival — draws the two-line block
-- background and renders its working-tree-vs-HEAD diff in the pane
-- (claude_sessions/diff_view.lua). Both stand when the cursor moves OUT of the
-- panel — the review keeps running while the user works elsewhere. The panel's
-- opening never selects — no j, no pin, no pane.

local diff_view = require('claude_sessions.diff_view')
local U = require('claude_sessions.util')

local M = {}

M.win = nil
M.buf = nil

local ns = vim.api.nvim_create_namespace('claude_sessions_diff')

local ADD_HL = 'ClaudeSessionsDiffAdd'
local DEL_HL = 'ClaudeSessionsDiffDel'
local UNTR_HL = 'ClaudeSessionsDiffUntracked'
-- The selected entry's two-line block background: the session panel's group
-- (a faint read on top of the normal background), so the two panels read as
-- one system.
local CURSOR_HL = 'ClaudeSessionsPanelCursor'

-- How many added/removed lines a full-width bar of blocks represents; a file's
-- bar is min(change / BAR_SCALE, 1) of the width. 100 ≈ a typical edit, so
-- everyday files fill most of the bar.
local BAR_SCALE = 100
local BAR_BLOCKS = 12 -- blocks in a full-width bar
local BAR_BLOCK = '▪' -- single display column, 3 bytes (U.rune_len rules)

-- Both rendered rows share the same one-space + indent prefix, so they align
-- at column `1 + #RENDER_INDENT` — the offset every counts/bar mark assumes.
local RENDER_INDENT = '  '

local in_flight = false -- a refresh's two probes are running; don't queue more

-- A split in flight: open() latches it synchronously so the two open() calls
-- one settle queues (panel_sync's diff_sync, then show_session's own) don't
-- BOTH split (see M.open). Declared in the state section — open_split and
-- open_probe clear it, and Lua locals aren't visible before their
-- declaration: below them, their writes bind to a global and the latch never
-- clears (the panel would never reopen).
local opening = false

-- The repo root the panel was opened for: private state of the last open()
-- (the callers of refresh spell no root). The root never changes for a cwd,
-- so no invalidation beyond close().
local panel_root = nil

-- The rows the last refresh rendered: land()'s repaint and focus_panel's
-- re-render replay them without re-running the two git probes — a keystroke
-- or a focus flip must not pay for two jobs.
local last_files = nil

-- Whether the review sweep has started. The first <C-e> (or j/k) lands the
-- FIRST file, every later one advances from the entry the selection rests on
-- — and the raw cursor can't tell those apart (it sits on entry 1's name line
-- from birth, indistinguishable from a landed selection on entry 1), hence
-- the flag. Only land() flips it on; M.close clears it with the rest of the
-- panel's context.
local review_started = false

-- Skip-identical state: the last render's TEXT and SELECTION row. A repaint
-- is due only when either half changed — rows byte-identical but the cursor
-- moved between same-shaped entries must still repaint (the block lands on
-- the new entry).
local last_text = nil
local last_row = nil

--- Is the panel window (still) up? The poll loop gates on this — no panel,
--- no git jobs.
function M.active()
  return U.valid_win(M.win)
end

--- The entry the RAW panel cursor rests on — one-based, clamped to the live
--- rows — or nil. No sweep gate: the flag-free read the focus ARRIVAL needs,
--- because the birth state is exactly what an arrival selects (the cursor
--- rests on entry 1 from birth, or wherever a mouse click put it). Any line —
--- a name, a counts row, or the blank below it — attributes to the entry it
--- belongs to (U.line_entry), clamped to the live count (a cursor left on a
--- row the last render dropped must not select past the list).
local function raw_cursor_row()
  if not (M.active() and U.valid_buf(M.buf)) then return nil end
  local count = vim.api.nvim_buf_line_count(M.buf)
  if count == 0 then return nil end
  local line = vim.api.nvim_win_get_cursor(M.win)[1]
  return math.min(math.max(U.line_entry(line), 1),
    math.max(U.entry_count(count), 1))
end

--- The file the panel cursor selects: raw_cursor_row behind the sweep flag,
--- nil until the sweep started. This gates the reads that must not CREATE a
--- selection — render's block and a departure's re-show. Creating one is
--- land()'s job alone: an explicit j/k / <C-e>, or a focus arrival.
local function cursor_row()
  if not review_started then return nil end
  return raw_cursor_row()
end

--- Run a git command of `root` on a job and hand its stdout (a string) to `cb`
--- when it exits 0, else nil — util's shared job helper with the `-C root`
--- prefix spelled once.
local function git(root, args, cb)
  U.job(vim.list_extend({ 'git', '-C', root }, args), cb)
end

--- The changes `git diff --numstat HEAD` reports: one { path, add, del } per
--- row (`add<TAB>del<TAB>path`; both counts `-` on unmerged paths — skipped).
--- Renames arrive mangled ('old => new'); the new path is shown.
local function fetch_numstat(root, cb)
  git(root, { 'diff', '--numstat', 'HEAD' }, function(out)
    local files = {}
    for _, row in ipairs(out and vim.split(out, '\n', { trimempty = true }) or {}) do
      local add, del, path = row:match('^(%d+)%s+(%d+)%s+(.+)$')
      if path and path:match('=>') then
        path = path:match('=> (.+)$') or path
      end
      if path then
        files[#files + 1] = { path = path, add = tonumber(add), del = tonumber(del) }
      end
    end
    cb(files)
  end)
end

--- All porcelain status rows of `root` (`--untracked-files=all`), one string
--- per line, or nil on exit ~= 0. Shared by open()'s clean-workspace probe
--- (which only needs "any rows?") and refresh()'s untracked probe (which
--- matches the `?? ` rows).
local function fetch_status(root, cb)
  git(root, { 'status', '--porcelain', '--untracked-files=all' }, function(out)
    cb(out and vim.split(out, '\n', { trimempty = true }) or nil)
  end)
end

local function define_highlights()
  vim.api.nvim_set_hl(0, ADD_HL, { fg = '#98c379' }) -- added: green
  vim.api.nvim_set_hl(0, DEL_HL, { fg = '#e06c75' }) -- removed: red
  vim.api.nvim_set_hl(0, UNTR_HL, { fg = '#e5c07b' }) -- untracked: yellow
end

--- The bar for a file: `g` green blocks then `r` red ones, sized by the change
--- relative to BAR_SCALE, split proportionally between the colors. Any change
--- shows at least one block; no change shows none.
local function bar(add, del)
  local change = add + del
  if change == 0 then return '', '' end
  local n = math.floor(math.min(change / BAR_SCALE, 1) * BAR_BLOCKS + 0.5)
  if n == 0 then n = 1 end
  local g = del == 0 and n or math.floor(n * add / change + 0.5)
  return string.rep(BAR_BLOCK, g), string.rep(BAR_BLOCK, n - g)
end

--- Render the files as three rows per entry (name / counts / blank), with the
--- selected entry's two rows padded to the window's width so its block
--- background spans full-width, and the marks that color the pieces. All
--- extmark columns are BYTE offsets; the pad arithmetic is RUNE count
--- (U.rune_len — the bar's ▪ blocks are 3 bytes apiece).
local function render(files)
  local lines, marks = {}, {}
  -- The file the cursor selects, derived once per repaint: the block follows
  -- the raw window cursor — no focus read (the pin holds through a focus
  -- flip) and no selection before the sweep starts (cursor_row's flag gate,
  -- so the panel's birth state spells no block and no pane).
  local row = cursor_row()
  local COUNTS_COL = 1 + #RENDER_INDENT -- the leading ' ' + indent both rows share
  local width = M.active() and vim.api.nvim_win_get_width(M.win) or 80
  for i, f in ipairs(files) do
    local name_lnum = U.entry_line(i) - 1 -- 0-based name row; the counts row is that + 1
    local counts_lnum = name_lnum + 1
    -- First row: the file's NAME only (the basename), indented like the
    -- counts below it. Default text color; no extmark.
    local name = f.path:match('[^/]+$') or f.path
    lines[#lines + 1] = ' ' .. RENDER_INDENT .. name
    -- Second row: the counts and the bar, indented under the name.
    local add_str = ('+%d'):format(f.add or 0)
    local del_str = ('-%d'):format(f.del or 0)
    local counts = f.untracked and '??' or (add_str .. ' ' .. del_str)
    lines[#lines + 1] = ' ' .. RENDER_INDENT .. counts
    if f.untracked then
      marks[#marks + 1] = {
        lnum = counts_lnum, col = COUNTS_COL, end_col = COUNTS_COL + 2, hl = UNTR_HL,
      }
    else
      local col = COUNTS_COL
      marks[#marks + 1] = { lnum = counts_lnum, col = col, end_col = col + #add_str, hl = ADD_HL }
      col = col + #add_str + 1
      marks[#marks + 1] = { lnum = counts_lnum, col = col, end_col = col + #del_str, hl = DEL_HL }
      -- The bar trails the counts on the same row, two spaces after.
      local g, r = bar(f.add, f.del)
      local bar_col = col + #del_str + 2
      lines[#lines] = lines[#lines] .. '  ' .. g .. r
      if #g > 0 then
        marks[#marks + 1] = { lnum = counts_lnum, col = bar_col, end_col = bar_col + #g, hl = ADD_HL }
      end
      if #r > 0 then
        marks[#marks + 1] = { lnum = counts_lnum, col = bar_col + #g, end_col = bar_col + #g + #r, hl = DEL_HL }
      end
    end
    -- The selected entry: pad its two rows AFTER the bar's own marks (they
    -- read byte offsets up to the bar's end — padding past them is safe),
    -- then the full-width block marks, one per row.
    if row == i then
      lines[#lines - 1] = U.pad_to(lines[#lines - 1], width)
      lines[#lines] = U.pad_to(lines[#lines], width)
      marks[#marks + 1] = { lnum = name_lnum, col = 0, end_col = #lines[#lines - 1], hl = CURSOR_HL }
      marks[#marks + 1] = { lnum = counts_lnum, col = 0, end_col = #lines[#lines], hl = CURSOR_HL }
    end
    -- A blank separator line below every entry (a trailing one too: it never
    -- shows, and dropping it per-entry costs a modulo in a hot-ish loop).
    lines[#lines + 1] = ''
  end
  -- Skip-identical: the poll loop refreshes per tick while the panel is up,
  -- and the usual result is rows byte-identical to the last. Coalesce the
  -- rewrite — set_lines marks every row changed and invalidates the window
  -- for a full redraw — when the fresh rows spell the same text and rest on
  -- the same entry.
  local text = table.concat(lines, '\n')
  if text == last_text and row == last_row then return end
  last_text, last_row = text, row
  U.set_rows(M.buf, ns, lines, marks)
end

--- The file the selection lands on: `last_files`' row `row`, or nil.
local function row_file(row)
  return row and last_files and last_files[row] or nil
end

--- Render the selected file's diff in the pane. Rows carry the repo-RELATIVE
--- path (numstat's spelling), which the pane takes directly.
local function select_pane(file)
  if file then diff_view.show(file.path, panel_root) end
end

--- Land the selection on entry `row`: the cursor onto its name line, the
--- repaint (the block draws there in the same keystroke), and the file's diff
--- in the pane. One spelling of "this entry is now the selection" for the j/k
--- move, <C-e>'s begin/step, and a focus arrival — and the one place the
--- sweep-start flag flips on, so the next <C-e> advances from here.
local function land(row)
  review_started = true
  pcall(vim.api.nvim_win_set_cursor, M.win, { U.entry_line(row), 0 })
  -- The block lands through the zero-job repaint (the remembered rows), not
  -- the two-probe refresh: a keystroke spawns no git jobs.
  if last_files then render(last_files) end
  -- The file the cursor just landed on IS the selection: its diff renders in
  -- the pane in the same keystroke (a no-op without diffview).
  select_pane(row_file(row))
end

--- Move the panel cursor `d` entries (j: +1, k: −1), clamped to the live row
--- count — or wrapped around it (`wrap`, <C-e>'s cycle). A move from no
--- cursor entry starts at the first (j) or last (k). The move lands on the
--- entry's NAME line (the block's top row) and the block draws there in the
--- same keystroke: the block follows the raw cursor, so moving the cursor IS
--- the selection.
local function move_cursor(d, wrap)
  if not M.active() then return end
  local n = U.entry_count(vim.api.nvim_buf_line_count(M.buf))
  if n == 0 then return end
  local row = cursor_row()
  if row == nil then
    row = d > 0 and 1 or n
  else
    row = row + d
    if wrap then
      row = row > n and 1 or row -- cycle forward past the end
    else
      row = math.min(math.max(row, 1), n)
    end
  end
  land(row)
end

--- <C-e>: the panel's global step — focus the panel and select a changed
--- file. Pressed from anywhere, the way <C-s> cycles sessions. The sweep
--- carries its position across presses: the first press lands the first file,
--- every press after advances from the selection and wraps past the last
--- file. Panel down: nothing to step — say so, the way <C-s> does with no
--- sessions.
function M.step_next()
  if not M.active() then
    U.notify('No diff panel: nothing to step through.', vim.log.levels.WARN)
    return
  end
  -- The focus move happens for its VISIBILITY and to hand the panel j/k; a
  -- refused one still steps — the selection is a pin, not a focus read.
  U.focus(M.win)
  move_cursor(1, true)
end

--- The focus flip: an arrival ON the diff PANEL is a SELECTION — land() the
--- entry under the cursor, the way a j/k pressed there would (the block draws
--- on it, its diff renders in the pane — opening a dismissed one: coming
--- back to the file list means the user wants its diff back). An arrival
--- anywhere else stands down — the pin holds, the repaint spells the
--- remembered rows, and a dismissed pane (the q keymap, a manual window
--- close) stays dismissed: only an explicit selection shows it again. No flip
--- ever closes the pane: the review's lifetime is the diff panel's. The
--- arrival lands in the panel's BIRTH state too — the cursor resting on
--- entry 1 from the panel's opening is as good as a j pressed there — which
--- is why the landing reads raw_cursor_row, not the sweep-gated cursor_row.
---
--- The pass lands ONE PASS LATER, not inside the event: the WinLeave/WinEnter
--- pair dispatches out of order (the leave can arrive after the enter of a
--- round-trip), so a gate read inside either event sees whoever was current
--- at dispatch, not where focus settled. A flip queues at most one pass (the
--- flag), so held-key window sweeps pay one render, not one per window
--- crossed.
local repaint_scheduled = false
local function focus_panel()
  if repaint_scheduled or not (M.active() and last_files) then return end
  repaint_scheduled = true
  vim.schedule(function()
    repaint_scheduled = false
    if not (M.active() and last_files) then return end
    if vim.api.nvim_get_current_win() == M.win then
      local row = raw_cursor_row()
      if row then land(row) end
    else
      render(last_files)
      if diff_view.active() then
        select_pane(row_file(cursor_row()))
      end
    end
  end)
end

--- j/k (and <Down>/<Up>): move the panel cursor. The editing keys are
--- silenced first (util's shared list) so these win; everything else keeps
--- its default. NOT silenced: <C-a> — the global mapping creates a session.
local function set_keymaps(buf)
  U.silence_editing_keys(buf)
  local function map(key, d, desc)
    vim.keymap.set('n', key, function() move_cursor(d) end,
      { buffer = buf, nowait = true, silent = true, desc = 'claude sessions: ' .. desc })
  end
  map('j', 1, 'next file')
  map('k', -1, 'previous file')
  map('<Down>', 1, 'next file')
  map('<Up>', -1, 'previous file')
end

--- Fetch the current diff and repaint the panel. No-op when the panel is
--- gone — the poll loop calls this per tick. A refresh that finds NO changes
--- closes the panel again (the workspace went clean while it was up). The two
--- probes run concurrently and join; one refresh runs at a time (`in_flight`)
--- — queuing more would land stale rows out of order.
function M.refresh()
  if not (M.active() and panel_root and not in_flight) then return end
  in_flight = true
  local root = panel_root
  local done, files, untracked_rows = 0, {}, nil
  local function join()
    done = done + 1
    if done < 2 then return end
    in_flight = false
    -- The panel can close while the jobs are in flight.
    if not U.valid_buf(M.buf) then return end
    for _, row in ipairs(untracked_rows or {}) do
      local path = row:match('^%?%? (.+)$')
      if path then files[#files + 1] = { path = path, untracked = true } end
    end
    if #files == 0 then
      M.close() -- workspace went clean: drop the panel
      return
    end
    last_files = files -- land/focus_panel's repaints replay these
    render(files)
  end
  fetch_numstat(root, function(rows)
    files = rows or {}
    join()
  end)
  fetch_status(root, function(rows)
    untracked_rows = rows
    join()
  end)
end

--- Tear the panel down (window + buffer). The tree and the session list (if
--- up) re-settle to the pre-panel layout — the same thirds rule
--- (U.calibrate_sidebar) — their pinned heights held through the teardown.
function M.close()
  if M.active() then
    local tw, lw = U.tree_window(), U.window_with_filetype('claude-sessions-panel')
    pcall(vim.api.nvim_win_close, M.win, true)
    U.calibrate_sidebar(tw, lw)
  end
  if U.valid_buf(M.buf) then
    vim.api.nvim_buf_delete(M.buf, { force = true })
  end
  M.win, M.buf = nil, nil
  last_text, last_row, last_files, panel_root = nil, nil, nil, nil
  review_started = false -- the sweep ended with the panel
  diff_view.close() -- the right-side pane dies with the panel
end

--- The split itself, out of open()'s root lookup: the root and the tree
--- window are known, and the workspace has changes. Runs inside the status
--- job's callback (scheduled).
local function open_split(root, tw)
  local buf = U.scratch_buffer('claude-sessions-diff')
  set_keymaps(buf)
  -- The sidebar is exact thirds (tree → this panel → session list). Seed the
  -- split with a plain third of the screen; the calibration below asserts
  -- the exact distribution from the stack's own (conserved) row sum.
  local height = math.max(1, math.floor(vim.o.lines / 3))
  -- Focus: this runs SCHEDULED — by the time it does, the callers'
  -- synchronous focus handoffs are long done — and the split below the tree
  -- steals the cursor from them. Remember whoever holds it right before
  -- anchoring and hand it back once the split has landed.
  local prev_focus = vim.api.nvim_get_current_win()
  -- `below` the tree: the split lands directly below it — between the tree
  -- and the session-list panel below it, in every (re)open order.
  vim.api.nvim_set_current_win(tw)
  vim.cmd('below ' .. height .. 'split')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].winfixheight = true -- the tree's options and layout churn must not resize it
  U.plain_text_window(win)
  -- The window can go away mid-race (a window churn) — focus the tree then,
  -- since the panel split directly below it.
  U.focus(prev_focus, tw)
  -- One calibration for the whole stack: this panel's rows, the tree's
  -- remainder, the session list (if up) included.
  U.calibrate_sidebar(tw, win, U.window_with_filetype('claude-sessions-panel'))

  M.buf, M.win = buf, win
  panel_root = root
  opening = false -- the split landed: active() reads true
  M.refresh()

  -- The window can also go away on its own; the full teardown runs here —
  -- WinClosed fires while the window is still valid, so the tree/list
  -- re-settle is calibrated at the actual close event.
  vim.api.nvim_create_autocmd('WinClosed', { buffer = buf, callback = function() M.close() end })
end

--- The split decision, out of open()'s root lookup: the root is known (or
--- known to be absent), the workspace probe decides. `opening` still holds
--- through here — cleared on every path below.
local function open_probe(root)
  if not root then -- no repo, nothing to show
    opening = false
    return
  end
  -- The tree can close while the root job is in flight.
  local tw = U.tree_window()
  if not tw then
    opening = false
    return
  end
  -- A clean workspace draws no diff panel: probe before splitting. The
  -- status job is nested — `opening` is cleared in its callback and the next
  -- open() re-probes.
  fetch_status(root, function(rows)
    if #(rows or {}) == 0 then
      opening = false -- clean workspace: no diff panel
      return
    end
    open_split(root, tw)
  end)
end

--- (Re)open the panel below the nvim-tree window. No-op without a tree or a
--- git repo — or when the workspace is CLEAN: nothing changed, so no diff
--- panel is drawn at all. Each open() re-runs the status probe, so the panel
--- appears the moment the first change lands. Already open (or a split in
--- flight) → no-op: refresh owns the rows.
---
--- The split happens inside the `git rev-parse` callback (scheduled), and
--- M.win lands only AFTER the split — so two open() calls one settle queues
--- both read active() == false and BOTH split. A split in flight is
--- remembered synchronously (`opening`, declared in the state section above):
--- the second open() becomes a no-op.
-- The repo root, cached per cwd: open() ran a rev-parse job per call (the
-- poll loop's one per fetch cadence while the panel is down) and the root
-- never changes for a cwd — a `cd` is the only thing that invalidates it, and
-- that lands synchronously where the cache is re-read.
local cached_root, cached_cwd = nil, nil
function M.open()
  if M.active() or opening then
    return -- up, or a split in flight: the poll loop / refresh owns the rows
  end
  opening = true
  local cwd = (vim.uv or vim.loop).cwd()
  if cached_cwd == cwd then
    open_probe(cached_root)
    return
  end
  git(cwd, { 'rev-parse', '--show-toplevel' }, function(out)
    local root = out and vim.trim(out) or nil
    cached_cwd, cached_root = cwd, root
    open_probe(root)
  end)
end

--- Follow the session panel's visibility: open while a session window is
--- displayed, closed when none is. One hook for the two wiring halves (the
--- panel sync, the tree's FileType) — the open decision is here, so the
--- callers spell one call instead of an if on is_visible.
function M.sync(visible)
  if visible then
    M.open() -- a no-op when already up; refresh owns the rows
  else
    M.close()
  end
end

--- Highlights on setup and on every colorscheme change. The focus-flip
--- autocmds are setup state, not open() state: they are GLOBAL — wiring them
--- in open() would pair them up on every open. The singleton pair here queues
--- focus_panel on every switch; focus_panel's own gates stand in for
--- anything per-open to forget.
function M.setup()
  define_highlights()
  vim.api.nvim_create_autocmd('ColorScheme', { callback = define_highlights })
  vim.api.nvim_create_autocmd('WinEnter', { pattern = '*', callback = focus_panel })
  vim.api.nvim_create_autocmd('WinLeave', { pattern = '*', callback = focus_panel })
end

return M
