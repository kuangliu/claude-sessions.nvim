-- The session-list panel split below nvim-tree, styled after Claude Code's
-- session picker: each live claude session renders as THREE buffer lines — a
-- state symbol (✓ idle, a spinning braille frame while busy) before the name,
-- the state word indented on the line below, then a blank separator. The
-- displayed session's entry carries a blue ᐅ in the leading gutter and a
-- two-line block background that the panel cursor rests on; stepping switches
-- sessions live (debounced while held).
--
-- Shown while a session window is displayed and a tree window exists to split
-- below; closed when the last displayed session closes. q dismisses it — the
-- sessions themselves are never touched.
--
-- The main module owns the session registry; this file consumes it through
-- the hooks assigned there at load (no require cycle). Until they are bound
-- the panel is inert.

local M = {}

local U = require('claude_sessions.util')

-- Bound by the main module: snapshot() → { busy, state, open, name }[] (index
-- == session number), show(i), close_session(i), rename_session(i, name).
M.snapshot = nil
M.show = nil
M.close_session = nil
M.rename_session = nil

-- True while the panel drives a switch (stepping): show_session then skips
-- its focus juggling so the cursor stays on the panel.
M.stepping = false

-- Panel window and buffer, nil when closed. Validity re-checked on every use
-- — the window can also go away through user layout edits.
M.win = nil
M.buf = nil

local ns = vim.api.nvim_create_namespace('claude_sessions_panel')
local step_timer ---@type uv.uv_timer_t?

-- Row the ᐅ is pinned to while a debounced step is in flight (the marker
-- rides with the cursor, not the switch trailing it by ~120ms). Nil when no
-- step is pending — the marker then marks the displayed session.
local arrow_row = nil

-- In-place rename state, set while a name is edited on its row (the `r`
-- flow): the buffer is unlocked and insert mode is WANTED there, so the mode
-- guard stands down until the edit ends. Carries the edited row's 0-based
-- symbol line and the name's byte offset in it (the backspace floor).
local renaming = nil

-- Insert-mode keys the rename's backspace floor arms. One list for the set
-- (edit start) and the del (edit end) so they can never drift apart.
local FLOOR_KEYS = { '<BS>', '<C-w>' }

-- Session n owns buffer lines 3n-2 (symbol + name) and 3n-1 (state word),
-- with a blank separator at 3n. The cursor sits on the SYMBOL line. Both
-- gutter spellings are FOUR display columns wide (ᐅ is 3 bytes / 1 column —
-- and extmark columns are BYTE offsets — so the marked row's later columns
-- sit 2 bytes further out than the blank gutter's).
local ARROW_GUTTER = ' ᐅ  '
local BLANK_GUTTER = '    '
local SYM_GAP = 2 -- spaces between the state symbol and the name
local SYM_IDLE = '✓' -- agent idle; busy sessions spin through SPIN_FRAMES
local WORD_PAD = 7 -- state-word indent: gutter (4) + symbol (1) + gap (2)

local entry_line, line_entry = U.entry_line, U.line_entry

-- State colors follow Claude Code's picker: red blocked, green idle, yellow
-- busy. The selected entry's block background is a faint read so the state
-- colors stay legible.
local function define_highlights()
  vim.api.nvim_set_hl(0, 'ClaudeSessionsPanelArrow', { fg = '#61afef' })
  vim.api.nvim_set_hl(0, 'ClaudeSessionsPanelBusy', { fg = '#e5c07b' })
  vim.api.nvim_set_hl(0, 'ClaudeSessionsPanelIdle', { fg = '#98c379' })
  vim.api.nvim_set_hl(0, 'ClaudeSessionsPanelBlocked', { fg = '#e06c75' })
  vim.api.nvim_set_hl(0, 'ClaudeSessionsPanelName', { bold = true })
  vim.api.nvim_set_hl(0, 'ClaudeSessionsPanelCursor', { bg = '#2c313c' })
end

local function active()
  return U.valid_win(M.win)
end

--- The live rows as an always-indexable array ({} before the hooks bind).
local function snapshot()
  return M.snapshot and M.snapshot() or {}
end

local function cancel_timer(timer)
  if not timer then return end
  pcall(function() timer:stop() end)
  pcall(function() timer:close() end)
end

local function leave_insert()
  if vim.fn.mode():find('^[it]') then vim.cmd('stopinsert') end
end

--- One event-loop pass from now: leave insert and put focus back on the
--- panel. Runs FIFO behind any startinsert closures toggleterm queued behind
--- a programmatic switch — those fire while the just-opened terminal still
--- holds focus, where they are harmless.
function M.reclaim_focus()
  vim.schedule(function()
    if not active() then return end
    leave_insert()
    if vim.api.nvim_get_current_win() ~= M.win then
      vim.api.nvim_set_current_win(M.win)
    end
  end)
end

-- `busy` is working (yellow, spinning braille); `waiting` — an agent parked
-- on a permission prompt — is blocked (a static red ◉); unknown → idle.
local STATE_STYLE = {
  busy = { sym = nil, word = 'busy', hl = 'ClaudeSessionsPanelBusy', spin = true },
  waiting = { sym = '◉', word = 'blocked', hl = 'ClaudeSessionsPanelBlocked' },
  idle = { sym = SYM_IDLE, word = 'idle', hl = 'ClaudeSessionsPanelIdle' },
}

local function state_style(s)
  return STATE_STYLE[s.state or (s.busy and 'busy' or 'idle')] or STATE_STYLE.idle
end

local function row_state(s, pin_row, i)
  return state_style(s), pin_row == i or (not pin_row and s.open)
end

-- Spinner: the WORKING symbol rotates one braille frame per SPIN_MS while
-- the panel is open and a spinning state is on the list (an idle panel pays
-- nothing). The tick itself stops the timer when nothing spins anymore.
local SPIN_FRAMES = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }
local SPIN_MS = 100
local spin_phase = 1
local spin_timer ---@type uv.uv_timer_t?

local function start_spinner()
  if spin_timer then return end
  spin_timer = (vim.uv or vim.loop).new_timer()
  spin_timer:start(SPIN_MS, SPIN_MS, vim.schedule_wrap(function()
    if not active() then
      cancel_timer(spin_timer)
      spin_timer = nil
      return
    end
    -- blocked's ◉ is static and does not hold the timer up
    local spinning = false
    for _, s in ipairs(snapshot()) do
      spinning = spinning or state_style(s).spin or false
    end
    if not spinning then
      cancel_timer(spin_timer)
      spin_timer = nil
      M.refresh() -- the last frame falls back to the static symbol
      return
    end
    spin_phase = (spin_phase % #SPIN_FRAMES) + 1
    M.refresh()
  end))
end

-- Rewrite the rows and their highlights. The ᐅ marks the DISPLAYED session,
-- or `pin_row` while a debounced step is in flight. Both lines of every
-- entry are padded to the window's DISPLAY width so the selected entry's
-- block background runs the full row; extmark columns stay BYTE offsets.
local function render(buf, snap, pin_row)
  local lines = {}
  local marks = {}
  local any_spinning = false
  local width = active() and vim.api.nvim_win_get_width(M.win) or 80
  local views = {}
  for i, s in ipairs(snap) do
    local style, marked = row_state(s, pin_row, i)
    local sym = style.sym or SPIN_FRAMES[spin_phase] -- nil sym = spinner frame
    any_spinning = any_spinning or style.spin
    views[i] = {
      style = style,
      marked = marked,
      sym = sym,
      gutter = marked and ARROW_GUTTER or BLANK_GUTTER,
      name = s.name or 'claude',
    }
  end
  for i, v in ipairs(views) do
    lines[entry_line(i)] = U.pad_to(
      v.gutter .. v.sym .. string.rep(' ', SYM_GAP) .. v.name, width)
    lines[entry_line(i) + 1] = U.pad_to(string.rep(' ', WORD_PAD) .. v.style.word, width)
    lines[entry_line(i) + 2] = ''
  end
  for i, v in ipairs(views) do
    local lnum = entry_line(i) - 1 -- 0-based symbol line
    local sym_col = #v.gutter
    local name_col = sym_col + #v.sym + SYM_GAP
    if v.marked then
      marks[#marks + 1] = { lnum = lnum, col = 0, end_col = #lines[lnum + 1], hl = 'ClaudeSessionsPanelCursor' }
      marks[#marks + 1] = { lnum = lnum + 1, col = 0, end_col = #lines[lnum + 2], hl = 'ClaudeSessionsPanelCursor' }
      -- col 1..4: one space, then the 3-byte ᐅ
      marks[#marks + 1] = { lnum = lnum, col = 1, end_col = 1 + #'ᐅ', hl = 'ClaudeSessionsPanelArrow' }
    end
    marks[#marks + 1] = { lnum = lnum, col = sym_col, end_col = sym_col + #v.sym, hl = v.style.hl }
    marks[#marks + 1] = { lnum = lnum, col = name_col, end_col = name_col + #v.name, hl = 'ClaudeSessionsPanelName' }
    marks[#marks + 1] = { lnum = lnum + 1, col = WORD_PAD, end_col = WORD_PAD + #v.style.word, hl = v.style.hl }
  end
  U.set_rows(buf, ns, lines, marks)
  if any_spinning then start_spinner() end
end

--- Move the panel cursor to the symbol line of the DISPLAYED session, so the
--- raw editor cursor never sits beside an unhighlighted row.
local function follow_displayed(snap)
  for i, s in ipairs(snap) do
    if s.open then
      pcall(vim.api.nvim_win_set_cursor, M.win, { entry_line(i), 0 })
      return
    end
  end
end

--- Display the session on row `row`. keep_focus keeps the cursor on the
--- panel (stepping); the focus juggling lives in show_session.
local function select_row(row, keep_focus)
  M.stepping = keep_focus
  M.show(row)
  M.stepping = false
end

--- The session row under the panel cursor, or nil when the panel is gone.
--- The cursor is always read from the panel's own window — keys can arrive
--- while the panel lacks focus.
local function cursor_row()
  if not active() then return nil end
  return line_entry(vim.api.nvim_win_get_cursor(M.win)[1])
end

-- <Down>/<Up>/j/k: move the cursor one entry and switch to that session. The
-- switch is debounced (~120ms): held keys sweep the cursor without paying a
-- terminal open per entry, and the entry under the cursor when the sweep
-- settles is the one that loads.
local function step(dir)
  local row = cursor_row()
  if not row then return end
  local snap = snapshot()
  row = row + dir
  if row < 1 or row > #snap then return end
  vim.api.nvim_win_set_cursor(M.win, { entry_line(row), 0 })
  arrow_row = row -- the marker rides with the cursor, never trails it
  M.refresh()

  cancel_timer(step_timer)
  step_timer = vim.defer_fn(function()
    step_timer = nil
    if not active() then return end
    select_row(cursor_row(), true)
    arrow_row = nil -- the switch settled: the marker rests on the display
    M.refresh()
    -- select_row left focus on the just-opened terminal; take it back one
    -- pass later (see reclaim_focus for why).
    M.reclaim_focus()
  end, 120)
end

-- <CR>/l/o: switch to the session under the cursor and focus it.
local function open_current()
  local row = cursor_row()
  if row then select_row(row, false) end
end

-- <C-d>: kill the session under the cursor. Focus stays on the panel.
local function close_current_row()
  local row = cursor_row()
  if row then M.close_session(row) end
end

--- End the in-place rename. `apply` commits the row's current text as the new
--- name (empty restores the default `claude`); otherwise the edit is
--- discarded. Either way: leave insert, drop the backspace floor, re-lock
--- the buffer, re-render the rows.
local function finish_rename(apply)
  if not renaming then return end
  local r = renaming
  renaming = nil
  pcall(vim.cmd, 'stopinsert') -- the <CR>/<Esc> mappings replace the builtin leave
  for _, key in ipairs(FLOOR_KEYS) do
    pcall(vim.keymap.del, 'i', key, { buffer = M.buf })
  end
  local value
  if U.valid_buf(M.buf) then
    if apply then
      local line = vim.api.nvim_buf_get_lines(M.buf, r.lnum, r.lnum + 1, false)[1] or ''
      value = vim.trim(line:sub(r.name_col))
    end
    vim.bo[M.buf].modifiable = false
  end
  if value then
    M.rename_session(r.row, value)
  else
    M.refresh() -- repaint: discards the edit / restores the old name
  end
end

-- <r>: rename the session under the cursor, in place on its row. The buffer
-- is unlocked, insert starts after the name's last char, Enter applies, any
-- other leave of insert cancels.
local function rename_current_row()
  local row = cursor_row()
  if not row or renaming then return end
  local s = snapshot()[row]
  if not s then return end
  local name = s.name or 'claude'
  local lnum = entry_line(row) - 1 -- 0-based symbol line
  -- The symbol can be a 3-byte spinner frame mid-animation, so the name's
  -- byte offset is read off the row text itself.
  local line = vim.api.nvim_buf_get_lines(M.buf, lnum, lnum + 1, false)[1] or ''
  local name_col = line:find(name, 1, true)
  if not name_col then return end -- row not in the expected shape; bail out
  renaming = { row = row, lnum = lnum, name_col = name_col }
  -- A backspace floor at the name start: <BS>/<C-w> refuse to delete left of
  -- it, so the gutter, symbol and gap survive any edit. (The 'backspace'
  -- option can express "stop at insert start" only globally — the floor is
  -- per-edit, hence a mapping.)
  local function backspace_floor()
    if vim.fn.col('.') <= name_col then return '' end
    return '<BS>'
  end
  for _, key in ipairs(FLOOR_KEYS) do
    vim.keymap.set('i', key, backspace_floor,
      { buffer = M.buf, expr = true, replace_keycodes = true, desc = 'claude sessions: rename floor' })
  end
  vim.bo[M.buf].modifiable = true
  vim.fn.cursor(lnum + 1, name_col + #name) -- insert starts past the name
  vim.cmd('startinsert')
end

-- Tear the panel down (window + buffer). Sessions keep running.
function M.close()
  -- A rename edit dies with the panel: drop the state so the mode guard is
  -- re-armed (the buffer delete takes the floor mappings with it).
  renaming = nil
  cancel_timer(step_timer)
  step_timer = nil
  cancel_timer(spin_timer)
  spin_timer = nil
  arrow_row = nil
  if active() then
    pcall(vim.api.nvim_win_close, M.win, true)
  end
  if U.valid_buf(M.buf) then
    vim.api.nvim_buf_delete(M.buf, { force = true })
  end
  M.win, M.buf = nil, nil
end

-- Rewrite the rows in place (no window churn); drops the panel when the last
-- session is gone.
function M.refresh()
  if not (active() and U.valid_buf(M.buf)) then
    return
  end
  -- A repaint here (spinner frame, busy flip) would clobber an in-place
  -- rename mid-keystroke; finish_rename repaints after the edit ends.
  if renaming then return end
  local snap = snapshot()
  if #snap == 0 then
    M.close()
    return
  end
  local line = vim.api.nvim_win_get_cursor(M.win)[1]
  render(M.buf, snap, arrow_row)
  -- Keep the cursor on a SYMBOL line: clamp to the list, then snap back to
  -- the same entry's symbol line (a raw clamp can land on a state-word or
  -- separator line).
  line = math.min(math.max(line, 1), entry_line(#snap))
  pcall(vim.api.nvim_win_set_cursor, M.win, { entry_line(line_entry(line)), 0 })
  if not arrow_row then follow_displayed(snap) end
end

-- Registry changed: refresh the rows, or close the panel when no session
-- window is displayed anymore. Never OPENS the panel — that happens when a
-- session is shown, or the tree opens while one is displayed. A switch (A's
-- window closing, B's opening) passes through the not-visible state: hold
-- the panel open and let show_session()'s open() refresh the rows, so the
-- panel never moves or loses the cursor.
function M.sync(visible)
  if not visible then
    M.close()
  elseif active() then
    M.refresh()
  end
end

-- Move the panel cursor to the displayed session's entry (after <C-s>).
function M.follow()
  if not active() then return end
  follow_displayed(snapshot())
end

local function set_keymaps(buf)
  U.silence_editing_keys(buf) -- so the functional maps below win
  -- Insert mode (in-place rename): Enter applies the edit instead of
  -- splitting the row; Esc leaves insert and InsertLeave cancels it.
  vim.keymap.set('i', '<CR>', function() finish_rename(true) end,
    { buffer = buf, nowait = true, silent = true, desc = 'claude sessions: apply rename' })
  vim.keymap.set('i', '<Esc>', function() finish_rename(false) end,
    { buffer = buf, nowait = true, silent = true, desc = 'claude sessions: cancel rename' })
  U.map_key(buf, 'q', function() M.close() end, 'close panel')
  U.map_key(buf, '<CR>', open_current, 'open session')
  U.map_key(buf, 'l', open_current, 'open session')
  U.map_key(buf, 'o', open_current, 'open session')
  U.map_key(buf, '<C-d>', close_current_row, 'close session')
  U.map_key(buf, 'r', rename_current_row, 'rename session')
  U.map_key(buf, '<Down>', function() step(1) end, 'next session')
  U.map_key(buf, 'j', function() step(1) end, 'next session')
  U.map_key(buf, '<Up>', function() step(-1) end, 'previous session')
  U.map_key(buf, 'k', function() step(-1) end, 'previous session')
end

-- (Re)open the panel below the tree window and fill in the rows. No-op
-- without a visible tree or with no sessions. Already open → refresh only.
-- The split takes focus; callers hand it back to where it belongs.
function M.open()
  if active() and U.valid_buf(M.buf) then
    M.refresh()
    return
  end
  M.close()
  local snap = snapshot()
  if #snap == 0 then return end
  local tw = U.tree_window()
  if not tw then return end

  local buf = U.scratch_buffer('claude-sessions-panel')
  local height = math.floor(vim.o.lines * 0.3)
  vim.api.nvim_set_current_win(tw)
  vim.cmd('below ' .. height .. 'split')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  U.plain_text_window(win) -- the split inherits the tree's options
  vim.api.nvim_win_set_cursor(win, { 1, 0 })

  M.buf, M.win = buf, win
  render(buf, snap)
  set_keymaps(buf)

  -- The window can also go away on its own; forget it so the next open()
  -- rebuilds cleanly.
  vim.api.nvim_create_autocmd('WinClosed', {
    buffer = buf,
    callback = function() M.win = nil end,
  })
end

-- Keep the panel in normal mode, no matter what lands on it. toggleterm's
-- BufEnter handler schedules `startinsert` for whichever terminal was
-- entered; when the panel holds focus a late-arriving closure fires it ON
-- THE PANEL — INSERT flashes and the nomodifiable buffer takes E21 on the
-- next keypress. Nothing in the autocmd system can intercept the command
-- before it runs (InsertEnter/ModeChanged fire after the mode change), so
-- intercept at the one seam we own: vim.cmd, while the panel is focused.
-- Covers the diff panel's filetype too.
local function install_mode_guard()
  -- Shared predicate: an insert the panels do not want — one landing on a
  -- read-only panel buffer while no rename is in flight (a rename's own
  -- insert is deliberate and passes).
  local PANEL_FTS = { 'claude-sessions-panel', 'claude-sessions-diff' }
  local function stray_insert(buf)
    if renaming then return false end
    local ft = vim.bo[buf].filetype
    for _, panel_ft in ipairs(PANEL_FTS) do
      if ft == panel_ft then return true end
    end
    return false
  end

  -- Root interception: the stray call is literally `vim.cmd('startinsert')`
  -- from a toggleterm closure. The stock vim.cmd is a table with __call/
  -- __index metatable functions — the replacement must keep that exact shape
  -- or every plugin using vim.cmd.<cmd>(...) breaks.
  local orig_cmd = vim.cmd
  local function is_startinsert(cmd)
    if type(cmd) == 'string' then
      return cmd:find('^starti') ~= nil
    end
    return type(cmd) == 'table' and type(cmd.cmd) == 'string' and cmd.cmd:find('^starti') ~= nil
  end
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.cmd = setmetatable({}, {
    __call = function(_, cmd, ...)
      if is_startinsert(cmd) and stray_insert(0) then return end
      return orig_cmd(cmd, ...)
    end,
    __index = function(_, k)
      if k == 'startinsert' then
        return function(...)
          if stray_insert(0) then return end
          return orig_cmd.startinsert(...)
        end
      end
      return orig_cmd[k]
    end,
  })

  -- Belt: insert mode entering on the panel is left immediately. InsertEnter
  -- fires BEFORE the new mode is observable — the event itself IS the
  -- signal, stopinsert unconditionally. Modifiable flips on for the duration
  -- so edits queued by a race ahead of the vim.cmd guard are absorbed
  -- without E21, and restores on leave.
  vim.api.nvim_create_autocmd('InsertEnter', {
    callback = function(ev)
      if not stray_insert(ev.buf) then return end
      vim.cmd('stopinsert')
      vim.bo[ev.buf].modifiable = true
    end,
  })
  vim.api.nvim_create_autocmd('InsertLeave', {
    callback = function(ev)
      if vim.bo[ev.buf].filetype == 'claude-sessions-diff' then
        vim.bo[ev.buf].modifiable = false
        return
      end
      if vim.bo[ev.buf].filetype ~= 'claude-sessions-panel' then return end
      if renaming then
        finish_rename(false) -- insert left without <CR>/<Esc>: cancel
        return
      end
      vim.bo[ev.buf].modifiable = false
    end,
  })
  -- ModeChanged fires AFTER the switch, so the mode read is accurate there.
  vim.api.nvim_create_autocmd('ModeChanged', {
    pattern = '*:[it]*',
    callback = function()
      if stray_insert(0) then vim.cmd('stopinsert') end
    end,
  })
  -- If insert still managed to land, queued keys would edit the buffer —
  -- blank every char before it lands.
  vim.api.nvim_create_autocmd('InsertCharPre', {
    callback = function()
      if stray_insert(0) then vim.v.char = '' end
    end,
  })
  -- Braces: the poll loop (300ms, only while sessions exist) notices a panel
  -- stuck in insert and evicts it. One mode + filetype check per tick.
  vim.api.nvim_create_autocmd('User', {
    pattern = 'ClaudeSessionsTick',
    callback = function()
      if not stray_insert(0) then return end
      if vim.fn.mode():find('^[it]') then vim.cmd('stopinsert') end
    end,
  })
end

-- Highlights are (re)defined on setup and on every colorscheme change.
function M.setup()
  define_highlights()
  vim.api.nvim_create_autocmd('ColorScheme', { callback = define_highlights })
  install_mode_guard()

  -- The panel follows the tree: it attaches below a freshly opened tree when
  -- a session is displayed (handing focus back to the tree), and goes with
  -- the tree when that closes.
  vim.api.nvim_create_autocmd('FileType', {
    pattern = 'NvimTree',
    callback = function()
      vim.schedule(function()
        local visible = false
        for _, s in ipairs(snapshot()) do
          visible = visible or s.open
        end
        if not visible then return end
        local tw = U.tree_window()
        if not tw then return end
        if active() then
          M.refresh() -- panel already up: just re-sync the rows
          return
        end
        M.open()
        U.focus(tw) -- hand focus back to the tree just opened
      end)
    end,
  })
  -- Tree closed: view.close() only closes the tree WINDOW (the NvimTree
  -- buffer survives for the next toggle), so the reliable signal is WinClosed
  -- for a window showing the tree's buffer.
  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = '*',
    callback = function(ev)
      local winid = tonumber(ev.match)
      if not winid then return end
      local ok, buf = pcall(vim.api.nvim_win_get_buf, winid)
      if not ok or not buf or vim.bo[buf].filetype ~= 'NvimTree' then return end
      if active() then M.close() end
    end,
  })
end

return M
