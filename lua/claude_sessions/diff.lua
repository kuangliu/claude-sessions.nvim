-- The diff panel of the tree sidebar: split `below` the nvim-tree window, so
-- it sits between the tree and the session-list panel (which splits below the
-- tree as well). It tracks files modified but not committed: three lines
-- per file —
--   ' aa.py'          (the basename only — directories dropped)
--   '   +37 -58  ▪▪▪▪▪▪□□□□□'
--   ''
-- the name on the first row (default text color), the counts and a bar of
-- solid blocks on the second
-- (`+37` in green, `-58` in red; the bar sized by the change — green for
-- added, red for removed, split proportionally; untracked files show `??`
-- in yellow with no bar). Data comes from `git diff --numstat HEAD` (staged +
-- unstaged) and `git status --porcelain` (untracked), each on a job, so
-- refreshes never block the editor.
--
-- Lifecycle mirrors the session-list panel: opened while a session window is
-- displayed and an nvim-tree window exists to split below; closed when the
-- tree or the last displayed session closes. A CLEAN workspace draws no panel
-- at all: open() splits only when `git status` reports changes, and a refresh
-- that finds none closes it again — the tree and the session list take the
-- rows back (see calibrate_sidebar). The panel is read-only.
--
-- Selection IS focus, like the session-list panel's: the file the panel
-- window's cursor rests on draws the two-line block background (that panel's
-- ClaudeSessionsPanelCursor group) while the panel holds focus, and the block
-- clears the moment focus moves away (WinLeave's repaint — focus_panel).
-- j/k move the cursor onto an entry's name line, with the block landing
-- there in the same keystroke.

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

-- How many added/removed lines a full-width bar of blocks represents; a
-- file's bar is min(change / BAR_SCALE, 1) of the width. 100 ≈ a typical
-- edit, so everyday files fill most of the bar.
local BAR_SCALE = 100
local BAR_BLOCKS = 12 -- blocks in a full-width bar

local in_flight = false -- a refresh's two probes are running; don't queue more

--- Is the panel window (still) up? The poll loop gates on this — no panel,
--- no git jobs.
function M.active()
  return M.win ~= nil and vim.api.nvim_win_is_valid(M.win)
end

--- The file the panel cursor selects: the window cursor's entry, one-based,
--- or nil (no panel, or the panel LACKS focus — an unfocused panel draws no
--- selection block; the cursor is the raw editor cursor, and where focus went
--- is none of this panel's business). The rows are three-line groups (name /
--- counts / blank) in the SAME shape the session panel renders, so its
--- mapping applies: any line — a name, a counts row, or the blank below it —
--- attributes to the entry it belongs to with floor((line + 2) / 3), clamped
--- to the live count (a cursor left on a row the last render dropped must not
--- select past the list). The block is drawn on this entry per repaint, so
--- focusing the panel is what selects a file — and unfocusing it is what
--- clears the block (focus_panel's own repaint).
local function cursor_row()
  if not (M.active() and M.buf and vim.api.nvim_buf_is_valid(M.buf)) then return nil end
  -- Focus gate: the block reads as the editor cursor's position — an editor
  -- cursor parked elsewhere is no selection, like a cursorline on an
  -- unfocused window (nvim clears its own cursorline on WinLeave for the
  -- same read).
  if vim.api.nvim_get_current_win() ~= M.win then return nil end
  local count = vim.api.nvim_buf_line_count(M.buf)
  if count == 0 then return nil end
  local line = vim.api.nvim_win_get_cursor(M.win)[1]
  return math.min(math.max(math.floor((line + 2) / 3), 1),
    math.max(math.floor(count / 3), 1))
end

--- The window currently showing nvim-tree's buffer, or nil. (Current tabpage
--- only: `nvim_list_wins` crosses tabs, and a sibling panel's window on
--- another tab must never be mistaken for this tab's.)
local function tree_window()
  return U.window_with_filetype('NvimTree')
end

--- The window showing the session-list panel's buffer, or nil. `below`-split
--- from the TREE keeps the diff rows between the tree and that panel in every
--- (re)open order (verified: an nvim-side `below split` from the tree inserts
--- directly below it), so this lookup feeds the height calibration — and it
--- is scoped to the current tabpage for the same reason tree_window is.
local function session_list_window()
  return U.window_with_filetype('claude-sessions-panel')
end

--- Calibrate the sidebar stack to thirds. NO restack — wincmd J moves the
--- current window to the bottom of the full-width FRAME, not its own column,
--- so in a real session (the session terminal in a column on the right) it
--- pulls the sidebar windows across full width and wrecks the layout. The
--- order is already correct by construction: every split is `below`-anchored
--- (panel.open() anchors below this panel when it is up, this panel splits
--- below the tree), so the stack lands tree → diff → session list on its own.
--- Windows that are not up (a panel still to open) are skipped — their own
--- open() calibrates the full stack.
---
--- The rule for any stack size: every window but the first takes
--- floor(rows / 3); the first (the tree) takes the remainder — the stack's
--- largest share, never crushed. The rows are read from the stack itself: a
--- column's window heights span the frame rows, so the sum is conserved
--- across the assertions, and rows derived from o.lines can disagree with
--- the stack whenever cmdline/frame churn shifted them. A win_set_height
--- redistributes within the stack (the nearest neighbour pays first), so
--- the assertions are ITERATED until exact, then the windows are repinned.
local function calibrate_sidebar(...)
  local up = {}
  for _, w in ipairs({ ... }) do
    if w and vim.api.nvim_win_is_valid(w) then up[#up + 1] = w end
  end
  if #up == 0 then return end
  -- Unpin: the heights are asserted below, and a pinned window can't hold.
  for _, w in ipairs(up) do
    vim.wo[w].winfixheight = false
  end
  local rows = 0
  for _, w in ipairs(up) do
    rows = rows + vim.api.nvim_win_get_height(w)
  end
  local panels = #up - 1
  local third = panels > 0 and math.max(1, math.floor(rows / 3)) or 0
  local targets = {}
  for i, w in ipairs(up) do
    targets[w] = (i == 1) and (rows - panels * third) or third
  end
  -- Iterate: assert every window to its target, re-read, repeat until exact
  -- (each pass's redistribution lands closer; the leftovers correct on the
  -- next). Capped so a stack that won't converge (a window clamped at min 1)
  -- still repins.
  for _ = 1, 8 do
    local exact = true
    for _, w in ipairs(up) do
      if vim.api.nvim_win_get_height(w) ~= targets[w] then
        vim.api.nvim_win_set_height(w, targets[w])
        exact = false
      end
    end
    if exact then break end
  end
  for _, w in ipairs(up) do
    vim.wo[w].winfixheight = true
  end
end

--- Run a git command on a job and hand its stdout (a string) to `cb` when it
--- exits with code 0, else nil. Non-blocking; the callback lands scheduled.
--- `args` is the argument list after `-C <root>` (e.g. { 'diff', '--numstat', 'HEAD' }).
local function git(root, args, cb)
  local stdout = {}
  local cmd = vim.list_extend({ 'git', '-C', root }, args)
  local ok, job_id = pcall(vim.fn.jobstart, cmd, {
    stdout_buffered = true,
    -- Chunks arrive as lines with the newlines dropped; join them back so a
    -- multi-row output (one numstat row per file) parses one row per line.
    on_stdout = function(_, data)
      if data then vim.list_extend(stdout, data) end
    end,
    on_exit = function(_, code)
      local out = code == 0 and table.concat(stdout, '\n') or nil
      vim.schedule(function() cb(out) end)
    end,
  })
  -- jobstart throws on a bad spec and returns the error string; a failed
  -- spawn (git gone from PATH, jobstart returning 0/-1) just shows empty.
  if not ok or type(job_id) ~= 'number' or job_id <= 0 then
    vim.schedule(function() cb(nil) end)
  end
end

--- The changes `git diff --numstat HEAD` reports, keyed by path: rows are
--- `add<TAB>del<TAB>path`, both counts `-` on unmerged paths (skipped).
local function fetch_numstat(root, cb)
  git(root, { 'diff', '--numstat', 'HEAD' }, function(out)
    local files = {}
    if out then
      for _, row in ipairs(vim.split(out, '\n', { trimempty = true })) do
        local add, del, path = row:match('^(%d+)%s+(%d+)%s+(.+)$')
        -- Renames arrive mangled ('old => new'); the new path is shown.
        if path and path:match('=>') then
          path = path:match('=> (.+)$') or path
        end
        if path then
          files[#files + 1] = {
            path = path,
            add = tonumber(add),
            del = tonumber(del),
          }
        end
      end
    end
    cb(files)
  end)
end

--- All porcelain status rows of `root` (`--untracked-files=all`), one string
--- per line, or nil on exit ~= 0. Shared by open()'s clean-workspace probe
--- (which only needs "any rows?") and refresh()'s untracked probe (which
--- matches the `?? ` rows) — one wrapper, one place for the command to grow.
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

--- The bar for a file: `g` green blocks then `r` red ones, sized by the
--- change relative to BAR_SCALE, split proportionally between the colors.
--- Any change shows at least one block; no change shows none. The block is
--- `▪` (a small box, BAR_BLOCK) — single display column like every rune the
--- panel draws.
local BAR_BLOCK = '▪'
local function bar(add, del)
  local change = add + del
  if change == 0 then return '', '' end
  local n = math.floor(math.min(change / BAR_SCALE, 1) * BAR_BLOCKS + 0.5)
  if n == 0 then n = 1 end
  local g = del == 0 and n or math.floor(n * add / change + 0.5)
  return string.rep(BAR_BLOCK, g), string.rep(BAR_BLOCK, n - g)
end

--- Three lines per file, and the extmarks that color the pieces of them: the
--- name on the first row (default text color — no mark), the counts and the
--- bar blocks on the second (indented under the name; one green mark, one red
--- for the counts, one each for the bar), then a blank separator below the
--- entry. All columns are byte offsets of their row; rows advance by three
--- per file, so row `i` of file `k` is `(k-1)*3 + i`.
local RENDER_INDENT = '  '
-- Skip-identical state: the last rendered text (see render's coalesce below).
-- Its own binding, NOT a field on render — a function value spells fields on
-- whatever upvalue the closure happens to capture, and this smoke test proved
-- one mis-capture (close() indexed an unrelated render upvalue) tears the
-- whole coalesce down.
local last_text = nil
-- The line the last render drew the selection block on: the coalesce's other
-- half — rows byte-identical but the cursor moved between same-shaped entries
-- must still repaint (the block lands on the new entry; see render).
local last_row = nil
-- The rows the last refresh rendered: focus_panel's repaint re-renders them
-- (the block lands where the cursor went / nothing where it left) without
-- re-running the two git probes — a focus flip must not pay for two jobs.
local last_files = nil
local function render(buf, files)
  local lines = {}
  local marks = {}
  -- The file the cursor selects, derived once per repaint: the block follows
  -- the raw window cursor, and the FOCUS gate inside cursor_row is what makes
  -- a focus flip select a file / clear the block.
  local row = cursor_row()
  local lnum = 0 -- buffer row, zero-based — advances three per file
  -- Render constants, hoisted: the two rows spell the SAME
  -- `' ' .. RENDER_INDENT` prefix (both align at column COUNTS_COL, the
  -- offset every mark below assumes), and the two-count gap is one space.
  local COUNTS_COL = 1 + #RENDER_INDENT
  -- The selection block is a plain row mark, and a plain row mark stops at
  -- the row's own end — pad both rows of the SELECTED entry to the window's
  -- width so the block reads full-width (the session panel pads its own rows
  -- for the same block). Width re-read per render: the sidebar can resize
  -- between renders. Padding arithmetic is RUNE count, not `#` — the bar's
  -- `▪` blocks are 3 bytes apiece and one display column each (the session
  -- panel's rune_len for the same reason), and extmark columns are byte
  -- offsets, so the block's span needs the BYTE length of the padded row —
  -- spelled from the rune count + the pad's own bytes.
  local width = M.active() and vim.api.nvim_win_get_width(M.win) or 80
  local pad_row = function()
    local runes = vim.fn.strcharlen(lines[#lines])
    local pad = math.max(width - runes, 0)
    lines[#lines] = lines[#lines] .. string.rep(' ', pad)
  end
  for i, f in ipairs(files) do
    -- First row: the file's NAME only (the basename — the directories of the
    -- path are dropped), indented like the counts below it — the same one
    -- leading space plus RENDER_INDENT, so both rows align at column
    -- `1 + #RENDER_INDENT`. Default text color; no extmark.
    local name = f.path:match('[^/]+$') or f.path
    lines[#lines + 1] = ' ' .. RENDER_INDENT .. name
    lnum = lnum + 1
    if row == i then pad_row() end

    -- Second row: the counts and the bar, indented under the name — the SAME
    -- one leading space plus RENDER_INDENT (both rows align at COUNTS_COL).
    add_str, del_str = ('+%d'):format(f.add or 0), ('-%d'):format(f.del or 0)
    local counts = f.untracked and '??' or (add_str .. ' ' .. del_str)
    lines[#lines + 1] = ' ' .. RENDER_INDENT .. counts
    if not f.untracked then
      marks[#marks + 1] = {
        lnum = lnum, col = COUNTS_COL, end_col = COUNTS_COL + #add_str, hl = ADD_HL,
      }
      marks[#marks + 1] = {
        lnum = lnum, col = COUNTS_COL + #add_str + 1,
        end_col = COUNTS_COL + #add_str + 1 + #del_str, hl = DEL_HL,
      }
    else
      marks[#marks + 1] = {
        lnum = lnum, col = COUNTS_COL, end_col = COUNTS_COL + 2, hl = UNTR_HL,
      }
    end
    -- The bar trails the counts on the same row. Untracked files show none.
    if not f.untracked then
      local g, r = bar(f.add, f.del)
      local bar_col = COUNTS_COL + #counts + 2
      -- The bar's gap: the same two spaces the named RENDER_INDENT spells,
      -- unnamed here — one literal, spelled with the indent it aligns with.
      lines[#lines] = lines[#lines] .. '  ' .. g .. r
      if #g > 0 then
        marks[#marks + 1] = {
          lnum = lnum, col = bar_col, end_col = bar_col + #g, hl = ADD_HL,
        }
      end
      if #r > 0 then
        marks[#marks + 1] = {
          lnum = lnum, col = bar_col + #g, end_col = bar_col + #g + #r, hl = DEL_HL,
        }
      end
    end
    -- Second row of the SELECTED entry: pad AFTER the bar's own marks (they
    -- read byte offsets up to the bar's end — padding past them is safe).
    if row == i then pad_row() end
    -- The SELECTED entry's block background: one row mark per row, spanning
    -- the padded full width (`col = 0` → the row's own BYTE length — the
    -- pad_row above already spelled it, and extmark columns are byte offsets,
    -- so `#` is the exact span). Two marks, NOT one spanning mark — rows
    -- advance by three per file, so a row-pair block is two single-row marks.
    if row == i then
      marks[#marks + 1] = { lnum = lnum - 1, col = 0, end_col = #lines[#lines - 1], hl = CURSOR_HL }
      marks[#marks + 1] = { lnum = lnum, col = 0, end_col = #lines[#lines], hl = CURSOR_HL }
    end
    lnum = lnum + 1

    -- A blank separator line below every entry — like the session-list panel
    -- below (its rows read symbol+name / state word / blank), so the diff
    -- rows read name / counts / blank. A trailing one too: it never shows,
    -- and dropping it per-entry costs a modulo in a hot-ish loop.
    lines[#lines + 1] = ''
    lnum = lnum + 1
  end
  -- Skip-identical: the poll loop refreshes per tick while the panel is up,
  -- and the usual result is rows byte-identical to the last (the agent writes
  -- every few seconds, not every 300ms). Coalesce the rewrite — set_lines
  -- marks every row changed and invalidates the window for a full redraw —
  -- when the fresh rows spell the same text. A cursor move never coalesces
  -- here: the pad_row above spells the selected entry's rows differently from
  -- its unselected spell, so a move changes the text — EXCEPT a move within
  -- same-shaped entries (two files with byte-identical rows spell the same
  -- padded text), which is fine to coalesce: the marks replay from the fresh
  -- `row` either way.
  local text = table.concat(lines, '\n')
  if text == (last_text or '') then
    -- Rows byte-identical but the cursor moved between same-shaped entries:
    -- the block must still land on the new entry. Repaint the marks only.
    if last_row ~= row then
      last_row = row
      U.set_rows(M.buf, ns, lines, marks)
    end
    return
  end
  last_text = text
  last_row = row
  -- util's rewrite helper — the session panel's render lands the same way.
  U.set_rows(buf, ns, lines, marks)
end

--- Move the panel cursor `d` entries (j: +1, k: −1), clamped to the live row
--- count. A move from the first entry starts at the first (j) or last (k).
--- The move lands on the entry's NAME line (the block's top row — the same
--- rule the session panel's step applies), and the repaint below draws the
--- block on the new entry in the same keystroke: the block follows the raw
--- cursor, so moving the cursor IS the selection.
local function move_cursor(d)
  if not M.active() then return end
  local count = vim.api.nvim_buf_line_count(M.buf)
  local n = math.max(math.floor(count / 3), 0)
  if n == 0 then return end
  local row = cursor_row()
  row = row == nil and (d > 0 and 1 or n) or math.min(math.max(row + d, 1), n)
  pcall(vim.api.nvim_win_set_cursor, M.win, { 3 * row - 2, 0 })
  M.refresh()
end

--- j/k: move the panel cursor. The panel is read-only; these are the only
--- functional maps on its buffer — the editing keys are silenced first
--- (util's shared list) so these win, and everything else keeps its default.
--- NOT silenced: <C-a> — the global mapping creates a session, and that must
--- work with the cursor on this panel too.
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

--- Repaint the rows through a FOCUS flip: focus arrived (the block lands on
--- the cursor's entry) or focus left (cursor_row's focus gate nils the
--- selection, and the unpadded rows clear it). Re-renders the remembered rows
--- — no git jobs on a focus flip — and coalesces when the fresh spell is
--- byte-identical to the last (a flip within same-shaped entries), since the
--- marks replay from the fresh `row` either way.
---
--- The repaint lands ONE PASS LATER, not inside the event: the WinLeave/
--- WinEnter pair dispatches out of order (the leave can arrive after the
--- enter of a round-trip — verified through wincmd), so a gate read inside
--- either event sees whoever was current at dispatch, not where focus
--- settled. A pass later every event has dispatched and the current-window
--- read inside cursor_row is settled — the settled read IS the final state.
--- A flip queues at most one repaint (the flag), so held-key window sweeps
--- pay one render, not one per window crossed.
local repaint_scheduled = false
local function focus_panel()
  if repaint_scheduled then return end
  repaint_scheduled = true
  vim.schedule(function()
    repaint_scheduled = false
    if not (M.active() and last_files and M.buf and vim.api.nvim_buf_is_valid(M.buf)) then
      return
    end
    render(M.buf, last_files)
  end)
end

--- Fetch the current diff and repaint the panel. No-op when the panel is
--- gone (no window, no git jobs) — the poll loop calls this per tick. A
--- refresh that finds NO changes closes the panel again (the workspace went
--- clean while it was up): the tree and the session list take the rows back,
--- and the next open() (a change, a session) re-probes.
---
--- The two probes run concurrently (numstat needs the root, status doesn't,
--- so they are independent jobs) and join — the status rows land nested, so
--- one shared `fetch_status` is extracted (open()'s pre-probe and the
--- refresh's untracked probe were two separate status jobs of the same
--- shape). One refresh runs at a time (`in_flight`): the poll loop can call
--- refresh while a previous one's probes are still in flight, and queuing
--- more just lands stale rows out of order.
function M.refresh()
  if not (M.active() and M.root and not in_flight) then return end
  in_flight = true
  local root = M.root
  local done, files, untracked_rows = 0, {}, nil
  local function join()
    done = done + 1
    if done < 2 then return end
    in_flight = false
    -- The panel can close while the jobs are in flight.
    if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then return end
    for _, row in ipairs(untracked_rows or {}) do
      local path = row:match('^%?%? (.+)$')
      if path then files[#files + 1] = { path = path, untracked = true } end
    end
    if #files == 0 then
      M.close() -- workspace went clean: drop the panel
      return
    end
    -- Remember the live rows: focus_panel's repaint re-renders them without
    -- re-running the two git probes (a focus flip must not pay for two jobs).
    last_files = files
    render(M.buf, files)
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

-- Tear the panel down (window + buffer). The tree and the session list (if
-- up) re-settle to the pre-panel layout — the same thirds rule, asserted by
-- calibrate_sidebar — their pinned heights held through the teardown and
-- nvim left the freed rows empty below the sidebar.
function M.close()
  if M.active() then
    local tw, lw = tree_window(), session_list_window()
    pcall(vim.api.nvim_win_close, M.win, true)
    calibrate_sidebar(tw, lw)
  end
  if M.buf and vim.api.nvim_buf_is_valid(M.buf) then
    vim.api.nvim_buf_delete(M.buf, { force = true })
  end
  M.win, M.buf = nil, nil
  M.root = nil -- the next open() re-runs rev-parse; no stale root for refresh
  last_text = nil -- the next open() renders into a fresh buffer
  last_files = nil -- focus_panel's repaint has no rows to re-render either
  last_row = nil
end

--- (Re)open the panel below the nvim-tree window and repaint the rows. No-op
--- without a tree or a git repo — or when the workspace is CLEAN: nothing
--- changed, so no diff panel is drawn at all and the sidebar stays tree +
--- session list. Each open() re-runs the status probe, so the panel appears
--- the moment the first change lands. Already open → refresh only.
---
--- The split happens inside the `git rev-parse` callback (scheduled), and
--- M.win lands only AFTER the split — so the two open() calls one settle
--- queues (panel_sync's diff_sync, then show_session's own) both read
--- active() == false and BOTH split: the stack ends with two diff windows
--- (tree → diff → diff → list, the wrecked sidebar). A split in flight is
--- remembered synchronously: the second open() becomes a no-op.
local opening = false
--- The split itself, out of open()'s callback: the root and the tree window
--- are known, and the workspace has changes. Runs inside the status job's
--- callback (scheduled) — the same focus/calibration comments apply below.
local function open_split(root, tw)
  local buf = U.scratch_buffer('claude-sessions-diff')
  -- Panel keymaps land on the buffer — j/k move the cursor (the selection
  -- follows it), and nothing else is functional on this read-only text.
  set_keymaps(buf)
  -- The sidebar is exact thirds (tree → this panel → session list). Seed the
  -- split with a plain third of the screen — the frame's cmdline/statusline/
  -- tabline rows only shift the seed, and calibrate_sidebar below asserts the
  -- exact distribution from the stack's own (conserved) row sum, so nothing
  -- intermediate is observable.
  local height = math.max(1, math.floor(vim.o.lines / 3))
  -- Focus: this runs SCHEDULED — by the time it does, the callers'
  -- synchronous focus handoffs are long done (usually focus on the
  -- just-opened session's terminal) — and the split below the tree steals
  -- the cursor from them. Remember whoever holds it right before anchoring
  -- and hand it back once the split has landed; leaving it on the new panel
  -- window is what parked the cursor on the sidebar after every session
  -- open.
  local prev_focus = vim.api.nvim_get_current_win()
  -- `below` the tree: the split lands directly below it — between the tree
  -- and the session-list panel below it, in every (re)open order — so the
  -- sidebar reads tree → diff → session list.
  vim.api.nvim_set_current_win(tw)
  vim.cmd('below ' .. height .. 'split')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  -- Keep the height pinned: the tree's own window options and later layout
  -- churn must not resize the panel. (The exact rows are asserted below.)
  vim.wo[win].winfixheight = true
  -- The split below the tree inherits the tree window's options; the panel
  -- is plain text (util.plain_text_window) — nothing decorates its edges.
  U.plain_text_window(win)
  -- The cursor was handed to the new split; give it back to whoever held it
  -- before the anchor (usually the session terminal). It may have gone away
  -- in the meantime (a window churn race) — focus the tree then, since the
  -- panel split directly below it.
  if vim.api.nvim_win_is_valid(prev_focus) then
    vim.api.nvim_set_current_win(prev_focus)
  else
    pcall(vim.api.nvim_set_current_win, tw)
  end
  -- One calibration for the whole stack: this panel's rows, the tree's
  -- remainder, all pinned — the session list (if up) is included.
  calibrate_sidebar(tw, win, session_list_window())

  M.buf, M.win, M.root = buf, win, root
  opening = false -- the split landed: M.win is set, active() reads true
  M.refresh()

  -- The window can also go away on its own; forget it so the next open()
  -- rebuilds cleanly.
  vim.api.nvim_create_autocmd('WinClosed', {
    buffer = buf,
    -- The window went away on its own (a user layout edit, the tree closing):
    -- the full teardown reaches its active() branch HERE — WinClosed fires
    -- while the window is still valid (see claude_sessions.lua's session
    -- handler) — so the tree/list re-settle is calibrated at the actual close
    -- event, and no defensive close() is needed at the next open().
    callback = function() M.close() end,
  })
end

function M.open()
  if M.active() or opening then
    M.refresh()
    return
  end
  opening = true
  local cwd = (vim.uv or vim.loop).cwd()
  git(cwd, { 'rev-parse', '--show-toplevel' }, function(out)
    local root = out and vim.trim(out) or nil
    if not root then -- no repo, nothing to show
      opening = false
      return
    end
    -- The tree can close while the root job is in flight.
    local tw = tree_window()
    if not tw then
      opening = false
      return
    end
    -- A clean workspace draws no diff panel: probe before splitting. The
    -- status job is nested — its callback lands after this one returned, so
    -- `opening` is cleared there and the next open() re-probes.
    fetch_status(root, function(rows)
      if rows == nil or #rows == 0 then
        opening = false -- clean workspace: no diff panel
        return
      end
      open_split(root, tw)
    end)
  end)
end

--- Follow the session panel's visibility: open while a session window is
--- displayed, closed when none is. One hook for the two wiring halves (the
--- panel sync, the tree's FileType) — the open decision is here, so the
--- callers spell one call instead of an if on is_visible.
function M.sync(visible)
  if visible then
    M.open() -- open() refreshes when already up
  else
    M.close()
  end
end

--- Highlights on setup and on every colorscheme change, like the session
--- panel's groups.
---
--- The focus-flip autocmds are setup state, not open() state: they are
--- GLOBAL (pattern `*`, see focus_panel's comment) — wiring them in open()
--- would pair them up on every open (the panel can close and re-open any
--- number of times). The singleton pair here queues focus_panel on every
--- switch; focus_panel's own gates (the active/last_files checks inside the
--- scheduled pass) stand in for anything per-open to forget.
function M.setup()
  define_highlights()
  vim.api.nvim_create_autocmd('ColorScheme', { callback = define_highlights })
  vim.api.nvim_create_autocmd('WinEnter', { pattern = '*', callback = focus_panel })
  vim.api.nvim_create_autocmd('WinLeave', { pattern = '*', callback = focus_panel })
end

return M
