-- jgd.plot — per-session op accumulation and plot history.
--
-- Frame semantics (see r-pkg/R/spec.R):
--   incremental=true  -> APPEND ops to the current plot (delta).
--   resizeReplay=true -> REPLACE the target plot's ops (full redraw).
--   newPage=true      -> a fresh plot (push to history).
--   otherwise (full, not newPage) -> replace the latest plot in place.

local M = {}

function M.new_session()
  return { history = {}, current = nil }
end

function M.on_frame(sess, msg)
  local plot = msg.plot or {}
  local ops = plot.ops or {}

  if msg.incremental == true and sess.current then
    for _, o in ipairs(ops) do
      sess.current.ops[#sess.current.ops + 1] = o
    end
    if plot.device then sess.current.device = plot.device end
  elseif msg.resizeReplay == true and sess.current then
    sess.current.ops = ops
    if plot.device then sess.current.device = plot.device end
  else
    local p = { ops = ops, device = plot.device, plotNumber = msg.plotNumber }
    sess.current = p
    if msg.newPage == true or #sess.history == 0 then
      sess.history[#sess.history + 1] = p
    else
      sess.history[#sess.history] = p
    end
  end

  return sess.current
end

return M
