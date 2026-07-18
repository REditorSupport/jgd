-- jgd.view — display the current plot PNG in a dedicated Neovim window via
-- image.nvim (Kitty graphics protocol). Falls back gracefully (returns
-- false) when image.nvim isn't available, e.g. headless CI.

local M = {}

local image_ok, image = pcall(require, "image")

local state = {
  win = nil,  -- dedicated viewer window
  buf = nil,  -- scratch buffer backing it
  img = nil,  -- current image.nvim object
}

function M.available()
  return image_ok
end

local function win_valid(w)
  return w and vim.api.nvim_win_is_valid(w)
end

-- Pick a window to split for the viewer: prefer a normal (non-terminal,
-- non-floating) window so we split the editor area and leave the R console
-- (a terminal, typically full-width at the bottom) untouched.
local function pick_host_win()
  local function ok(w)
    if not win_valid(w) then return false end
    if vim.api.nvim_win_get_config(w).relative ~= "" then return false end -- floating
    local b = vim.api.nvim_win_get_buf(w)
    return vim.bo[b].buftype ~= "terminal"
  end
  local cur = vim.api.nvim_get_current_win()
  if ok(cur) then return cur end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if ok(w) then return w end
  end
  return cur
end

-- Create (once) the viewer as a right-hand split of the editor window, so
-- it sits in the top-right and the R console keeps the full bottom width.
local function ensure_window()
  if win_valid(state.win) then return end
  local return_to = vim.api.nvim_get_current_win()

  local host = pick_host_win()
  vim.api.nvim_set_current_win(host)
  vim.cmd("rightbelow vsplit")
  state.win = vim.api.nvim_get_current_win()

  state.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(state.win, state.buf)
  local bo = vim.bo[state.buf]
  bo.filetype = "jgd"
  bo.buftype = "nofile"
  bo.bufhidden = "wipe"
  bo.swapfile = false

  local wo = vim.wo[state.win]
  wo.number = false
  wo.relativenumber = false
  wo.cursorline = false
  wo.list = false
  wo.signcolumn = "no"
  wo.fillchars = "eob: " -- hide end-of-buffer "~" markers

  -- Buffer-local nav keys, active only while the viewer is focused.
  local function map(lhs, cmd, desc)
    vim.keymap.set("n", lhs, "<cmd>" .. cmd .. "<cr>",
      { buffer = state.buf, nowait = true, silent = true, desc = desc })
  end
  map("h", "JgdPrev", "jgd: previous plot")
  map("<Left>", "JgdPrev", "jgd: previous plot")
  map("l", "JgdNext", "jgd: next plot")
  map("<Right>", "JgdNext", "jgd: next plot")
  map("d", "JgdDelete", "jgd: delete plot")
  map("x", "JgdDelete", "jgd: delete plot")
  map("w", "JgdSave", "jgd: save/export plot")
  map("q", "JgdClose", "jgd: close viewer")
  map("r", "JgdRefresh", "jgd: refresh")

  vim.api.nvim_win_set_width(state.win, math.max(20, math.floor(vim.o.columns * 0.42)))

  if win_valid(return_to) then vim.api.nvim_set_current_win(return_to) end
end

--- Show a PNG in the viewer window. opts.label is shown as a winbar; its
--- row is accounted for in pixel_size() so the image doesn't overflow.
function M.show(png_path, opts)
  if not image_ok then return false, "image.nvim not available" end
  opts = opts or {}
  ensure_window()
  if state.img then pcall(function() state.img:clear() end) end
  if opts.label then pcall(function() vim.wo[state.win].winbar = opts.label end) end

  local w = vim.api.nvim_win_get_width(state.win)
  local ok, img_or_err = pcall(image.from_file, png_path, {
    id = "jgd-plot",
    window = state.win,
    buffer = state.buf,
    x = 0,
    y = 0,
    width = w, -- fit to window width; height follows aspect (kitty clips to win)
  })
  if not ok then return false, img_or_err end
  state.img = img_or_err
  pcall(function() state.img:render() end)
  return true
end

--- Re-render the current image at the window's current width (for resize).
function M.refresh()
  if state.img and win_valid(state.win) then
    local w = vim.api.nvim_win_get_width(state.win)
    pcall(function() state.img:render({ x = 0, y = 0, width = w }) end)
  end
end

function M.clear()
  if state.img then pcall(function() state.img:clear() end); state.img = nil end
end

function M.close()
  M.clear()
  if win_valid(state.win) then pcall(vim.api.nvim_win_close, state.win, true) end
  state.win, state.buf = nil, nil
end

function M.is_open()
  return win_valid(state.win)
end

-- Extra rows to leave clear at the bottom so whole-cell rounding in the
-- image backend never spills the plot past the window into the split below.
M.height_margin_rows = 1

--- Pixel dimensions of the viewer window (cols/rows * terminal cell size),
--- or nil if unavailable. Used to tell R what size to replay the plot at.
function M.pixel_size()
  if not win_valid(state.win) then return nil end
  local ok, term = pcall(require, "image.utils.term")
  if not ok or not term.get_size then return nil end
  local sz = term.get_size()
  if not sz or not sz.cell_width or sz.cell_width == 0 then return nil end
  local cols = vim.api.nvim_win_get_width(state.win)
  local rows = vim.api.nvim_win_get_height(state.win)
  -- nvim_win_get_height ignores the winbar, which still consumes one content
  -- row; subtract it plus a safety margin so the image fits below the winbar.
  if vim.wo[state.win].winbar ~= "" then rows = rows - 1 end
  rows = rows - (M.height_margin_rows or 0)
  if rows < 1 then rows = 1 end
  return math.floor(cols * sz.cell_width), math.floor(rows * sz.cell_height)
end

return M
