-- The diff pane: when the sidebar diff panel selects a file (an explicit j/k
-- or <C-e> — the panel's opening never selects), the file's
-- working-tree-vs-HEAD diff is rendered here via diffview.nvim's engine — the
-- same GitHub-style unified view (full-file, word-diffed, treesitter-lifted,
-- gitsigns gutter bars, hunk navigation) — and it edits: d reverts the
-- cursor line's change (u undoes), D reverts the whole file, c commits.
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
-- The pane's last render target, { abspath, root }: a show() of the same pair
-- while the pane is up skips the engine pipeline — the focus-flip arrival pass
-- re-selects the landed entry on every flip, and a step can land a file the
-- pane already shows. Two git spawns, a working-file read and a two-sided
-- treesitter parse are too heavy to run twice per keystroke.
local last_target = nil

-- Soft dependency: the engine modules, or nil when diffview.nvim is not
-- installed. Resolved once; every entry gates on it.
local ok, render, git
ok, render = pcall(require, 'diffview.render')
if ok then
  git = require('diffview.git')
end

--- Is the pane window (still) up? The gate for every entry here, and the one
--- read diff.lua's focus pass makes: a focus flip may only re-render a LIVE
--- pane — a dismissal (the q keymap, a manual window close) must not be
--- resurrected by one; only an explicit selection (j/k, <C-e>) shows the
--- pane again.
function M.active()
  return U.valid_win(M.win)
end

-- The pane's look: util's plain-text look, plus the signcolumn the
-- gitsigns-style add/del bars draw in. One table spells the whole look —
-- plain_diff_window applies it, and the take-over captures/restores exactly
-- these keys, so the pane's look can never leak onto the user's window.
local PANE_LOOK = U.plain_look({ signcolumn = 'yes:1' })

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
-- shows (bufhidden=hide), so its birth state lives here — the keymaps, and
-- the one WinClosed that forgets/rehomes when the pane window dies on its own
-- (per pane buffer, not per show: per-show would stack one autocmd per reopen
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
  vim.cmd('edit ' .. vim.fn.fnameescape(abspath))
  if target then
    vim.api.nvim_win_set_cursor(0, { target, 0 })
  end
end

--------------------------------------------------------------------------
-- working-tree edits (d / u), whole-file revert (D), commit (c)
--------------------------------------------------------------------------
-- Migrated from diffview's actions: the view rows carry the old/new line
-- numbers the edits need — a d on an added row deletes that line from the
-- working file, on a removed row it restores the line into it (exact for
-- end-of-file deletions and del runs behind add hunks), each edit is pushed
-- on the buffer's undo stack for u, D reverts the whole shown file through
-- the diff panel's discard machinery, and c stages everything and commits —
-- the review is of the whole workspace, so the commit is too. The rows are
-- the view's source of truth; the working file is the edits': a stale view
-- (the file changed underneath) refuses the edit rather than guessing.

-- Bound by diff.lua at load: the panel owns the rows and the git discard,
-- the pane calls back after its edits so the rows re-probe (and a clean
-- workspace takes the whole review down).
M.discard_file = nil
M.reprobe = nil

--- The file the pane shows, resolved for the edits: `rel` (repo-relative, as
--- the rows carry it), `root`, and `path` (absolute — the working file). Nil
--- when no live target.
local function edit_target()
  if not (M.active() and last_target) then return nil end
  return {
    rel = last_target.abspath,
    root = last_target.root,
    path = last_target.root .. '/' .. last_target.abspath,
  }
end

-- Join edited lines back into file content. `trailing` keeps the file's own
-- trailing newline; `add_newline` appends one (a restored line landing at the
-- END of a file that lacks one inherits it from the HEAD side, so the revert
-- shows as complete instead of a lone newline diff).
local function join_lines(ls, trailing, add_newline)
  local out = table.concat(ls, '\n')
  if (trailing or add_newline) and #ls > 0 then out = out .. '\n' end
  return out
end

-- Write `content` to the working file; nil means the pre-edit file was absent
-- (a deleted file being restored, or reverted to absent again), so remove it.
-- Returns false after notifying when the filesystem call fails.
local function write_working_file(abspath, content)
  if content == nil then
    local ok, err = os.remove(abspath)
    if not ok then
      U.notify('diff pane: cannot remove ' .. abspath .. ': ' .. tostring(err),
        vim.log.levels.ERROR)
    end
    return ok
  end
  local f, err = io.open(abspath, 'wb')
  if not f then
    U.notify('diff pane: cannot write ' .. abspath .. ': ' .. tostring(err),
      vim.log.levels.ERROR)
    return false
  end
  f:write(content)
  f:close()
  return true
end

-- Reload open, unmodified buffers of the edited file so the edit shows up in
-- the editor too. Buffers with unsaved changes are left alone.
local function reload_open_buffers(abspath)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and not vim.bo[b].modified
        and vim.api.nvim_buf_get_name(b) == abspath then
      pcall(vim.api.nvim_buf_call, b, function() vim.cmd('edit!') end)
    end
  end
end

-- View-row index (1-based) of the cursor's current line, or nil for headers.
local function cursor_row(buf)
  local offset = vim.b[buf].diffview_offset or 0
  local sline = vim.api.nvim_win_get_cursor(0)[1]
  if sline <= offset then return nil end
  return sline - offset
end

-- Revert an added line: delete it from the working file. Returns the new file
-- content and the undo entry; nil content if the view is stale.
local function revert_add(path, r)
  local new_raw = git.read_file_raw(path)
  local ls = new_raw and git.lines(new_raw) or {}
  local content = r.text:sub(2)
  local trailing_new = new_raw and new_raw:sub(-1) == '\n' or false
  if ls[r.newln] ~= content then return nil, nil end
  table.remove(ls, r.newln)
  local out = join_lines(ls, trailing_new, false)
  local entry = { kind = 'add', pos = r.newln, before = new_raw, after = out }
  return out, entry
end

-- Revert a removed line: restore it into the working file at the new-side
-- position of its old line. The old-side number minus the deleted lines
-- before it, plus the added lines before it (a surviving old line maps to
-- one new line, and an added line also occupies one slot ahead of this line
-- in the new file). Exact for every case — including end-of-file deletions,
-- where vim.diff anchors the hunk at the new side's start, and del runs that
-- follow earlier add hunks.
local function revert_del(path, rows, idx, root, rel)
  local r = rows[idx]
  local new_raw = git.read_file_raw(path)
  local ls = new_raw and git.lines(new_raw) or {}
  local content = r.text:sub(2)
  local trailing_new = new_raw and new_raw:sub(-1) == '\n' or false

  local dels_before, adds_before = 0, 0
  for i = 1, idx - 1 do
    local k = rows[i].kind
    if k == 'del' then dels_before = dels_before + 1
    elseif k == 'add' then adds_before = adds_before + 1 end
  end
  local pos = r.oldln - dels_before + adds_before
  local at_end = pos == #ls + 1

  -- stale-view guard: the new-side line at the insertion point must still
  -- hold the content the view shows
  for _, rr in ipairs(rows) do
    if rr.newln == pos then
      if ls[pos] ~= rr.text:sub(2) then return nil, nil end
      break
    end
  end

  local old_trailing = false
  if at_end and not trailing_new then
    local old_raw = git.git_show_raw(root, 'HEAD:' .. rel)
    old_trailing = old_raw and old_raw:sub(-1) == '\n' or false
  end
  table.insert(ls, pos, content)
  local out = join_lines(ls, trailing_new, at_end and old_trailing)
  local entry = { kind = 'del', pos = pos, old_line = r.oldln, before = new_raw, after = out }
  return out, entry
end

-- Finish a working-tree edit: reload open buffers, re-render the pane from
-- the new working-tree state (forced — the target did not change but its
-- content did), and let the panel re-probe (its counts follow; a clean
-- workspace takes the review down).
local function after_edit(t)
  reload_open_buffers(t.path)
  M.show(t.rel, t.root, true)
  if M.reprobe then M.reprobe(false) end
end

--- d: revert the change on the cursor line — an added line is deleted from
--- the working file, a removed line is restored into it. The edit is written
--- straight to disk (the view's source of truth), the view re-renders and
--- the cursor moves to the next remaining change line. Each edit is pushed
--- onto the buffer's undo stack as before/after content snapshots, so `u`
--- can restore the exact prior state.
function M.revert_line()
  local buf = vim.api.nvim_get_current_buf()
  local t = edit_target()
  if not (t and buf == M.buf) or vim.b[buf].diffview_binary then
    U.notify('diff pane: cannot revert this view', vim.log.levels.WARN)
    return
  end
  local rows = vim.b[buf].diffview_rows
  local idx = cursor_row(buf)
  local r = rows and idx and rows[idx]
  if not r or (r.kind ~= 'add' and r.kind ~= 'del') then
    U.notify('diff pane: not on a changed line', vim.log.levels.WARN)
    return
  end

  local out, entry
  if r.kind == 'add' then
    out, entry = revert_add(t.path, r)
  else
    out, entry = revert_del(t.path, rows, idx, t.root, t.rel)
  end
  if not entry then
    U.notify('diff pane: working file changed; reopen the view', vim.log.levels.WARN)
    return
  end
  if not write_working_file(t.path, out) then return end
  local stack = vim.b[buf].diffview_undo or {}
  stack[#stack + 1] = entry
  vim.b[buf].diffview_undo = stack

  after_edit(t)

  -- land the cursor on the next remaining change line. The re-render keeps
  -- the cursor's line number, so scan forward from there — the row under it
  -- may now hold the rest of the same hunk, which still counts as "next".
  local rows2 = vim.b[buf].diffview_rows
  local off2 = vim.b[buf].diffview_offset or 0
  for i = math.max(vim.api.nvim_win_get_cursor(0)[1], off2 + 1), vim.api.nvim_buf_line_count(buf) do
    local rr = rows2[i - off2]
    if rr and (rr.kind == 'add' or rr.kind == 'del') then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      break
    end
  end
end

--- u: reverse the most recent d. The working file must still match the
--- recorded after-state (otherwise the entry is stale and gets dropped); it
--- is then restored to the exact recorded before-state. The cursor returns
--- to the row the d touched.
function M.undo_revert()
  local buf = vim.api.nvim_get_current_buf()
  local t = edit_target()
  if not (t and buf == M.buf) then
    U.notify('diff pane: cannot revert this view', vim.log.levels.WARN)
    return
  end
  local stack = vim.b[buf].diffview_undo or {}
  local entry = stack[#stack]
  if not entry then
    U.notify('diff pane: nothing to undo', vim.log.levels.INFO)
    return
  end
  if git.read_file_raw(t.path) ~= entry.after then
    table.remove(stack, #stack)
    vim.b[buf].diffview_undo = stack -- vim.b values are copies; write back
    U.notify('diff pane: working file changed; skipping undo', vim.log.levels.WARN)
    return
  end
  if not write_working_file(t.path, entry.before) then return end
  table.remove(stack, #stack)
  vim.b[buf].diffview_undo = stack -- vim.b values are copies; write back

  after_edit(t)

  -- return the cursor to the reverted line: an added line is back as a
  -- context row carrying its new-side number; a removed line is a del row
  -- again under its old-side number.
  local rows = vim.b[buf].diffview_rows
  local offset = vim.b[buf].diffview_offset or 0
  local target
  for i, r in ipairs(rows) do
    if entry.kind == 'add' then
      if r.newln == entry.pos then target = i; break end
    else
      if r.kind == 'del' and r.oldln == entry.old_line then target = i; break end
    end
  end
  if target then
    vim.api.nvim_win_set_cursor(0, { offset + target, 0 })
  end
end

--- D: revert the whole shown file — the diff panel's <C-d> machinery on the
--- pane's target (the hook classifies what the row record would have said),
--- with the same tail: buffers reload, the rows re-probe, and the pin hands
--- a live pane the cursor's next file — or the clean workspace closes the
--- review. Asks first: a whole-file revert is a bigger swing than a line
--- edit, and the y/N prompt spells the default — only a typed y reverts;
--- Enter (or anything else) is a No.
function M.revert_file()
  local buf = vim.api.nvim_get_current_buf()
  local t = edit_target()
  if not (t and buf == M.buf) or not M.discard_file then
    U.notify('diff pane: cannot revert this view', vim.log.levels.WARN)
    return
  end
  local answer = vim.fn.input(('Revert file %s? y/N: '):format(t.rel))
  if not answer:lower():find('^y') then return end
  M.discard_file(t.root, { path = t.rel }, M.reprobe)
end

--- c: prompt for a commit message, stage everything and commit. The review
--- is of the whole workspace, so the commit is too (diffview's spelling).
--- The re-probe on the landing closes the review when the commit emptied it.
function M.commit_changes()
  local t = edit_target()
  if not (t and git) then return end
  vim.ui.input({ prompt = 'Commit message: ' }, function(input)
    if input == nil then return end -- cancelled
    local message = vim.trim(input)
    if message == '' then
      U.notify('diff pane: commit message cannot be empty', vim.log.levels.WARN)
      return
    end
    local _, err = git.commit_all(t.root, message)
    if err then
      U.notify('diff pane: ' .. err, vim.log.levels.ERROR)
      return
    end
    U.notify('diff pane: committed changes')
    if M.reprobe then M.reprobe(false) end
  end)
end

-- The pane's keymaps: q closes it, ]]/[[ jump hunks, <CR> opens the source,
-- d/u revert (and undo the revert of) the cursor line, D reverts the whole
-- file, c commits.
local function set_keymaps(buf)
  vim.keymap.set('n', ']]', function() jump_hunk(1) end,
    { buffer = buf, nowait = true, silent = true, desc = 'claude sessions: next change' })
  vim.keymap.set('n', '[[', function() jump_hunk(-1) end,
    { buffer = buf, nowait = true, silent = true, desc = 'claude sessions: prev change' })
  vim.keymap.set('n', '<CR>', jump_to_source,
    { buffer = buf, nowait = true, silent = true, desc = 'claude sessions: open source' })
  vim.keymap.set('n', 'd', function() M.revert_line() end,
    { buffer = buf, nowait = true, silent = true, desc = 'claude sessions: revert line' })
  vim.keymap.set('n', 'u', function() M.undo_revert() end,
    { buffer = buf, nowait = true, silent = true, desc = 'claude sessions: undo revert' })
  vim.keymap.set('n', 'D', function() M.revert_file() end,
    { buffer = buf, nowait = true, silent = true, desc = 'claude sessions: revert file' })
  vim.keymap.set('n', 'c', function() M.commit_changes() end,
    { buffer = buf, nowait = true, silent = true, desc = 'claude sessions: commit changes' })
end

--- The editor window the pane takes over: a real (non-floating) window whose
--- buffer is a NORMAL one — no terminal, no qf/help, nothing of the sessions
--- layout. The LARGEST such window wins: the main editor area, when several
--- code windows share the row. Nil when the screen holds nothing but the
--- sessions layout.
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
--- one beside the session terminal, seeded at the terminal's own width
--- (`columns * 0.4`, the sessions config's vertical size), so the pane and
--- the terminal read as one pair.
local function show_window(buf)
  if M.active() then
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
    -- terminal's pinned width are untouched.
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
    -- Host for the split: a displayed session window keeps the pane beside
    -- the terminal — BETWEEN the tree and the terminal (the sidebar's file
    -- list reading straight into its diff), not the far right the global
    -- `splitright` would put it. `splitright = false` while the split lands
    -- puts the pane on the terminal's left; the one-split flip is restored
    -- before anything else can read it. No session on screen: plain vsplit
    -- from where we are.
    local host = U.window_with_filetype('claude')
    local prev = vim.api.nvim_get_current_win()
    U.focus(host)
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
--- across calls, so stepping files re-renders in place. `force` re-renders a
--- same target — the working-tree edits (d/u) changed what the diff shows,
--- and a fresh render must not be skipped for being "already there".
function M.show(abspath, root, force)
  if not (ok and render and git and abspath and root) then return end
  -- Same-target skip: the pane already shows this file's diff — a focus
  -- arrival re-selects the landed entry on every flip, and a step lands a
  -- file the pane may already be showing (a wrapped cycle revisits file
  -- one). The skip leaves the pane (and its cursor) exactly as this show
  -- would have; `force` (a working-tree edit) bypasses it.
  local same_target = M.active() and last_target ~= nil
    and last_target.abspath == abspath and last_target.root == root
  if same_target and not force then
    return
  end
  -- The render can flip focus twice (the split path's host move and
  -- hand-back); the diff panel's focus-flip pass sees those as
  -- arrivals/departures, but neither half holds a state to flip — the panel's
  -- selection is pinned and a departure spells no close — so the flip pair
  -- lands a repaint either way and stands.
  last_target = { abspath = abspath, root = root }
  local rel = git.relpath(root, abspath)

  local old_raw = git.git_show_raw(root, 'HEAD:' .. rel) -- nil for untracked files
  local new_raw = git.read_file_raw(root .. '/' .. rel) -- nil for deleted files
  local rows, counts
  if git.is_binary(root, rel, root .. '/' .. rel) then
    rows = { render.row('Binary file differs (not shown)', 'del', nil, 1) }
    counts = { add = 0, del = 1 }
  else
    rows, counts = render.build_view(old_raw, new_raw)
    rows = render.collapse_context(rows)
  end

  local buf = M.buf
  if not U.valid_buf(buf) then
    buf = create_buf()
    set_keymaps(buf)
    M.buf = buf
  end
  render.render(buf, root .. '/' .. rel, rel, rows, counts)
  -- treesitter lifting reads raw content again; spell the sides once more
  render.apply_treesitter(buf, root .. '/' .. rel, rows, old_raw, new_raw)
  show_window(buf)

  -- Land the cursor on the first change (the header's end runs into it), so
  -- the pane opens on the file's edits rather than its top. Fresh selections
  -- only: a forced re-render (a d/u edit) keeps the working position — the
  -- edit's own cursor logic decides where the cursor goes.
  if same_target then return end
  vim.schedule(function()
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
  if not M.replaced and M.active() then
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
