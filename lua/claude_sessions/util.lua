-- Primitives shared by the two sidebar panels (panel.lua, diff.lua): window
-- lookups, the scratch buffers they render into, their plain window look, the
-- row rewrite both renders end with, and the row↔entry mapping of the shared
-- three-line row shape. Inert helpers — no state, no lifecycle; the panels own
-- theirs.

local U = {}

--- Is this window id a real, live window?
function U.valid_win(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

--- Is this buffer id a real, live buffer?
function U.valid_buf(buf)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

--- Focus a window, if it is still there; `fallback` when it is not. Returns
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

--- The window currently showing a buffer of filetype `ft`, or nil. Current
--- tabpage only: nvim_list_wins crosses tabs, and a sibling panel's window on
--- another tab must never be mistaken for this tab's.
function U.window_with_filetype(ft)
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local ok, b = pcall(vim.api.nvim_win_get_buf, w)
    if ok and vim.bo[b].filetype == ft then return w end
  end
end

--- Pin `opts` ({ name = value, ... }) as window-local options on `win`.
function U.apply_winopts(win, opts)
  for opt, val in pairs(opts) do
    vim.wo[win][opt] = val
  end
end

--- The window currently showing nvim-tree's buffer, or nil. Both panels split
--- from it (they anchor below it).
function U.tree_window()
  return U.window_with_filetype('NvimTree')
end

--- The plugin's notify convention: `msg` under the 'claude sessions' title,
--- at `level` (INFO when none).
function U.notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'claude sessions' })
end

--- Run `args` on a job and hand its stdout (joined, one row per output line)
--- to `cb` when it exits 0, else nil. Non-blocking; the callback lands
--- scheduled. A failed spawn (the command gone from PATH) lands nil too —
--- callers gate on the value, never on an error.
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

-- Both panels render THREE buffer lines per entry — a name/symbol row, a
-- detail row, a blank separator — so their row↔entry mapping is shared here.

--- First buffer line (1-based) of entry `i` — the name/symbol row.
function U.entry_line(i)
  return 3 * i - 2
end

--- Entry index for buffer line `line` (either row of an entry, or the
--- separator below it).
function U.line_entry(line)
  return math.floor((line + 2) / 3)
end

--- How many entries a buffer of `lines` lines holds — the mapping's inverse.
function U.entry_count(lines)
  return math.floor(lines / 3)
end

--- Display width of a short panel string. Every rune the panels draw (gutter
--- arrow, state symbols, spinner frames, the bar's boxes) is single-width,
--- but NOT single-BYTE — `ᐅ`/`✓`/`⠋`/`▪` are 3 bytes — so padding and extmark
--- columns need the rune count, not `#`.
function U.rune_len(str)
  return vim.fn.strcharlen(str)
end

--- Right-pad `s` with spaces to `width` display columns (a no-op past width).
--- Full-width rows are how a selected entry's block background spans its
--- panel: a plain row mark stops at the row's own end, so the row itself is
--- padded rather than extended with hl_eol (whose semantics proved
--- unreliable across nvim builds).
function U.pad_to(s, width)
  local pad = math.max(width - U.rune_len(s), 0)
  return pad > 0 and s .. string.rep(' ', pad) or s
end

--- A hidden scratch buffer a panel renders into.
function U.scratch_buffer(filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].filetype = filetype
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].buflisted = false
  vim.bo[buf].swapfile = false
  -- No completion popups on the panel text (blink.cmp reads this var; the
  -- session panel's rename edits are where it bites).
  vim.b[buf].completion = false
  return buf
end

-- Plain-text window look. The panels split below the tree and inherit its
-- window options; they are plain text — nothing decorates their edges (a
-- fold/sign column would draw grey blocks beside the rows).
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

--- The plain-text look, with `overrides` merged over (a fresh table either
--- way) — the table a module spells its whole look from: apply it, and
--- capture/restore its keys around anything that rewrites the look.
function U.plain_look(overrides)
  return vim.tbl_extend('force', PLAIN_TEXT, overrides or {})
end

--- Apply the plain-text look to a freshly split panel window.
function U.plain_text_window(win)
  U.apply_winopts(win, PLAIN_TEXT)
end

-- Terminals draw their own cursor; the global cursorline/cursorcolumn only
-- paint BEHIND it — a full-width row plus a full-height column — and a
-- terminal screen never repaints the cells those stop highlighting when focus
-- moves on, so every window switch leaves the cross (or the T a CLI's next
-- frame cleared half of) baked into the terminal. The panels' plain look
-- already drops both; terminal windows need the same two dropped — directly
-- at the open sites of the windows this plugin owns, and via the BufWinEnter
-- hook in setup() wherever a terminal buffer lands in any other window.
local TERMINAL_PLAIN = { cursorline = false, cursorcolumn = false }

--- Strip cursorline/cursorcolumn from a window showing a terminal buffer
--- (see TERMINAL_PLAIN for why they must never draw there).
function U.plain_terminal_window(win)
  U.apply_winopts(win, TERMINAL_PLAIN)
end

--- Calibrate the sidebar stack (the tree + the panels split below it) to
--- thirds: every window but the first takes floor(rows / 3); the first (the
--- tree) takes the remainder — the stack's largest share, never crushed. The
--- rows are read from the stack itself: rows derived from o.lines can
--- disagree with it whenever cmdline/frame churn shifted them. A
--- win_set_height redistributes within the stack (the nearest neighbour pays
--- first), so the assertion is ITERATED until exact, then the windows are
--- repinned. NO restack — wincmd J moves the current window to the bottom of
--- the full-width FRAME, not its own column, so in a real session it pulls
--- the sidebar windows across full width and wrecks the layout. Windows that
--- are not up (a panel still to open) are skipped — their own open()
--- calibrates the full stack.
function U.calibrate_sidebar(...)
  local up = {}
  for _, w in ipairs({ ... }) do
    if U.valid_win(w) then up[#up + 1] = w end
  end
  if #up == 0 then return end
  -- Unpin: the heights are asserted below, and a pinned window can't hold.
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
  -- Capped so a stack that won't converge (a window clamped at min 1) still
  -- repins.
  for _ = 1, 8 do
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
--- of { lnum = row, col = byte offset, end_col = byte offset, hl = group }.
--- The whole rewrite runs modifiable so a nomodifiable panel can take fresh
--- rows; the marks replay after set_lines (the rows don't exist before).
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
-- nomodifiable one nvim refuses them with a noisy E21. Silence the common
-- ones FIRST so a panel's functional maps win; everything else keeps its
-- default. NOT silenced: <C-a> — the global mapping creates a session, and
-- that must work with the cursor on a panel too.
local SILENCED_KEYS = { 'a', 'A', 'i', 'I', 'O', 'c', 'C', 's', 'S', 'd', 'x', 'p', 'u' }

--- Silence the editing keys on a read-only panel buffer (see SILENCED_KEYS).
function U.silence_editing_keys(buf)
  for _, key in ipairs(SILENCED_KEYS) do
    vim.keymap.set('n', key, '<Nop>', { buffer = buf, nowait = true, silent = true })
  end
end

return U
