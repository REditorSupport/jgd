-- jgd.dispatch — decode one NDJSON line and route it.
--
-- Handshake is deferred: the server_info welcome is sent on the FIRST
-- message from R (any type), per spec (avoids a Windows named-pipe race).

local metrics = require("jgd.metrics")

local M = {}

function M.handle(conn, line, ctx)
  local ok, msg = pcall(vim.json.decode, line)
  if not ok or type(msg) ~= "table" then return end

  if not conn.welcomed then
    conn.welcomed = true
    ctx.send(conn, {
      type = "server_info",
      serverName = "jgd.nvim",
      protocolVersion = 1,
      transport = ctx.transport,
    })
  end

  local t = msg.type
  if t == "metrics_request" then
    ctx.send(conn, metrics.response(msg, ctx.dpi or 96, ctx.font_scale or 1))
    if ctx.on_metrics then ctx.on_metrics(conn, msg) end
  elseif t == "frame" then
    local dev = msg.plot and msg.plot.device
    if dev and dev.dpi then ctx.dpi = dev.dpi end -- remember for metrics scaling
    if ctx.on_frame then ctx.on_frame(conn, msg) end
  elseif t == "close" then
    if ctx.on_close then ctx.on_close(conn) end
  end
  -- "ping" needs no action beyond the welcome above; unknown types ignored.
end

return M
