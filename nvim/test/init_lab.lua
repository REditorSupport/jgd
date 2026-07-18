-- Isolated Neovim config for testing the jgd image viewer (Layer D).
-- Launched via nvim/test/lab.sh, which points all XDG dirs into
-- nvim/test/xdg/ so this NEVER touches your real ~/.config/nvim or
-- ~/.local/share/nvim. Revert = delete nvim/test/xdg/.
--
-- Requires: Ghostty/Kitty terminal, ImageMagick CLI, R + jgd package.

local repo_nvim = vim.env.JGD_REPO_NVIM
if not repo_nvim or repo_nvim == "" then
  error("JGD_REPO_NVIM not set (launch via nvim/test/lab.sh)")
end

-- Bootstrap lazy.nvim into the isolated data dir.
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  vim.fn.system({
    "git", "clone", "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git", "--branch=stable", lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

-- Make the jgd plugin (repo/nvim/lua/jgd) importable. lazy.nvim rebuilds
-- 'runtimepath' during setup and would drop a manual rtp:append, so we
-- prepend to package.path directly (lazy-proof) AND register jgd as a
-- local lazy plugin via dir= so it's managed on the runtimepath too.
package.path = table.concat({
  repo_nvim .. "/lua/?.lua",
  repo_nvim .. "/lua/?/init.lua",
  package.path,
}, ";")

require("lazy").setup({
  { "3rd/image.nvim", build = false },
  { dir = repo_nvim, name = "jgd.nvim" },
}, {
  root = vim.fn.stdpath("data") .. "/lazy",
})

-- Configure image.nvim + jgd once plugins are ready.
vim.api.nvim_create_autocmd("User", {
  pattern = "VeryLazy",
  callback = function()
    require("image").setup({
      backend = "kitty",
      processor = "magick_cli",
      max_width_window_percentage = 100,
      max_height_window_percentage = 100,
    })
    local sock = require("jgd").setup({})
    vim.notify("jgd server listening: " .. sock)

    -- :JgdLab — open R in a terminal split, wired to the jgd socket.
    -- We auto-activate the device via a temp R_PROFILE_USER: without an
    -- explicit jgd::jgd() call, R would use its default device (quartz on
    -- macOS) and plots would open there instead of streaming to us.
    vim.api.nvim_create_user_command("JgdLab", function()
      local rprofile = vim.fn.stdpath("cache") .. "/jgd-lab-rprofile.R"
      local f = assert(io.open(rprofile, "w"))
      f:write([[local({
  suppressMessages(library(jgd))
  jgd()
  cat("\n[jgd] device active - try: plot(cars)\n")
})
]])
      f:close()
      vim.cmd("botright split")
      vim.cmd("resize 16")
      vim.fn.jobstart({ "R", "--quiet", "--no-save" }, {
        term = true,
        env = { JGD_SOCKET = sock, R_PROFILE_USER = rprofile },
      })
      vim.cmd("startinsert")
    end, {})

    vim.notify("Run :JgdLab to open R, then try plot(cars)")
  end,
})
