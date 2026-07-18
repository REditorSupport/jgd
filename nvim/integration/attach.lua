-- Runtime attach: test jgd in your REAL R.nvim setup without editing your
-- config. Source it from a running Neovim:
--
--     :luafile /Users/gmcd/Documents/Projects/jgd/nvim/integration/attach.lua
--
-- Then, in your R console (send via R.nvim), run ONCE:
--
--     jgd::jgd()
--
-- After that, send plot lines normally (e.g. plot(cars)) and they render
-- in a right-hand split. Undo everything by restarting Neovim — nothing
-- persistent is written to your config. (A discovery.json is written to
-- your jgd cache dir and removed on exit.)

local this = debug.getinfo(1, "S").source:sub(2)      -- .../nvim/integration/attach.lua
local nvim_dir = vim.fn.fnamemodify(this, ":h:h")      -- .../nvim

-- Make the jgd plugin importable regardless of your plugin manager's rtp.
package.path = table.concat({
  nvim_dir .. "/lua/?.lua",
  nvim_dir .. "/lua/?/init.lua",
  package.path,
}, ";")
vim.opt.rtp:append(nvim_dir)

-- Ensure image.nvim is available. If your config doesn't provide it, reuse
-- the copy the lab installed (nvim/test/xdg/.../image.nvim).
if not pcall(require, "image") then
  local lab_image = nvim_dir .. "/test/xdg/data/nvim/lazy/image.nvim"
  if (vim.uv or vim.loop).fs_stat(lab_image) then
    vim.opt.rtp:append(lab_image)
  end
end

local has_image, image = pcall(require, "image")
if has_image then
  pcall(function()
    image.setup({
      backend = "kitty",
      processor = "magick_cli",
      -- default caps images to 50% of window height; let plots fill the split
      max_width_window_percentage = 100,
      max_height_window_percentage = 100,
    })
  end)
else
  vim.notify("jgd: image.nvim not found; the viewer needs it. See nvim/README.md",
    vim.log.levels.WARN)
end

-- Bump text size beyond the "correct" dpi/72 sizing to taste (1.0 = exact).
local FONT_SCALE = 1.25

local sock = require("jgd").setup({ font_scale = FONT_SCALE })
vim.notify(table.concat({
  "jgd attached (server: " .. sock .. ").",
  "In your R console run once:  jgd::jgd()",
  "Then send plot lines (e.g. plot(cars)).",
}, "\n"))
