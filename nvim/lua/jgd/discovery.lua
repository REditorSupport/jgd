-- jgd.discovery — write/remove the platform discovery file so R's jgd()
-- can auto-connect without JGD_SOCKET. Written atomically (temp + rename).

local uv = vim.uv or vim.loop
local M = {}

function M.cache_dir()
  if vim.fn.has("mac") == 1 then
    return vim.fn.expand("~/Library/Caches/jgd")
  elseif vim.fn.has("win32") == 1 then
    return (vim.env.LOCALAPPDATA or vim.fn.expand("~")) .. "/jgd"
  else
    local xdg = vim.env.XDG_CACHE_HOME
    if xdg and #xdg > 0 then return xdg .. "/jgd" end
    return vim.fn.expand("~/.cache/jgd")
  end
end

function M.path()
  return M.cache_dir() .. "/discovery.json"
end

--- Write discovery.json pointing at socket_uri (e.g. "unix:///abs/path").
function M.write(socket_uri, extra)
  local dir = M.cache_dir()
  vim.fn.mkdir(dir, "p")
  local path = M.path()
  local data = {
    serverName = "jgd.nvim",
    socketPath = socket_uri,
    pid = uv.os_getpid(),
    serverInfo = extra or {},
  }
  local tmp = path .. ".tmp" .. tostring(uv.os_getpid())
  local f = assert(io.open(tmp, "w"))
  f:write(vim.json.encode(data))
  f:close()
  os.rename(tmp, path)
  return path
end

--- Remove discovery.json, but only if we still own it (PID check).
function M.remove()
  local path = M.path()
  if not uv.fs_stat(path) then return end
  local f = io.open(path, "r")
  if not f then return end
  local content = f:read("*a")
  f:close()
  local ok, d = pcall(vim.json.decode, content or "")
  if ok and type(d) == "table" and d.pid == uv.os_getpid() then
    os.remove(path)
  end
end

return M
