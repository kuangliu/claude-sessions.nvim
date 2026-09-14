-- The diff panel of the tree sidebar: split below the nvim-tree window
-- (between the tree and the session panel), tracking files modified but not
-- committed. Three lines per file — name, counts + a sized bar (green/red;
-- `??` yellow for untracked), blank — fed by `git diff --numstat HEAD` and
-- `git status --porcelain` on jobs, so refreshes never block.
--
-- Lifecycle mirrors the session panel: up while a session window is displayed
-- and a tree window exists; closed when the tree or the last displayed session
-- closes. A CLEAN workspace draws no panel at all (open() probes before
-- splitting; a clean refresh closes it again).
--
-- Selection is a PIN, not focus: the entry last landed on (an explicit j/k or
-- <C-e>, or a focus arrival) draws the block background and renders its
-- working-tree-vs-HEAD diff in the pane (diff_view.lua). Both stand when the
-- cursor moves OUT of the panel; the panel's opening never selects.

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
local BAR_BLOCK = '▪' -- single display column, 3 bytes (count columns, not bytes)

-- Both rendered rows share the same one-space + indent prefix, so they align
-- at column `1 + #RENDER_INDENT` — the offset every counts/bar mark assumes.
local RENDER_INDENT = '  '

local in_flight = false -- a refresh's two probes are running; don't queue more

-- A split in flight: open() latches it synchronously so two open() calls one
-- settle queues don't BOTH split (see M.open). Declared here, ABOVE
-- open_split/open_probe — Lua locals aren't visible before their declaration;
-- below them these writes would bind to a global and the latch would never
-- clear (the panel would never reopen).
local opening = false

-- The repo root the panel was opened for: private state of the last open()
-- (the callers of refresh spell no root). The root never changes for a cwd,
-- so no invalidation beyond close().
local panel_root = nil

-- The rows the last refresh rendered: repaints replay them without re-running
-- the two git probes.
local last_files = nil

-- Whether the review sweep has started. The raw cursor can't tell "never
-- selected" (it sits on entry 1's name line from birth) from "selected entry
-- 1", hence the flag. Only land() flips it on; M.close clears it.
local review_started = false

-- Skip-identical state: the last render's TEXT and SELECTION row. Either
-- half changing means a repaint is due.
local last_text = nil
local last_row = nil

--- Is the panel window (still) up? The poll loop gates on this — no panel,
--- no git jobs.
function M.active()
  return U.valid_win(M.win)
end

--- The entry the RAW panel cursor rests on (1-based, clamped to the live
--- rows), or nil. No sweep gate — the read a focus ARRIVAL needs (the birth
--- state is exactly what an arrival selects).
local function raw_cursor_row()
  if not (M.active() and U.valid_buf(M.buf)) then return nil end
  local count = vim.api.nvim_buf_line_count(M.buf)
  if count == 0 then return nil end
  local line = vim.api.nvim_win_get_cursor(M.win)[1]
  return math.min(math.max(U.line_entry(line), 1),
    math.max(U.entry_count(count), 1))
end

--- The selected entry: raw_cursor_row behind the sweep flag, nil until the
--- sweep started — gates the reads that must not CREATE a selection (render's
--- block, a departure's re-show).
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
--- row. Renames arrive mangled ('old => new'); the old name rides along as
--- `renamed_from` — the discard needs it, or restoring only the new name
--- would leave the source behind as a staged deletion.
local function fetch_numstat(root, cb)
  git(root, { 'diff', '--numstat', 'HEAD' }, function(out)
    local files = {}
    for _, row in ipairs(out and vim.split(out, '\n', { trimempty = true }) or {}) do
      local add, del, path = row:match('^(%d+)%s+(%d+)%s+(.+)$')
      local renamed_from
      if path and path:match('=>') then
        renamed_from = path:match('^(.+) => ') -- the old side of a full rename
        path = path:match('=> (.+)$') or path
      end
      if path then
        files[#files + 1] = {
          path = path, add = tonumber(add), del = tonumber(del), renamed_from = renamed_from,
        }
      end
    end
    cb(files)
  end)
end

--- All porcelain status rows of `root`, one string per line, or nil on
--- failure. Shared by open()'s clean-workspace probe and refresh()'s
--- untracked probe.
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
--- relative to BAR_SCALE and split proportionally. Any change shows at least
--- one block.
local function bar(add, del)
  local change = add + del
  if change == 0 then return '', '' end
  local n = math.floor(math.min(change / BAR_SCALE, 1) * BAR_BLOCKS + 0.5)
  if n == 0 then n = 1 end
  local g = del == 0 and n or math.floor(n * add / change + 0.5)
  return string.rep(BAR_BLOCK, g), string.rep(BAR_BLOCK, n - g)
end

--- Render the files as three rows per entry, the selected entry's two rows
--- padded full-width so its block background spans them. Extmark columns are
--- BYTE offsets; the pad arithmetic is display-column count.
local function render(files)
  local lines, marks = {}, {}
  -- The block follows the raw cursor through focus flips (the pin), but the
  -- flag gate means no selection before the sweep starts — birth state spells
  -- no block and no pane.
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
  -- Skip-identical: the poll loop's per-tick refresh usually finds rows
  -- byte-identical to the last — coalesce the rewrite (set_lines marks every
  -- row changed and invalidates the window).
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

--- Land the selection on entry `row`: cursor, repaint, and the file's diff in
--- the pane. The one place the sweep-start flag flips on.
local function land(row)
  review_started = true
  pcall(vim.api.nvim_win_set_cursor, M.win, { U.entry_line(row), 0 })
  -- The zero-job repaint (remembered rows): a keystroke spawns no git jobs.
  if last_files then render(last_files) end
  -- The file the cursor just landed on IS the selection: its diff renders in
  -- the pane in the same keystroke (a no-op without diffview).
  select_pane(row_file(row))
end

--- Move the selection `d` entries, clamped to the live row count — or
--- wrapped (`wrap`, <C-e>'s cycle). A move from no selection starts at the
--- first (j) or last (k).
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

--- <C-e>: focus the panel and select the next changed file, wrapping. A
--- SINGLE changed file has nothing to step to — the press toggles the diff
--- pane instead (mirroring <C-s>'s single-session window toggle).
function M.step_next()
  if not M.active() then
    U.notify('No diff panel: nothing to step through.', vim.log.levels.WARN)
    return
  end
  if U.entry_count(vim.api.nvim_buf_line_count(M.buf)) == 1 then
    if diff_view.active() then
      diff_view.close()
    else
      land(1)
    end
    return
  end
  -- The focus move is for visibility and handing the panel j/k; a refused one
  -- still steps — the selection is a pin, not a focus read.
  U.focus(M.win)
  move_cursor(1, true)
end

--- The focus flip: an arrival ON the panel is a SELECTION — land() the entry
--- under the cursor (a dismissed pane re-opens; coming back to the file list
--- means the user wants its diff back). An arrival anywhere else stands down
--- — the pin holds and a dismissed pane stays dismissed. No flip ever closes
--- the pane. The pass lands ONE PASS LATER: the WinLeave/WinEnter pair
--- dispatches out of order, so a gate read inside either event sees whoever
--- was current at dispatch. A flip queues at most one pass (the flag).
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

--- Shared tail of every working-tree change (the panel's <C-d>, the pane's
--- d/u/D): reload open buffers (checktime skips dirty ones), re-probe the
--- rows, and let a live pane follow the pin.
function M.reprobe()
  vim.cmd('checktime')
  M.refresh(function()
    if diff_view.active() then select_pane(row_file(raw_cursor_row())) end
  end)
end

--- Classify `path` into the spec the discard needs, off one full status scan.
--- A pathspec-filtered status would not do: it spells a staged rename as a
--- plain `A` and loses the old side the discard must restore.
local function classify_file(root, path, done)
  fetch_status(root, function(rows)
    local row, renamed_from
    local rename_pat = '^R%s+(.-) -> ' .. vim.pesc(path) .. '$'
    for _, l in ipairs(rows or {}) do
      local old = l:match(rename_pat)
      if old then
        row, renamed_from = l, old
        break
      end
      if l:sub(4) == path then
        row = l
        break
      end
    end
    done({
      path = path,
      untracked = (row and row:sub(1, 2) == '??') or false,
      renamed_from = renamed_from,
    })
  end)
end

--- Discard every uncommitted change of `spec` ({ path, untracked,
--- renamed_from? }) under `root`, after a y/N prompt (only a typed y
--- discards), then `done()`. Tracked in HEAD: checkout. Staged as new:
--- `git rm -f` (checkout has no HEAD copy to take). Untracked: deleted. A
--- rename restores the old name too, or the source would survive as a staged
--- deletion.
function M.discard_file(root, spec, done)
  local answer = vim.fn.input(('Revert file %s? y/N: '):format(spec.path))
  if not answer:lower():find('^y') then return end

  if spec.untracked then
    local ok = (vim.uv or vim.loop).fs_unlink(root .. '/' .. spec.path)
    if not ok then
      U.notify('Could not delete ' .. spec.path, vim.log.levels.ERROR)
      return
    end
    return done()
  end

  -- Not in HEAD (a staged new file): checkout has nothing to take, the rm IS
  -- the reset. A failed checkout reports and still settles — the rows
  -- re-probe show whatever actually happened.
  local name = spec.path:match('[^/]+$') or spec.path
  local function reset_new_side()
    git(root, { 'rm', '-f', '--', spec.path }, function(out)
      if out == nil then
        U.notify('Could not discard ' .. name, vim.log.levels.ERROR)
      end
      done()
    end)
  end
  local function checkout_new_side(then_)
    git(root, { 'checkout', 'HEAD', '--', spec.path }, function(out)
      if out ~= nil then return done() end
      then_()
    end)
  end
  -- The rename's old name first, so the rows never re-probe a half-done
  -- discard.
  if spec.renamed_from then
    git(root, { 'checkout', 'HEAD', '--', spec.renamed_from }, function()
      checkout_new_side(reset_new_side)
    end)
  else
    checkout_new_side(reset_new_side)
  end
end

--- The diff pane's D entry: it knows only the path (no row record), so
--- classify first, then the same prompted discard.
function M.discard_path(root, path, done)
  classify_file(root, path, function(spec)
    M.discard_file(root, spec, done)
  end)
end

--- Stage everything and commit with `message`, both on jobs. `done(err)`
--- lands scheduled: nil on success, else which step failed.
function M.commit_all(root, message, done)
  git(root, { 'add', '--all' }, function(out)
    if out == nil then return done('git add failed') end
    git(root, { 'commit', '-m', message }, function(out)
      if out == nil then return done('git commit failed') end
      done(nil)
    end)
  end)
end

--- <C-d>: discard the file under the cursor; the shared tail re-probes.
local function discard_current()
  local file = row_file(raw_cursor_row())
  if not file then return end
  M.discard_file(panel_root, file, M.reprobe)
end

--- j/k move the selection; <CR>/l open the diff in the pane; <C-d> discards.
local function set_keymaps(buf)
  U.silence_editing_keys(buf)
  local function move(d)
    return function() move_cursor(d) end
  end
  U.map_key(buf, 'j', move(1), 'next file')
  U.map_key(buf, 'k', move(-1), 'previous file')
  U.map_key(buf, '<Down>', move(1), 'next file')
  U.map_key(buf, '<Up>', move(-1), 'previous file')

  -- <CR>/l: open the file under the cursor in the pane and FOCUS the pane,
  -- where its keymaps (]]/[[, <CR>, q) take over.
  local function open_pane()
    local row = raw_cursor_row()
    if not row then return end
    land(row)
    U.focus(diff_view.win)
  end
  U.map_key(buf, '<CR>', open_pane, 'open diff in pane')
  U.map_key(buf, 'l', open_pane, 'open diff in pane')
  U.map_key(buf, '<C-d>', discard_current, 'discard file changes')
end

--- Fetch the current diff and repaint. A refresh that finds no changes
--- closes the panel (the workspace went clean). One refresh runs at a time —
--- queuing more would land stale rows out of order. `then_` runs after a
--- join that rendered rows, never after the clean close.
function M.refresh(then_)
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
    -- The rewrite can SHRINK the list and the window cursor clamps onto a
    -- counts or separator line — re-anchor onto the clamped entry's name
    -- line (the session panel's refresh spells the same snap-back).
    local row = raw_cursor_row()
    if row then
      pcall(vim.api.nvim_win_set_cursor, M.win, { U.entry_line(row), 0 })
    end
    if then_ then then_() end
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

--- Tear the panel down (window + buffer); the sidebar re-settles to thirds.
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

--- The split itself (root and tree window known, workspace dirty). Runs
--- inside the status job's callback (scheduled).
local function open_split(root, tw)
  local buf = U.scratch_buffer('claude-sessions-diff')
  set_keymaps(buf)
  -- Seed the split with a plain third; the calibration below asserts the
  -- exact thirds distribution from the stack's own row sum.
  local height = math.max(1, math.floor(vim.o.lines / 3))
  -- The scheduled split steals focus from the callers' long-done handoffs —
  -- remember whoever holds it and hand it back once the split lands.
  local prev_focus = vim.api.nvim_get_current_win()
  -- `below` the tree: the split lands directly below it, in every (re)open
  -- order.
  vim.api.nvim_set_current_win(tw)
  vim.cmd('below ' .. height .. 'split')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].winfixheight = true -- the tree's options and layout churn must not resize it
  U.plain_text_window(win)
  -- The window can go away mid-race — focus the tree then.
  U.focus(prev_focus, tw)
  -- One calibration for the whole stack: tree, this panel, session list.
  U.calibrate_sidebar(tw, win, U.window_with_filetype('claude-sessions-panel'))

  M.buf, M.win = buf, win
  panel_root = root
  opening = false -- the split landed: active() reads true
  M.refresh()

  -- The window can also go away on its own; the full teardown runs here.
  vim.api.nvim_create_autocmd('WinClosed', { buffer = buf, callback = function() M.close() end })
end

--- The split decision: the root is known, the workspace probe decides.
--- `opening` holds through here — cleared on every path below.
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
  -- A clean workspace draws no diff panel: probe before splitting.
  fetch_status(root, function(rows)
    if #(rows or {}) == 0 then
      opening = false -- clean workspace: no diff panel
      return
    end
    open_split(root, tw)
  end)
end

--- (Re)open the panel below the tree window. No-op without a tree, a git
--- repo, or workspace changes — each open() re-runs the status probe, so the
--- panel appears the moment the first change lands. Already open (or a split
--- in flight, `opening`) → no-op: refresh owns the rows.
-- The repo root, cached per cwd (a `cd` is the only invalidation).
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

--- Follow visibility: open while a session window is displayed, closed when
--- none is.
function M.sync(visible)
  if visible then
    M.open() -- a no-op when already up; refresh owns the rows
  else
    M.close()
  end
end

--- Highlights on setup and every colorscheme change. The focus-flip autocmds
--- are GLOBAL setup state (wiring them in open() would pair them per open).
function M.setup()
  define_highlights()
  vim.api.nvim_create_autocmd('ColorScheme', { callback = define_highlights })
  vim.api.nvim_create_autocmd('WinEnter', { pattern = '*', callback = focus_panel })
  vim.api.nvim_create_autocmd('WinLeave', { pattern = '*', callback = focus_panel })
end

return M
