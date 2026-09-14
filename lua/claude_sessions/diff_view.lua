-- The diff pane: when the sidebar diff panel selects a file (an explicit j/k
-- or <C-e> — the panel's opening never selects), the file's
-- working-tree-vs-HEAD diff is rendered here via diffview.nvim's engine —
-- the same GitHub-style unified view (full-file, word-diffed,
-- treesitter-lifted, gitsigns gutter bars, hunk navigation) — and it edits:
-- d reverts the cursor line's change (u undoes), D reverts the whole file, c
-- commits.
--
-- The adapter owns only the plumbing: resolve the HEAD and working copies,
-- build the view rows, paint them into a scratch buffer, and show it
-- diffview-style — the pane TAKES OVER the editor window (buffer, cursor and
-- window options remembered; restored exactly on exit), falling back to a
-- vsplit beside the session terminal only when no editor window exists.
-- diffview stays a soft dependency: with it absent show() is a no-op.

local U = require('claude_sessions.util')

local M = {}

M.win = nil
M.buf = nil
-- The editor window the pane took over, as { buf, cursor, opts }. Nil when
-- the pane lives in its own split.
M.replaced = nil

-- Bound by claude_sessions.lua's wiring section (the panel/module pattern):
-- discard_path(root, path, done) runs the prompted whole-file discard (D);
-- commit(root, message, done) stages and commits (c); reprobe() is the tail
-- every edit lands in.
M.discard_path = nil
M.commit = nil
M.reprobe = nil

-- The pane's last render target, { rel, root }: a show() of the same pair
-- while the pane is up skips the engine pipeline — two git spawns and a
-- two-sided treesitter parse are too heavy to run twice per keystroke.
local last_target = nil

-- Soft dependency: the engine modules, or nil when diffview.nvim is not
-- installed. Resolved once; every entry gates on it.
local ok, render, git
ok, render = pcall(require, 'diffview.render')
if ok then
  git = require('diffview.git')
end

--- Is the pane window (still) up? The gate for every entry here — a focus
--- flip may only re-render a LIVE pane (a dismissal must not be resurrected);
--- only an explicit selection shows the pane again.
function M.active()
  return U.valid_win(M.win)
end

-- The pane's look: util's plain-text look plus the signcolumn the add/del
-- bars draw in. One table — the take-over captures/restores exactly these
-- keys, so the pane's look never leaks onto the user's window.
local PANE_LOOK = U.plain_look({ signcolumn = 'yes:1' })

local function plain_diff_window(win)
  U.apply_winopts(win, PANE_LOOK)
end

--- Hand the taken-over editor window back. `win` invalid (a manual :close):
--- open the buffer in a fresh split anchored on the tree. Clears M.replaced
--- either way; no-op when nothing was taken over.
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
--- back — one spelling of the teardown, shared by the WinClosed pass and
--- M.close.
local function release(win)
  M.win = nil
  restore_replaced(win)
end

-- Build the view buffer once: a named nofile scratch in diffview's shape
-- (the b-vars render.render writes are what the hunk-jump scan reads). The
-- buffer survives across shows (bufhidden=hide), so its birth state lives
-- here — the keymaps, and the one WinClosed (per pane buffer, not per show).

-- A row carrying a content change — added or removed. The hunk jumps and the
-- d edit key on this.
local function change_row(r)
  return r and (r.kind == 'add' or r.kind == 'del') or false
end

local function create_buf()
  local buf = U.scratch_buffer('diffview')
  pcall(vim.api.nvim_buf_set_name, buf, 'claude-sessions://' .. buf)
  vim.keymap.set('n', 'q', function() M.close() end,
    { buffer = buf, nowait = true, silent = true, desc = 'claude sessions: close diff pane' })
  vim.api.nvim_create_autocmd('WinClosed', {
    buffer = buf,
    callback = function() release(nil) end,
  })
  return buf
end

--- Jump to the next/previous change hunk (]]/[[) — a contiguous run of
--- add/del rows, read off the pane's own buffer.
local function jump_hunk(d)
  local buf = vim.api.nvim_get_current_buf()
  local rows = vim.b[buf].diffview_rows
  local offset = vim.b[buf].diffview_offset or 0
  local total = vim.api.nvim_buf_line_count(buf)
  local function is_change(i)
    return change_row(rows and i > 0 and rows[i])
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
--- new-side line (removed rows have none — the nearest earlier line stands
--- in). The pane's WINDOW stays; the next selection re-renders over the
--- file.
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
-- numbers the edits need — d on an added row deletes that line from the
-- working file, on a removed row it restores the line into it, each edit is
-- pushed on the undo stack for u, D reverts the whole shown file through the
-- diff panel's discard machinery, and c stages everything and commits. The
-- rows are the view's source of truth; the working file is the edits': a
-- stale view (the file changed underneath) refuses the edit rather than
-- guessing.

-- The d edits' undo stack — module-local on purpose: each entry holds two
-- whole-file snapshots, and a vim.b stack would deep-copy them through VimL
-- on every push. Depth-capped; dies with the review (M.close).
local undo_stack = {}
local UNDO_DEPTH = 20

--- The file the pane shows, resolved for the edits: `rel` (repo-relative),
--- `root`, and `path` (absolute). Nil when no live target.
local function edit_target()
  if not (M.active() and last_target) then return nil end
  return {
    rel = last_target.rel,
    root = last_target.root,
    path = last_target.root .. '/' .. last_target.rel,
  }
end

-- Join edited lines back into file content, re-appending the newline a file
-- with a trailing newline owns.
local function join_lines(ls, want_newline)
  local out = table.concat(ls, '\n')
  if want_newline and #ls > 0 then out = out .. '\n' end
  return out
end

-- Write `content` to the working file; nil means the pre-edit file was
-- absent, so remove it. Returns false after notifying on failure.
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

-- The working file as the edits see it: lines, the row's content with the
-- render's sign char stripped, and whether the file ends with a newline.
local function read_working(path, r)
  local raw = git.read_file_raw(path)
  return raw and git.lines(raw) or {}, r.text:sub(2),
    raw and raw:sub(-1) == '\n' or false, raw
end

-- View-row index (1-based) of the cursor's current line, or nil for headers.
local function cursor_row(buf)
  local offset = vim.b[buf].diffview_offset or 0
  local sline = vim.api.nvim_win_get_cursor(0)[1]
  if sline <= offset then return nil end
  return sline - offset
end

-- Revert an added line: delete it from the working file. Returns the new
-- content and the undo entry; nil content if the view is stale.
local function revert_add(t, r)
  local ls, content, trailing_new, raw = read_working(t.path, r)
  if ls[r.newln] ~= content then return nil, nil end
  table.remove(ls, r.newln)
  local out = join_lines(ls, trailing_new)
  return out, { kind = 'add', pos = r.newln, before = raw, after = out }
end

-- Revert a removed line: restore it into the working file at the new-side
-- position of its old line (old-side number minus deleted lines before it,
-- plus added lines before it). Exact for end-of-file deletions and del runs
-- that follow earlier add hunks.
local function revert_del(t, rows, idx)
  local r = rows[idx]
  local ls, content, trailing_new, raw = read_working(t.path, r)

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

  -- a restored line landing at the END of a file that lacks a trailing
  -- newline inherits one from the HEAD side, so the revert shows complete.
  local old_trailing = false
  if at_end and not trailing_new then
    local old_raw = git.git_show_raw(t.root, 'HEAD:' .. t.rel)
    old_trailing = old_raw and old_raw:sub(-1) == '\n' or false
  end
  table.insert(ls, pos, content)
  local out = join_lines(ls, trailing_new or (at_end and old_trailing))
  return out, { kind = 'del', pos = pos, old_line = r.oldln, before = raw, after = out }
end

-- Finish a working-tree edit: re-probe (checktime reloads open buffers),
-- then a FORCED re-render — the target did not change but its content did.
local function after_edit(t)
  M.reprobe()
  M.show(t.rel, t.root, true)
end

--- d: revert the change on the cursor line — added deleted from the working
--- file, removed restored into it. Each edit pushes before/after content
--- snapshots onto the undo stack for `u`.
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
  if not change_row(r) then
    U.notify('diff pane: not on a changed line', vim.log.levels.WARN)
    return
  end

  local out, entry
  if r.kind == 'add' then
    out, entry = revert_add(t, r)
  else
    out, entry = revert_del(t, rows, idx)
  end
  if not entry then
    U.notify('diff pane: working file changed; reopen the view', vim.log.levels.WARN)
    return
  end
  if not write_working_file(t.path, out) then return end
  undo_stack[#undo_stack + 1] = entry
  if #undo_stack > UNDO_DEPTH then table.remove(undo_stack, 1) end

  after_edit(t)

  -- land the cursor on the next remaining change line — the row under it may
  -- now hold the rest of the same hunk, which still counts as "next".
  local rows2 = vim.b[buf].diffview_rows
  local off2 = vim.b[buf].diffview_offset or 0
  for i = math.max(vim.api.nvim_win_get_cursor(0)[1], off2 + 1), vim.api.nvim_buf_line_count(buf) do
    if change_row(rows2[i - off2]) then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      break
    end
  end
end

--- u: reverse the most recent d — restore the exact recorded before-state
--- (a stale entry, file moved under the stack, is dropped). The cursor
--- returns to the row the d touched.
function M.undo_revert()
  local buf = vim.api.nvim_get_current_buf()
  local t = edit_target()
  if not (t and buf == M.buf) then
    U.notify('diff pane: cannot revert this view', vim.log.levels.WARN)
    return
  end
  local entry = undo_stack[#undo_stack]
  if not entry then
    U.notify('diff pane: nothing to undo', vim.log.levels.INFO)
    return
  end
  if git.read_file_raw(t.path) ~= entry.after then
    undo_stack[#undo_stack] = nil -- stale: the file moved under the stack
    U.notify('diff pane: working file changed; skipping undo', vim.log.levels.WARN)
    return
  end
  if not write_working_file(t.path, entry.before) then return end
  undo_stack[#undo_stack] = nil

  after_edit(t)

  -- return the cursor to the reverted line: an added line is back as a
  -- context row carrying its new-side number; a removed line is a del row
  -- again under its old-side number.
  local rows = vim.b[buf].diffview_rows
  local offset = vim.b[buf].diffview_offset or 0
  local target
  if entry.kind == 'add' then
    for i, r in ipairs(rows) do
      if r.newln == entry.pos then target = i; break end
    end
  else
    for i, r in ipairs(rows) do
      if r.kind == 'del' and r.oldln == entry.old_line then target = i; break end
    end
  end
  if target then
    vim.api.nvim_win_set_cursor(0, { offset + target, 0 })
  end
end

--- D: revert the whole shown file through the diff panel's discard
--- machinery (classify first: the pane has no row record). The discard
--- prompts its y/N.
function M.revert_file()
  local buf = vim.api.nvim_get_current_buf()
  local t = edit_target()
  if not (t and buf == M.buf) then
    U.notify('diff pane: cannot revert this view', vim.log.levels.WARN)
    return
  end
  M.discard_path(t.root, t.rel, M.reprobe)
end

--- c: prompt for a commit message, stage everything and commit (the review
--- is of the whole workspace, so the commit is too — diffview's spelling).
function M.commit_changes()
  local t = edit_target()
  if not t then return end
  vim.ui.input({ prompt = 'Commit message: ' }, function(input)
    if input == nil then return end -- cancelled
    local message = vim.trim(input)
    if message == '' then
      U.notify('diff pane: commit message cannot be empty', vim.log.levels.WARN)
      return
    end
    M.commit(t.root, message, function(err)
      if err then
        U.notify('diff pane: ' .. err, vim.log.levels.ERROR)
        return
      end
      U.notify('diff pane: committed changes')
      M.reprobe()
    end)
  end)
end

-- The pane's keymaps: q closes it, ]]/[[ jump hunks, <CR> opens the source,
-- d/u revert (and undo), D reverts the file, c commits.
local function set_keymaps(buf)
  U.map_key(buf, ']]', function() jump_hunk(1) end, 'next change')
  U.map_key(buf, '[[', function() jump_hunk(-1) end, 'prev change')
  U.map_key(buf, '<CR>', jump_to_source, 'open source')
  U.map_key(buf, 'd', M.revert_line, 'revert line')
  U.map_key(buf, 'u', M.undo_revert, 'undo revert')
  U.map_key(buf, 'D', M.revert_file, 'revert file')
  U.map_key(buf, 'c', M.commit_changes, 'commit changes')
end

--- The editor window the pane takes over: a real (non-floating) window with
--- a NORMAL buffer (no terminal, no qf/help). The LARGEST such window wins.
--- Nil when the screen holds nothing but the sessions layout.
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

--- Show the pane buffer's window: reuse the pane's own window when up; else
--- TAKE OVER an editor window (captured in M.replaced; release restores);
--- else split one beside the session terminal at the terminal's own width.
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
    -- Host for the split: a displayed session window keeps the pane BETWEEN
    -- the tree and the terminal, not the far right the global `splitright`
    -- would put it — flip splitright off for the one split. No session on
    -- screen: plain vsplit from where we are.
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
  -- One landing for both placements: the pane's buffer, its look, at the
  -- top.
  vim.api.nvim_win_set_buf(win, buf)
  plain_diff_window(win)
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  if handback then
    U.focus(handback) -- hand focus back to whoever held it
  end
  M.win = win
end

--- Render the diff of `rel` against `root` and show it in the pane. No-op
--- without the engine (diffview absent) or a root. Reuses the pane window and
--- buffer across calls, so stepping files re-renders in place. `force`
--- re-renders a same target — the working-tree edits changed what the diff
--- shows.
function M.show(rel, root, force)
  if not (ok and render and git and rel and root) then return end
  -- Same-target skip: the focus-flip arrival pass re-selects the landed
  -- entry on every flip, and a wrapped cycle revisits file one. `force` (a
  -- working-tree edit) bypasses it.
  local same_target = M.active() and last_target ~= nil
    and last_target.rel == rel and last_target.root == root
  if same_target and not force then
    return
  end
  -- The render can flip focus twice (the split path's host move and
  -- hand-back); the diff panel's focus-flip pass lands a repaint either way
  -- and stands — neither half holds a state to flip.
  last_target = { rel = rel, root = root }

  local old_raw = git.git_show_raw(root, 'HEAD:' .. rel) -- nil for untracked files
  local new_raw = git.read_file_raw(root .. '/' .. rel) -- nil for deleted files
  local rows, counts
  -- The binary probe is skipped on a forced re-render: the edit path just
  -- round-tripped the file through text reads and writes.
  if not force and git.is_binary(root, rel, root .. '/' .. rel) then
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

  -- Land the cursor on the first change, so the pane opens on the file's
  -- edits rather than its top. Fresh selections only — a forced re-render
  -- keeps the working position.
  if same_target then return end
  vim.schedule(function()
    if not (U.valid_win(M.win) and U.valid_buf(buf)) then return end
    local rows2 = vim.b[buf].diffview_rows
    local off2 = vim.b[buf].diffview_offset or 0
    for i = 1, #(rows2 or {}) do
      if change_row(rows2[i]) then
        pcall(vim.api.nvim_win_set_cursor, M.win, { off2 + i, 0 })
        return
      end
    end
  end)
end

--- Tear the pane down (window + buffer). A taken-over editor window is NOT
--- closed — it is the user's window: restore gives it back what the
--- take-over found; only the pane's scratch buffer dies.
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
  undo_stack = {} -- the edits' undo entries died with the review
end

return M
