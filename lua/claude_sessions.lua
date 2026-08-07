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

-- --- Options --------------------------------------------------------------
-- Defaults, merged over by setup(). `auto_reload` reloads file buffers that a
-- running session's claude process changed on disk. Reloads are safe:
-- `checktime` skips buffers with uncommitted edits, so in-progress work is
-- never clobbered.
local opts = {
  auto_reload = true,
}
local setup_done = false

-- --- State ---------------------------------------------------------------
-- sessions: ordered list of live records { name, term }
-- current:  the session whose window is currently displayed, if any
-- last_closed: most recently closed session whose process is still alive
local sessions = {}
local current = nil
local last_closed = nil

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
local CHECK_EVERY = 3 -- reload externally-changed buffers every N ticks (=> ~0.9s)

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
      -- A session's claude process edits files in the background while the
      -- user works elsewhere; pick those edits up in open buffers. `checktime`
      -- reloads only buffers whose file changed on disk and that have no
      -- uncommitted edits, so the user's in-progress work is never clobbered.
      if opts.auto_reload and fetch_tick % CHECK_EVERY == 0 then
        vim.cmd('checktime')
      end
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

--- Renumber the live sessions 1..N (in list order) so the display names never
--- grow past the number of currently open sessions: with three sessions the
--- statusline shows "claude #1..#3" no matter how many have been created and
--- closed before.
local function renumber()
  for i, s in ipairs(sessions) do
    local name = 'claude #' .. i
    s.name = name
    if s.term then
      s.term.display_name = name
      if s.term.bufnr and vim.api.nvim_buf_is_valid(s.term.bufnr) then
        vim.b[s.term.bufnr].claude_session_name = name
      end
    end
  end
end

-- --- Public API ----------------------------------------------------------

--- on_exit callback: auto-cleanup when a claude process ends.
--- Sessions run with close_on_exit = false (see create) so that a killed job's
--- exit does not make toggleterm close the window / restore focus to the origin
--- window; that focus restore is what makes <C-d> steal focus ~0.5s later. We
--- tidy the window and buffer here instead.
function M._on_session_exit(record)
  local term = record.term
  if term then
    if window_open(term) then
      term:close()
    end
    if term.bufnr and vim.api.nvim_buf_is_valid(term.bufnr) then
      vim.api.nvim_buf_delete(term.bufnr, { force = true })
    end
  end
  remove_record(record)
  renumber()
end

--- Create a NEW session and open it on the right.
function M.create()
  local record = { name = '' } -- renumbered below
  record.term = Terminal():new({
    cmd = 'claude',
    direction = 'vertical',
    display_name = '', -- set by renumber()
    -- Empty string == unset for claude's child-session check (verified): this
    -- clears the marker inherited from this nvim's environment so the spawned
    -- process is treated as an independent, trackable agent.
    env = { CLAUDE_CODE_CHILD_SESSION = '' },
    -- Keep toggleterm from closing the window / restoring focus when the job
    -- dies; _on_session_exit cleans up instead.
    close_on_exit = false,
    on_exit = function() M._on_session_exit(record) end,
  })
  table.insert(sessions, record)
  show_session(record)
  -- Use a non-toggleterm filetype so lualine's toggleterm extension (matches
  -- ft == 'toggleterm') does not replace the statusline inside sessions.
  -- Toggleterm still tracks the buffer via vim.b.toggle_number.
  if record.term.bufnr and vim.api.nvim_buf_is_valid(record.term.bufnr) then
    vim.bo[record.term.bufnr].ft = 'claude'
  end
  renumber() -- names the new session (and renumbers existing ones) 1..N
  ensure_poll_timer()
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
  -- Remember the window showing the target, so the split can be kept in place.
  local win = window_open(term) and term.window or nil
  if term.bufnr and vim.api.nvim_buf_is_valid(term.bufnr) then
    -- Wiping the terminal buffer kills the claude job; the record is dropped
    -- below. close_on_exit = false keeps the job's later exit from closing the
    -- window / moving focus.
    vim.api.nvim_buf_delete(term.bufnr, { force = true })
  end
  remove_record(target)
  renumber() -- keep display names 1..N as sessions are closed
  notify('Closed session: ' .. target.name)
  if #sessions > 0 then
    local next_session = sessions[index] or sessions[#sessions]
    if win and vim.api.nvim_win_is_valid(win) then
      -- Keep the same split: swap the next session's buffer into this window
      -- in place (no window close/reopen, so the statusline and bufferline get
      -- a single clean update instead of flickering).
      close_all_open_windows(next_session.term)
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_buf(win, next_session.term.bufnr)
      next_session.term.window = win
      current = next_session
      -- The window inherited the closed session's highlights; apply the new
      -- session's.
      require('toggleterm.ui').hl_term(next_session.term)
      vim.cmd('startinsert')
    else
      show_session(next_session)
    end
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
