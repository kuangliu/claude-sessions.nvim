-- The session-list panel split below nvim-tree, styled after Claude Code's
-- session picker: TWO buffer lines per live claude session — a state symbol
-- (✓ idle, a spinning braille frame while busy) before the name, and the
-- state word on the line below, indented under the name. The displayed
-- session's line carries a blue ᐅ in the leading gutter; cursorline browsing;
-- debounced stepping that switches sessions live.
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
-- array of { busy = bool, open = bool, name = string? } (array index ==
-- session number), `show(i)` displays session i, `close_session(i)` kills
-- session i, `row_name(i)` is the session's display name (rename prompt
-- default), and `rename_session(i, name)` renames it.
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

-- Row (session index) the ᐅ is pinned to while a debounced step is in flight:
-- the marker rides with the cursor, not with the switch that trails it by
-- ~120ms. Nil whenever no step is pending — the marker then falls back to the
-- row of the displayed session.
local arrow_row = nil

-- Layout, Claude-Code session-picker style. Session n owns buffer lines
-- 2n-1 (symbol + name) and 2n (state word, indented under the name):
--   ' ᐅ  ✓ claude'
--   '     idle'
-- The cursor sits on the SYMBOL line; ceil(line / 2) maps any line back to
-- its session. Both gutter spellings are THREE display columns wide; ᐅ is
-- 3 bytes / 1 display column — and extmark columns are BYTE offsets — so the
-- marked row's later columns sit 2 bytes further out than the blank gutter's.
local ARROW_GUTTER = ' ᐅ '
local BLANK_GUTTER = '   '
local SYM_IDLE = '✓' -- agent idle; busy sessions spin through SPIN_FRAMES
local WORD_PAD = 5 -- state-word indent: gutter (3) + symbol (1) + space (1)

--- First (symbol) buffer line of session `i`.
local function entry_line(i)
  return 2 * i - 1
end

--- Session index for buffer line `line` (either line of an entry).
local function line_entry(line)
  return math.ceil(line / 2)
end

local function define_highlights()
  -- Same accent blue as diffview's commit hashes for the arrow. The state
  -- colors follow Claude Code's picker: red blocked, green idle, yellow
  -- working/busy.
  vim.api.nvim_set_hl(0, 'ClaudeSessionsPanelArrow', { fg = '#61afef' })
  vim.api.nvim_set_hl(0, 'ClaudeSessionsPanelBusy', { fg = '#e5c07b' }) -- working: yellow
  vim.api.nvim_set_hl(0, 'ClaudeSessionsPanelIdle', { fg = '#98c379' }) -- idle: green
  vim.api.nvim_set_hl(0, 'ClaudeSessionsPanelBlocked', { fg = '#e06c75' }) -- blocked: red
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

--- Is the panel window (still) up?
local function active()
  return M.win ~= nil and vim.api.nvim_win_is_valid(M.win)
end

--- Stop and dispose of a uv timer. Either call can fail on an already-closed
--- timer; ignore that.
local function cancel_timer(timer)
  if not timer then return end
  pcall(function() timer:stop() end)
  pcall(function() timer:close() end)
end

--- Leave insert/terminal-pending mode if we're in either. The mode read is
--- accurate here, unlike inside InsertEnter (see install_mode_guard).
local function leave_insert()
  if vim.fn.mode():find('^[it]') then vim.cmd('stopinsert') end
end

-- Spinner. Busy sessions show a rotating braille frame instead of a static
-- symbol; the timer below advances it one frame per SPIN_MS while the panel
-- is open and something is busy — an idle panel pays nothing. The frames are
-- all single display columns, so the layout never shifts between frames.
local SPIN_FRAMES = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }
local SPIN_MS = 100
local spin_phase = 1 -- index into SPIN_FRAMES
local spin_timer ---@type uv.uv_timer_t?

--- Start the spinner timer if it is not already running. Called from render
--- when a session is busy; the tick itself stops the timer when nothing is
--- busy anymore, so no stop bookkeeping is needed on the busy->idle edge.
local function start_spinner()
  if spin_timer then return end
  spin_timer = (vim.uv or vim.loop).new_timer()
  spin_timer:start(SPIN_MS, SPIN_MS, vim.schedule_wrap(function()
    if not active() then
      cancel_timer(spin_timer)
      spin_timer = nil
      return
    end
    local busy = false
    local snap = M.snapshot and M.snapshot() or {}
    for _, s in ipairs(snap) do busy = busy or s.busy end
    if not busy then
      cancel_timer(spin_timer)
      spin_timer = nil
      M.refresh() -- the last frame falls back to ✓
      return
    end
    spin_phase = (spin_phase % #SPIN_FRAMES) + 1
    M.refresh()
  end))
end

--- One event-loop pass from now: leave insert and put focus back on the
--- panel. Runs FIFO behind any startinsert closures toggleterm queued behind
--- a programmatic switch — those fire while the just-opened terminal still
--- holds focus, where they are harmless; even a stray insert that lands on
--- the panel lives for microseconds and is never painted.
function M.reclaim_focus()
  vim.schedule(function()
    if not active() then return end
    leave_insert()
    if vim.api.nvim_get_current_win() ~= M.win then
      vim.api.nvim_set_current_win(M.win)
    end
  end)
end

-- Rewrite the rows and their highlights. The ᐅ in the leading gutter marks a
-- session — the DISPLAYED one by default (the one the statusline dots mark
-- with •), or `pin_row` while a debounced step is in flight so the marker
-- moves with the cursor instead of trailing it. The name column shows the
-- session name — `#N claude` by default, or the session's custom name once
-- one is set with `r`.
-- State styling: the word shown on the second line and the highlight group
-- for symbol + word, keyed by the CLI's status string. `busy` is working
-- (yellow, spinning); `waiting` — an agent parked on a permission prompt —
-- is blocked (red, spinning); anything unknown falls back to idle (green).
local STATE_STYLE = {
  busy = { word = 'busy', hl = 'ClaudeSessionsPanelBusy' },
  waiting = { word = 'blocked', hl = 'ClaudeSessionsPanelBlocked' },
  idle = { word = 'idle', hl = 'ClaudeSessionsPanelIdle' },
}

local function render(buf, snap, pin_row)
  local lines = {}
  local any_busy = false
  for i, s in ipairs(snap) do
    local marked = pin_row == i or (not pin_row and s.open)
    local gutter = marked and ARROW_GUTTER or BLANK_GUTTER
    local state = s.state or (s.busy and 'busy' or 'idle')
    local style = STATE_STYLE[state] or STATE_STYLE.idle
    local sym = state ~= 'idle' and SPIN_FRAMES[spin_phase] or SYM_IDLE
    any_busy = any_busy or state ~= 'idle'
    lines[entry_line(i)] = gutter .. sym .. ' ' .. (s.name or 'claude')
    lines[entry_line(i) + 1] = string.rep(' ', WORD_PAD) .. style.word
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  for i, s in ipairs(snap) do
    local marked = pin_row == i or (not pin_row and s.open)
    local gutter = marked and ARROW_GUTTER or BLANK_GUTTER
    local lnum = entry_line(i) - 1 -- 0-based symbol line
    local state = s.state or (s.busy and 'busy' or 'idle')
    local style = STATE_STYLE[state] or STATE_STYLE.idle
    if marked then
      -- the arrow, in the commit panel's hash accent
      vim.api.nvim_buf_set_extmark(buf, ns, lnum, 1, {
        end_col = 4, hl_group = 'ClaudeSessionsPanelArrow',
      })
    end
    -- the state symbol, in the state's color
    vim.api.nvim_buf_set_extmark(buf, ns, lnum, #gutter, {
      end_col = #gutter + #SYM_IDLE, hl_group = style.hl,
    })
    -- the state word on the line below, in the same color
    vim.api.nvim_buf_set_extmark(buf, ns, lnum + 1, WORD_PAD, {
      end_col = WORD_PAD + #style.word, hl_group = style.hl,
    })
  end
  if any_busy then start_spinner() end
end

-- Display the session on row `row`. keep_focus keeps the cursor on the panel
-- (stepping); otherwise focus follows the session window. The focus juggling
-- itself lives in the main module's show_session.
local function select_row(row, keep_focus)
  M.stepping = keep_focus
  M.show(row)
  M.stepping = false
end

-- <Down>/<Up>/j/k: move the cursor one entry and switch to that session. The
-- MARKER moves with the cursor — the entry is re-rendered with the arrow
-- pinned to it in the same keystroke. The switch itself is debounced (~120ms):
-- held keys sweep the cursor without paying a terminal open per entry, and
-- the entry under the cursor when the sweep settles is the one that loads.
local function step(dir)
  -- The panel may not currently hold focus (keys go through the terminal
  -- window that shows the cursorline'd panel below the tree); drive its
  -- cursor from wherever we are.
  if not active() then return end
  local snap = M.snapshot and M.snapshot() or {}
  local row = line_entry(vim.api.nvim_win_get_cursor(M.win)[1]) + dir
  if row < 1 or row > #snap then return end
  vim.api.nvim_win_set_cursor(M.win, { entry_line(row), 0 })

  -- Pin the arrow to the entry just stepped onto and repaint, so it never
  -- trails the cursor while the debounced switch is in flight.
  arrow_row = row
  M.refresh()

  cancel_timer(step_timer)
  step_timer = vim.defer_fn(function()
    step_timer = nil
    if not active() then return end
    select_row(line_entry(vim.api.nvim_win_get_cursor(M.win)[1]), true)
    -- The switch settled: the displayed session now IS the cursor entry, so
    -- the pin drops and the marker rests on the displayed session again.
    arrow_row = nil
    M.refresh()
    -- select_row left focus on the just-opened terminal; take it back one
    -- pass later (see reclaim_focus for why).
    M.reclaim_focus()
  end, 120)
end

-- <CR>/l/o: switch to the session under the cursor and focus it.
local function open_current()
  if not active() then return end
  select_row(line_entry(vim.api.nvim_win_get_cursor(M.win)[1]), false)
end

-- <C-d>: kill the session under the cursor. Same semantics as terminal-mode
-- <C-d>: the process dies, the rows disappear, the split shows the next
-- session. Focus stays on the panel.
local function close_current_row()
  if not active() then return end
  M.close_session(line_entry(vim.api.nvim_win_get_cursor(M.win)[1]))
end

-- <r>: rename the session under the cursor. An empty input restores the
-- default `#N claude` name; Esc cancels.
local function rename_current_row()
  if not active() then return end
  local row = line_entry(vim.api.nvim_win_get_cursor(M.win)[1])
  local default = M.row_name and M.row_name(row) or ''
  vim.ui.input({ prompt = 'Session name: ', default = default }, function(value)
    if value == nil then return end -- cancelled
    M.rename_session(row, value)
  end)
end

-- Tear the panel down (window + buffer). Sessions keep running.
function M.close()
  cancel_timer(step_timer)
  step_timer = nil
  cancel_timer(spin_timer)
  spin_timer = nil
  arrow_row = nil
  if active() then
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
  if not (active() and M.buf and vim.api.nvim_buf_is_valid(M.buf)) then
    return
  end
  local snap = M.snapshot and M.snapshot() or {}
  if #snap == 0 then
    M.close()
    return
  end
  local line = vim.api.nvim_win_get_cursor(M.win)[1]
  render(M.buf, snap, arrow_row)
  -- Keep the cursor on a SYMBOL line: clamp to the list, then snap back to
  -- the same entry's symbol line (a raw clamp can land on a state-word line).
  line = math.min(math.max(line, 1), 2 * #snap)
  pcall(vim.api.nvim_win_set_cursor, M.win, { entry_line(line_entry(line)), 0 })
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
  elseif active() then
    M.refresh()
  end
end

-- Move the panel cursor to the symbol line of the currently displayed session
-- (the switch machinery marks it `open`). Called after a <C-s> switch settles.
function M.follow()
  if M.switching or not active() then return end
  local snap = M.snapshot and M.snapshot() or {}
  for i, s in ipairs(snap) do
    if s.open then
      pcall(vim.api.nvim_win_set_cursor, M.win, { entry_line(i), 0 })
      return
    end
  end
end

local function make_panel_buffer()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].filetype = 'claude-sessions-panel'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].buflisted = false
  vim.bo[buf].swapfile = false
  return buf
end

-- Panel keymaps. Editing keys have no business here, and on a nomodifiable
-- buffer nvim refuses them with a noisy E21 (the reported error). Silence the
-- common ones FIRST so the functional maps below win; everything else keeps
-- its default.
local SILENCED_KEYS = { 'a', 'A', 'i', 'I', 'O', 'c', 'C', 's', 'S', 'd', 'x', 'p', 'u', '<C-a>' }

local function set_keymaps(buf)
  for _, key in ipairs(SILENCED_KEYS) do
    vim.keymap.set('n', key, '<Nop>', { buffer = buf, nowait = true, silent = true })
  end
  local function map(key, fn, desc)
    vim.keymap.set('n', key, fn,
      { buffer = buf, nowait = true, silent = true, desc = 'claude sessions: ' .. desc })
  end
  map('q', function() M.close() end, 'close panel')
  map('<CR>', open_current, 'open session')
  map('l', open_current, 'open session')
  map('o', open_current, 'open session')
  map('<C-d>', close_current_row, 'close session')
  -- the vim-ish spelling of the same close: dd, like deleting a line
  map('dd', close_current_row, 'close session')
  map('r', rename_current_row, 'rename session')
  -- moving through the list switches sessions as it goes (debounced while held)
  map('<Down>', function() step(1) end, 'next session')
  map('j', function() step(1) end, 'next session')
  map('<Up>', function() step(-1) end, 'previous session')
  map('k', function() step(-1) end, 'previous session')
end

-- (Re)open the panel below the nvim-tree window and fill in the rows. No-op
-- without a visible tree or with no sessions. Already open → refresh only.
-- The split takes focus; callers hand it back to where it belongs.
function M.open()
  if active() and M.buf and vim.api.nvim_buf_is_valid(M.buf) then
    M.refresh()
    return
  end
  M.close()
  local snap = M.snapshot and M.snapshot() or {}
  if #snap == 0 then return end
  local tw = tree_window()
  if not tw then return end

  local buf = make_panel_buffer()
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
  set_keymaps(buf)

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
  -- itself IS the signal, stopinsert unconditionally. Modifiable is flipped
  -- on for the duration so edits queued by a race ahead of the vim.cmd guard
  -- above are absorbed without E21, and restored on leave.
  vim.api.nvim_create_autocmd('InsertEnter', {
    callback = function(ev)
      if vim.bo.filetype ~= 'claude-sessions-panel' then return end
      vim.cmd('stopinsert')
      vim.bo[ev.buf].modifiable = true
    end,
  })
  vim.api.nvim_create_autocmd('InsertLeave', {
    callback = function(ev)
      if vim.bo[ev.buf].filetype == 'claude-sessions-panel' then
        vim.bo[ev.buf].modifiable = false
      end
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
  -- blank every char before it lands.
  vim.api.nvim_create_autocmd('InsertCharPre', {
    callback = function()
      if vim.bo.filetype == 'claude-sessions-panel' then vim.v.char = '' end
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
        if active() then
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
      if not active() then return end
      M.close()
    end,
  })
end

return M
