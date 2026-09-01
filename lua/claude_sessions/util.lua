-- Primitives shared by the two sidebar panels (panel.lua, diff.lua): window
-- lookups, the scratch buffers they render into, their plain window look and
-- the row rewrite both renders end with. Inert helpers — no state, no
-- lifecycle; the panels own theirs.

local U = {}

--- Is this window id a real, live window?
function U.valid_win(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

--- Focus a window, if it is still there; `fallback` when it is not.
function U.focus(win, fallback)
  if U.valid_win(win) then
    pcall(vim.api.nvim_set_current_win, win)
  elseif fallback then
    pcall(vim.api.nvim_set_current_win, fallback)
  end
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

--- Apply the plain look to a freshly split panel window.
function U.plain_text_window(win)
  for opt, val in pairs(PLAIN_TEXT) do
    vim.wo[win][opt] = val
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
-- that must work with the cursor on a panel too. (Also silenced by the diff
-- panel: j/k move its cursor, not insert.)
U.SILENCED_KEYS = { 'a', 'A', 'i', 'I', 'O', 'c', 'C', 's', 'S', 'd', 'x', 'p', 'u' }

--- Silence the editing keys on a read-only panel buffer (see SILENCED_KEYS).
function U.silence_editing_keys(buf)
  for _, key in ipairs(U.SILENCED_KEYS) do
    vim.keymap.set('n', key, '<Nop>', { buffer = buf, nowait = true, silent = true })
  end
end

return U
