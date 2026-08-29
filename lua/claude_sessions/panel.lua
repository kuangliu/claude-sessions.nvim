-- The session-list panel split below nvim-tree, styled after diffview's
-- commit-history panel: one fixed-column row per live claude session (index,
-- agent name, busy state), cursorline browsing, debounced stepping that
-- switches sessions live.
--
-- Shown while a session window is displayed and an nvim-tree window exists to
-- split below; closed when the last displayed session closes. The panel never
-- touches the sessions themselves — q dismisses it, the processes keep
-- running.
--
-- The main module owns the session registry; this file consumes it through
-- the `snapshot`/`show` functions assigned there at load (no require cycle).
-- Until they are bound the panel is inert.

local M = {}

-- Bound by the main module: `snapshot()` returns the live sessions as an
-- array of { busy = bool, open = bool } (array index == session number),
-- `show(i)` displays session i, `close_session(i)` kills session i,
-- `row_name(i)` is the session's display name (rename prompt default), and
-- `rename_session(i, name)` renames it.
-- (Named close_session: M.close below tears the panel itself down.)
M.snapshot = nil
M.show = nil
M.close_session = nil
M.row_name = nil
M.rename_session = nil

-- True while the panel is driving a switch (stepping): show_session then
-- skips its focus juggling so the cursor stays on the panel.
M.stepping = false

-- True while the registry is mid-switch (show_session swaps session windows):
-- sync() holds the panel open through the churn so its position never moves.
M.switching = false

-- Panel window and buffer, nil when closed. Validity is re-checked on every
-- use — the window can also go away through user layout edits.
M.win = nil
M.buf = nil

local ns = vim.api.nvim_create_namespace('claude_sessions_panel')
local step_timer ---@type uv.uv_timer_t?

-- Fixed columns (0-based), mirroring the commit panel's hash column:
--   ' #1   claude   busy'
--    ^1   ^6        ^15
local ID_PAD = 4
local STATE_PAD = 8
local BUSY_COL = 1 + ID_PAD + 1 + STATE_PAD + 1

local function define_highlights()
  -- Same accent blue as diffview's commit hashes; onedark's green and
  -- comment grey for the busy / idle words.
  vim.api.nvim_set_hl(0, 'ClaudeSessionsPanelId', { fg = '#61afef' })
  vim.api.nvim_set_hl(0, 'ClaudeSessionsPanelBusy', { fg = '#98c379' })
  vim.api.nvim_set_hl(0, 'ClaudeSessionsPanelIdle', { fg = '#5c6370' })
end

-- The window currently showing nvim-tree's buffer, or nil.
local function tree_window()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local ok, b = pcall(vim.api.nvim_win_get_buf, w)
    if ok and vim.bo[b].filetype == 'NvimTree' then
      return w
    end
  end
end

-- Rewrite the rows and their highlights. Buffer line n is session n — no
-- pseudo rows, so the cursor row IS the selection. The middle word is the
-- agent name — `claude`, or the session's custom name once one is set with
-- `r`; renamed rows drop their trailing highlight so the name reads plain.
local function render(buf, snap)
  local lines = {}
  for i, s in ipairs(snap) do
    lines[i] = string.format(' %-' .. ID_PAD .. 's %-' .. STATE_PAD .. 's %s',
      '#' .. i, s.name or 'claude', s.busy and 'busy' or 'idle')
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  for i, s in ipairs(snap) do
    local lnum = i - 1 -- 0-based extmark row
    -- the index, in the commit panel's hash accent
    vim.api.nvim_buf_set_extmark(buf, ns, lnum, 1, {
      end_col = 1 + #('#' .. i), hl_group = 'ClaudeSessionsPanelId',
    })
    -- the busy word: green while the agent works, comment grey when idle
    vim.api.nvim_buf_set_extmark(buf, ns, lnum, BUSY_COL, {
      end_col = BUSY_COL + 4,
      hl_group = s.busy and 'ClaudeSessionsPanelBusy' or 'ClaudeSessionsPanelIdle',
    })
  end
end

-- Display the session on buffer row `row`. keep_focus keeps the cursor on the
-- panel (stepping); otherwise focus follows the session window. The focus
-- juggling itself lives in the main module's show_session.
local function select_row(row, keep_focus)
  M.stepping = keep_focus
  M.show(row)
  M.stepping = false
end

-- <Down>/<Up>/j/k: move the cursor one row and switch to that session. The
-- switch is debounced (~120ms): held keys sweep the cursor without paying a
-- terminal open per row, and the row under the cursor when the sweep settles
-- is the one that loads. Focus ends up back on the panel, one event-loop pass
-- after the switch — see the comment inside the debounce callback.
local function step(dir)
  -- The panel may not currently hold focus (keys go through the terminal
  -- window that shows the cursorline'd panel below the tree); drive its
  -- cursor from wherever we are.
  if not (M.win and vim.api.nvim_win_is_valid(M.win)) then return end
  local snap = M.snapshot and M.snapshot() or {}
  local row = vim.api.nvim_win_get_cursor(M.win)[1] + dir
  if row < 1 or row > #snap then return end
  vim.api.nvim_win_set_cursor(M.win, { row, 0 })

  if step_timer then
    pcall(function() step_timer:stop() end)
    pcall(function() step_timer:close() end)
  end
  step_timer = vim.defer_fn(function()
    step_timer = nil
    if not (M.win and vim.api.nvim_win_is_valid(M.win)) then return end
    select_row(vim.api.nvim_win_get_cursor(M.win)[1], true)
    -- select_row left focus on the just-opened terminal, where any startinsert
    -- toggleterm queued behind this switch fires harmlessly. Take the focus
    -- back in the SAME event-loop pass — vim.schedule runs FIFO behind those
    -- queued closures with no redraw in between, so even a stray insert that
    -- lands on the panel lives for microseconds and is never painted.
    vim.schedule(function()
      if not (M.win and vim.api.nvim_win_is_valid(M.win)) then return end
      if vim.fn.mode():find('^[it]') then vim.cmd('stopinsert') end
      vim.api.nvim_set_current_win(M.win)
    end)
  end, 120)
end

-- <CR>/l/o: switch to the session under the cursor and focus it.
local function open_current()
  if not M.win or not vim.api.nvim_win_is_valid(M.win) then return end
  select_row(vim.api.nvim_win_get_cursor(M.win)[1], false)
end

-- <C-d>: kill the session under the cursor. Same semantics as terminal-mode
-- <C-d>: the process dies, the row disappears, the split shows the next
-- session. Focus stays on the panel.
local function close_current_row()
  if not (M.win and vim.api.nvim_win_is_valid(M.win)) then return end
  local row = vim.api.nvim_win_get_cursor(M.win)[1]
  M.close_session(row)
end

-- <r>: rename the session under the cursor. An empty input restores the
-- default `claude` name; Esc cancels.
local function rename_current_row()
  if not (M.win and vim.api.nvim_win_is_valid(M.win)) then return end
  local row = vim.api.nvim_win_get_cursor(M.win)[1]
  local default = M.row_name and M.row_name(row) or ''
  vim.ui.input({ prompt = 'Session name: ', default = default }, function(value)
    if value == nil then return end -- cancelled
    M.rename_session(row, value)
  end)
end

-- Tear the panel down (window + buffer). Sessions keep running.
function M.close()
  if step_timer then
    pcall(function() step_timer:stop() end)
    pcall(function() step_timer:close() end)
    step_timer = nil
  end
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    pcall(vim.api.nvim_win_close, M.win, true)
  end
  if M.buf and vim.api.nvim_buf_is_valid(M.buf) then
    vim.api.nvim_buf_delete(M.buf, { force = true })
  end
  M.win, M.buf = nil, nil
end

-- Rewrite the rows in place (no window churn); drops the panel when the last
-- session is gone.
function M.refresh()
  if not (M.win and vim.api.nvim_win_is_valid(M.win) and M.buf and vim.api.nvim_buf_is_valid(M.buf)) then
    return
  end
  local snap = M.snapshot and M.snapshot() or {}
  if #snap == 0 then
    M.close()
    return
  end
  local row = vim.api.nvim_win_get_cursor(M.win)[1]
  render(M.buf, snap)
  pcall(vim.api.nvim_win_set_cursor, M.win, { math.min(math.max(row, 1), #snap), 0 })
end

-- Registry changed: refresh the rows, or close the panel when no session
-- window is displayed anymore. Never OPENS the panel — that happens only when
-- a session is shown, or the tree opens while one is displayed. A switch
-- (session A's window closing, session B's opening) passes through the
-- not-visible state: hold the panel open and let show_session()'s open()
-- refresh the rows, so the panel never moves or loses the cursor.
function M.sync(visible)
  if M.switching then return end
  if not visible then
    M.close()
  elseif M.win and vim.api.nvim_win_is_valid(M.win) then
    M.refresh()
  end
end

-- Move the panel cursor to the row of the currently displayed session (the
-- switch machinery marks it `open`). Called after a <C-s> switch settles.
function M.follow()
  if M.switching or not (M.win and vim.api.nvim_win_is_valid(M.win)) then return end
  local snap = M.snapshot and M.snapshot() or {}
  for i, s in ipairs(snap) do
    if s.open then
      pcall(vim.api.nvim_win_set_cursor, M.win, { i, 0 })
      return
    end
  end
end

-- (Re)open the panel below the nvim-tree window and fill in the rows. No-op
-- without a visible tree or with no sessions. Already open → refresh only.
-- The split takes focus; callers hand it back to where it belongs.
function M.open()
  if M.win and vim.api.nvim_win_is_valid(M.win) and M.buf and vim.api.nvim_buf_is_valid(M.buf) then
    M.refresh()
    return
  end
  M.close()
  local snap = M.snapshot and M.snapshot() or {}
  if #snap == 0 then return end
  local tw = tree_window()
  if not tw then return end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].filetype = 'claude-sessions-panel'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].buflisted = false
  vim.bo[buf].swapfile = false

  -- Fixed height: 30% of the screen, like diffview's commit panel cap.
  local height = math.floor(vim.o.lines * 0.3)
  vim.api.nvim_set_current_win(tw)
  vim.cmd('below ' .. height .. 'split')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.api.nvim_win_set_cursor(win, { 1, 0 })

  M.buf, M.win = buf, win
  render(buf, snap)

  -- Editing keys have no business here, and on a nomodifiable buffer nvim
  -- refuses them with a noisy E21 (the reported error). Silence the common
  -- ones FIRST so the functional maps below win; everything else keeps its
  -- default.
  for _, key in ipairs({ 'a', 'A', 'i', 'I', 'O', 'c', 'C', 's', 'S', 'd', 'x', 'p', 'u', '<C-a>' }) do
    vim.keymap.set('n', key, '<Nop>', { buffer = buf, nowait = true, silent = true })
  end

  vim.keymap.set('n', 'q', function() M.close() end,
    { buffer = buf, nowait = true, silent = true, desc = 'claude sessions: close panel' })
  vim.keymap.set('n', '<CR>', open_current,
    { buffer = buf, nowait = true, silent = true, desc = 'claude sessions: open session' })
  vim.keymap.set('n', 'l', open_current,
    { buffer = buf, nowait = true, silent = true, desc = 'claude sessions: open session' })
  vim.keymap.set('n', 'o', open_current,
    { buffer = buf, nowait = true, silent = true, desc = 'claude sessions: open session' })
  vim.keymap.set('n', '<C-d>', close_current_row,
    { buffer = buf, nowait = true, silent = true, desc = 'claude sessions: close session' })
  -- the vim-ish spelling of the same close: dd, like deleting a line
  vim.keymap.set('n', 'dd', close_current_row,
    { buffer = buf, nowait = true, silent = true, desc = 'claude sessions: close session' })
  vim.keymap.set('n', 'r', rename_current_row,
    { buffer = buf, nowait = true, silent = true, desc = 'claude sessions: rename session' })
  -- moving through the list switches sessions as it goes (debounced while held)
  vim.keymap.set('n', '<Down>', function() step(1) end,
    { buffer = buf, nowait = true, silent = true, desc = 'claude sessions: next session' })
  vim.keymap.set('n', 'j', function() step(1) end,
    { buffer = buf, nowait = true, silent = true, desc = 'claude sessions: next session' })
  vim.keymap.set('n', '<Up>', function() step(-1) end,
    { buffer = buf, nowait = true, silent = true, desc = 'claude sessions: previous session' })
  vim.keymap.set('n', 'k', function() step(-1) end,
    { buffer = buf, nowait = true, silent = true, desc = 'claude sessions: previous session' })

  -- The window can also go away on its own (:close on the panel, tree-side
  -- layout edits); forget it so the next open() rebuilds cleanly.
  vim.api.nvim_create_autocmd('WinClosed', {
    buffer = buf,
    callback = function() M.win = nil end,
  })
end

-- Keep the panel in normal mode, no matter what lands on it. toggleterm's
-- BufEnter handler schedules `startinsert` for whichever terminal was entered;
-- when the panel holds focus a late-arriving closure fires it ON THE PANEL,
-- flashing INSERT and putting this nomodifiable buffer into insert mode (E21
-- on the next keypress). Nothing in the autocmd system can intercept the
-- command itself before it runs (InsertEnter/ModeChanged fire after the mode
-- change), so intercept at the one seam we own: vim.cmd, while the panel is
-- the focused window. Calls from anywhere else pass straight through.
local function install_mode_guard()
  -- Root interception: the stray call is literally `vim.cmd('startinsert')`
  -- from a toggleterm closure, and when the panel holds focus that command
  -- would either enter insert on this buffer or (on a nomodifiable buffer)
  -- raise E21 as its error message — the reported crash. Intercept it at the
  -- one seam we own, while the panel is the focused buffer, and drop it:
  -- no mode change, no error. Calls from every other context pass through.
  local orig_cmd = vim.cmd
  -- Matches both `vim.cmd('startinsert')` and the `vim.cmd{cmd=...}` table form.
  local function is_startinsert(cmd)
    if type(cmd) == 'string' then
      return cmd:find('^starti') ~= nil
    end
    return type(cmd) == 'table' and type(cmd.cmd) == 'string' and cmd.cmd:find('^starti') ~= nil
  end
  -- The stock vim.cmd is a table with __call/__index metatable functions:
  -- __call handles `vim.cmd('...')`, __index resolves `vim.cmd.highlight(...)`
  -- per-command functions — nvim-surround's plugin file does exactly that on
  -- load. The replacement must keep that exact shape or every such plugin
  -- breaks with "attempt to index field 'cmd'".
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.cmd = setmetatable({}, {
    __call = function(_, cmd, ...)
      if is_startinsert(cmd) and vim.bo.filetype == 'claude-sessions-panel' then
        return
      end
      return orig_cmd(cmd, ...)
    end,
    __index = function(_, k)
      if k == 'startinsert' then
        return function(...)
          if vim.bo.filetype == 'claude-sessions-panel' then return end
          return orig_cmd.startinsert(...)
        end
      end
      return orig_cmd[k]
    end,
  })
  -- Belt: insert mode entering on the panel is left immediately. InsertEnter
  -- fires BEFORE the new mode is observable — vim.fn.mode() still reads 'n'
  -- inside the callback — so a mode check here would never fire; the event
  -- itself IS the signal, stopinsert unconditionally.
  vim.api.nvim_create_autocmd('InsertEnter', {
    callback = function()
      if vim.bo.filetype == 'claude-sessions-panel' then vim.cmd('stopinsert') end
    end,
  })
  -- ModeChanged fires AFTER the switch, so there the mode read is accurate —
  -- and the pattern must match old:new mode strings, not filetypes.
  vim.api.nvim_create_autocmd('ModeChanged', {
    pattern = '*:[it]*',
    callback = function()
      if vim.bo.filetype == 'claude-sessions-panel' then vim.cmd('stopinsert') end
    end,
  })
  -- If insert still managed to land (a render window with modifiable=true,
  -- a race ahead of the guards above), queued keys would edit this buffer —
  -- blank every char before it lands, and restore the write lock on leave.
  vim.api.nvim_create_autocmd('InsertCharPre', {
    callback = function()
      if vim.bo.filetype == 'claude-sessions-panel' then vim.v.char = '' end
    end,
  })
  vim.api.nvim_create_autocmd('InsertEnter', {
    callback = function(ev)
      if vim.bo.filetype ~= 'claude-sessions-panel' then return end
      vim.cmd('stopinsert')
      vim.bo[ev.buf].modifiable = true -- absorb queued edits without E21
    end,
  })
  vim.api.nvim_create_autocmd('InsertLeave', {
    callback = function(ev)
      if vim.bo[ev.buf].filetype == 'claude-sessions-panel' then
        vim.bo[ev.buf].modifiable = false
      end
    end,
  })
  -- Braces: a stray startinsert can also slip through between events; the
  -- poll loop (300ms, only while sessions exist) notices a panel stuck in
  -- insert and evicts it. Cheap: one mode + filetype check per tick.
  vim.api.nvim_create_autocmd('User', {
    pattern = 'ClaudeSessionsTick',
    callback = function()
      if vim.bo.filetype ~= 'claude-sessions-panel' then return end
      if vim.fn.mode():find('^[it]') then vim.cmd('stopinsert') end
    end,
  })
end

-- Highlights are (re)defined on setup and on every colorscheme change, like
-- diffview's groups.
function M.setup()
  define_highlights()
  vim.api.nvim_create_autocmd('ColorScheme', { callback = define_highlights })
  install_mode_guard()

  -- The panel follows the tree: when the tree opens while a session window is
  -- displayed, attach the panel below it (handing focus back to the tree the
  -- user just opened); when the tree closes, the panel goes with it.
  vim.api.nvim_create_autocmd('FileType', {
    pattern = 'NvimTree',
    callback = function()
      vim.schedule(function()
        local snap = M.snapshot and M.snapshot() or {}
        local visible = false
        for _, s in ipairs(snap) do
          visible = visible or s.open
        end
        if not visible then return end
        if not tree_window() then return end
        if M.win and vim.api.nvim_win_is_valid(M.win) then
          M.refresh() -- panel already up: just re-sync the rows
          return
        end
        M.open()
        local tw = tree_window()
        if tw and vim.api.nvim_win_is_valid(tw) then
          pcall(vim.api.nvim_set_current_win, tw)
        end
      end)
    end,
  })
  -- Tree closed (<Leader>f toggle, :NvimTreeClose, q in the tree): the panel
  -- split below it goes with it. view.close() only closes the tree window (the
  -- NvimTree buffer survives for the next toggle), so the reliable signal is
  -- WinClosed for a window showing the tree's buffer. Match any window id and
  -- check the buffer inside — the WinClosed pattern is the window-id string.
  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = '*',
    callback = function(ev)
      local winid = tonumber(ev.match)
      if not winid then return end
      local ok, buf = pcall(vim.api.nvim_win_get_buf, winid)
      if not ok or not buf or vim.bo[buf].filetype ~= 'NvimTree' then return end
      if not (M.win and vim.api.nvim_win_is_valid(M.win)) then return end
      M.close()
    end,
  })
end

return M
