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
-- panel render smoke covers the row machinery. Not covered: on_session_exit
-- (the toggleterm stub ignores spec.on_exit), the diff panel's git jobs
-- (the harness chdirs to a non-git temp dir, so the probes no-op), and
-- t-mode keymap callbacks that depend on a live input loop (feedkeys never
-- applies the mode transition inside a -l script).

-- Resolve the repo root from this script's own path (absolute invocation;
-- `vim.fs.abspath` normalizes the relative form `nvim -l scripts/...` yields).
local here = vim.fs.abspath(debug.getinfo(1, 'S').source:sub(2))
local root = vim.fs.dirname(vim.fs.dirname(here))
vim.opt.runtimepath:append(root)

-- A non-git temp cwd: the diff panel's `git rev-parse` probe must not find
-- a repo (or a workspace), so no diff panel ever splits.
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, 'p')
vim.fn.chdir(tmp)

local M = require('claude_sessions')
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
          vim.cmd('vsplit')
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
  local cfg = vim.api.nvim_win_get_config(vim.api.nvim_get_current_win())
  return cfg.relative ~= '' and vim.api.nvim_get_current_win() or nil
end

local function sessions(n)
  for _ = 1, n do M.create() end
end

-- Is `buf` a live session terminal (buftype terminal, not the shell)?
local function is_session_buf(buf)
  return vim.bo[buf].buftype == 'terminal'
    and vim.bo[buf].filetype ~= 'claude-shell'
end

-- The single-window zoom invariant: no real (non-float) window may show a
-- session terminal while the float is up — two windows on one terminal fight
-- over the pty and the TUI garbles.
local function assert_no_session_splits(tag)
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local ok, cfg = pcall(vim.api.nvim_win_get_config, w)
    if ok and cfg and cfg.relative == '' then
      assert_(not is_session_buf(vim.api.nvim_win_get_buf(w)),
        (tag .. ': a split shows a session terminal alongside the float'))
    end
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
  local first = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.bo[b].filetype == 'claude-shell' then first[#first + 1] = b end
  end
  assert_eq(#first, 1, 'shell window count after open')
  M.toggle_shell() -- close from inside the shell
  M.toggle_shell() -- the SAME shell buffer comes back
  local second = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.bo[b].filetype == 'claude-shell' then second[#second + 1] = b end
  end
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
  local shells = 0
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == 'claude-shell' then
      shells = shells + 1
    end
  end
  assert_eq(shells, 1, 'C-b while zoomed disturbed the shell split')
  M.toggle_shell() -- cursor inside the shell: closes it
  shells = 0
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == 'claude-shell' then
      shells = shells + 1
    end
  end
  assert_eq(shells, 0, 'second C-b did not close the shell')
  M.toggle_shell() -- re-opens the SAME shell
  shells = 0
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == 'claude-shell' then
      shells = shells + 1
    end
  end
  assert_eq(shells, 1, 'third C-b did not re-open the shell')
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
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    assert_(vim.bo[vim.api.nvim_win_get_buf(w)].filetype ~= 'claude-shell',
      'C-b while zoomed opened a shell window')
  end
  ok()

elseif scenario == 'panel-smoke' then
  -- A tree window + sessions draw the panel with rows and working maps.
  vim.cmd('new')
  local tree_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, tree_buf)
  vim.bo[tree_buf].filetype = 'NvimTree'
  sessions(2)
  local panel_w, panel_b
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.bo[b].filetype == 'claude-sessions-panel' then
      panel_w, panel_b = w, b
    end
  end
  assert_(panel_w, 'no session panel window')
  assert_eq(vim.api.nvim_buf_line_count(panel_b), 6, 'panel line count (2 entries x 3)')
  assert_(vim.fn.maparg('q', 'n', false, panel_b) ~= '', 'panel q map missing')
  assert_(vim.fn.maparg('j', 'n', false, panel_b) ~= '', 'panel j map missing')
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
