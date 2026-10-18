-- Primitives shared by the panels: window lookups, scratch buffers, the
-- plain window look, the row rewrite both renders end with, and the row↔entry
-- mapping of the shared three-line row shape. Inert helpers — no state, no
-- lifecycle; the panels own theirs.

local U = {}

-- The event loop, old-name compatible: one spelling for every timer/cwd/fs
-- call in the plugin.
U.uv = vim.uv or vim.loop

-- The name a session shows until it is renamed — one home for the literal the
-- registry and the panel both fall back to.
U.DEFAULT_NAME = 'claude'

function U.valid_win(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

function U.valid_buf(buf)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

--- Focus a window if it is still there; `fallback` when it is not. Returns
--- whether focus landed on `win`.
function U.focus(win, fallback)
  if U.valid_win(win) and pcall(vim.api.nvim_set_current_win, win) then
    return vim.api.nvim_get_current_win() == win
  elseif fallback then
    pcall(vim.api.nvim_set_current_win, fallback)
  end
  return false
end

--- The current tab's real windows: non-floating, non-external — a floating
--- picker is someone else's UI, never a layout candidate.
function U.real_windows()
  local wins = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local ok, cfg = pcall(vim.api.nvim_win_get_config, w)
    if ok and cfg and (cfg.relative or '') == '' and not cfg.external then
      wins[#wins + 1] = w
    end
  end
  return wins
end

--- The window showing a buffer of filetype `ft`, or nil. Current tabpage
--- only — a sibling panel's window on another tab must never count here.
function U.window_with_filetype(ft)
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local ok, b = pcall(vim.api.nvim_win_get_buf, w)
    if ok and vim.bo[b].filetype == ft then return w end
  end
end

--- The window showing nvim-tree's buffer, or nil (both panels anchor below it).
function U.tree_window()
  return U.window_with_filetype('NvimTree')
end

function U.apply_winopts(win, opts)
  for opt, val in pairs(opts) do
    vim.wo[win][opt] = val
  end
end

--- Split a window `height` rows tall directly below `anchor` and show `buf` in
--- it, then `style` that window. `below` splits the CURRENT window's row, so
--- the current window moves to the anchor first. Returns the new window.
function U.split_below(anchor, height, buf, style)
  vim.api.nvim_set_current_win(anchor)
  vim.cmd('below ' .. height .. 'split')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  if style then style(win) end
  return win
end

-- The sidebar's stack, top to bottom: nvim-tree, the changed-files panel,
-- the session list. Anchors and calibration follow this order however the
-- windows are (re)opened.
local SIDEBAR_FTS = { 'NvimTree', 'claude-sessions-diff', 'claude-sessions-panel' }

-- The panel buffers that live in the tree's column (the stack's tail).
U.PANEL_FTS = { SIDEBAR_FTS[2], SIDEBAR_FTS[3] }

-- Narrowest editor column left when fitting the terminal's width.
local MIN_EDITOR_WIDTH = 10

--- The live sidebar stack, top-down — windows not up are skipped.
function U.sidebar_windows()
  local wins = {}
  for _, ft in ipairs(SIDEBAR_FTS) do
    local w = U.window_with_filetype(ft)
    if w then wins[#wins + 1] = w end
  end
  return wins
end

--- Is `buf` a sidebar buffer (the tree or one of its panels)?
local function sidebar_ft(buf)
  return vim.tbl_contains(SIDEBAR_FTS, vim.bo[buf].filetype)
end

--- Horizontal extent {left, right} of `win`, in screen columns.
local function extent(win)
  local left = vim.api.nvim_win_get_position(win)[2]
  return left, left + vim.api.nvim_win_get_width(win) - 1
end

--- The horizontal extents of the sidebar windows in `wins`.
local function sidebar_extents(wins)
  local out = {}
  for _, w in ipairs(wins) do
    if sidebar_ft(vim.api.nvim_win_get_buf(w)) then
      out[#out + 1] = { extent(w) }
    end
  end
  return out
end

--- The displayed session terminal window, or nil. toggleterm may reset its
--- filetype to 'toggleterm' for a moment, so the session marker counts too.
function U.session_window()
  for _, w in ipairs(U.real_windows()) do
    local b = vim.api.nvim_win_get_buf(w)
    local ft = vim.bo[b].filetype
    if ft == 'claude' or (ft == 'toggleterm' and vim.b[b].claude_session_name) then
      return w
    end
  end
end

--- A real window showing a normal (editable) buffer in its own column — what
--- nvim-tree opens files into — or nil. The largest wins (the pane's
--- take-over preference); `except` skips one window (a broken split being
--- repaired); windows overlapping the sidebar don't count.
function U.editor_window(except)
  local wins = U.real_windows()
  local extents = sidebar_extents(wins)
  local best, best_area
  for _, w in ipairs(wins) do
    if w ~= except then
      local b = vim.api.nvim_win_get_buf(w)
      if vim.bo[b].buftype == '' then
        local left, right = extent(w)
        local broken = false
        for _, e in ipairs(extents) do
          if e[2] >= left and e[1] <= right then
            broken = true
            break
          end
        end
        if not broken then
          local area = vim.api.nvim_win_get_width(w) * vim.api.nvim_win_get_height(w)
          if area > (best_area or -1) then
            best, best_area = w, area
          end
        end
      end
    end
  end
  return best
end

--- Does `win` horizontally overlap a sidebar window? In a sane sessions
--- layout the sidebar is its own column; overlap means nvim-tree split the
--- TREE and dropped the file inside the sidebar column.
function U.sidebar_overlap(win)
  local left, right = extent(win)
  for _, e in ipairs(sidebar_extents(U.real_windows())) do
    if e[2] >= left and e[1] <= right then return true end
  end
  return false
end

--- An empty, unlisted, self-wiping normal buffer — an editor slot.
function U.empty_editor_buffer()
  local buf = vim.api.nvim_create_buf(false, false)
  vim.bo[buf].bufhidden = 'wipe'
  return buf
end

--- Move the file in `win` — which landed inside the sidebar column — out to
--- an editor window left of the session terminal.
function U.repair_editor_window(win)
  if not U.valid_win(win) then return end
  local buf = vim.api.nvim_win_get_buf(win)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local target = U.ensure_editor_window(win)
  if not target then return end
  vim.api.nvim_win_set_buf(target, buf)
  pcall(vim.api.nvim_win_set_cursor, target, cursor)
  vim.api.nvim_set_current_win(target)
  pcall(vim.api.nvim_win_close, win, true)
  U.normalize_columns() -- closing the bad split freed width
end

--- The configured width of a vertical session terminal (toggleterm's `size`,
--- evaluated for the vertical direction), or nil when unknown.
local function terminal_width()
  local ok, cfg = pcall(require, 'toggleterm.config')
  if not ok then return nil end
  local ok2, size = pcall(cfg.get, 'size')
  if not ok2 then return nil end
  if type(size) == 'function' then
    local ok3, value = pcall(size, { direction = 'vertical' })
    size = ok3 and value or nil
  end
  return type(size) == 'number' and math.floor(size) or nil
end

--- nvim-tree's resolved sidebar width, or nil when unknown/adaptive.
local function tree_width()
  local ok, vs = pcall(require, 'nvim-tree.view-state')
  if ok and vs.Active and not vs.Active.adaptive_size
      and type(vs.Active.initial_width) == 'number' then
    return vs.Active.initial_width
  end
end

--- Restore the sessions column proportions: sidebar at nvim-tree's width,
--- session terminal at its configured width, editor column takes the rest.
--- nvim-tree and toggleterm both set 'winfixwidth', so Neovim hands a closed
--- editor's width to one of them — the sidebar can balloon and the terminal
--- shrink. Runs after every layout change the plugin drives.
function U.normalize_columns()
  local host = U.session_window()
  if not host then return end
  local tree = U.tree_window()
  local side = tree_width()
  if tree and side and vim.api.nvim_win_get_width(tree) ~= side then
    pcall(vim.api.nvim_win_set_width, tree, side)
  end
  local term = terminal_width()
  local ed = U.editor_window()
  if not (term and ed) then return end
  local total = vim.api.nvim_win_get_width(host) + vim.api.nvim_win_get_width(ed)
  local target = math.min(term, total - MIN_EDITOR_WIDTH)
  if target >= MIN_EDITOR_WIDTH and target ~= vim.api.nvim_win_get_width(host) then
    pcall(vim.api.nvim_win_set_width, host, target)
  end
end

-- Coalesce the normalizations a batch window close would queue.
local normalize_pending = false

--- Normalize on the next event-loop pass, at most once per batch.
function U.schedule_normalize()
  if normalize_pending then return end
  normalize_pending = true
  vim.schedule(function()
    normalize_pending = false
    U.normalize_columns()
  end)
end

--- The editable window, creating an empty one in the column left of the
--- session terminal when the layout has none (the sessions layout's editor
--- column). Without it nvim-tree's next file open splits the TREE window and
--- lands inside the sidebar column. nil without a terminal to anchor on.
function U.ensure_editor_window(except)
  local win = U.editor_window(except)
  if win then
    U.normalize_columns()
    return win
  end
  -- A real session window, never the zoom float: splitting from a float
  -- lands a degenerate full-width window. `vnew` gives the split an empty
  -- buffer directly, so the terminal is never shown in two windows.
  local host = U.session_window()
  if not host then return nil end
  local prev = vim.api.nvim_get_current_win()
  local splitright = vim.o.splitright
  vim.o.splitright = false
  U.focus(host)
  local ok = pcall(vim.cmd, 'vnew')
  vim.o.splitright = splitright
  if not ok or vim.api.nvim_get_current_win() == host then
    U.focus(prev, host)
    return nil
  end
  win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buflisted = false
  vim.bo[buf].bufhidden = 'wipe'
  U.normalize_columns()
  U.focus(prev, win)
  return win
end

--- `msg` under the 'claude sessions' title, at `level` (INFO when none).
function U.notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'claude sessions' })
end

--- Run `args` on a job and hand its stdout (joined) to `cb` when it exits 0,
--- else nil. Non-blocking; the callback lands scheduled. Callers gate on the
--- value, never on an error.
function U.job(args, cb)
  local stdout = {}
  local ok, job_id = pcall(vim.fn.jobstart, args, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then vim.list_extend(stdout, data) end
    end,
    on_exit = function(_, code)
      local out = code == 0 and table.concat(stdout, '\n') or nil
      vim.schedule(function() cb(out) end)
    end,
  })
  if not ok or type(job_id) ~= 'number' or job_id <= 0 then
    vim.schedule(function() cb(nil) end)
  end
end

-- Both panels render THREE buffer lines per entry — a name row, a detail
-- row, a blank separator — so the row↔entry mapping is shared here.

function U.entry_line(i) -- first (1-based) buffer line of entry `i`
  return 3 * i - 2
end

function U.line_entry(line) -- entry index for buffer line `line`
  return math.floor((line + 2) / 3)
end

function U.entry_count(lines) -- entries held by a buffer of `lines` lines
  return math.floor(lines / 3)
end

--- Right-pad `s` to `width` display columns. Full-width rows are how a
--- selected entry's block background spans its panel (hl_eol proved
--- unreliable across builds). strcharlen, not #: every rune the panels draw
--- (ᐅ/✓/⠋/▪) is single-width but multi-byte.
function U.pad_to(s, width)
  local pad = math.max(width - vim.fn.strcharlen(s), 0)
  return pad > 0 and s .. string.rep(' ', pad) or s
end

--- A hidden scratch buffer to render into. `filetype` optional (each panel
--- tags its own). nvim_create_buf's scratch flag already gives buftype
--- 'nofile', bufhidden 'hide', buflisted false and swapfile false.
function U.scratch_buffer(filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  if filetype then vim.bo[buf].filetype = filetype end
  vim.b[buf].completion = false -- no completion popups on panel text
  return buf
end

-- Plain-text window look. The panels split below the tree and inherit its
-- options; they are plain text — nothing decorates their edges.
local PLAIN_TEXT = {
  number = false,
  relativenumber = false,
  signcolumn = 'no',
  foldcolumn = '0',
  cursorcolumn = false,
  statuscolumn = '',
  wrap = false,
  cursorline = false, -- the selected entry is highlighted by render() instead
}

--- The plain look with `overrides` merged over (a fresh table) — spell a
--- module's whole look from it, and capture/restore its keys around anything
--- that rewrites the look.
function U.plain_look(overrides)
  return vim.tbl_extend('force', PLAIN_TEXT, overrides or {})
end

--- Apply the plain-text look to a freshly split panel window.
function U.plain_text_window(win)
  U.apply_winopts(win, PLAIN_TEXT)
end

-- Terminals draw their own cursor; cursorline/cursorcolumn only paint BEHIND
-- it, and a terminal screen never repaints those cells when focus moves on —
-- the cross stays baked in. Never let the two draw in a terminal window.
local TERMINAL_PLAIN = { cursorline = false, cursorcolumn = false }

--- Strip cursorline/cursorcolumn from a window showing a terminal buffer.
function U.plain_terminal_window(win)
  U.apply_winopts(win, TERMINAL_PLAIN)
end

--- Calibrate the sidebar stack (tree + panels below it) to thirds: every
--- window but the first takes floor(rows/3); the tree takes the remainder.
--- `wins` is the stack top-down — U.sidebar_windows() is the usual spelling.
--- Rows are read from the stack itself (o.lines can disagree with it after
--- cmdline/frame churn). win_set_height redistributes within the stack
--- (nearest neighbour pays first), so the assertion is ITERATED until exact,
--- then the windows are repinned. NO restack — wincmd J moves the current
--- window to the bottom of the full-width FRAME, not its own column, which
--- wrecks the layout. Windows not up are skipped; their own open()
--- calibrates the full stack.
function U.calibrate_sidebar(wins)
  local up = {}
  for _, w in ipairs(wins or {}) do
    if U.valid_win(w) then up[#up + 1] = w end
  end
  if #up == 0 then return end
  for _, w in ipairs(up) do
    vim.wo[w].winfixheight = false
  end
  local rows = 0
  for _, w in ipairs(up) do
    rows = rows + vim.api.nvim_win_get_height(w)
  end
  local panels = #up - 1
  local third = panels > 0 and math.max(1, math.floor(rows / 3)) or 0
  local targets = {}
  for i, w in ipairs(up) do
    targets[w] = (i == 1) and (rows - panels * third) or third
  end
  for _ = 1, 8 do -- capped so a stack that can't converge still repins
    local exact = true
    for _, w in ipairs(up) do
      if vim.api.nvim_win_get_height(w) ~= targets[w] then
        vim.api.nvim_win_set_height(w, targets[w])
        exact = false
      end
    end
    if exact then break end
  end
  for _, w in ipairs(up) do
    vim.wo[w].winfixheight = true
  end
end

--- Replace a panel buffer's rows and repaint its extmarks: `marks` is a list
--- of { lnum, col, end_col, hl } (cols are byte offsets). Runs modifiable so
--- a nomodifiable panel can take fresh rows; marks replay after set_lines.
function U.set_rows(buf, ns, lines, marks)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, m.lnum, m.col, {
      end_row = m.lnum, end_col = m.end_col, hl_group = m.hl,
    })
  end
end

-- Editing keys have no business on a read-only panel buffer, and on a
-- nomodifiable one nvim refuses them with a noisy E21. NOT silenced:
-- <C-a> — the global mapping creates a session and must work on a panel.
local SILENCED_KEYS = { 'a', 'A', 'i', 'I', 'O', 'c', 'C', 's', 'S', 'd', 'x', 'p', 'u' }

--- Silence the editing keys on a read-only panel buffer (see SILENCED_KEYS).
function U.silence_editing_keys(buf)
  for _, key in ipairs(SILENCED_KEYS) do
    vim.keymap.set('n', key, '<Nop>', { buffer = buf, nowait = true, silent = true })
  end
end

--- Set one read-only-panel keymap: buffer-local, nowait, silent, plugin-desc'd.
function U.map_key(buf, key, fn, desc)
  vim.keymap.set('n', key, fn,
    { buffer = buf, nowait = true, silent = true, desc = 'claude sessions: ' .. desc })
end

return U
