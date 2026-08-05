-- Multi-session manager for Claude Code.
--
-- Each session is a toggleterm vertical terminal (right split, 40% width)
-- whose claude process keeps running while its window is closed. Creating a
-- new session replaces the displayed window; the layout stays stable because
-- toggleterm persists the split width (persist_size default) and every
-- session opens via the same "botright vsplit" + "vertical resize" path.
--
-- Keymaps:
--   <C-a>  create a new session and open it on the right
--   <C-d>  close the current session (terminal mode only)

local M = {}

local function toggleterm_terminal()
  return require('toggleterm.terminal').Terminal
end

-- Ordered list of live sessions: { name = string, term = Terminal }
local sessions = {}
-- Record whose window is currently displayed, if any.
local current = nil
-- Session whose window was most recently closed (still alive).
local last_closed = nil
-- Monotonic counter for display names ("claude #1", "claude #2", ...).
local seq = 0

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'claude sessions' })
end

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
--- Window-only close: processes keep running. Guarantees the new session
--- alone occupies the right side, and preserves the old zsh<->claude mutual
--- exclusion from util.toggle_term. Remembers the most recently closed
--- session so <C-s> can bring it back.
local function close_all_open_windows(keep)
  for _, term in ipairs(require('toggleterm.terminal').get_all()) do
    if term ~= keep and window_open(term) then
      term:close()
      local s = session_for_term(term)
      if s then last_closed = s end
    end
  end
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

--- on_exit callback: auto-cleanup when a claude process ends.
--- toggleterm (close_on_exit = true default) closes the window and wipes
--- the buffer itself, so no UI work is needed here.
function M._on_session_exit(record)
  remove_record(record)
  notify('Session ended: ' .. record.name)
end

--- Create a NEW session and open it on the right.
function M.create()
  seq = seq + 1
  local name = 'claude #' .. seq
  local record = { name = name }
  record.term = toggleterm_terminal():new({
    cmd = 'claude',
    direction = 'vertical',
    display_name = name,
    on_exit = function() M._on_session_exit(record) end,
  })
  table.insert(sessions, record)
  close_all_open_windows(record.term)
  record.term:open() -- botright vsplit + vertical resize 40%
  -- tag the buffer so the statusline can show "claude #1" instead of the
  -- raw term:// buffer name; and use a non-toggleterm filetype so lualine's
  -- toggleterm extension (which matches ft == 'toggleterm') does not replace
  -- the statusline inside sessions. Toggleterm still tracks the buffer via
  -- vim.b.toggle_number.
  if record.term.bufnr and vim.api.nvim_buf_is_valid(record.term.bufnr) then
    vim.b[record.term.bufnr].claude_session_name = name
    vim.bo[record.term.bufnr].ft = 'claude'
  end
  current = record
  notify('New session: ' .. name)
end

--- Close the current session (window + process) and drop it.
--- If no window is displayed, closes the most recently created session.
function M.close_current()
  if #sessions == 0 then
    notify('No claude sessions to close.', vim.log.levels.WARN)
    return
  end
  local target = current or sessions[#sessions]
  local term = target.term
  if window_open(term) then
    term:close() -- window-only; the process is still alive
  end
  if term.bufnr and vim.api.nvim_buf_is_valid(term.bufnr) then
    -- Wiping the terminal buffer kills the claude job; toggleterm's buffer
    -- TermClose autocmd cleans its registry.
    vim.api.nvim_buf_delete(term.bufnr, { force = true })
  end
  remove_record(target)
  notify('Closed session: ' .. target.name)
end

--- Statusline indicator: one dot per session; filled (•) for the session
--- whose window is currently displayed, hollow (◦) for the rest.
function M.statusline_indicator()
  if #sessions == 0 then
    return ''
  end
  local parts = {}
  for _, s in ipairs(sessions) do
    table.insert(parts, window_open(s.term) and '•' or '◦')
  end
  return table.concat(parts, ' ')
end

--- <C-s>: cycle sessions. If no session window is displayed, show the most
--- recently closed one; otherwise switch to the next session in the list
--- (wrapping around).
function M.next_session()
  if #sessions == 0 then
    notify('No claude sessions. Press <C-a> to create one.', vim.log.levels.WARN)
    return
  end

  -- which session is currently displayed?
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
  close_all_open_windows(target.term)
  target.term:open()
  current = target
end

--- Define the keymaps. Called once at plugin load.
function M.setup()
  vim.keymap.set({ 'n', 't' }, '<C-a>', function() M.create() end,
    { noremap = true, silent = true, desc = 'New Claude Code session' })
  vim.keymap.set({ 'n', 't' }, '<C-s>', function() M.next_session() end,
    { noremap = true, silent = true, desc = 'Switch Claude Code session' })
  vim.keymap.set('t', '<C-d>', function() M.close_current() end,
    { noremap = true, silent = true, desc = 'Close Claude Code session' })

  -- Remember manually closed session windows (e.g. :close) so <C-s> can
  -- bring the most recently closed session back.
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

  -- Toggleterm force-resets ft='toggleterm' on every TermEnter (see its
  -- handle_term_enter FIXME), which would let lualine's toggleterm extension
  -- replace the statusline again on refocus. React to the reset itself: the
  -- FileType event fires synchronously whenever ft is set to 'toggleterm'
  -- (by any code path), so restore 'claude' immediately for tagged buffers.
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
