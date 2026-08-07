-- Multi-session manager for Claude Code.
--
-- Each session is a toggleterm vertical terminal (right split, 40% width)
-- whose claude process keeps running while its window is closed. Creating a
-- new session replaces the displayed window; the layout stays stable because
-- toggleterm persists the split width and every session opens via the same
-- botright vsplit + vertical resize path.
--
-- Keymaps:
--   <C-a>  create a new session and open it on the right
--   <C-s>  switch sessions (toggle / cycle / reopen last closed)
--   <C-d>  close the current session (terminal mode only)

local M = {}

local Terminal = function()
  return require('toggleterm.terminal').Terminal
end

-- --- State ---------------------------------------------------------------
-- sessions: ordered list of live records { name, term }
-- current:  the session whose window is currently displayed, if any
-- last_closed: most recently closed session whose process is still alive
local sessions = {}
local current = nil
local last_closed = nil
local seq = 0 -- monotonic counter for display names ("claude #1", ...)

-- --- Busy-state tracking -------------------------------------------------
-- `claude agents --json` reports each independent Claude session's OS pid and
-- status. We poll it on a timer, cache pid -> is_busy, and blink the dot of
-- every busy session on each statusline refresh.
local busy_by_pid = {} -- map<number pid, boolean>
local blink_on = true -- toggled once per statusline render; busy dots alternate
local poll_timer = nil
local fetch_inflight = false
local fetch_tick = 0

local POLL_INTERVAL_MS = 300 -- blink cadence + poll tick
local FETCH_EVERY = 3 -- fetch `claude agents` every N ticks (=> ~0.9s)

-- --- Notifications -------------------------------------------------------

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'claude sessions' })
end

-- --- Busy-state ----------------------------------------------------------

--- OS pid of a session's claude process, or nil if it can't be determined.
local function session_pid(s)
  local job_id = s.term and s.term.job_id
  if not job_id then return nil end
  local ok, pid = pcall(vim.fn.jobpid, job_id)
  if ok and pid and pid > 0 then return pid end
  return nil
end

--- Is this session's agent currently busy? False when the pid is unknown or
--- not yet in the cache.
local function session_busy(s)
  local pid = session_pid(s)
  return pid ~= nil and busy_by_pid[pid] == true
end

--- Async-fetch `claude agents --json` and refresh the pid -> busy cache.
--- Runs the CLI on a job and parses stdout as it arrives (non-blocking).
---
--- Sessions spawned inside an nvim that itself runs under Claude would inherit
--- CLAUDE_CODE_CHILD_SESSION and stay hidden from `claude agents`, so create()
--- strips that marker (see below) to make each session an independent, trackable
--- agent.
local function refresh_busy_state()
  if fetch_inflight then return end
  fetch_inflight = true
  local stdout = {}
  vim.fn.jobstart({ 'claude', 'agents', '--json' }, {
    stdout_buffered = true,
    on_stdout = function(_, data) vim.list_extend(stdout, data or {}) end,
    on_exit = function()
      fetch_inflight = false
      local ok, agents = pcall(vim.fn.json_decode, table.concat(stdout, ''))
      if not ok or type(agents) ~= 'table' then return end
      local next_map = {}
      for _, a in ipairs(agents) do
        if type(a) == 'table' and a.pid then
          next_map[a.pid] = (a.status == 'busy')
        end
      end
      busy_by_pid = next_map
    end,
  })
end

--- (Re)start the poll timer. Runs for the editor's lifetime; cheap when idle
--- (only blinks/refreshes while sessions exist).
local function ensure_poll_timer()
  if poll_timer then return end
  poll_timer = (vim.uv or vim.loop).new_timer()
  poll_timer:start(POLL_INTERVAL_MS, POLL_INTERVAL_MS, vim.schedule_wrap(function()
    -- Fetch agent state on a slower sub-cycle; the blink phase is advanced
    -- inside statusline_indicator() (one toggle per actual render), so we only
    -- trigger redraws here for a lively cadence.
    fetch_tick = fetch_tick + 1
    if fetch_tick % FETCH_EVERY == 0 then
      refresh_busy_state()
    end
    -- Only redraw when there is something to show, so an idle editor with no
    -- sessions pays no cost.
    if #sessions > 0 then
      vim.cmd('redrawstatus')
    end
  end))
end

-- --- Window / session helpers --------------------------------------------

--- Is this terminal's window currently displayed in the UI?
local function window_open(term)
  return term.window ~= nil
    and vim.api.nvim_win_is_valid(term.window)
    and vim.api.nvim_win_get_buf(term.window) == term.bufnr
end

--- Find the live session record for a toggleterm terminal, if any.
local function session_for_term(term)
  for _, s in ipairs(sessions) do
    if s.term == term then return s end
  end
end

--- Close the window of every displayed toggleterm terminal except `keep`.
--- Window-only: processes keep running. This guarantees the kept session alone
--- occupies the right side, and preserves the old zsh<->claude mutual exclusion
--- from util.toggle_term. Remembers the most recently closed session for <C-s>.
local function close_all_open_windows(keep)
  for _, term in ipairs(require('toggleterm.terminal').get_all()) do
    if term ~= keep and window_open(term) then
      term:close()
      local s = session_for_term(term)
      if s then last_closed = s end
    end
  end
end

--- Close everything else, open this session's window, and mark it current.
local function show_session(s)
  close_all_open_windows(s.term)
  s.term:open()
  current = s
end

--- Remove a session record from the list (idempotent).
local function remove_record(record)
  for i, s in ipairs(sessions) do
    if s == record then
      table.remove(sessions, i)
      break
    end
  end
  if current == record then
    current = nil
  end
end

-- --- Public API ----------------------------------------------------------

--- on_exit callback: auto-cleanup when a claude process ends.
--- toggleterm (close_on_exit = true default) closes the window and wipes the
--- buffer itself, so no UI work is needed here.
function M._on_session_exit(record)
  remove_record(record)
  notify('Session ended: ' .. record.name)
end

--- Create a NEW session and open it on the right.
function M.create()
  seq = seq + 1
  local name = 'claude #' .. seq
  local record = { name = name }
  record.term = Terminal():new({
    cmd = 'claude',
    direction = 'vertical',
    display_name = name,
    -- Empty string == unset for claude's child-session check (verified): this
    -- clears the marker inherited from this nvim's environment so the spawned
    -- process is treated as an independent, trackable agent.
    env = { CLAUDE_CODE_CHILD_SESSION = '' },
    on_exit = function() M._on_session_exit(record) end,
  })
  table.insert(sessions, record)
  show_session(record)
  -- Tag the buffer so the statusline can show "claude #1" instead of the raw
  -- term:// name, and use a non-toggleterm filetype so lualine's toggleterm
  -- extension (matches ft == 'toggleterm') does not replace the statusline
  -- inside sessions. Toggleterm still tracks the buffer via vim.b.toggle_number.
  if record.term.bufnr and vim.api.nvim_buf_is_valid(record.term.bufnr) then
    vim.b[record.term.bufnr].claude_session_name = name
    vim.bo[record.term.bufnr].ft = 'claude'
  end
  ensure_poll_timer()
  notify('New session: ' .. name)
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

--- Close the current session (window + process) and drop it.
--- The split stays occupied: the session that followed the closed one (or the
--- last remaining one, if the closed one was last) is shown in its place.
--- If no window is displayed, closes the most recently created session.
function M.close_current()
  if #sessions == 0 then
    notify('No claude sessions to close.', vim.log.levels.WARN)
    return
  end
  local target = current or sessions[#sessions]
  local term = target.term
  -- Position of the closed session, so its successor can be shown.
  local index
  for i, s in ipairs(sessions) do
    if s == target then
      index = i
      break
    end
  end
  if window_open(term) then
    term:close() -- window-only; the process is still alive
  end
  if term.bufnr and vim.api.nvim_buf_is_valid(term.bufnr) then
    -- Wiping the terminal buffer kills the claude job; toggleterm's TermClose
    -- autocmd cleans its registry.
    vim.api.nvim_buf_delete(term.bufnr, { force = true })
  end
  remove_record(target)
  notify('Closed session: ' .. target.name)
  -- Keep the split occupied: show the session that took the closed one's place.
  if #sessions > 0 then
    local next_session = sessions[index] or sessions[#sessions]
    show_session(next_session)
    -- Killing the claude job above (buf_delete) makes nvim's terminal handling
    -- return focus to the origin window once the job actually dies (~0.5s
    -- later), undoing show_session's focus. Refocus the shown session on a
    -- short retry loop until focus sticks.
    local tries = 0
    local function keep_focus()
      tries = tries + 1
      local win = next_session.term.window
      if vim.api.nvim_win_is_valid(win) then
        local curwin = vim.api.nvim_get_current_win()
        local mode = vim.api.nvim_get_mode().mode
        -- Refocus if focus drifted, and enter insert mode if the terminal is
        -- in terminal-normal (nt) mode.
        if curwin ~= win or mode:find('nt') then
          vim.api.nvim_set_current_win(win)
          vim.cmd('startinsert')
        end
      end
      if tries < 12 then -- ~1.8s: long enough to outlast the job-exit refocus
        vim.defer_fn(keep_focus, 150)
      end
    end
    vim.schedule(keep_focus)
  end
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
    else
      show_session(s)
    end
    return
  end

  -- Which session is currently displayed?
  local open_index
  for i, s in ipairs(sessions) do
    if window_open(s.term) then
      open_index = i
      break
    end
  end

  local target
  if open_index then
    target = sessions[open_index % #sessions + 1] -- next, wrapping around
  elseif last_closed and session_for_term(last_closed.term) then
    target = last_closed -- nothing displayed: bring back the last closed one
  else
    target = sessions[#sessions] -- most recent session
  end

  if window_open(target.term) then
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
  -- and the poll timer triggers extra redraws while sessions exist.
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

--- Define the keymaps and autocmds. Called once at plugin load.
function M.setup()
  vim.keymap.set({ 'n', 't' }, '<C-a>', function() M.create() end,
    { noremap = true, silent = true, desc = 'New Claude Code session' })
  vim.keymap.set({ 'n', 't' }, '<C-s>', function() M.next_session() end,
    { noremap = true, silent = true, desc = 'Switch Claude Code session' })
  vim.keymap.set('t', '<C-d>', function() M.close_current() end,
    { noremap = true, silent = true, desc = 'Close Claude Code session' })

  -- Remember manually closed session windows (e.g. :close) so <C-s> can bring
  -- the most recently closed session back.
  vim.api.nvim_create_autocmd('WinClosed', {
    callback = function(args)
      local wid = tonumber(args.match)
      for _, s in ipairs(sessions) do
        if s.term.window == wid then
          last_closed = s
          break
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
end

return M
