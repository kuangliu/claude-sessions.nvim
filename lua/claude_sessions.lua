-- Multi-session manager for Claude Code.
--
-- Each session is a toggleterm vertical terminal (right split, 40% width)
-- whose claude process keeps running while its window is closed. Creating a
-- new session replaces the displayed window; the layout stays stable because
-- toggleterm persists the split width and every session opens via the same
-- botright vsplit + vertical resize path.
--
-- While a session window is displayed, a session-list panel is split below
-- nvim-tree, styled after Claude Code's session picker: a state symbol and
-- name per session (with the state word and a blank separator below it), the
-- displayed session marked by an arrow and a block background; j/k steps
-- through the list switching sessions live. See claude_sessions/panel.lua.
--
-- Keymaps:
--   <C-a>  create a new session and open it on the right
--   <C-s>  switch sessions (toggle / cycle / reopen last closed)
--   <C-e>  focus the diff panel and step to the next changed file — the
--          first press starts the sweep, later presses advance from the
--          selection and wrap past the last file (either window focused)
--   <C-d>  close the current session (terminal mode only)

local M = {}

local panel = require('claude_sessions.panel')
local diff = require('claude_sessions.diff')
local U = require('claude_sessions.util') -- shared window/buffer helpers

-- --- Options --------------------------------------------------------------
-- Defaults, merged over by setup(). `auto_reload` reloads file buffers that a
-- running session's claude process changed on disk. Reloads are safe:
-- `checktime` skips buffers with uncommitted edits, so in-progress work is
-- never clobbered.
local opts = {
  auto_reload = true,
}
local setup_done = false

-- --- State ----------------------------------------------------------------
-- sessions: ordered list of live records { name, custom_name, term }
-- current:  the session whose window is currently displayed, if any
-- last_closed: most recently closed session whose process is still alive
local sessions = {}
local current = nil
local last_closed = nil

-- --- Small helpers ----------------------------------------------------------

--- Focus a window, if it is still there. util's helper — the fallback-less
--- spelling of the same pcall'd focus the panels' reclaim uses.
local focus = U.focus

--- The plugin's notify convention (util's shared helper — the title lives
--- there, and the panels spell it too).
local notify = U.notify

-- --- Poll loop -------------------------------------------------------------
-- While sessions exist, a uv timer ticks every POLL_INTERVAL_MS and drives two
-- cheap jobs: fetching each agent's busy state (`claude agents --json`) and,
-- while anything is busy, blinking the statusline dots and auto-reloading
-- buffers the agent changed on disk. Everything is gated on `any_busy` (or on
-- busy<->idle transitions), so an idle editor pays nothing, and the timer
-- stops entirely once the last session closes.
local busy_by_pid = {} -- map<number pid, string status ('busy'/'idle'/...)
local any_busy = false -- is any live session's agent busy right now?
local blink_on = true -- toggled once per statusline render; busy dots alternate
local poll_timer = nil
local fetch_inflight = false
local tick = 0

local POLL_INTERVAL_MS = 300 -- blink cadence + poll tick
local FETCH_EVERY = 7 -- fetch `claude agents` every N ticks (=> ~2.1s)
local CHECK_EVERY = 3 -- reload externally-changed buffers every N ticks (=> ~0.9s)

--- OS pid of a session's claude process, or nil if it can't be determined.
local function session_pid(s)
  local job_id = s.term and s.term.job_id
  if not job_id then return nil end
  local ok, pid = pcall(vim.fn.jobpid, job_id)
  if ok and pid and pid > 0 then return pid end
  return nil
end

--- This session's agent state as reported by `claude agents --json` —
--- 'busy', 'idle', or anything else the CLI grows (e.g. a blocked state);
--- nil when the pid is unknown or not yet in the cache.
local function session_state(s)
  local pid = session_pid(s)
  if pid == nil then return nil end
  return busy_by_pid[pid]
end

--- Is this session's agent currently busy? False when the state is unknown.
local function session_busy(s)
  return session_state(s) == 'busy'
end

--- Recompute `any_busy` from the fresh pid cache. On a busy<->idle transition
--- the statusline needs one redraw to start/stop blinking; when the agent just
--- went quiet, one extra `checktime` picks up writes from its final working
--- ticks.
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

--- Async-fetch `claude agents --json` and refresh the pid -> busy cache.
--- Runs the CLI on a job (non-blocking) — util's shared job helper lands the
--- stdout as one string, or nil on a failed spawn (e.g. `claude` not on PATH
--- when nvim was launched without the shell environment: keep the last known
--- busy state and retry on the next tick).
---
--- Sessions spawned inside an nvim that itself runs under Claude would inherit
--- CLAUDE_CODE_CHILD_SESSION and stay hidden from `claude agents`, so create()
--- strips that marker (see below) to make each session an independent, trackable
--- agent.
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

--- Stop the poll timer. Called when the last session closes; also resets the
--- cycle counter and busy state so a later start begins clean.
local function stop_poll_timer()
  if poll_timer then
    poll_timer:stop()
    poll_timer:close()
    poll_timer = nil
  end
  tick = 0
  any_busy = false
end

--- One timer tick: fetch agent state on a slow sub-cycle, and keep the blink
--- (plus auto-reload) alive while something is actually busy.
local function poll_tick()
  tick = tick + 1
  if #sessions == 0 then
    stop_poll_timer()
    return
  end
  -- Panel mode guard's periodic check (see panel.install_mode_guard).
  vim.cmd('doautocmd User ClaudeSessionsTick')
  -- An agent actively working is the usual reason the working tree changes,
  -- so the diff panel tracks it: up → repaint per tick WHILE the agent works
  -- (the tree can only be changing under its hands — an idle editor's tree is
  -- static, so refreshing it 3x/sec bought nothing), slow-cycle otherwise;
  -- down → probe+open on the slow sub-cycle (two git jobs), so a panel that
  -- was never drawn (a clean workspace at open time) still appears when the
  -- first change lands — a refresh-only call here would be a permanent no-op
  -- then.
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
  -- The blink phase is advanced inside statusline_indicator() (one toggle per
  -- actual render), so we only redraw here to keep a lively blink while busy.
  if any_busy then
    -- Reload file buffers the agent is actively writing, skipping buffers
    -- with uncommitted edits.
    if opts.auto_reload and tick % CHECK_EVERY == 0 then
      vim.cmd('checktime')
    end
    vim.cmd('redrawstatus')
  end
end

--- (Re)start the poll timer. Cheap while idle: a tick that finds no sessions
--- stops the timer again, so an editor with no sessions pays nothing.
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

--- Find the live session record for a toggleterm terminal, if any.
local function session_for_term(term)
  return find_session(function(s) return s.term == term end)
end

--- Index of `record` in the sessions list, or nil.
local function find_session_index(record)
  return select(2, find_session(function(s) return s == record end))
end

-- Defined in the Display section below; forward-declared so the panel hooks
-- bound before it capture the local, not a nil global.
local show_session

--- Push a session's display name into its terminal: toggleterm's display_name
--- and the buffer var the statusline reads.
local function apply_name(s, name)
  s.name = name
  local term = s.term
  if not term then return end
  term.display_name = name
  if U.valid_buf(term.bufnr) then
    vim.b[term.bufnr].claude_session_name = name
  end
end

--- Default session names. Every session is just `claude` — the panel's cursor
--- and the window layout tell them apart. Custom-named sessions (panel `r`)
--- keep their name through renumbers.
local function renumber()
  for _, s in ipairs(sessions) do
    if not s.custom_name then apply_name(s, 'claude') end
  end
end

--- Drop a session record: remove it from the list, renumber the rest, and
--- forget it as current / last-closed.
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

--- Push the registry/window state to both panels: re-render their rows, or
--- close them when nothing is displayed anymore. The diff panel shadows the
--- session panel's visibility (its open/close decision is diff.sync's). The
--- hold for a session switch lives HERE — one guard, both halves (panel.switching):
--- panel.sync holds its own open through the churn, and the diff half must too,
--- or the churn's close_all_open_windows → panel_sync initiates a redundant
--- open mid-churn (show_session's own diff.open() then lands as a no-op there).
--- No hold inside diff.sync itself: the panels read each other only through
--- this module, which binds both — the churn owner's depth is the right one.
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
      -- the CLI's own status string ('busy'/'idle'/...), for the panel's word
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

--- The panel's <C-d>: kill the session on that row. `M.close_current` is
--- defined below (public API), so this closure resolves it at call time.
panel.close_session = function(i)
  local s = sessions[i]
  if s then M.close_current(s, { stepping = true }) end
end

panel.rename_session = function(i, name)
  if sessions[i] then M.rename(i, name) end
end

-- --- Display ----------------------------------------------------------------

--- Close the window of every displayed toggleterm terminal except `keep`.
--- Window-only: processes keep running. This guarantees the kept session alone
--- occupies the right side, and preserves the old zsh<->claude mutual exclusion
--- from util.toggle_term. Remembers the most recently closed session for <C-s>.
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

--- Run `open` (a toggleterm terminal open) without letting toggleterm request
--- insert mode. A no-op unless `stepping`.
---
--- toggleterm's BufEnter handler (persist_mode = false -> start_in_insert =
--- true) schedules a startinsert on every programmatic terminal switch; the
--- scheduled call fires after this function returns, by which time the panel
--- has taken focus back, so insert lands on the panel and the statusline
--- flashes INSERT (or the nomodifiable panel takes the E21). eventignore
--- can't stop an already-scheduled callback, but it CAN stop the BufEnter
--- autocmd from scheduling one — it is honored while the autocmd fires, i.e.
--- inside the open below. The synchronous spawn-time startinsert
--- (setup_buffer_autocommands checks config.start_in_insert) is disarmed the
--- same way, for the brand-new-terminal path of the open. When the user opens
--- a session for real (<C-s>/<CR>/<C-a>) events flow normally and the
--- terminal starts in insert as usual.
local function without_insert(stepping, open)
  if not stepping then
    open()
    return
  end
  local saved_ei = vim.o.eventignore
  vim.o.eventignore = 'BufEnter'
  local ok_cfg, cfg = pcall(require, 'toggleterm.config')
  local saved_sii
  if ok_cfg then
    saved_sii = cfg.get('start_in_insert')
    cfg.set({ start_in_insert = false })
  end
  open()
  vim.o.eventignore = saved_ei
  if ok_cfg then cfg.set({ start_in_insert = saved_sii }) end
end

--- Close everything else, open this session's window, and mark it current.
--- Keeps the panel in sync. Focus: the panel's fresh open (a split below the
--- tree) steals focus, so hand it back to the session window — except while
--- the panel is stepping (j/k), where the panel keeps the cursor.
show_session = function(s)
  local stepping = panel.stepping
  -- Already displayed: opening again would split a second window over the
  -- same terminal (toggleterm's open() always spawns a new split). Just focus
  -- the existing window — l/<CR> on the displayed row means "show me it".
  if window_open(s.term) then
    current = s
    panel.follow()
    focus(s.term.window)
    return
  end

  panel.switching = true -- hold panel_sync's both halves through the window churn
  without_insert(stepping, function()
    close_all_open_windows(s.term)
    s.term:open()
  end)
  panel.switching = false
  current = s
  panel.open() -- refresh rows (open/closed states flipped)
  diff.open() -- the uncommitted-changes panel above the tree

  if stepping then
    -- Focus: the just-opened terminal keeps it for THIS event-loop pass. The
    -- panel takes focus back one scheduled pass later (panel.step re-claims),
    -- which is guaranteed to run AFTER any startinsert closures toggleterm
    -- queued behind the BufEnter of this very switch — those fire while the
    -- terminal still holds focus, where they are harmless. Focusing the panel
    -- synchronously instead would let a queued startinsert fire on the panel
    -- and flash INSERT on the statusline.
    return
  end
  panel.follow() -- panel cursor follows the displayed session
  focus(s.term.window)
end

--- on_exit callback: auto-cleanup when a claude process ends.
--- Sessions run with close_on_exit = false (see create) so that a killed job's
--- exit does not make toggleterm close the window / restore focus to the origin
--- window; that focus restore is what makes <C-d> steal focus ~0.5s later. We
--- tidy the window and buffer here instead.
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
    -- Empty string == unset for claude's child-session check (verified): this
    -- clears the marker inherited from this nvim's environment so the spawned
    -- process is treated as an independent, trackable agent.
    env = { CLAUDE_CODE_CHILD_SESSION = '' },
    -- Keep toggleterm from closing the window / restoring focus when the job
    -- dies; on_session_exit cleans up instead.
    close_on_exit = false,
    on_exit = function() on_session_exit(record) end,
  })
  table.insert(sessions, record)
  show_session(record)
  -- Use a non-toggleterm filetype so lualine's toggleterm extension (matches
  -- ft == 'toggleterm') does not replace the statusline inside sessions.
  -- Toggleterm still tracks the buffer via vim.b.toggle_number.
  if U.valid_buf(record.term.bufnr) then
    vim.bo[record.term.bufnr].ft = 'claude'
  end
  renumber() -- names the new session (custom names elsewhere are kept)
  start_poll_timer()
  notify('New session: ' .. record.name)
  -- When <C-a> fires from inside an existing terminal (t-mode mapping), nvim's
  -- terminal handling overrides toggleterm's startinsert once the mapping
  -- completes, leaving the new session in terminal normal mode. Schedule
  -- startinsert to run after the mapping machinery settles.
  vim.schedule(function()
    if vim.api.nvim_get_current_win() == record.term.window then
      vim.cmd('startinsert')
    end
  end)
end

--- Close a session (window + process) and drop it. `target` picks the session;
--- default is the displayed one (or the most recently created when none is
--- displayed). The split stays occupied: the session that followed the closed
--- one (or the last remaining one, if the closed one was last) is shown in its
--- place. With `close_opts.stepping` (a panel-driven close) focus stays on the
--- panel: the successor is still swapped into the split, but silently, and
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
  -- Remember the window showing the target, so the split can be kept in place.
  local win = window_open(term) and term.window or nil

  -- Wiping the terminal buffer kills the claude job; the record is dropped
  -- below. close_on_exit = false keeps the job's later exit from closing the
  -- window / moving focus. Deleting the LAST buffer of its window also tears
  -- the window down, so `win` may be invalid afterwards — re-checked below.
  if U.valid_buf(term.bufnr) then
    vim.api.nvim_buf_delete(term.bufnr, { force = true })
  end
  drop_record(target)
  notify('Closed session: ' .. target.name)

  if #sessions == 0 then
    panel_sync() -- last session gone: drop the panel
    return
  end
  local next_session = sessions[index] or sessions[#sessions]

  -- The closed session's window survived the buffer wipe: keep the same split
  -- and swap the successor's buffer in (no window close/reopen, so the
  -- statusline and bufferline get a single clean update instead of
  -- flickering). Panel-driven: the cursor stays on the panel where the user
  -- closed (rows shifted, refresh clamps it); the terminal takes insert mode
  -- when the user next enters it.
  if U.valid_win(win) then
    close_all_open_windows(next_session.term)
    vim.api.nvim_win_set_buf(win, next_session.term.bufnr)
    next_session.term.window = win
    current = next_session
    -- The window inherited the closed session's highlights; apply the new
    -- session's.
    require('toggleterm.ui').hl_term(next_session.term)
    panel.open()
    diff.refresh()
    if not stepping then
      vim.api.nvim_set_current_win(win)
      vim.cmd('startinsert')
      panel.follow()
    end
    return
  end

  -- The closed session's window went away with its buffer.
  if not stepping then
    show_session(next_session)
    return
  end
  if window_open(next_session.term) then
    -- Background close: nothing on screen was showing the closed session, so
    -- only the rows shrink.
    panel.refresh()
    return
  end
  -- The DISPLAYED session was closed (panel-driven): show the successor
  -- through the normal path — panel.stepping keeps show_session from letting
  -- toggleterm request insert mode. No panel.step is driving this close, so
  -- re-claim the panel one scheduled pass later — FIFO behind any startinsert
  -- closures toggleterm queued, which fire harmlessly on the terminal.
  panel.stepping = stepping
  show_session(next_session)
  panel.stepping = false
  panel.reclaim_focus()
end

--- Is any claude session window currently displayed in the UI?
--- Used to enforce mutual exclusion with regular terminals: opening a
--- terminal closes a visible session window first (see close_window), and
--- opening a session closes open terminals via close_all_open_windows.
function M.is_visible()
  return displayed_session() ~= nil
end

--- Close the displayed session window(s) without killing their processes.
--- The split closes, the closed session is remembered as last_closed so <C-s>
--- can bring it back, and current is cleared. Returns true if any window was
--- closed.
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

--- Rename session `i` (1-based, panel row). An empty result restores the
--- default `claude` name and re-enables renumbering for it; a custom name
--- survives later renumbers (creates/closes reshuffle the others around it).
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

--- <C-s>: cycle sessions. With a single session, toggle its window
--- open/closed. With multiple, if no session window is displayed, show the
--- most recently closed one; otherwise switch to the next session in the
--- list (wrapping around).
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
    else
      show_session(s)
    end
    return
  end

  -- Pick the target: the session after the displayed one (wrapping), or —
  -- nothing displayed — the last closed one, else the most recent. last_closed
  -- is only ever set to live records (drop_record clears it), so it needs no
  -- liveness check.
  local displayed, displayed_index = displayed_session()
  local target = displayed and sessions[displayed_index % #sessions + 1]
    or last_closed
    or sessions[#sessions]

  if window_open(target.term) then
    -- Close any other open toggleterm window (e.g. a zsh terminal) so the
    -- session alone is displayed, then focus it.
    close_all_open_windows(target.term)
    target.term:focus()
    return
  end
  show_session(target)
end

--- Statusline indicator: one dot per session.
---   •  window open (idle)        ◦  window closed (idle)
---   busy sessions blink — the dot shows on one refresh and disappears (a
---   blank of the same width) on the next, so a busy session reads as a
---   flashing dot. Width is kept stable across phases so neighbouring dots
---   don't shuffle left/right while blinking.
function M.statusline_indicator()
  if #sessions == 0 then
    return ''
  end
  -- Advance the blink phase each redraw; lualine calls this on every refresh
  -- and the poll timer triggers extra redraws while a session is busy.
  blink_on = not blink_on
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

--- Define the keymaps and autocmds. Called once at plugin load; a later call
--- (e.g. from a lazy.nvim `config` block) only merges in options.
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
  vim.keymap.set('t', '<C-d>', function() M.close_current() end,
    { noremap = true, silent = true, desc = 'Close Claude Code session' })

  -- Remember manually closed session windows (e.g. :close, <C-w>c, q) so
  -- <C-s> can bring the most recently closed session back — and drop the
  -- panel when the last displayed window goes: closing the window directly
  -- bypasses close_window(), which is where the panel usually learns about
  -- visibility changes. WinClosed fires while the window is still valid
  -- (nvim tears it down after the event), so is_visible() would read true and
  -- keep the panel — defer the sync one event-loop pass, when the window is
  -- really gone.
  vim.api.nvim_create_autocmd('WinClosed', {
    callback = function(args)
      local wid = tonumber(args.match)
      for _, s in ipairs(sessions) do
        if s.term.window == wid then
          last_closed = s
          vim.schedule(panel_sync)
          return
        end
      end
    end,
  })

  -- Toggleterm force-resets ft='toggleterm' on every TermEnter (its
  -- handle_term_enter FIXME), which would let lualine's toggleterm extension
  -- replace the statusline again on refocus. Restore 'claude' for tagged
  -- buffers whenever the reset fires (FileType is synchronous on any ft set).
  vim.api.nvim_create_autocmd('FileType', {
    pattern = 'toggleterm',
    callback = function()
      if vim.b.claude_session_name then
        vim.bo.filetype = 'claude'
      end
    end,
  })

  panel.setup()
  diff.setup()

  -- The diff panel needs a tree window to split above; the tree closing (or
  -- the last displayed session closing) takes the diff panel with it.
  vim.api.nvim_create_autocmd('FileType', {
    pattern = 'NvimTree',
    callback = function() diff.sync(M.is_visible()) end,
  })
end

return M
