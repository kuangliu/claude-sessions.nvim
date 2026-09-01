-- The session-list panel split below nvim-tree, styled after Claude Code's
-- session picker: each live claude session renders as THREE buffer lines — a
-- state symbol (✓ idle, a spinning braille frame while busy) before the name,
-- the state word indented on the line below, then a blank separator. The
-- displayed session's entry carries a blue ᐅ in the leading gutter and a
-- two-line block background that the panel cursor rests on; stepping switches
-- sessions live (debounced while held).
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

local U = require('claude_sessions.util') -- shared window/buffer helpers

-- Bound by the main module: `snapshot()` returns the live sessions as an
-- array of { busy = bool, open = bool, name = string? } (array index ==
-- session number), `show(i)` displays session i, `close_session(i)` kills
-- session i, and `rename_session(i, name)` renames it.
-- (Named close_session: M.close below tears the panel itself down.)
M.snapshot = nil
M.show = nil
M.close_session = nil
M.rename_session = nil

-- True while the panel is driving a switch (stepping): show_session then
-- skips its focus juggling so the cursor stays on the panel.
M.stepping = false

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

-- In-place rename state, set while a session name is being edited directly on
-- its row (the `r` flow): the panel buffer is unlocked and insert mode is
-- WANTED there, so the mode guard stands down until the edit ends — Enter
-- applies the name, leaving insert any other way (Esc, a click elsewhere)
-- cancels it. Carries the edited row: its 0-based symbol line and the byte
-- offset of the name in that line (the backspace floor).
local renaming = nil

-- Insert-mode keys the rename's backspace floor arms (see rename_current_row):
-- both delete leftward, so both must stop at the name. One list for the set
-- (edit start) and the del (edit end) so they can never drift apart.
local FLOOR_KEYS = { '<BS>', '<C-w>' }

-- Layout, Claude-Code session-picker style. Session n owns buffer lines
-- 3n-2 (symbol + name) and 3n-1 (state word, indented under the name), with a
-- blank separator line at 3n between entries:
--   ' ᐅ  ✓  claude'
--   '       idle'
--   ''
-- The cursor sits on the SYMBOL line; any line (a separator attributes to the
-- entry above it) maps back to its session — the same three-line shape the
-- diff panel renders, so util's entry_line/line_entry apply. Both gutter
-- spellings are FOUR display columns wide (ᐅ is 3 bytes / 1 display
-- column — and extmark columns are BYTE offsets — so the marked row's later
-- columns sit 2 bytes further out than the blank gutter's).
local ARROW_GUTTER = ' ᐅ  '
local BLANK_GUTTER = '    '
local GUTTER_COLS = 4 -- display width of EITHER gutter spelling (ᐅ is 3 bytes)
local SYM_GAP = 2 -- spaces between the state symbol and the name
local SYM_IDLE = '✓' -- agent idle; busy sessions spin through SPIN_FRAMES
local WORD_PAD = 7 -- state-word indent: gutter (4) + symbol (1) + gap (2)

-- The panel's three-line row shape is util's (name / detail / blank), so its
-- row↔entry mapping applies directly — aliased once here, the ~12 call sites
-- spell the short names. `rune_len` rides along (the panel's local copy is
-- folded into the alias — one spelling of the rune-vs-byte rule, in util).
local entry_line, line_entry, rune_len = U.entry_line, U.line_entry, U.rune_len

local function define_highlights()
  -- Same accent blue as diffview's commit hashes for the arrow. The state
  -- colors follow Claude Code's picker: red blocked, green idle, yellow
  -- working/busy.
  vim.api.nvim_set_hl(0, 'ClaudeSessionsPanelArrow', { fg = '#61afef' })
  vim.api.nvim_set_hl(0, 'ClaudeSessionsPanelBusy', { fg = '#e5c07b' }) -- working: yellow
  vim.api.nvim_set_hl(0, 'ClaudeSessionsPanelIdle', { fg = '#98c379' }) -- idle: green
  vim.api.nvim_set_hl(0, 'ClaudeSessionsPanelBlocked', { fg = '#e06c75' }) -- blocked: red
  -- Session names, bold like the picker's.
  vim.api.nvim_set_hl(0, 'ClaudeSessionsPanelName', { bold = true })
  -- The selected entry's two-line block background: a faint read on top of
  -- the normal background, so the state colors stay legible.
  vim.api.nvim_set_hl(0, 'ClaudeSessionsPanelCursor', { bg = '#2c313c' })
end

--- Is the panel window (still) up?
local function active()
  return U.valid_win(M.win)
end

--- The live rows as an always-indexable array. Empty until the main module
--- binds the hook — the panel is inert before that, and every reader here
--- (spinner tick, keymaps, refresh) wants rows without a nil check.
local function snapshot()
  return M.snapshot and M.snapshot() or {}
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

-- State styling: symbol, word shown on the second line, and the highlight
-- group for symbol + word, keyed by the CLI's status string. `busy` is
-- working (yellow, spinning braille); `waiting` — an agent parked on a
-- permission prompt — is blocked (a static red ◉, like the picker's);
-- anything unknown falls back to idle (green ✓).
local STATE_STYLE = {
  busy = { sym = nil, word = 'busy', hl = 'ClaudeSessionsPanelBusy', spin = true },
  waiting = { sym = '◉', word = 'blocked', hl = 'ClaudeSessionsPanelBlocked' },
  idle = { sym = SYM_IDLE, word = 'idle', hl = 'ClaudeSessionsPanelIdle' },
}

--- The style for a snapshot row's state (unknown strings fall back to idle).
local function state_style(s)
  return STATE_STYLE[s.state or (s.busy and 'busy' or 'idle')] or STATE_STYLE.idle
end

--- Resolved display state of one snapshot row: the STYLE (symbol/word/hl/
--- spin) and whether the ᐅ marks this entry. `pin_row` (a debounced step in
--- flight) overrides the displayed session as the marked entry.
local function row_state(s, pin_row, i)
  return state_style(s), pin_row == i or (not pin_row and s.open)
end

-- Spinner. The WORKING state's symbol is a rotating braille frame; the timer
-- below advances it one frame per SPIN_MS while the panel is open and a
-- spinning state is on the list — an idle panel pays nothing. The frames are
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
    -- Keep spinning only while a SPINNING state (working) is on the list;
    -- blocked's ◉ is static and does not hold the timer up.
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

-- Rewrite the rows and their highlights. The ᐅ in the leading gutter marks a
-- session — the DISPLAYED one by default, or `pin_row` while a debounced step
-- is in flight so the marker moves with the cursor instead of trailing it.
-- The name column shows the session's custom name once one is set with `r`;
-- the default is just `claude` (the cursor and window layout tell sessions
-- apart).
local function render(buf, snap, pin_row)
  local lines = {}
  local marks = {}
  local any_spinning = false
  -- Both lines of every entry are padded to the panel window's DISPLAY width,
  -- so the selected entry's block background is two PLAIN single-line extmarks
  -- running the full row. No hl_eol: its semantics proved unreliable across
  -- nvim builds (a mark's final line is clipped to end_col and the EOL
  -- continuation misbehaves) — padded text needs no extension at all.
  -- Extmark columns stay BYTE offsets; the width/pad arithmetic is in columns.
  local width = active() and vim.api.nvim_win_get_width(M.win) or 80
  -- One resolved view per entry, shared by the line pass and the mark pass:
  -- the state style, whether the ᐅ marks it, and the symbol/gutter/name
  -- segments both passes need.
  local views = {}
  for i, s in ipairs(snap) do
    local style, marked = row_state(s, pin_row, i)
    -- nil sym = the working state's spinner frame
    local sym = style.sym or SPIN_FRAMES[spin_phase]
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
    -- Columns, not bytes: the arrow gutter is 5 bytes / 4 columns.
    local pad = string.rep(' ',
      math.max(width - GUTTER_COLS - rune_len(v.sym) - SYM_GAP - rune_len(v.name), 0))
    lines[entry_line(i)] = v.gutter .. v.sym .. string.rep(' ', SYM_GAP) .. v.name .. pad
    local word_line = string.rep(' ', WORD_PAD) .. v.style.word
    lines[entry_line(i) + 1] = word_line .. string.rep(' ', math.max(width - #word_line, 0))
    -- a blank separator line below every entry (a trailing one too: it never
    -- shows, and dropping it per-entry costs a modulo in a hot-ish loop)
    lines[entry_line(i) + 2] = ''
  end
  -- The extmarks that color the pieces of every row: the selected entry's
  -- block background (one full-width background mark per line — the lines
  -- themselves are padded to the window width), the arrow in the commit
  -- panel's hash accent, the state symbol and word in the state's color, and
  -- the session name in bold. All columns are BYTE offsets of their row.
  for i, v in ipairs(views) do
    local lnum = entry_line(i) - 1 -- 0-based symbol line
    -- Byte offsets for the marks: gutter/symbol/name segments of the line.
    local sym_col = #v.gutter
    local name_col = sym_col + #v.sym + SYM_GAP
    if v.marked then
      marks[#marks + 1] = {
        lnum = lnum, col = 0, end_col = #lines[lnum + 1],
        hl = 'ClaudeSessionsPanelCursor',
      }
      marks[#marks + 1] = {
        lnum = lnum + 1, col = 0, end_col = #lines[lnum + 2],
        hl = 'ClaudeSessionsPanelCursor',
      }
      -- col 1..4: one space, then the 3-byte ᐅ
      marks[#marks + 1] = {
        lnum = lnum, col = 1, end_col = 1 + #'ᐅ', hl = 'ClaudeSessionsPanelArrow',
      }
    end
    -- the state symbol, in the state's color (ends before the 2-space gap)
    marks[#marks + 1] = {
      lnum = lnum, col = sym_col, end_col = sym_col + #v.sym, hl = v.style.hl,
    }
    -- the session name, in bold
    marks[#marks + 1] = {
      lnum = lnum, col = name_col, end_col = name_col + #v.name,
      hl = 'ClaudeSessionsPanelName',
    }
    -- the state word on the line below, in the same color
    marks[#marks + 1] = {
      lnum = lnum + 1, col = WORD_PAD, end_col = WORD_PAD + #v.style.word,
      hl = v.style.hl,
    }
  end
  -- util's rewrite helper — the same clear/set/land the diff panel's render
  -- ends with (set_lines marks every row changed, so the rows land locked).
  U.set_rows(buf, ns, lines, marks)
  if any_spinning then start_spinner() end
end

--- Move the panel cursor to the symbol line of the DISPLAYED session — the
--- entry the block background is drawn on — so the raw editor cursor never
--- sits beside an unhighlighted row (a stray block on the left edge). Two
--- callers, one job: after a switch settles (`follow`) and after any refresh
--- with no step in flight (stepping holds the cursor where the user put it).
local function follow_displayed(snap)
  for i, s in ipairs(snap) do
    if s.open then
      pcall(vim.api.nvim_win_set_cursor, M.win, { entry_line(i), 0 })
      return
    end
  end
end

-- Display the session on row `row`. keep_focus keeps the cursor on the panel
-- (stepping); otherwise focus follows the session window. The focus juggling
-- itself lives in the main module's show_session.
local function select_row(row, keep_focus)
  M.stepping = keep_focus
  M.show(row)
  M.stepping = false
end

--- The session row under the panel cursor, or nil when the panel is gone.
--- Keys can arrive while the panel lacks focus (they route through the
--- terminal window that shows it below the tree), so the cursor is always
--- read from the panel's own window, wherever focus is.
local function cursor_row()
  if not active() then return nil end
  return line_entry(vim.api.nvim_win_get_cursor(M.win)[1])
end

-- <Down>/<Up>/j/k: move the cursor one entry and switch to that session. The
-- MARKER moves with the cursor — the entry is re-rendered with the arrow
-- pinned to it in the same keystroke. The switch itself is debounced (~120ms):
-- held keys sweep the cursor without paying a terminal open per entry, and
-- the entry under the cursor when the sweep settles is the one that loads.
local function step(dir)
  local row = cursor_row()
  if not row then return end
  local snap = snapshot()
  row = row + dir
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
    select_row(cursor_row(), true)
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
  local row = cursor_row()
  if row then select_row(row, false) end
end

-- <C-d>: kill the session under the cursor. Same semantics as terminal-mode
-- <C-d>: the process dies, the rows disappear, the split shows the next
-- session. Focus stays on the panel.
local function close_current_row()
  local row = cursor_row()
  if row then M.close_session(row) end
end

--- End the in-place rename. `apply` commits the row's current text as the new
--- name (empty restores the default `claude`); otherwise the edit is
--- discarded. Either way: leave insert, remove the backspace floor mapping,
--- re-arm the mode guard, re-lock the buffer, and re-render the rows (which
--- also repairs anything else the edit touched).
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
    M.rename_session(r.row, value) -- refreshes the rows with the new name
  else
    M.refresh() -- repaint: discards the edit / restores the old name
  end
end

-- <r>: rename the session under the cursor, in place on its row — no cmdline
-- prompt. The buffer is unlocked, insert mode starts with the cursor after
-- the name's last char, Enter applies the new name, Esc (or leaving insert
-- any other way) cancels and restores the row.
local function rename_current_row()
  local row = cursor_row()
  if not row or renaming then return end
  local s = snapshot()[row]
  if not s then return end
  local name = s.name or 'claude'
  local lnum = entry_line(row) - 1 -- 0-based symbol line
  -- The name starts after the gutter, the state symbol and the gap. The
  -- symbol can be a 3-byte spinner frame mid-animation, so the name's byte
  -- offset is read off the row: find the name text after the leading
  -- gutter..symbol..gap prefix.
  local line = vim.api.nvim_buf_get_lines(M.buf, lnum, lnum + 1, false)[1] or ''
  local name_col = line:find(name, 1, true)
  if not name_col then return end -- row not in the expected shape; bail out
  renaming = { row = row, lnum = lnum, name_col = name_col }
  -- A backspace floor at the name start: insert-mode <BS>/<C-w> refuse to
  -- delete left of it, so the gutter, the state symbol and the gap the name
  -- sits on survive any edit. (A plain 'backspace' option can express "stop
  -- at insert start" only globally — the floor is per-edit, hence a mapping.)
  local function backspace_floor()
    if vim.fn.col('.') <= name_col then return '' end
    return '<BS>'
  end
  for _, key in ipairs(FLOOR_KEYS) do
    vim.keymap.set('i', key, backspace_floor,
      { buffer = M.buf, expr = true, replace_keycodes = true, desc = 'claude sessions: rename floor' })
  end
  vim.bo[M.buf].modifiable = true
  -- byte col just past the name's last char = where insert mode starts typing
  vim.fn.cursor(lnum + 1, name_col + #name)
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
  -- An in-place rename has unlocked text on the rows; a repaint here (a
  -- spinner frame, a busy-state flip) would clobber the edit mid-keystroke.
  -- finish_rename repaints after the edit ends.
  if renaming then return end
  local snap = snapshot()
  if #snap == 0 then
    M.close()
    return
  end
  local line = vim.api.nvim_win_get_cursor(M.win)[1]
  render(M.buf, snap, arrow_row)
  -- Keep the cursor on a SYMBOL line: clamp to the list (the last entry's
  -- symbol line — util's mapping, spelled entry_line(#snap); the raw `3n-2`
  -- it replaces), then snap back to the same entry's symbol line (a raw
  -- clamp can land on a state-word or separator line). One line SHORT of it
  -- (`- 1`) is what broke j/k for months: a cursor on the last entry's
  -- symbol line clamped to the separator above and snapped to entry n-1 —
  -- with two sessions every refresh yanked the cursor back to entry 1, so
  -- the list would not step at all.
  line = math.min(math.max(line, 1), U.entry_line(#snap))
  pcall(vim.api.nvim_win_set_cursor, M.win, { entry_line(line_entry(line)), 0 })
  -- No step in flight: rest the cursor on the displayed session's entry so it
  -- never sits beside an unhighlighted row (the stray block on the left).
  if not arrow_row then follow_displayed(snap) end
end

-- Registry changed: refresh the rows, or close the panel when no session
-- window is displayed anymore. Never OPENS the panel — that happens only when
-- a session is shown, or the tree opens while one is displayed. A switch
-- (session A's window closing, session B's opening) passes through the
-- not-visible state: hold the panel open and let show_session()'s open()
-- refresh the rows, so the panel never moves or loses the cursor.
function M.sync(visible)
  if not visible then
    M.close()
  elseif active() then
    M.refresh()
  end
end

-- Move the panel cursor to the displayed session's entry. Called after a
-- <C-s> switch settles.
function M.follow()
  if not active() then return end
  follow_displayed(snapshot())
end

-- Panel keymaps. Editing keys have no business here, and on a nomodifiable
-- buffer nvim refuses them with a noisy E21 (the reported error). Silence the
-- common ones FIRST (util's shared list — the diff panel silences the same
-- ones, minus its own j/k cursor moves) so the functional maps below win;
-- everything else keeps its default. NOT silenced: <C-a> — the global mapping
-- creates a session, and that must work with the cursor on the panel too.
local function set_keymaps(buf)
  U.silence_editing_keys(buf)
  local function map(key, fn, desc)
    vim.keymap.set('n', key, fn,
      { buffer = buf, nowait = true, silent = true, desc = 'claude sessions: ' .. desc })
  end
  -- Insert mode (in-place rename): Enter applies the edit instead of splitting
  -- the row; Esc leaves insert and the InsertLeave hook cancels the edit.
  vim.keymap.set('i', '<CR>', function() finish_rename(true) end,
    { buffer = buf, nowait = true, silent = true, desc = 'claude sessions: apply rename' })
  vim.keymap.set('i', '<Esc>', function() finish_rename(false) end,
    { buffer = buf, nowait = true, silent = true, desc = 'claude sessions: cancel rename' })
  map('q', function() M.close() end, 'close panel')
  map('<CR>', open_current, 'open session')
  map('l', open_current, 'open session')
  map('o', open_current, 'open session')
  map('<C-d>', close_current_row, 'close session')
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
  -- Fixed height: 30% of the screen, like diffview's commit panel cap.
  local height = math.floor(vim.o.lines * 0.3)
  vim.api.nvim_set_current_win(tw)
  vim.cmd('below ' .. height .. 'split')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  -- The split below the tree inherits the tree window's options; the panel is
  -- plain text (util's helper — the diff panel applies the same look).
  U.plain_text_window(win)
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
  -- Every hook below shares one predicate: an insert the panel does not want
  -- — one that lands on one of the frame's read-only panel buffers while no
  -- rename is in flight (a rename's own insert is deliberate and passes; see
  -- `renaming` above). The diff panel (the sidebar's changed-files list) is a
  -- different buffer with a different filetype — a late toggleterm closure
  -- spells startinsert on IT too, and the same INSERT flash / E21 lands
  -- there. Both spellings share the guard.
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
  -- fires BEFORE the new mode is observable — vim.fn.mode() still reads 'n'
  -- inside the callback — so a mode check here would never fire; the event
  -- itself IS the signal, stopinsert unconditionally. Modifiable is flipped
  -- on for the duration so edits queued by a race ahead of the vim.cmd guard
  -- above are absorbed without E21, and restored on leave.
  vim.api.nvim_create_autocmd('InsertEnter', {
    callback = function(ev)
      if not stray_insert(ev.buf) then return end
      vim.cmd('stopinsert')
      vim.bo[ev.buf].modifiable = true
    end,
  })
  vim.api.nvim_create_autocmd('InsertLeave', {
    callback = function(ev)
      -- The rename's own lifecycle (cancel, modifiable restore) is the
      -- session panel's spelling — the diff panels spell none (they are
      -- ALWAYS nomodifiable; U.set_rows owns their flips), so their leave
      -- just restores nomodifiable.
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
  -- ModeChanged fires AFTER the switch, so there the mode read is accurate —
  -- and the pattern must match old:new mode strings, not filetypes.
  vim.api.nvim_create_autocmd('ModeChanged', {
    pattern = '*:[it]*',
    callback = function()
      if stray_insert(0) then vim.cmd('stopinsert') end
    end,
  })
  -- If insert still managed to land (a render window with modifiable=true,
  -- a race ahead of the guards above), queued keys would edit this buffer —
  -- blank every char before it lands.
  vim.api.nvim_create_autocmd('InsertCharPre', {
    callback = function()
      if stray_insert(0) then vim.v.char = '' end
    end,
  })
  -- Braces: a stray startinsert can also slip through between events; the
  -- poll loop (300ms, only while sessions exist) notices a panel stuck in
  -- insert and evicts it. Cheap: one mode + filetype check per tick. The
  -- rename's own insert is exempt (renaming set).
  vim.api.nvim_create_autocmd('User', {
    pattern = 'ClaudeSessionsTick',
    callback = function()
      if not stray_insert(0) then return end
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
        local snap = snapshot()
        local visible = false
        for _, s in ipairs(snap) do
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
