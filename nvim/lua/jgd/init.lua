-- jgd — top-level module.
--
-- Two entry points:
--   * M.start_server{...}  — headless/protocol use (Layers A/B/C tests).
--   * M.setup{...}         — full in-editor viewer (Layer D): server +
--                            discovery + render pipeline + image.nvim view.

local server = require("jgd.server")
local plotmod = require("jgd.plot")

local M = {}

--- Start a jgd server with per-connection session accumulation.
--- opts: { socket=<path>, on_frame(conn,msg,session), on_metrics, on_close }
function M.start_server(opts)
  opts = opts or {}
  local sessions = {}
  local handle
  handle = server.start({
    socket = opts.socket,
    font_scale = opts.font_scale,
    on_metrics = opts.on_metrics,
    on_frame = function(conn, msg)
      local s = sessions[conn]
      if not s then s = plotmod.new_session(); sessions[conn] = s end
      plotmod.on_frame(s, msg)
      if opts.on_frame then opts.on_frame(conn, msg, s) end
    end,
    on_close = function(conn)
      if opts.on_close then opts.on_close(conn, sessions[conn]) end
      sessions[conn] = nil
    end,
  })
  handle.sessions = sessions
  return handle
end

M.stop = server.stop

-- ---- Full in-editor viewer (Layer D) ----

local view = require("jgd.view")
local svg = require("jgd.svg")
local raster = require("jgd.raster")

M._state = {
  handle = nil, socket = nil, png = nil, pending = false,
  session = nil, -- last session that produced a frame
  index = nil,   -- 1-based position in that session's history
}

-- The plot currently selected for display, plus its position (i of n).
local function current_plot()
  local s = M._state.session
  if not s or #s.history == 0 then return nil end
  local i = math.min(M._state.index or #s.history, #s.history)
  return s.history[i], i, #s.history
end

local function render_current()
  local plot, i, n = current_plot()
  if not plot then return end
  local svg_str = svg.ops_to_svg(plot, M._state.font_scale)
  raster.render(svg_str, M._state.png, function(ok, err)
    if ok then
      view.show(M._state.png, { label = string.format(" jgd  [%d/%d] ", i, n) })
    else
      vim.notify("jgd: rasterize failed: " .. tostring(err), vim.log.levels.WARN)
    end
  end)
end

-- ---- History navigation ----

function M.next_plot()
  local s = M._state.session
  if not s then return end
  M._state.index = math.min((M._state.index or #s.history) + 1, #s.history)
  render_current()
end

function M.prev_plot()
  local s = M._state.session
  if not s then return end
  M._state.index = math.max((M._state.index or #s.history) - 1, 1)
  render_current()
end

function M.delete_plot()
  local s = M._state.session
  if not s or #s.history == 0 then return end
  local i = math.min(M._state.index or #s.history, #s.history)
  table.remove(s.history, i)
  if #s.history == 0 then
    s.current = nil
    view.clear()
    return
  end
  M._state.index = math.min(i, #s.history)
  render_current()
end

--- Send a message up to the connected R session (best-effort).
local function send_to_r(tbl)
  local c = M._state.conn
  local h = M._state.handle
  if c and h and h.ctx and h.ctx.send then pcall(h.ctx.send, c, tbl) end
end

-- Ask R to replay the current plot at the viewer window's pixel size, so it
-- re-lays-out crisply (rather than us just scaling the raster). Only applies
-- to the latest plot; historical plots scale locally via view.refresh().
local function maybe_resize()
  if not view.is_open() then return end
  local s = M._state.session
  if not s or #s.history == 0 then return end
  if M._state.index and M._state.index ~= #s.history then return end -- viewing history
  local w, h = view.pixel_size()
  if not w or w < 10 or h < 10 then return end
  local plot = current_plot()
  if plot and plot.device
      and math.abs((plot.device.width or 0) - w) <= 2
      and math.abs((plot.device.height or 0) - h) <= 2 then
    return -- already at target size; avoids resize/replay oscillation
  end
  send_to_r({ type = "resize", width = w, height = h })
end

local resize_pending = false
local function schedule_resize()
  if resize_pending then return end
  resize_pending = true
  vim.defer_fn(function() resize_pending = false; maybe_resize() end, 150)
end

--- Start the server, advertise it via discovery.json, and render every
--- incoming frame into the image.nvim viewer.
--- opts: { socket=<path> }  (defaults to a path under stdpath("cache"))
function M.setup(opts)
  opts = opts or {}
  local discovery = require("jgd.discovery")

  local cache = vim.fn.stdpath("cache")
  vim.fn.mkdir(cache, "p")
  local sock = opts.socket or (cache .. "/jgd-nvim.sock")
  M._state.socket = sock
  M._state.png = cache .. "/jgd-current.png"
  M._state.font_scale = opts.font_scale or 1

  M._state.handle = M.start_server({
    socket = sock,
    font_scale = M._state.font_scale,
    on_frame = function(conn, _, session)
      M._state.conn = conn
      M._state.session = session
      M._state.index = #session.history -- jump to latest on new activity
      -- Coalesce bursts of (incremental) frames into one render.
      if M._state.pending then return end
      M._state.pending = true
      vim.defer_fn(function()
        M._state.pending = false
        render_current()
        schedule_resize() -- fit the plot to the window on first display
      end, 30)
    end,
    on_close = function() M._state.conn = nil end,
  })

  discovery.write("unix://" .. sock)

  -- On window resize: scale immediately for feedback, then ask R to replay
  -- crisply at the new size (debounced).
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    callback = function()
      pcall(view.refresh)
      schedule_resize()
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      pcall(discovery.remove)
      pcall(M.stop, M._state.handle)
    end,
  })

  -- Convenience user commands.
  vim.api.nvim_create_user_command("JgdClose", function() view.close() end, {})
  vim.api.nvim_create_user_command("JgdRefresh", function() view.refresh() end, {})
  vim.api.nvim_create_user_command("JgdNext", M.next_plot, {})
  vim.api.nvim_create_user_command("JgdPrev", M.prev_plot, {})
  vim.api.nvim_create_user_command("JgdDelete", M.delete_plot, {})

  return sock
end

return M
