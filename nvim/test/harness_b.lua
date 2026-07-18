-- Layer B: end-to-end headless smoke test (no display).
--   R plot(cars)  ->  jgd.nvim server  ->  accumulate  ->  SVG  ->  PNG
-- Requires: R with the `jgd` package, and `rsvg-convert` on PATH.
-- Run from the repo root:
--   nvim --headless -l nvim/test/harness_b.lua
-- Exits 0 and prints the SVG/PNG paths on success; exits 1 on failure.

local uv = vim.uv or vim.loop
vim.opt.runtimepath:append(vim.fn.getcwd() .. "/nvim")

local jgd = require("jgd")
local svg = require("jgd.svg")
local raster = require("jgd.raster")

local sock = string.format("/tmp/jgd-nvim-%d.sock", uv.os_getpid())
local out_png = string.format("/tmp/jgd-nvim-%d.png", uv.os_getpid())
local out_svg = out_png:gsub("%.png$", ".svg")

local stats = { frames = 0, metrics = 0 }
local last_session

local handle = jgd.start_server({
  socket = sock,
  on_metrics = function() stats.metrics = stats.metrics + 1 end,
  on_frame = function(_, _, s) stats.frames = stats.frames + 1; last_session = s end,
})
print("server listening: " .. sock)

local function fail(m)
  print("\nFAIL: " .. m)
  if stats.r_err and #stats.r_err > 0 then print("--- R stderr ---\n" .. stats.r_err) end
  jgd.stop(handle)
  vim.cmd("cq 1")
end

-- Drive R. JGD_SOCKET makes discovery deterministic (raw path is accepted).
local r_done = false
vim.system(
  { "R", "--quiet", "--no-save", "-e",
    "library(jgd); jgd(); plot(cars); Sys.sleep(0.8); invisible(dev.off())" },
  { env = { JGD_SOCKET = sock }, text = true },
  function(res)
    r_done = true
    stats.r_code = res.code
    stats.r_err = res.stderr
  end)

vim.wait(20000, function() return r_done end, 50)
vim.wait(600, function() return false end, 50) -- drain trailing socket reads

print(string.format("R exit=%s  frames=%d  metrics=%d",
  tostring(stats.r_code), stats.frames, stats.metrics))

if not last_session or not last_session.current then
  return fail("no frame/plot received from R")
end
if stats.metrics == 0 then
  print("WARN: no metrics_request seen (unexpected for plot(cars))")
end

local plot = last_session.current
print("ops in final plot: " .. #plot.ops)

local svg_str = svg.ops_to_svg(plot)
local sf = assert(io.open(out_svg, "w"))
sf:write(svg_str)
sf:close()

local done = false
raster.render(svg_str, out_png, function(ok, err)
  stats.raster_ok = ok
  stats.raster_err = err
  done = true
end)
vim.wait(10000, function() return done end, 50)

if not stats.raster_ok then
  return fail("rsvg-convert failed: " .. tostring(stats.raster_err))
end
local st = uv.fs_stat(out_png)
if not st or st.size == 0 then
  return fail("PNG missing or empty")
end

print("\nPASS")
print("  SVG: " .. out_svg)
print("  PNG: " .. out_png .. " (" .. st.size .. " bytes)")
jgd.stop(handle)
vim.cmd("qa!")
