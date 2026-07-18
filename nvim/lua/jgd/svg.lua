-- jgd.svg — translate a jgd plot (device + ops) into an SVG string.
--
-- Coordinates are device pixels, top-left origin — identical to SVG's
-- default user space, so no transform is needed. Colors arrive as
-- "rgba(r,g,b,a)" strings (or JSON null); we split them into an SVG color
-- plus an opacity attribute for maximum rasterizer compatibility.

local M = {}
local NIL = vim.NIL
local function present(v) return v ~= nil and v ~= NIL end
local function num(v) return present(v) and v or 0 end

local function xml_escape(s)
  return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- "rgba(r,g,b,a)" -> ("rgb(r,g,b)", alpha) ; nil if absent/transparent.
local function parse_color(v)
  if not present(v) or type(v) ~= "string" then return nil end
  local r, g, b, a = v:match("rgba%(%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*,%s*([%d%.]+)%s*%)")
  if r then return string.format("rgb(%s,%s,%s)", r, g, b), tonumber(a) end
  return v, 1 -- pass through any other CSS color form
end

local function map_family(fam)
  if not present(fam) or fam == "" or fam == "sans" then return "sans-serif" end
  if fam == "serif" or fam == "Times" then return "serif" end
  if fam == "mono" or fam == "Courier" then return "monospace" end
  return fam
end

local function stroke_attrs(gc, out)
  local col, op = parse_color(gc and gc.col)
  if col then
    out[#out + 1] = string.format('stroke="%s"', col)
    if op and op < 1 then out[#out + 1] = string.format('stroke-opacity="%s"', op) end
    out[#out + 1] = string.format('stroke-width="%s"', present(gc.lwd) and gc.lwd or 1)
    local lty = gc.lty
    if present(lty) and type(lty) == "table" and #lty > 0 then
      out[#out + 1] = string.format('stroke-dasharray="%s"', table.concat(lty, ","))
    end
    if present(gc.lend) then out[#out + 1] = string.format('stroke-linecap="%s"', gc.lend) end
    if present(gc.ljoin) then out[#out + 1] = string.format('stroke-linejoin="%s"', gc.ljoin) end
    if present(gc.lmitre) then out[#out + 1] = string.format('stroke-miterlimit="%s"', gc.lmitre) end
  else
    out[#out + 1] = 'stroke="none"'
  end
end

local function fill_attrs(gc, out)
  local col, op = parse_color(gc and gc.fill)
  if col then
    out[#out + 1] = string.format('fill="%s"', col)
    if op and op < 1 then out[#out + 1] = string.format('fill-opacity="%s"', op) end
  else
    out[#out + 1] = 'fill="none"'
  end
end

local function shape_attrs(gc) -- fill + stroke (polygon, rect, circle, path)
  local out = {}
  fill_attrs(gc, out)
  stroke_attrs(gc, out)
  return table.concat(out, " ")
end

local function stroke_only(gc) -- line, polyline
  local out = { 'fill="none"' }
  stroke_attrs(gc, out)
  return table.concat(out, " ")
end

local function points(x, y)
  local t = {}
  for i = 1, #x do t[#t + 1] = string.format("%s,%s", x[i], y[i]) end
  return table.concat(t, " ")
end

local function text_el(op, fscale)
  local gc = op.gc or {}
  local font = gc.font or {}
  local size = (present(font.size) and font.size or 12) * (fscale or 1)
  local face = present(font.face) and font.face or 1
  local fam = map_family(font.family)
  local weight = (face == 2 or face == 4) and "bold" or "normal"
  local style = (face == 3 or face == 4) and "italic" or "normal"
  local hadj = present(op.hadj) and op.hadj or 0
  local anchor = (hadj == 0) and "start" or ((hadj >= 1) and "end" or "middle")
  local fillcol, fillop = parse_color(gc.col)
  fillcol = fillcol or "black"
  local opac = (fillop and fillop < 1) and string.format(' fill-opacity="%s"', fillop) or ""
  local rot = present(op.rot) and op.rot or 0
  -- R rot is CCW degrees; SVG rotate() is CW-positive in y-down space -> negate.
  local transform = (rot ~= 0) and string.format(' transform="rotate(%s %s %s)"', -rot, op.x, op.y) or ""
  return string.format(
    '<text x="%s" y="%s" font-family="%s" font-size="%s" font-weight="%s" '
      .. 'font-style="%s" text-anchor="%s" fill="%s"%s%s>%s</text>',
    op.x, op.y, fam, size, weight, style, anchor, fillcol, opac, transform,
    xml_escape(op.str or ""))
end

local function path_el(op)
  local d = {}
  for _, sub in ipairs(op.subpaths or {}) do
    for i, pt in ipairs(sub) do
      d[#d + 1] = (i == 1 and "M" or "L") .. pt[1] .. " " .. pt[2]
    end
    d[#d + 1] = "Z"
  end
  local rule = (op.winding == "evenodd") and "evenodd" or "nonzero"
  return string.format('<path d="%s" fill-rule="%s" %s/>', table.concat(d, " "), rule, shape_attrs(op.gc))
end

local function raster_el(op)
  local rw, rh = math.abs(op.w), math.abs(op.h)
  -- op.x/op.y is the bottom-left corner; SVG <image> anchors top-left.
  return string.format(
    '<image x="%s" y="%s" width="%s" height="%s" preserveAspectRatio="none" xlink:href="%s"/>',
    op.x, op.y - rh, rw, rh, op.data)
end

--- Render a plot (`{ops=..., device=...}`) to an SVG string.
--- font_scale multiplies text size (on top of the dpi/72 device scaling).
--- out_w/out_h set the <svg> width/height (viewBox stays at device size, so
--- the content scales aspect-correctly); default to the device size.
function M.ops_to_svg(plot, font_scale, out_w, out_h)
  local dev = plot.device or {}
  local w = (num(dev.width) ~= 0) and dev.width or 768
  local h = (num(dev.height) ~= 0) and dev.height or 576
  -- Text font size is in points; scale to device pixels by dpi/72 to match
  -- the device's cra convention (matches the metrics responder), times an
  -- optional user font_scale.
  local fscale = (((dev.dpi and dev.dpi > 0) and dev.dpi or 96) / 72) * (font_scale or 1)
  local body, defs = {}, {}
  local clip_open, clip_id = false, 0

  local bg = parse_color(dev.bg)
  if bg then
    body[#body + 1] = string.format('<rect x="0" y="0" width="%s" height="%s" fill="%s"/>', w, h, bg)
  end

  for _, op in ipairs(plot.ops or {}) do
    local o = op.op
    if o == "clip" then
      if clip_open then body[#body + 1] = "</g>"; clip_open = false end
      clip_id = clip_id + 1
      local id = "clip" .. clip_id
      -- R may send corners in either order; SVG needs a top-left origin
      -- with non-negative width/height.
      defs[#defs + 1] = string.format(
        '<clipPath id="%s"><rect x="%s" y="%s" width="%s" height="%s"/></clipPath>',
        id, math.min(op.x0, op.x1), math.min(op.y0, op.y1),
        math.abs(op.x1 - op.x0), math.abs(op.y1 - op.y0))
      body[#body + 1] = string.format('<g clip-path="url(#%s)">', id)
      clip_open = true
    elseif o == "line" then
      body[#body + 1] = string.format('<line x1="%s" y1="%s" x2="%s" y2="%s" %s/>',
        op.x1, op.y1, op.x2, op.y2, stroke_only(op.gc))
    elseif o == "polyline" then
      body[#body + 1] = string.format('<polyline points="%s" %s/>', points(op.x, op.y), stroke_only(op.gc))
    elseif o == "polygon" then
      body[#body + 1] = string.format('<polygon points="%s" %s/>', points(op.x, op.y), shape_attrs(op.gc))
    elseif o == "rect" then
      body[#body + 1] = string.format('<rect x="%s" y="%s" width="%s" height="%s" %s/>',
        math.min(op.x0, op.x1), math.min(op.y0, op.y1),
        math.abs(op.x1 - op.x0), math.abs(op.y1 - op.y0), shape_attrs(op.gc))
    elseif o == "circle" then
      body[#body + 1] = string.format('<circle cx="%s" cy="%s" r="%s" %s/>', op.x, op.y, op.r, shape_attrs(op.gc))
    elseif o == "text" then
      body[#body + 1] = text_el(op, fscale)
    elseif o == "path" then
      body[#body + 1] = path_el(op)
    elseif o == "raster" then
      body[#body + 1] = raster_el(op)
    elseif o == "beginGroup" then
      body[#body + 1] = "<g>" -- ext effects (filter/opacity/blend) deferred
    elseif o == "endGroup" then
      body[#body + 1] = "</g>"
    end
  end
  if clip_open then body[#body + 1] = "</g>" end

  local ow = out_w or w
  local oh = out_h or h
  return string.format(
    '<?xml version="1.0" encoding="UTF-8"?>\n'
      .. '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
      .. 'width="%s" height="%s" viewBox="0 0 %s %s"><defs>%s</defs>%s</svg>',
    ow, oh, w, h, table.concat(defs), table.concat(body))
end

return M
