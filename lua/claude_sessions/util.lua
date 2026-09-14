-- Primitives shared by the panels: window lookups, scratch buffers, the
-- plain window look, the row rewrite both renders end with, and the row↔entry
-- mapping of the shared three-line row shape. Inert helpers — no state, no
-- lifecycle; the panels own theirs.

local U = {}

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

--- A hidden scratch buffer to render into. `filetype` optional (a scratch
--- with no filetype of its own, e.g. the zoom-park buffer).
function U.scratch_buffer(filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  if filetype then vim.bo[buf].filetype = filetype end
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].buflisted = false
  vim.bo[buf].swapfile = false
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
--- Rows are read from the stack itself (o.lines can disagree with it after
--- cmdline/frame churn). win_set_height redistributes within the stack
--- (nearest neighbour pays first), so the assertion is ITERATED until exact,
--- then the windows are repinned. NO restack — wincmd J moves the current
--- window to the bottom of the full-width FRAME, not its own column, which
--- wrecks the layout. Windows not up are skipped; their own open()
--- calibrates the full stack.
function U.calibrate_sidebar(...)
  local up = {}
  for _, w in ipairs({ ... }) do
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
