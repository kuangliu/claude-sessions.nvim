-- Multi-session manager for Claude Code.
--
-- Each session is a toggleterm vertical terminal (right split, 40% width)
-- whose claude process keeps running while its window is closed. Creating a
-- new session replaces the displayed window; the layout stays stable because
-- toggleterm persists the split width and every session opens via the same
-- botright vsplit + vertical resize path.
--
-- While a session window is displayed, a session-list panel is split below
-- nvim-tree, styled after Claude Code's session picker (panel.lua), and —
-- when the workspace is dirty — a changed-files diff panel between the two
-- (diff.lua), whose selection renders the file's diff in a right-side pane
-- (diff_view.lua).
--
-- Keymaps:
--   <C-a>  create a new session and open it on the right
--   <C-s>  switch sessions (toggle / cycle / reopen last closed)
--   <C-e>  focus the diff panel and step to the next changed file
--   <C-b>  toggle a shell terminal below the displayed session
--   <C-space>  zoom the displayed session (or the shell under the cursor)
--     fullscreen; again to come back
--   <C-d>  close the current session (terminal mode only)

local M = {}

local panel = require('claude_sessions.panel')
local diff = require('claude_sessions.diff')
local diff_view = require('claude_sessions.diff_view')
local U = require('claude_sessions.util')

local focus = U.focus
local notify = U.notify

-- --- Options --------------------------------------------------------------
-- Defaults, merged over by setup(). `auto_reload` reloads file buffers a
-- session's claude process changed on disk (checktime skips buffers with
-- uncommitted edits, so in-progress work is never clobbered).
local opts = { auto_reload = true }
local setup_done = false

-- --- State ----------------------------------------------------------------
-- sessions: ordered list of live records { name, custom_name, term }
-- current:  the session whose window is currently displayed, if any
-- last_closed: most recently closed session whose process is still alive
local sessions = {}
local current = nil
local last_closed = nil

-- --- Poll loop ---------------------------------------------------------------
-- While sessions exist, a uv timer ticks every POLL_INTERVAL_MS: fetching
-- agents' busy state (`claude agents --json`) on a slow sub-cycle and, while
-- anything is busy, blinking the statusline dots and auto-reloading changed
-- buffers. Gated on `any_busy`, so an idle editor pays nothing; the timer
-- stops entirely once the last session closes.
local busy_by_pid = {} -- map<pid, status string ('busy'/'idle'/...)>
local any_busy = false -- is any live session's agent busy right now?
local blink_on = true -- toggled once per statusline render; busy dots alternate
local poll_timer = nil
local fetch_inflight = false
local tick = 0

local POLL_INTERVAL_MS = 300 -- blink cadence + poll tick
local FETCH_EVERY = 7 -- fetch `claude agents` every N ticks (=> ~2.1s)
local CHECK_EVERY = 3 -- reload externally-changed buffers every N ticks (=> ~0.9s)

--- OS pid of a session's claude process, or nil.
local function session_pid(s)
  local job_id = s.term and s.term.job_id
  if not job_id then return nil end
  local ok, pid = pcall(vim.fn.jobpid, job_id)
  return ok and pid and pid > 0 and pid or nil
end

--- This session's agent state ('busy'/'idle'/...) from `claude agents
--- --json`; nil when the pid is unknown or not yet in the cache.
local function session_state(s)
  local pid = session_pid(s)
  return pid and busy_by_pid[pid] or nil
end

local function session_busy(s)
  return session_state(s) == 'busy'
end

--- Recompute `any_busy`. On a busy<->idle transition: one statusline redraw
--- to start/stop blinking, plus a checktime when the agent just went quiet.
local function update_busy()
  local was_busy = any_busy
  any_busy = false
  for _, s in ipairs(sessions) do
    if session_busy(s) then
      any_busy = true
      break
    end
  end
  if any_busy == was_busy then return end
  if opts.auto_reload and was_busy and not any_busy then
    vim.cmd('checktime')
  end
  panel.refresh() -- busy/idle words on the panel rows
  vim.cmd('redrawstatus')
end

--- Async-fetch `claude agents --json` and refresh the pid -> status cache.
--- A failed spawn keeps the last known busy state and retries next tick.
local function refresh_busy_state()
  if fetch_inflight then return end
  fetch_inflight = true
  U.job({ 'claude', 'agents', '--json' }, function(out)
    fetch_inflight = false
    if not out then return end
    local ok, agents = pcall(vim.fn.json_decode, out)
    if not ok or type(agents) ~= 'table' then return end
    local next_map = {}
    for _, a in ipairs(agents) do
      if type(a) == 'table' and a.pid and type(a.status) == 'string' then
        next_map[a.pid] = a.status
      end
    end
    busy_by_pid = next_map
    update_busy()
  end)
end

--- Stop the poll timer; reset the tick counter and busy state.
local function stop_poll_timer()
  if poll_timer then
    poll_timer:stop()
    poll_timer:close()
    poll_timer = nil
  end
  tick = 0
  any_busy = false
end

--- One timer tick: the mode guard's periodic check, the diff panel's
--- repaint, the busy fetch, and (while busy) the blink + auto-reload.
local function poll_tick()
  tick = tick + 1
  if #sessions == 0 then
    stop_poll_timer()
    return
  end
  -- Panel mode guard's periodic check (see panel.install_mode_guard).
  vim.cmd('doautocmd User ClaudeSessionsTick')
  -- The diff panel repaints per tick WHILE an agent works (an idle tree is
  -- static), slow-cycle otherwise; down → probe+open on the slow sub-cycle,
  -- so a never-drawn panel still appears when the first change lands.
  if M.is_visible() then
    if diff.active() then
      if any_busy or tick % FETCH_EVERY == 0 then diff.refresh() end
    elseif tick % FETCH_EVERY == 0 then
      diff.open()
    end
  end
  if tick % FETCH_EVERY == 0 then
    refresh_busy_state()
  end
  -- The blink phase advances once per tick here, never inside
  -- statusline_indicator() (lualine may evaluate it any number of times per
  -- redraw — a render-driven toggle would blink faster the busier the UI
  -- gets).
  if any_busy then
    blink_on = not blink_on
    if opts.auto_reload and tick % CHECK_EVERY == 0 then
      vim.cmd('checktime') -- skip buffers with uncommitted edits
    end
    vim.cmd('redrawstatus')
  end
end

--- (Re)start the poll timer. Cheap while idle: a tick that finds no sessions
--- stops the timer again.
local function start_poll_timer()
  if poll_timer then return end
  poll_timer = (vim.uv or vim.loop).new_timer()
  poll_timer:start(POLL_INTERVAL_MS, POLL_INTERVAL_MS, vim.schedule_wrap(poll_tick))
end

-- --- Session registry -------------------------------------------------------

--- Is this terminal's window currently displayed in the UI?
local function window_open(term)
  return U.valid_win(term.window)
    and vim.api.nvim_win_get_buf(term.window) == term.bufnr
end

--- First live session matching `pred`, as (record, index); or nothing.
local function find_session(pred)
  for i, s in ipairs(sessions) do
    if pred(s) then return s, i end
  end
end

--- The session whose window is currently displayed, if any.
local function displayed_session()
  return find_session(function(s) return window_open(s.term) end)
end

local function session_for_term(term)
  return find_session(function(s) return s.term == term end)
end

--- Index of `record` in the sessions list, or nil.
local function find_session_index(record)
  return select(2, find_session(function(s) return s == record end))
end

-- Forward-declared (defined in the Display section below) so the panel hooks
-- bound above it capture the local, not a nil global.
local show_session

--- Push a session's display name into its terminal and the statusline var.
local function apply_name(s, name)
  s.name = name
  local term = s.term
  if not term then return end
  term.display_name = name
  if U.valid_buf(term.bufnr) then
    vim.b[term.bufnr].claude_session_name = name
  end
end

--- Default session names: every session is just `claude` (the panel cursor
--- and the layout tell them apart). Custom names survive renumbers.
local function renumber()
  for _, s in ipairs(sessions) do
    if not s.custom_name then apply_name(s, 'claude') end
  end
end

--- Drop a session record: remove it, renumber the rest, forget it as
--- current / last-closed.
local function drop_record(record)
  local index = find_session_index(record)
  if index then table.remove(sessions, index) end
  if current == record then current = nil end
  if last_closed == record then last_closed = nil end
  renumber()
end

-- --- Panel wiring -----------------------------------------------------------
-- panel.lua is required at the top; its hooks are bound here, after the
-- registry helpers they close over (avoids a require cycle).

--- Push registry/window state to both panels. The switch hold (panel
--- .switching) lives here — one guard, both halves: the churn's
--- close_all_open_windows → panel_sync must not open a redundant panel
--- mid-churn (show_session's own open() then lands as a no-op).
local function panel_sync()
  if panel.switching then return end -- mid-switch churn: show_session owns both halves
  panel.sync(M.is_visible())
  diff.sync(M.is_visible())
end

--- The panel's rows: live sessions in list order as { busy, state, open, name }.
panel.snapshot = function()
  local snap = {}
  for i, s in ipairs(sessions) do
    snap[i] = {
      busy = session_busy(s),
      state = session_state(s),
      open = window_open(s.term),
      -- the middle column shows `claude` until the session is renamed
      name = s.custom_name and s.name or nil,
    }
  end
  return snap
end

panel.show = function(i)
  local s = sessions[i]
  if s then show_session(s) end
end

--- The panel's <C-d>: kill the session on that row (M.close_current is
--- defined below; the closure resolves it at call time).
panel.close_session = function(i)
  local s = sessions[i]
  if s then M.close_current(s, { stepping = true }) end
end

panel.rename_session = function(i, name)
  if sessions[i] then M.rename(i, name) end
end

--- The diff pane's edits call back into the diff panel's machinery: D
--- discards through the same prompted discard, c commits, and every edit
--- lands in the shared re-probe tail.
diff_view.discard_path = diff.discard_path
diff_view.commit = diff.commit_all
diff_view.reprobe = diff.reprobe

-- Forward-declared (defined in the Zoom section below) so the shell toggle
-- (which yields to an open zoom) and the shell's <C-d> capture the locals,
-- not nil globals.
local zoomed, unzoom, drop_dead_zoom

-- --- Shell terminal ---------------------------------------------------------
-- <C-b>: a plain shell in a split below the displayed session — same column,
-- 1/3 of the session's height. The shell outlives its window, so <C-b>
-- re-shows the SAME shell; a session switch re-anchors it below the new
-- session window. Not a toggleterm terminal on purpose: the mutual exclusion
-- in close_all_open_windows would close the shell on every session switch.

local shell_buf = nil -- the shell's terminal buffer, nil when never opened
local shell_win = nil -- its window, valid only while displayed
-- Where the cursor stood when <C-b> opened the shell: { win, pos,
-- reopen_insert }. Dies with the shell itself.
local shell_prev = nil

--- Run `fn` with BufEnter suppressed: toggleterm's BufEnter handler schedules
--- a startinsert on every programmatic switch INTO a terminal window, which
--- would fire after the switcher's code returns — onto whatever window is
--- focused by then. Restores the option even if `fn` raises (a leaked
--- 'BufEnter' would silently kill every BufEnter autocmd).
local function with_no_bufenter(fn)
  local saved_ei = vim.o.eventignore
  vim.o.eventignore = 'BufEnter'
  local ok, err = pcall(fn)
  vim.o.eventignore = saved_ei
  if not ok then error(err, 0) end
end

--- Take down the shell's WINDOW, leaving the shell itself alive. Nil
--- `shell_win` BEFORE closing so teardown the close triggers sees the window
--- as already gone and no-ops.
local function hide_shell_window()
  if not (shell_win and U.valid_win(shell_win)) then return end
  local win = shell_win
  shell_win = nil
  pcall(vim.api.nvim_win_close, win, true)
end

--- Forget the shell outright — window, buffer, snapshot. The single home of
--- the shell's death sequence; on_exit and close_shell both route through
--- here so no path can nil one piece without the rest.
local function forget_shell()
  hide_shell_window()
  if U.valid_buf(shell_buf) then
    vim.api.nvim_buf_delete(shell_buf, { force = true })
  end
  shell_buf = nil
  shell_prev = nil -- the shell is dead; its snapshot describes nothing
end

--- Focus the displayed session's terminal window, if there is one.
local function focus_session()
  local s = current
  if s and U.valid_win(s.term.window) then focus(s.term.window) end
end

--- Split the shell window below `below` (a session window): 1/3 of its
--- height, in the same column.
local function open_shell_window(below)
  local height = math.max(1, math.floor(vim.api.nvim_win_get_height(below) / 3))
  U.focus(below)
  vim.cmd('below ' .. height .. 'split')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, shell_buf)
  U.plain_terminal_window(win) -- the shell draws its own cursor too
  shell_win = win
  return win
end

--- Show the shell below the displayed session. None yet spawns one — the
--- split opens FIRST (termopen runs on the CURRENT buffer, and running it
--- while a session terminal is current would fail its unmodified-buffer
--- check).
local function show_shell()
  local s = current
  if not (s and window_open(s.term)) then
    notify('No displayed session to split a shell below.', vim.log.levels.WARN)
    return
  end
  if not U.valid_buf(shell_buf) then
    shell_buf = vim.api.nvim_create_buf(false, true) -- scratch: hidden, no swap
  end
  open_shell_window(s.term.window)
  if vim.bo[shell_buf].buftype ~= 'terminal' then
    -- Never started (a fresh scratch buffer is 'nofile'; termopen flips it to
    -- 'terminal') — start the shell in it.
    vim.fn.termopen(vim.o.shell, {
      -- The user typed `exit` (or the shell died): take its window down and
      -- forget the buffer, so the next <C-b> spawns a fresh shell instead of
      -- re-showing a dead one.
      on_exit = forget_shell,
    })
    vim.bo[shell_buf].filetype = 'claude-shell'
  end
  vim.api.nvim_win_set_cursor(shell_win, { vim.api.nvim_buf_line_count(shell_buf), 0 })
  vim.cmd('startinsert')
end

--- <C-b>: toggle the shell split below the displayed session. While zoomed,
--- the key only takes the zoom float down — the shell split underneath keeps
--- its own state, so a second press is what really toggles it. Closing from
--- INSIDE the shell returns the cursor (and mode) to where <C-b> opened it.
function M.toggle_shell()
  if zoomed() then
    unzoom()
    return
  end
  if not (shell_win and U.valid_win(shell_win)) then
    local cur = vim.api.nvim_get_current_win()
    -- Decide "was the user typing?" at capture: a t-mode mapping runs its
    -- callback from 'i', so that spelling counts too.
    local mode = vim.api.nvim_get_mode().mode
    shell_prev = {
      win = cur,
      pos = vim.api.nvim_win_get_cursor(cur),
      reopen_insert = mode == 'i' or mode == 't' or mode == 'R',
    }
    show_shell()
  elseif vim.api.nvim_get_current_win() ~= shell_win then
    hide_shell_window() -- cursor elsewhere already — leave it where it is
  else
    -- Closing THE cursor's window auto-moves focus to a neighbour — the
    -- BufEnter suppression keeps the mode set below sticky.
    local prev = shell_prev
    shell_prev = nil
    with_no_bufenter(function()
      hide_shell_window()
      if prev and U.valid_win(prev.win) then
        focus(prev.win)
        pcall(vim.api.nvim_win_set_cursor, prev.win, prev.pos)
      else
        focus_session()
      end
      -- <C-b> in the shell is an insert-mode mapping: insert mode would
      -- otherwise ride along into the restored window.
      pcall(vim.cmd, (prev and prev.reopen_insert) and 'startinsert' or 'stopinsert')
    end)
  end
end

--- Kill the shell outright — the <C-d> spelling ON the shell split (that key
--- otherwise closes the claude session). The on_exit hook repeats this
--- teardown once the job dies — forget_shell's nil'd state makes that pass a
--- no-op.
local function close_shell()
  if U.valid_buf(shell_buf) then
    local job_id = vim.b[shell_buf].terminal_job_id
    if type(job_id) == 'number' and job_id > 0 then pcall(vim.fn.jobstop, job_id) end
  end
  forget_shell()
  drop_dead_zoom()
  focus_session()
end

--- The displayed session changed: re-anchor the shell split below the new
--- session window, or take it away when none remains. The shell itself
--- survives — <C-b> brings the same shell back.
local function sync_shell()
  hide_shell_window()
  local s = current
  if s and window_open(s.term) and U.valid_buf(shell_buf) then
    open_shell_window(s.term.window)
  end
end

-- --- Zoom -------------------------------------------------------------------
-- <C-space>: a full-screen float showing the SAME terminal buffer as the
-- displayed session (or the <C-b> shell when the cursor is on it) — a
-- temporary viewport, not a new layout: the split stays where it is
-- underneath, and the float dies on the second press. A buffer wipe takes the
-- float with it; other display churn rebuilds it when the zoomed buffer is
-- still around.

local zoom_win = nil -- the fullscreen float, valid only while zoomed
local zoom_buf = nil -- the terminal buffer it shows (session or shell)
local zoom_prev = nil -- where the cursor stood when zoom opened

--- The float's config, read live so a resize between zoom and resync still
--- fits. Full-bleed: top-left of the editor to just above the cmdline — the
--- statusline row hides underneath.
local function zoom_config()
  return {
    relative = 'editor',
    row = 0,
    col = 0,
    width = vim.o.columns,
    height = vim.o.lines - vim.o.cmdheight - 1,
    style = 'minimal',
    border = 'none',
    zindex = 50,
  }
end

--- Is the zoom float (still) up?
zoomed = function()
  return U.valid_win(zoom_win)
end

--- Forget a zoom whose window is already gone AND whose buffer is dead.
--- Returns whether anything was dropped.
drop_dead_zoom = function()
  if zoomed() then return false end
  if zoom_win == nil and zoom_buf == nil then return false end
  if zoom_buf ~= nil and U.valid_buf(zoom_buf) then return false end
  zoom_win, zoom_buf, zoom_prev = nil, nil, nil
  return true
end

--- Take the zoom float down, returning the cursor to where zoom opened.
--- Also removes the terminal-normal `q` mapping zoom_buffer installed.
unzoom = function()
  if not zoomed() then return end
  local win = zoom_win
  zoom_win = nil
  pcall(vim.api.nvim_win_close, win, true)
  local buf = zoom_buf
  zoom_buf = nil
  pcall(vim.keymap.del, 'n', 'q', { buffer = buf })
  local prev = zoom_prev
  zoom_prev = nil
  if prev and U.valid_win(prev) then
    pcall(vim.api.nvim_set_current_win, prev)
  else
    focus_session()
  end
end

--- While zoomed, focus stays on the float (never the split); else focus `win`.
local function focus_zoom_or(win)
  if zoomed() then
    focus(zoom_win)
  else
    focus(win)
  end
end

--- Open the zoom float over `buf`. Never reuses a live window id: on the
--- close_current path the wipe tears the float's window down but the
--- `zoom_win` id can still test valid, so unconditionally closing it would
--- kill the JUST-opened float.
---
--- `keep_home` preserves the existing cursor home (zoom_prev) — the spelling
--- a churn rebuild uses.
---
--- `q` in terminal-NORMAL closes the float, the same dismiss spelling as
--- every other panel. n-mode, not t-mode: after <Esc> the terminal is in
--- terminal-normal (n-mode maps), and while typing into the job q must stay
--- plain input. Buffer-local, removed by unzoom; a stray press without a live
--- float never touches the split underneath.
local function zoom_buffer(buf, keep_home)
  if not U.valid_buf(buf) then return end
  local prev = vim.api.nvim_get_current_win()
  if zoomed() then
    local win = zoom_win
    zoom_win = nil
    pcall(vim.api.nvim_win_close, win, true)
  else
    zoom_win = nil
  end
  zoom_buf = buf
  if not keep_home then zoom_prev = prev end
  zoom_win = vim.api.nvim_open_win(buf, true, zoom_config())
  vim.keymap.set('n', 'q', function()
    if zoomed() then unzoom() end
  end, { buffer = buf, nowait = true, silent = true, desc = 'claude sessions: unzoom' })
  vim.cmd('startinsert')
end

--- Show `buf` in the zoom float: first zoom opens it, a live float repoints
--- onto the new buffer — a session switch while zoomed jumps straight to the
--- new session fullscreen. Keeps whatever cursor home the zoom already had.
local function zoom_repoint(buf)
  if not U.valid_buf(buf) then return end
  if zoomed() then
    vim.api.nvim_win_set_buf(zoom_win, buf)
    zoom_buf = buf
    vim.api.nvim_set_current_win(zoom_win)
  else
    zoom_buffer(buf)
  end
  vim.cmd('startinsert')
end

--- Rebuild a zoom float whose buffer survived display churn that took the
--- float's window down; dead buffer → drop the state. A float still up after
--- churn may sit parked on scratch (hide_zoom_for_churn): repoint onto the
--- real buffer — only the session branches repaint, so the shell zoom riding
--- out a switch lands here.
local function resync_zoom()
  if zoomed() then
    if U.valid_buf(zoom_buf) and vim.api.nvim_win_get_buf(zoom_win) ~= zoom_buf then
      zoom_repoint(zoom_buf)
    end
    return
  end
  if zoom_win == nil and zoom_buf == nil then return end
  if drop_dead_zoom() then return end
  zoom_buffer(zoom_buf, true)
end

--- Park the zoom float's WINDOW for toggleterm churn: swap a blank scratch
--- buffer into the float, so open_split's find_open_windows sees no terminal
--- window and splits the new session into the right-side column instead of
--- off the float. The float never closes — no flash, no WinClosed, no reopen.
--- Returns the parked buffer (nil when nothing was up).
local zoom_scratch = nil -- blank buffer parked in the float during churn

local function hide_zoom_for_churn()
  if not zoomed() then return nil end
  if not U.valid_buf(zoom_scratch) then
    zoom_scratch = U.scratch_buffer()
  end
  -- The float keeps focus on scratch (no q map: a stray q is plain input,
  -- never an unzoom). zoom_buf keeps pointing at the parked session buffer —
  -- the float still "shows" it logically, so drop_dead_zoom/resync_zoom keep
  -- working, and zoom_win stays valid so zoom_repoint takes the no-flash
  -- win_set_buf path.
  pcall(vim.api.nvim_win_set_buf, zoom_win, zoom_scratch)
  return zoom_buf
end

--- <C-space>: zoom the displayed session's terminal (or the <C-b> shell when
--- the cursor is on it); press again to come back.
function M.toggle_zoom()
  if zoomed() then
    unzoom()
    return
  end
  -- On the <C-b> shell split → zoom the shell.
  if shell_win and U.valid_win(shell_win)
      and vim.api.nvim_get_current_win() == shell_win then
    if U.valid_buf(shell_buf) then
      zoom_buffer(shell_buf)
    else
      notify('No shell to zoom.', vim.log.levels.WARN)
    end
    return
  end
  -- Elsewhere → zoom the displayed session.
  local s = current
  if s and window_open(s.term) then
    zoom_buffer(s.term.bufnr)
    return
  end
  notify('No displayed session to zoom.', vim.log.levels.WARN)
end

-- --- Display ----------------------------------------------------------------

--- Close the window of every displayed toggleterm terminal except `keep`.
--- Window-only: processes keep running. Guarantees the kept session alone
--- occupies the right side — at most one of {claude session, plain terminal}
--- is visible at a time. Remembers the most recently closed session for <C-s>.
local function close_all_open_windows(keep)
  local closed_any = false
  for _, term in ipairs(require('toggleterm.terminal').get_all()) do
    if term ~= keep and window_open(term) then
      term:close()
      local s = session_for_term(term)
      if s then last_closed = s end
      closed_any = true
    end
  end
  -- A session window went away (a terminal opened over it): the panel lives
  -- below the session, so it goes too. show_session() reopens it right after.
  if closed_any then panel_sync() end
end

--- Run `open` without letting toggleterm request insert mode — a no-op
--- unless `stepping`. with_no_bufenter covers the queued BufEnter startinsert;
--- the synchronous spawn-time startinsert (brand-new-terminal path) needs the
--- start_in_insert config flipped instead, which is why this wrapper exists
--- on top of it. A real open (<C-s>/<CR>/<C-a>) flows normally.
local function without_insert(stepping, open)
  if not stepping then
    open()
    return
  end
  local ok_cfg, cfg = pcall(require, 'toggleterm.config')
  local saved_sii
  if ok_cfg then
    saved_sii = cfg.get('start_in_insert')
    cfg.set({ start_in_insert = false })
  end
  with_no_bufenter(open)
  if ok_cfg then cfg.set({ start_in_insert = saved_sii }) end
end

--- Close everything else, open this session's window, mark it current, keep
--- the panels in sync. Focus lands on the session window (the panel keeps it
--- while stepping).
show_session = function(s)
  local stepping = panel.stepping
  -- Already displayed: opening again would split a second window over the
  -- same terminal (toggleterm's open() always spawns a new split). Just focus
  -- the existing window — l/<CR> on the displayed row means "show me it".
  -- While zoomed the float holds focus instead.
  if window_open(s.term) then
    current = s
    panel.follow()
    focus_zoom_or(s.term.window)
    return
  end

  -- Park scratch in the zoom float BEFORE the churn: the float stays up the
  -- whole time — no close/reopen flash, only the fullscreen content swaps
  -- once. Panel stepping also lands here with scratch parked for a switch
  -- that may never settle; zoom_repoint below restores either way (every path
  -- ends on a displayed session).
  local parked_buf = hide_zoom_for_churn()
  panel.switching = true -- hold panel_sync's both halves through the window churn
  without_insert(stepping, function()
    close_all_open_windows(s.term)
    s.term:open()
  end)
  panel.switching = false
  current = s
  U.plain_terminal_window(s.term.window) -- terminals draw their own cursor
  panel.open() -- refresh rows (open/closed states flipped)
  diff.open() -- the uncommitted-changes panel above the tree
  sync_shell() -- the shell split re-anchors below the new session window

  -- The display moved: a session zoom follows it fullscreen (a shell zoom
  -- stays on the shell); a float churn took down rebuilds while its buffer
  -- lives.
  if zoom_buf ~= shell_buf then
    if parked_buf or (zoom_buf and U.valid_buf(zoom_buf)) then
      zoom_repoint(s.term.bufnr)
    else
      drop_dead_zoom()
    end
  else
    resync_zoom()
  end

  if stepping then
    -- The just-opened terminal keeps focus for THIS pass; the panel takes it
    -- back one scheduled pass later — guaranteed AFTER any startinsert
    -- closures toggleterm queued, which fire harmlessly on the terminal.
    -- A synchronous panel focus would let a queued startinsert fire ON the
    -- panel and flash INSERT.
    return
  end
  panel.follow() -- panel cursor follows the displayed session
  -- While zoomed the float holds focus (zoom_repoint already put it there);
  -- focusing the split would leave the user staring at the old layout with a
  -- live fullscreen float on top.
  focus_zoom_or(s.term.window)
end

--- on_exit: tidy the window and buffer when a claude process ends.
--- close_on_exit = false keeps toggleterm's own teardown (window close +
--- focus restore — the thing that made <C-d> steal focus ~0.5s later) off.
local function on_session_exit(record)
  local term = record.term
  if term then
    if window_open(term) then
      term:close()
    end
    if U.valid_buf(term.bufnr) then
      vim.api.nvim_buf_delete(term.bufnr, { force = true })
    end
  end
  drop_record(record)
  drop_dead_zoom()
  panel_sync() -- the exited session may have been the displayed one
end

-- --- Public API -------------------------------------------------------------

--- Create a NEW session and open it on the right.
function M.create()
  local record = { name = '' } -- renumbered below
  local Terminal = require('toggleterm.terminal').Terminal
  record.term = Terminal:new({
    cmd = 'claude --allow-dangerously-skip-permissions',
    direction = 'vertical',
    display_name = '', -- set by renumber()
    -- Empty string == unset for claude's child-session check: clears the
    -- marker inherited from this nvim's environment so the session is an
    -- independent, trackable agent.
    env = { CLAUDE_CODE_CHILD_SESSION = '' },
    -- Keep toggleterm from closing the window / restoring focus when the job
    -- dies; on_session_exit cleans up instead.
    close_on_exit = false,
    on_exit = function() on_session_exit(record) end,
  })
  table.insert(sessions, record)
  show_session(record)
  -- A non-toggleterm filetype keeps lualine's toggleterm extension off the
  -- statusline; toggleterm still tracks the buffer via vim.b.toggle_number.
  if U.valid_buf(record.term.bufnr) then
    vim.bo[record.term.bufnr].ft = 'claude'
  end
  renumber() -- names the new session (custom names elsewhere are kept)
  start_poll_timer()
  notify('New session: ' .. record.name)
  -- <C-a> from inside a terminal (t-mode mapping): nvim overrides toggleterm's
  -- startinsert once the mapping completes, leaving terminal-normal. Schedule
  -- a startinsert to run after the mapping machinery settles.
  vim.schedule(function()
    if vim.api.nvim_get_current_win() == record.term.window then
      vim.cmd('startinsert')
    end
  end)
end

--- Close a session (window + process) and drop it; the split stays occupied
--- — the successor is shown in its place. `stepping` keeps focus on the panel;
--- closing a background session leaves the display alone.
function M.close_current(target, close_opts)
  close_opts = close_opts or {}
  if #sessions == 0 then
    notify('No claude sessions to close.', vim.log.levels.WARN)
    return
  end
  target = target or current or sessions[#sessions]
  local term = target.term
  -- Position of the closed session, so its successor can be shown.
  local index = find_session_index(target)
  -- Panel-driven close: the list keeps focus and drives the display silently.
  local stepping = close_opts.stepping or panel.stepping
  -- The zoom state BEFORE the wipe (read first: wiping a buffer shown in two
  -- windows closes BOTH, so afterwards zoom_buf points at a dead buffer and
  -- the comparison would never fire) — capture the follow-onto-successor
  -- intent now. `win` too: it may not survive the wipe.
  local win = window_open(term) and term.window or nil
  local keep_zoom = zoom_buf ~= nil and zoom_buf == term.bufnr

  -- Wiping the buffer kills the job (close_on_exit = false keeps the exit
  -- from closing the window / moving focus). Deleting the LAST buffer of its
  -- window tears the window down — `win` is re-checked below.
  if U.valid_buf(term.bufnr) then
    vim.api.nvim_buf_delete(term.bufnr, { force = true })
  end
  drop_record(target)
  notify('Closed session: ' .. target.name)

  if #sessions == 0 then
    -- The wipe took the zoom float's window with it too; just forget the
    -- dead state — unzoom's refocus would land nowhere with no sessions.
    drop_dead_zoom()
    panel_sync() -- last session gone: drop the panel
    return
  end
  local next_session = sessions[index] or sessions[#sessions]
  -- The closed session's zoom follows it onto the successor fullscreen
  -- (`keep_zoom` was captured before the wipe above).)

  -- The window survived the wipe: keep the same split and swap the
  -- successor's buffer in (a single clean statusline update, no flicker).
  -- Unlike show_session/next_session, no park here — the buffer is ALREADY
  -- wiped, so the zoom float is already gone and zoom_win dangles invalid;
  -- zoom_buf's dead pointer is exactly what keep_zoom below needs, and `win`
  -- only survives when some OTHER window was showing a live session.
  if U.valid_win(win) then
    close_all_open_windows(next_session.term)
    vim.api.nvim_win_set_buf(win, next_session.term.bufnr)
    next_session.term.window = win
    current = next_session
    -- Apply the successor's highlights; re-strip the cursorline/column.
    require('toggleterm.ui').hl_term(next_session.term)
    U.plain_terminal_window(win) -- and re-strip the cursorline/cursorcolumn
    panel.open()
    diff.refresh()
    if keep_zoom then
      -- Reopen on the successor from the kept cursor home.
      zoom_buffer(next_session.term.bufnr, true)
    elseif zoom_buf ~= shell_buf and zoom_buf and U.valid_buf(zoom_buf) then
      -- A live zoom on some OTHER buffer: rebuild it — close_all_open_windows
      -- above may have taken its window down.
      resync_zoom()
    else
      drop_dead_zoom()
    end
    if not stepping then
      focus_zoom_or(win)
      vim.cmd('startinsert')
      panel.follow()
    end
    return
  end

  -- The window went away with its buffer (the common case when zoomed: the
  -- wipe closes BOTH split and float). The successor opens through the normal
  -- path, which repoints a parked/live session zoom onto it — a parked
  -- keep_zoom just re-arms its intent (zoom_buf → successor; the stale
  -- zoom_win must go, or zoom_repoint would win_set_buf on a dead id).
  if keep_zoom then
    zoom_win = nil
    zoom_buf = next_session.term.bufnr
  end
  if not stepping then
    show_session(next_session)
    return
  end
  if window_open(next_session.term) then
    -- Background close: only the rows shrink.
    panel.refresh()
    return
  end
  -- The DISPLAYED session was closed (panel-driven): show the successor
  -- through the normal path — panel.stepping keeps show_session from letting
  -- toggleterm request insert. Re-claim the panel one scheduled pass later,
  -- FIFO behind the queued startinserts (harmless on the terminal).
  panel.stepping = stepping
  show_session(next_session)
  panel.stepping = false
  panel.reclaim_focus()
end

--- Is any session window displayed? The mutual-exclusion gate with regular
--- terminals: opening a terminal closes a visible session window first, and
--- opening a session closes open terminals.
function M.is_visible()
  return displayed_session() ~= nil
end

--- Close the displayed session window(s) without killing processes; the
--- closed session is remembered as last_closed for <C-s>.
function M.close_window()
  local closed = false
  for _, s in ipairs(sessions) do
    if window_open(s.term) then
      s.term:close()
      last_closed = s
      closed = true
    end
  end
  if not closed then return false end
  current = nil
  panel_sync()
  return true
end

--- Is there at least one live session?
function M.has_sessions()
  return #sessions > 0
end

--- Rename session `i` (empty restores the default `claude`; a custom name
--- survives renumbers).
function M.rename(i, new_name)
  local s = sessions[i]
  if not s then return end
  new_name = vim.trim(new_name or '')
  if new_name == '' then
    s.custom_name = nil
    renumber()
  else
    s.custom_name = true
    apply_name(s, new_name)
  end
  notify('Session renamed: ' .. s.name)
  panel.refresh()
end

--- <C-s>: cycle sessions — single session toggles its window; multiple with
--- none displayed show the last closed; otherwise the next in the list
--- (wrapping).
function M.next_session()
  if #sessions == 0 then
    notify('No claude sessions. Press <C-a> to create one.', vim.log.levels.WARN)
    return
  end

  -- Single session: toggle its window. The process keeps running while closed.
  if #sessions == 1 then
    local s = sessions[1]
    if window_open(s.term) then
      s.term:close()
      current = nil
      panel_sync()
      -- term:close() restores focus to toggleterm's origin window — off the
      -- zoom float. The float survives (the session's buffer lives on, and a
      -- shell zoom rides the shell), so put focus back on it: the user was
      -- typing there.
      if zoomed() then focus(zoom_win) end
    else
      show_session(s)
    end
    return
  end

  -- Target: the session after the displayed one (wrapping), or the last
  -- closed, else the most recent. last_closed is only ever set to live
  -- records (drop_record clears it) — no liveness check needed.
  local displayed, displayed_index = displayed_session()
  local target = displayed and sessions[displayed_index % #sessions + 1]
    or last_closed
    or sessions[#sessions]

  if window_open(target.term) then
    -- Hide the zoom float first (it would count as an open terminal window —
    -- see hide_zoom_for_churn), close any other open toggleterm window, then
    -- focus the target: a session zoom repoints onto it, a shell zoom
    -- rebuilds while its buffer lives.
    local was_zoomed = hide_zoom_for_churn()
    close_all_open_windows(target.term)
    current = target
    panel.follow()
    if zoom_buf ~= shell_buf then
      if was_zoomed or (zoom_buf and U.valid_buf(zoom_buf)) then
        zoom_repoint(target.term.bufnr)
      else
        drop_dead_zoom()
      end
    else
      resync_zoom()
    end
    focus_zoom_or(target.term.window)
    return
  end
  show_session(target)
end

--- Statusline indicator: one dot per session — • open, ◦ closed (idle);
--- busy sessions blink (a blank of the same width on alternate phases, so
--- neighbouring dots never shuffle).
function M.statusline_indicator()
  if #sessions == 0 then
    return ''
  end
  -- Pure read: the phase advances once per poll tick, so the blink keeps a
  -- steady cadence no matter how often lualine evaluates this.
  local parts = {}
  for _, s in ipairs(sessions) do
    if session_busy(s) and not blink_on then
      parts[#parts + 1] = ' ' -- disappear (same width as •/◦)
    else
      parts[#parts + 1] = window_open(s.term) and '•' or '◦'
    end
  end
  return table.concat(parts, ' ')
end

--- Keymaps and autocmds. Called once at plugin load; a later call only
--- merges in options.
function M.setup(user_opts)
  opts = vim.tbl_deep_extend('force', opts, user_opts or {})
  if setup_done then return end
  setup_done = true
  vim.keymap.set({ 'n', 't' }, '<C-a>', function() M.create() end,
    { noremap = true, silent = true, desc = 'New Claude Code session' })
  vim.keymap.set({ 'n', 't' }, '<C-s>', function() M.next_session() end,
    { noremap = true, silent = true, desc = 'Switch Claude Code session' })
  vim.keymap.set({ 'n', 't' }, '<C-e>', function() diff.step_next() end,
    { noremap = true, silent = true, desc = 'Next changed file (diff panel)' })
  vim.keymap.set('t', '<C-d>', function()
    -- ON the shell split this key closes the shell, not the session. Matched
    -- by BUFFER, not window: a shell zoom shows the same buffer in the
    -- float, and <C-d> there must still mean "close the shell".
    local cur_buf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
    if U.valid_buf(shell_buf) and cur_buf == shell_buf then
      close_shell()
    else
      M.close_current()
    end
  end,
    { noremap = true, silent = true, desc = 'Close Claude Code session (or the shell split)' })
  vim.keymap.set({ 'n', 't' }, '<C-b>', function() M.toggle_shell() end,
    { noremap = true, silent = true, desc = 'Toggle shell below the session' })
  vim.keymap.set({ 'n', 't' }, '<C-space>', function() M.toggle_zoom() end,
    { noremap = true, silent = true, desc = 'Zoom session/shell fullscreen' })

  -- Remember manually closed session windows (e.g. :close, <C-w>c) for <C-s>
  -- — and drop the panel when the last displayed window goes. WinClosed fires
  -- while the window is still valid, so is_visible() would read true; defer
  -- the sync one pass, when the window is really gone.
  vim.api.nvim_create_autocmd('WinClosed', {
    callback = function(args)
      local wid = tonumber(args.match)
      -- The zoom float closed from the outside: forget it and rebuild one
      -- pass later when its buffer is still alive (diff pane moves take the
      -- float down; the buffer survives).
      if wid == zoom_win then
        vim.schedule(resync_zoom)
        return
      end
      for _, s in ipairs(sessions) do
        if s.term.window == wid then
          last_closed = s
          vim.schedule(panel_sync)
          return
        end
      end
    end,
  })

  -- The editor resized under a live zoom: refit the float to full-bleed.
  vim.api.nvim_create_autocmd('VimResized', {
    callback = function()
      if zoomed() then
        vim.api.nvim_win_set_config(zoom_win, zoom_config())
      end
    end,
  })

  -- Toggleterm force-resets ft='toggleterm' on every TermEnter, which would
  -- let lualine's extension replace the statusline again on refocus. Restore
  -- 'claude' for tagged buffers (FileType fires synchronously on any set).
  vim.api.nvim_create_autocmd('FileType', {
    pattern = 'toggleterm',
    callback = function()
      if vim.b.claude_session_name then
        vim.bo.filetype = 'claude'
      end
    end,
  })

  -- Strip cursorline/cursorcolumn wherever a terminal buffer lands (see
  -- util.TERMINAL_PLAIN for why) — the plugin's own windows are stripped at
  -- their open sites; these hooks cover toggleterm's opens and plain
  -- terminals elsewhere. Both are needed: BufWinEnter fires when an EXISTING
  -- terminal buffer is displayed, TermOpen when termopen flips an
  -- already-displayed buffer into one (toggleterm's fresh open: split first,
  -- spawn second).
  local function strip_terminal_windows(buf)
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local ok, b = pcall(vim.api.nvim_win_get_buf, w)
      if ok and b == buf then U.plain_terminal_window(w) end
    end
  end
  vim.api.nvim_create_autocmd('BufWinEnter', {
    callback = function(ev)
      if vim.bo[ev.buf].buftype ~= 'terminal' then return end
      strip_terminal_windows(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd('TermOpen', {
    callback = function(ev) strip_terminal_windows(ev.buf) end,
  })

  panel.setup()
  diff.setup()

  -- The diff panel needs a tree window to split above; the tree closing
  -- takes it with it.
  vim.api.nvim_create_autocmd('FileType', {
    pattern = 'NvimTree',
    callback = function() diff.sync(M.is_visible()) end,
  })
end

return M
