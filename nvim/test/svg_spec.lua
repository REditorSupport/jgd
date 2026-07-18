-- Layer A: pure-Lua unit checks for svg + metrics. No R, no display, no
-- external tools. Run from the repo root:
--   nvim --headless -l nvim/test/svg_spec.lua
-- Exits 0 on success, 1 on any failure (CI-friendly).

vim.opt.runtimepath:append(vim.fn.getcwd() .. "/nvim")

local svg = require("jgd.svg")
local metrics = require("jgd.metrics")

local fails = 0
local function check(name, cond)
  if cond then
    print("ok   - " .. name)
  else
    fails = fails + 1
    print("FAIL - " .. name)
  end
end

local plot = {
  device = { width = 200, height = 100, bg = "rgba(255,255,255,1)" },
  ops = {
    { op = "clip", x0 = 0, y0 = 0, x1 = 200, y1 = 100 },
    { op = "line", x1 = 0, y1 = 0, x2 = 200, y2 = 100,
      gc = { col = "rgba(255,0,0,1)", lwd = 2, lty = {} } },
    { op = "circle", x = 100, y = 50, r = 10,
      gc = { col = "rgba(0,0,0,1)", fill = "rgba(0,0,255,0.5)" } },
    { op = "text", x = 100, y = 50, str = "A<&>B", rot = 90, hadj = 0.5,
      gc = { col = "rgba(0,0,0,1)", font = { family = "sans", face = 2, size = 12 } } },
  },
}

local out = svg.ops_to_svg(plot)
check("svg root element", out:find("<svg", 1, true) ~= nil)
check("viewBox set", out:find('viewBox="0 0 200 100"', 1, true) ~= nil)
check("background rect", out:find('fill="rgb(255,255,255)"', 1, true) ~= nil)
check("line stroke color", out:find('stroke="rgb(255,0,0)"', 1, true) ~= nil)
check("line stroke width", out:find('stroke-width="2"', 1, true) ~= nil)
check("clip group emitted", out:find("clip-path=", 1, true) ~= nil)
check("circle fill-opacity", out:find('fill-opacity="0.5"', 1, true) ~= nil)
check("text anchor middle", out:find('text-anchor="middle"', 1, true) ~= nil)
check("text rotation negated", out:find("rotate(-90", 1, true) ~= nil)
check("xml escaping", out:find("A&lt;&amp;&gt;B", 1, true) ~= nil)
check("bold weight", out:find('font-weight="bold"', 1, true) ~= nil)

local sw = metrics.response({ kind = "strWidth", id = 1, str = "Hello",
  gc = { font = { size = 12, face = 1, family = "sans" } } })
check("strWidth positive", sw.width > 0)
check("strWidth id echoed", sw.id == 1)
check("strWidth type", sw.type == "metrics_response")

local mi = metrics.response({ kind = "metricInfo", id = 2, c = 77,
  gc = { font = { size = 12 } } })
check("metricInfo ascent > 0", mi.ascent > 0)
check("metricInfo descent > 0", mi.descent > 0)

if fails == 0 then
  print("\nALL PASS (" .. "svg_spec)")
  vim.cmd("qa!")
else
  print("\n" .. fails .. " FAILURE(S)")
  vim.cmd("cq 1")
end
