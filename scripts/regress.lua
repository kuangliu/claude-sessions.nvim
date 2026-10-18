-- Headless regression suite for claude-sessions.nvim.
--
-- Run one scenario per process:
--   nvim --headless -u NONE -l scripts/regress.lua <scenario>
--
-- Each scenario stubs toggleterm (vsplit + a real `sleep` termopen job) and
-- drives the plugin through its public API, asserting on windows and
-- buffers. A failed assert prints FAIL and exits nonzero (cq!); a passing
-- one prints "<scenario> OK" and exits 0. The suite covers the display /
-- zoom / shell paths that carry the plugin's load-bearing invariants; the
-- panel render smoke covers the row machinery, and tree-toggle chdirs into a
-- real temp repo so the diff panel's git probes run. Not covered:
-- on_session_exit (the toggleterm stub ignores spec.on_exit) and t-mode
-- keymap callbacks that depend on a live input loop (feedkeys never applies
-- the mode transition inside a -l script).

-- Resolve the repo root from this script's own path (absolute invocation;
-- `vim.fs.abspath` normalizes the relative form `nvim -l scripts/...` yields).
local here = vim.fs.abspath(debug.getinfo(1, 'S').source:sub(2))
local root = vim.fs.dirname(vim.fs.dirname(here))
vim.opt.runtimepath:append(root)

-- A non-git temp cwd: the diff panel's `git rev-parse` probe must not find
-- a repo, so no diff panel ever splits.
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, 'p')
vim.fn.chdir(tmp)

local M = require('claude_sessions')
local U = require('claude_sessions.util')
M.setup({})

-- toggleterm stub: enough Terminal surface for the plugin's display
-- machinery — open (vsplit + real termopen job), close, focus — plus the
-- config get/set pair and ui.hl_term that close_current's window-survived
-- path calls. get_all must return every created terminal: the plugin's
-- close_all_open_windows iterates it to enforce "one displayed session".
local all_terms = {}

-- A window-less job spawn into a fresh buffer — real toggleterm's
-- Terminal:spawn; no toggle_number until a real open runs __set_options.
local function spawn_buf(term)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_call(buf, function()
    vim.fn.termopen('/bin/sh -c "sleep 100000"')
  end)
  term.bufnr = buf
  return buf
end

package.loaded['toggleterm.terminal'] = {
  Terminal = {
    new = function(_, spec)
      local term = {
        cmd = spec.cmd, direction = spec.direction, display_name = '',
        bufnr = nil, window = nil, job_id = 0,
        open = function(self)
          vim.cmd('botright vsplit') -- real toggleterm opens on the far right
          local win = vim.api.nvim_get_current_win()
          if not (self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr)) then
            spawn_buf(self)
            vim.b[self.bufnr].toggle_number = #all_terms + 1 -- real toggleterm: set on open
          end
          vim.api.nvim_win_set_buf(win, self.bufnr)
          self.window = win
        end,
        close = function(self)
          if self.window and vim.api.nvim_win_is_valid(self.window) then
            vim.api.nvim_win_close(self.window, true)
          end
          self.window = nil
        end,
        focus = function(self)
          if self.window and vim.api.nvim_win_is_valid(self.window) then
            vim.api.nvim_set_current_win(self.window)
          end
        end,
        spawn = function(self)
          if not (self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr)) then
            spawn_buf(self)
          end
        end,
      }
      all_terms[#all_terms + 1] = term
      return term
    end,
  },
  get_all = function() return all_terms end,
}
package.loaded['toggleterm.config'] = {
  get = function() return true end,
  set = function() end,
}
package.loaded['toggleterm.ui'] = {
  hl_term = function() end,
}

-- --- Harness -------------------------------------------------------------

local scenario = arg and arg[1] or ''

local function fail(msg)
  print(('%s FAIL: %s'):format(scenario, msg))
  vim.cmd('cq!')
end

local function ok()
  print(('%s OK'):format(scenario))
  vim.cmd('qa!')
end

local function assert_eq(got, want, what)
  if got ~= want then
    fail(('%s: got %s, want %s'):format(what, tostring(got), tostring(want)))
  end
end

local function assert_(cond, what)
  if not cond then fail(what) end
end

local function float_win()
  local win = vim.api.nvim_get_current_win()
  return vim.api.nvim_win_get_config(win).relative ~= '' and win or nil
end

local function sessions(n)
  for _ = 1, n do M.create() end
end

-- A fake nvim-tree window: a scratch buffer with ft NvimTree shown in a new
-- window. `ft_first` emulates nvim-tree's own order — create_buffer() sets
-- the filetype, open_window() creates the window after.
local function open_tree(ft_first)
  local buf = vim.api.nvim_create_buf(false, true)
  if ft_first then vim.bo[buf].filetype = 'NvimTree' end
  vim.cmd('new')
  vim.api.nvim_win_set_buf(0, buf)
  if not ft_first then vim.bo[buf].filetype = 'NvimTree' end
  return buf
end

-- A temp git repo with one committed file and a clean working tree — the
-- diff panel still splits, with its placeholder row.
local function clean_repo()
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, 'p')
  vim.fn.system({ 'git', '-C', repo, 'init', '-q' })
  vim.fn.writefile({ 'one' }, repo .. '/f.txt')
  vim.fn.system({ 'git', '-C', repo, 'add', '.' })
  vim.fn.system({
    'git', '-C', repo, '-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-qm', 'init',
  })
  vim.fn.chdir(repo)
  return repo
end

-- The same repo with one uncommitted change — the diff panel's rows.
local function dirty_repo()
  local repo = clean_repo()
  vim.fn.writefile({ 'one', 'two' }, repo .. '/f.txt')
  return repo
end

-- The sessions layout with a dirty workspace and both panels rendered.
local function open_diff_layout()
  dirty_repo()
  open_tree(false)
  sessions(1)
  local diff = require('claude_sessions.diff')
  assert_(vim.wait(3000, function()
    return diff.active()
      and (vim.api.nvim_buf_get_lines(diff.buf, 0, 1, false)[1] or '') ~= ''
  end, 20), 'diff panel did not render rows')
  return diff
end

-- Close every normal-buffer window: the no-editor state.
local function close_editor_windows()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.bo[b].buftype == '' then vim.api.nvim_win_close(w, true) end
  end
end

-- The editable window (and its buffer) once one appears.
local function wait_editor_slot()
  local slot
  assert_(vim.wait(1000, function()
    slot = U.editor_window()
    return slot ~= nil
  end, 20), 'no editable window')
  return slot, vim.api.nvim_win_get_buf(slot)
end

-- Is `buf` a live session terminal (buftype terminal, not the shell)?
local function is_session_buf(buf)
  return vim.bo[buf].buftype == 'terminal'
    and vim.bo[buf].filetype ~= 'claude-shell'
end

-- The buffers of filetype `ft` shown in this tab's windows.
local function bufs_with_ft(ft)
  local out = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.bo[b].filetype == ft then out[#out + 1] = b end
  end
  return out
end

-- The single-window zoom invariant: no real (non-float) window may show a
-- session terminal while the float is up — two windows on one terminal fight
-- over the pty and the TUI garbles. Reads the plugin's own notion of a real
-- window, so the assertion cannot drift from what the plugin lays out.
local function assert_no_session_splits(tag)
  for _, w in ipairs(U.real_windows()) do
    assert_(not is_session_buf(vim.api.nvim_win_get_buf(w)),
      (tag .. ': a split shows a session terminal alongside the float'))
  end
end

-- --- Scenarios -----------------------------------------------------------

if scenario == 'zoom-cycle' then
  -- Session zoom survives repeated C-s on both switch legs; the float keeps
  -- focus, always shows a session terminal, and no split shows a session
  -- terminal alongside it (the single-window invariant).
  sessions(3)
  M.toggle_zoom()
  local zw = vim.api.nvim_get_current_win()
  for i = 1, 4 do
    M.next_session()
    local b = vim.api.nvim_win_get_buf(zw)
    assert_(is_session_buf(b), ('leg %d: float not on a session terminal'):format(i))
    assert_(vim.api.nvim_get_current_win() == zw, ('leg %d: float lost focus'):format(i))
    assert_no_session_splits(('leg %d'):format(i))
  end
  ok()

elseif scenario == 'zoom-rebuild' then
  -- Zoomed switches leave the session window-less (the float IS the display);
  -- unzoom then rebuilds the window behind the float and lands on it with no
  -- float left up.
  sessions(3)
  M.toggle_zoom()
  M.next_session()
  M.next_session()
  assert_no_session_splits('mid-zoom')
  M.toggle_zoom()
  assert_(float_win() == nil, 'unzoom left the float up')
  assert_(is_session_buf(vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())),
    'unzoom did not land on the rebuilt session window')
  ok()

elseif scenario == 'zoom-create' then
  -- <C-a> while zoomed: the new session is spawned window-less and the float
  -- repoints onto it, focus held; unzoom rebuilds ITS window.
  sessions(1)
  M.toggle_zoom()
  local zw = vim.api.nvim_get_current_win()
  M.create()
  assert_(vim.api.nvim_win_is_valid(zw), 'create while zoomed killed the float')
  assert_(is_session_buf(vim.api.nvim_win_get_buf(zw)),
    'float not on the new session terminal after create')
  assert_(vim.api.nvim_get_current_win() == zw, 'create stole focus from the float')
  assert_no_session_splits('after create')
  M.toggle_zoom()
  assert_(float_win() == nil, 'unzoom after create left the float up')
  assert_(is_session_buf(vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())),
    'unzoom after create did not land on the new session window')
  ok()

elseif scenario == 'shell-zoom-cycle' then
  -- Shell zoom stays on the shell across repeated C-s.
  sessions(3)
  M.toggle_shell()
  M.toggle_zoom()
  local zw = vim.api.nvim_get_current_win()
  for i = 1, 4 do
    M.next_session()
    local b = vim.api.nvim_win_get_buf(zw)
    assert_eq(vim.bo[b].filetype, 'claude-shell', ('leg %d: float not on the shell'):format(i))
    assert_(vim.api.nvim_get_current_win() == zw, ('leg %d: float lost focus'):format(i))
  end
  ok()

elseif scenario == 'plain-cycle' then
  -- No zoom: plain switching never leaves a float up.
  sessions(3)
  for _ = 1, 3 do M.next_session() end
  assert_(float_win() == nil, 'a float is up where none was expected')
  ok()

elseif scenario == 'unzoom-after' then
  -- Unzoom after switches lands on a real window.
  sessions(3)
  M.toggle_shell()
  M.toggle_zoom()
  M.next_session()
  M.next_session()
  M.toggle_zoom()
  assert_(float_win() == nil, 'unzoom did not land on a real window')
  ok()

elseif scenario == 'close-zoomed' then
  -- Zoomed C-d follows onto the successor: a NEW float is up on a terminal,
  -- focus held; unzoom then lands on a real window.
  sessions(3)
  M.toggle_zoom()
  M.close_current()
  local zw = vim.api.nvim_get_current_win()
  assert_eq(vim.api.nvim_win_get_config(zw).relative ~= '', true,
    'no zoom float after zoomed C-d')
  local b = vim.api.nvim_win_get_buf(zw)
  assert_(is_session_buf(b), 'float not on the successor terminal')
  M.toggle_zoom()
  assert_(float_win() == nil, 'unzoom did not land on a real window')
  ok()

elseif scenario == 'close-unzoomed' then
  -- Plain C-d: successor in the split, no float.
  sessions(3)
  M.close_current()
  local b = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
  assert_(is_session_buf(b), 'current window not on a session terminal')
  assert_(float_win() == nil, 'a float is up where none was expected')
  ok()

elseif scenario == 'close-last' then
  -- Closing the last session leaves nothing behind.
  sessions(1)
  M.close_current()
  assert_eq(M.has_sessions(), false, 'has_sessions after closing the last')
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    assert_(vim.bo[b].buftype ~= 'terminal', 'a terminal window survived')
  end
  ok()

elseif scenario == 'shell-toggle' then
  -- C-b open/close/re-open cycles ONE shell; sessions survive the toggles.
  sessions(2)
  M.toggle_shell()
  local first = bufs_with_ft('claude-shell')
  assert_eq(#first, 1, 'shell window count after open')
  M.toggle_shell() -- close from inside the shell
  M.toggle_shell() -- the SAME shell buffer comes back
  local second = bufs_with_ft('claude-shell')
  assert_eq(#second, 1, 'shell window count after re-open')
  assert_eq(second[1], first[1], 're-open spawned a new shell instead of reusing')
  M.toggle_shell()
  assert_(M.has_sessions(), 'sessions lost to shell toggling')
  ok()

elseif scenario == 'shell-zoom-lifecycle' then
  -- The shell's lifecycle under zoom interplay: zoom the shell, C-b takes
  -- only the float down (the shell split survives underneath), the next C-b
  -- closes the shell from inside it, and a third C-b re-opens it — the
  -- shell itself outlives its windows.
  -- (The t-mode <C-d> keymap's shell-vs-session buffer match is not drivable
  -- from a headless -l script — feedkeys never applies the mode transition —
  -- so that branch is covered by inspection: the callback matches
  -- cur_buf == shell_buf before closing the shell, else closes the session.)
  sessions(2)
  M.toggle_shell()
  M.toggle_zoom()
  assert_eq(vim.bo[vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())].filetype,
    'claude-shell', 'float not on the shell before C-b')
  M.toggle_shell() -- zoomed: only takes the float down
  assert_(float_win() == nil, 'C-b while zoomed left the float up')
  assert_eq(#bufs_with_ft('claude-shell'), 1, 'C-b while zoomed disturbed the shell split')
  M.toggle_shell() -- cursor inside the shell: closes it
  assert_eq(#bufs_with_ft('claude-shell'), 0, 'second C-b did not close the shell')
  M.toggle_shell() -- re-opens the SAME shell
  assert_eq(#bufs_with_ft('claude-shell'), 1, 'third C-b did not re-open the shell')
  assert_(M.has_sessions(), 'sessions lost to the shell lifecycle')
  ok()

elseif scenario == 'single-shell-zoom-cycle' then
  -- ONE session, shell zoomed: <C-s> closes the session window underneath
  -- without stealing focus from the float (toggleterm's origin-window restore
  -- must not win), and the next <C-s> reopens onto the same float.
  sessions(1)
  M.toggle_shell()
  M.toggle_zoom()
  local zw = vim.api.nvim_get_current_win()
  M.next_session() -- single-session close branch
  assert_(vim.api.nvim_win_is_valid(zw), 'float gone after single-session close')
  assert_(vim.api.nvim_get_current_win() == zw,
    'focus left the zoom float on single-session close')
  M.next_session() -- reopen branch
  assert_(vim.api.nvim_get_current_win() == zw, 'focus not on the float after reopen')
  assert_eq(vim.bo[vim.api.nvim_win_get_buf(zw)].filetype, 'claude-shell',
    'float lost the shell')
  M.toggle_zoom() -- unzoom lands on a real window
  assert_(float_win() == nil, 'unzoom did not land on a real window')
  ok()

elseif scenario == 'zoomed-cb' then
  -- C-b while zoomed ONLY takes the float down; no shell window appears.
  sessions(2)
  M.toggle_zoom()
  M.toggle_shell()
  assert_(float_win() == nil, 'C-b while zoomed left the float up')
  assert_eq(#bufs_with_ft('claude-shell'), 0, 'C-b while zoomed opened a shell window')
  ok()

elseif scenario == 'panel-smoke' then
  -- A tree window + sessions draw the panel with rows and working maps.
  open_tree(true)
  sessions(2)
  local panel_w = U.window_with_filetype('claude-sessions-panel')
  assert_(panel_w, 'no session panel window')
  local panel_b = vim.api.nvim_win_get_buf(panel_w)
  assert_eq(vim.api.nvim_buf_line_count(panel_b), 6, 'panel line count (2 entries x 3)')
  assert_(vim.fn.maparg('q', 'n', false, panel_b) ~= '', 'panel q map missing')
  assert_(vim.fn.maparg('j', 'n', false, panel_b) ~= '', 'panel j map missing')
  ok()

elseif scenario == 'tree-toggle' then
  -- Closing the tree takes both sidebar panels down with it; reopening the
  -- tree (filetype set BEFORE the window exists, as nvim-tree does) brings
  -- both back.
  dirty_repo()

  local function sidebar()
    return {
      tree = U.window_with_filetype('NvimTree'),
      panel = U.window_with_filetype('claude-sessions-panel'),
      diff = U.window_with_filetype('claude-sessions-diff'),
    }
  end
  local function both_up()
    local s = sidebar()
    return s.tree and s.panel and s.diff
  end

  -- Open the tree, then start a session: both panels attach below it.
  open_tree(false)
  sessions(1)
  assert_(vim.wait(3000, both_up, 20), 'panels did not attach below the open tree')

  -- Toggle closed: no sidebar window may survive, but the right-side diff
  -- pane (the review) stays — the tree closes the sidebar, not the review.
  local diff_view = require('claude_sessions.diff_view')
  local real_close, pane_closes = diff_view.close, 0
  diff_view.close = function()
    pane_closes = pane_closes + 1
    return real_close()
  end
  vim.api.nvim_win_close(sidebar().tree, true)
  local down = vim.wait(1000, function()
    local s = sidebar()
    return not (s.tree or s.panel or s.diff)
  end, 20)
  assert_(down, 'closing the tree left a sidebar panel behind')
  assert_eq(pane_closes, 0, 'closing the tree closed the right-side diff pane')

  -- Toggle open in nvim-tree's own order: filetype first, window second.
  -- The cached repo root reaches the open probe synchronously, so the
  -- deferred sync is what finds the tree window.
  open_tree(true)
  assert_(vim.wait(3000, both_up, 20), 'reopening the tree did not bring the panels back')

  -- A plain close (visibility going away) still takes the pane with it —
  -- exactly once: the teardown does not re-enter itself.
  require('claude_sessions.diff').close()
  assert_eq(pane_closes, 1, 'a plain panel close no longer closes the diff pane')
  diff_view.close = real_close
  ok()

elseif scenario == 'diff-clean-panel' then
  -- The diff panel is part of the sidebar stack even on a clean workspace
  -- (a placeholder row), and it follows the workspace back to dirty and
  -- clean without ever leaving the stack.
  local repo = clean_repo()
  open_tree(false)
  sessions(1)
  local diff = require('claude_sessions.diff')
  local function panel_text()
    return table.concat(vim.api.nvim_buf_get_lines(diff.buf, 0, -1, false), '\n')
  end
  assert_(vim.wait(3000, function() return diff.active() end, 20),
    'the diff panel did not open on a clean workspace')
  assert_(vim.wait(3000, function()
    return panel_text():find('No uncommitted changes', 1, true) ~= nil
  end, 20), 'the clean panel did not render its placeholder')
  assert_(U.window_with_filetype('claude-sessions-panel'), 'the session panel is missing')

  -- A change lands: rows replace the placeholder.
  vim.fn.writefile({ 'one', 'two' }, repo .. '/f.txt')
  assert_(vim.wait(5000, function()
    return panel_text():find('f.txt', 1, true) ~= nil
  end, 20), 'the panel did not pick up the first change')

  -- Clean again: the panel stays up and the placeholder comes back.
  vim.fn.system({ 'git', '-C', repo, 'checkout', '--', 'f.txt' })
  assert_(vim.wait(5000, function()
    return diff.active() and panel_text():find('No uncommitted changes', 1, true) ~= nil
  end, 20), 'the panel dropped or kept stale rows when the workspace went clean')
  ok()

elseif scenario == 'pane-close-slot' then
  -- No editor window: the diff pane lives in its own split. Closing it must
  -- leave an empty, nvim-tree-usable editor slot — otherwise nvim-tree's next
  -- file open splits the TREE window, putting a file inside the sidebar.
  local diff = open_diff_layout()
  local diff_view = require('claude_sessions.diff_view')
  close_editor_windows()

  -- Simulate the pane's fallback split (the diffview engine is not part of
  -- the harness): a nofile scratch in its own window, no taken-over editor.
  local pane_buf = U.scratch_buffer('diffview')
  vim.cmd('vsplit')
  local pane_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(pane_win, pane_buf)
  diff_view.win, diff_view.buf, diff_view.replaced = pane_win, pane_buf, nil

  -- q on the diff file panel (the global :exit map) closes its window.
  vim.api.nvim_win_close(diff.win, true)
  assert_(vim.wait(1000, function()
    return not diff.active() and not diff_view.active()
  end, 20), 'q did not close the panel and pane')

  local _, slot_buf = wait_editor_slot()
  assert_eq(vim.api.nvim_buf_get_name(slot_buf), '', 'the editor slot is not an empty buffer')
  ok()

elseif scenario == 'panel-close-slot' then
  -- Closing the diff panel from outside with NO pane open and no editor
  -- window must still leave an editable window — nvim-tree's next file open
  -- would otherwise split the TREE inside the sidebar column.
  local diff = open_diff_layout()
  close_editor_windows()

  -- q on the diff file panel (the global :exit map).
  vim.api.nvim_win_close(diff.win, true)
  assert_(vim.wait(1000, function() return not diff.active() end, 20), 'q did not close the panel')

  local slot, slot_buf = wait_editor_slot()
  assert_eq(vim.api.nvim_buf_get_name(slot_buf), '', 'editor slot is not an empty buffer')

  -- The slot sits right of the sidebar column, not inside it.
  local panel = U.window_with_filetype('claude-sessions-panel')
  local slot_col = vim.api.nvim_win_get_position(slot)[2]
  local panel_right = vim.api.nvim_win_get_position(panel)[2]
    + vim.api.nvim_win_get_width(panel)
  assert_(slot_col >= panel_right, 'editor slot overlaps the sidebar column')
  ok()

elseif scenario == 'broken-open-repair' then
  -- The safety net: a file window that lands inside the sidebar column (how
  -- nvim-tree opens a file when no editable window exists) is moved out to
  -- the editor column.
  open_diff_layout()

  -- Mimic nvim-tree's open_in_new_window fallback: split the TREE and show a
  -- named normal buffer in the new window.
  vim.api.nvim_set_current_win(U.tree_window())
  vim.cmd('belowright vsplit')
  local broken = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. '/opened.txt')
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'x' })
  vim.api.nvim_win_set_buf(broken, buf)

  assert_(vim.wait(1000, function() return not vim.api.nvim_win_is_valid(broken) end, 20),
    'the broken file window was not repaired')
  local file_win = vim.fn.win_findbuf(buf)[1]
  assert_(file_win, 'the file buffer is not displayed after the repair')
  assert_(not U.sidebar_overlap(file_win), 'the file window still overlaps the sidebar')
  ok()

elseif scenario == 'width-normalize' then
  -- A closed editor's width can land in a pinned neighbour (nvim-tree and
  -- toggleterm set 'winfixwidth'); the normalizer restores the sidebar and
  -- terminal widths and leaves the remainder to the editor column.
  vim.o.columns = 168
  vim.o.lines = 49
  package.loaded['nvim-tree.view-state'] = { Active = { initial_width = 30 } }
  require('toggleterm.config').get = function(key)
    if key == 'size' then return 32 end
    return true
  end

  vim.cmd('vsplit')
  vim.cmd('vsplit')
  local ws = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do ws[#ws + 1] = w end
  table.sort(ws, function(a, b)
    return vim.api.nvim_win_get_position(a)[2] < vim.api.nvim_win_get_position(b)[2]
  end)
  local side, ed, term = ws[1], ws[2], ws[3]
  -- Distinct buffers: vsplit windows share the buffer, and the filetypes
  -- must be per window.
  local side_buf = U.scratch_buffer('NvimTree')
  local term_buf = U.scratch_buffer('claude')
  local ed_buf = U.empty_editor_buffer()
  vim.api.nvim_win_set_buf(side, side_buf)
  vim.api.nvim_win_set_buf(ed, ed_buf)
  vim.api.nvim_win_set_buf(term, term_buf)
  vim.wo[side].winfixwidth = true
  vim.wo[term].winfixwidth = true

  -- The mess: the sidebar swallowed the editor's width, the editor is a
  -- sliver, the terminal is narrower than configured.
  vim.api.nvim_win_set_width(term, 28)
  vim.api.nvim_win_set_width(ed, 10)
  vim.api.nvim_win_set_width(side, 60)

  U.normalize_columns()
  assert_eq(vim.api.nvim_win_get_width(side), 30, 'sidebar width not normalized')
  assert_eq(vim.api.nvim_win_get_width(term), 32, 'terminal width not normalized')
  assert_(vim.api.nvim_win_get_width(ed) > 10, 'editor did not take the remainder')
  ok()

elseif scenario == 'zoom-no-park' then
  -- Zoomed C-s keeps the float on real session content the whole way: it
  -- never swaps to a scratch buffer, no split shows a session terminal
  -- alongside it, no park scratch is created, and the old session's toggle
  -- marker survives (the marker is only ever stripped inside unzoom's
  -- rebuild churn, then restored).
  sessions(2)
  M.toggle_zoom()
  local zw = vim.api.nvim_get_current_win()
  local old_buf = vim.api.nvim_win_get_buf(zw)
  M.next_session()
  assert_(vim.api.nvim_win_is_valid(zw), 'the switch killed the zoom float')
  assert_(is_session_buf(vim.api.nvim_win_get_buf(zw)),
    'the float was parked on a scratch buffer mid-switch')
  assert_no_session_splits('mid-switch')
  assert_(vim.b[old_buf].toggle_number ~= nil,
    'the switch left the old session buffer stripped of its toggle marker')
  local scratches = 0
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == ''
        and vim.bo[b].buftype == 'nofile' then
      scratches = scratches + 1
    end
  end
  assert_eq(scratches, 0, 'the switch created a park scratch buffer')
  ok()

else
  print('unknown scenario: ' .. scenario)
  vim.cmd('cq!')
end
