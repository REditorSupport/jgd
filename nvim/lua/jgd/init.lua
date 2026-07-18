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

--- Save the current plot to disk, matching the VS Code jgd extension's
--- export behavior: the plot is scaled to FIT within a `w_in x h_in @ dpi`
--- box (default 7x7in @ 150dpi), preserving its current aspect. Format is
--- inferred from the path extension (".svg" vector, else ".png" raster).
function M.save(path, dims)
  local plot = current_plot()
  if not plot then
    vim.notify("jgd: no plot to save", vim.log.levels.WARN)
    return
  end
  path = vim.fn.expand(path)
  dims = dims or {}
  local ex = M._state.export or {}
  local w_in = dims.w_in or ex.width or 7
  local h_in = dims.h_in or ex.height or 7
  local dpi = dims.dpi or ex.dpi or 150

  local dev = plot.device or {}
  local plotW = (dev.width and dev.width > 0) and dev.width or 768
  local plotH = (dev.height and dev.height > 0) and dev.height or 576
  -- Fit into the box preserving aspect (matches VS Code's scale = min(...)).
  local scale = math.min((w_in * dpi) / plotW, (h_in * dpi) / plotH)
  local outW = math.floor(plotW * scale + 0.5)
  local outH = math.floor(plotH * scale + 0.5)

  local svg_str = svg.ops_to_svg(plot, M._state.font_scale, outW, outH)
  local ext = (path:match("%.([%aA-Z]+)$") or "png"):lower()

  if ext == "svg" then
    local f, err = io.open(path, "w")
    if not f then
      vim.notify("jgd: cannot write " .. path .. ": " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    f:write(svg_str)
    f:close()
    vim.notify(string.format("jgd: saved %s (%dx%d)", path, outW, outH))
    return
  end

  -- PNG: the SVG carries width/height=outWxoutH, so rsvg renders at that size.
  vim.system({ "rsvg-convert", "-f", "png", "-o", path }, { stdin = svg_str }, function(res)
    vim.schedule(function()
      if res.code == 0 then
        vim.notify(string.format("jgd: saved %s (%dx%d)", path, outW, outH))
      else
        vim.notify("jgd: save failed: " .. tostring(res.stderr), vim.log.levels.ERROR)
      end
    end)
  end)
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
  M._state.export = {
    width = opts.export_width or 7,   -- inches (VS Code: plot.jgd.exportWidth)
    height = opts.export_height or 7, -- inches (VS Code: plot.jgd.exportHeight)
    dpi = opts.export_dpi or 150,     -- (VS Code: plot.jgd.exportDpi)
  }

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
  vim.api.nvim_create_user_command("JgdSave", function(o)
    local ex = M._state.export
    local default_spec = string.format("%s x %s @ %s", ex.width, ex.height, ex.dpi)

    -- "7 x 7 @ 150" -> { w_in, h_in, dpi }; nil if unparseable.
    local function parse_dims(s)
      local w, h, dpi = s:match("^%s*([%d.]+)%s*[xX,]%s*([%d.]+)%s*@?%s*(%d*)%s*$")
      if not w then return nil end
      return { w_in = tonumber(w), h_in = tonumber(h), dpi = tonumber(dpi) or ex.dpi }
    end
    local function valid(d)
      if not d then return "enter as \"7 x 7 @ 150\"" end
      if d.w_in < 0.5 or d.h_in < 0.5 or d.w_in > 50 or d.h_in > 50 then
        return "dimensions must be 0.5-50 inches"
      end
      if d.dpi < 36 or d.dpi > 600 then return "DPI must be 36-600" end
      return nil
    end

    local path_arg = o.fargs[1]
    if path_arg and path_arg ~= "" then
      local spec = (#o.fargs > 1) and table.concat(o.fargs, " ", 2) or default_spec
      local dims = parse_dims(spec)
      local err = valid(dims)
      if err then vim.notify("jgd: " .. err, vim.log.levels.WARN); return end
      M.save(path_arg, dims)
      return
    end

    -- Interactive: size prompt (VS Code default 7 x 7 @ 150), then path.
    vim.ui.input({ prompt = "Export size (W x H inches @ DPI): ", default = default_spec },
      function(spec)
        if not spec then return end
        local dims = parse_dims(spec)
        local err = valid(dims)
        if err then vim.notify("jgd: " .. err, vim.log.levels.WARN); return end
        vim.ui.input({ prompt = "Save plot to: ",
          default = vim.fn.getcwd() .. "/plot.png", completion = "file" },
          function(p)
            if p and p ~= "" then M.save(p, dims) end
          end)
      end)
  end, { nargs = "*", complete = "file",
    desc = "Save current jgd plot (VS Code-style: W x H inches @ DPI; .svg or .png)" })

  return sock
end

return M
