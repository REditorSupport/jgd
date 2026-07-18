-- jgd.server — libuv socket server. R connects outward to us; we speak the
-- server side of the jgd protocol. Unix-domain socket for now (macOS/Linux);
-- TCP fallback is a TODO.

local uv = vim.uv or vim.loop
local dispatch = require("jgd.dispatch")

local M = {}

local function new_conn(client)
  return { client = client, buf = "", welcomed = false }
end

--- Start listening on a unix socket path.
--- opts: { socket=<path>, on_frame, on_metrics, on_close }
function M.start(opts)
  opts = opts or {}
  local path = assert(opts.socket, "jgd.server: opts.socket (path) required")

  if uv.fs_stat(path) then uv.fs_unlink(path) end -- clear stale socket

  local server = uv.new_pipe(false)
  local ok, err = pcall(function() server:bind(path) end)
  if not ok then error("jgd.server: bind failed on " .. path .. ": " .. tostring(err)) end

  local ctx = {
    transport = "unix",
    font_scale = opts.font_scale or 1,
    send = function(conn, tbl)
      conn.client:write(vim.json.encode(tbl) .. "\n")
    end,
    on_frame = opts.on_frame,
    on_metrics = opts.on_metrics,
    on_close = opts.on_close,
  }

  server:listen(128, function(lerr)
    if lerr then return end
    local client = uv.new_pipe(false)
    server:accept(client)
    local conn = new_conn(client)
    client:read_start(function(rerr, chunk)
      if rerr then client:close(); return end
      if not chunk then -- EOF: R disconnected
        if ctx.on_close then ctx.on_close(conn) end
        client:close()
        return
      end
      conn.buf = conn.buf .. chunk
      while true do
        local nl = conn.buf:find("\n", 1, true)
        if not nl then break end
        local ln = conn.buf:sub(1, nl - 1)
        conn.buf = conn.buf:sub(nl + 1)
        if #ln > 0 then dispatch.handle(conn, ln, ctx) end
      end
    end)
  end)

  return { server = server, path = path, ctx = ctx }
end

function M.stop(handle)
  if not handle then return end
  if handle.server and not handle.server:is_closing() then handle.server:close() end
  if handle.path and uv.fs_stat(handle.path) then uv.fs_unlink(handle.path) end
end

return M
