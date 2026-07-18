-- jgd.metrics — font-metrics responder.
--
-- R's device blocks up to 500ms per uncached string waiting for a
-- metrics_response, and DISCARDS any reply with width <= 0 (falling back
-- to its own C approximation). So we must reply promptly with POSITIVE
-- values. We mirror R's built-in ratios (src/metrics.c) and the browser
-- renderer's convention of treating font size (points, = cex*ps) directly
-- as pixels (no dpi/72 conversion) so results match the Deno/browser oracle
-- and our own SVG output (which sets font-size to the same value).

local M = {}

local function avg_char_width(family, face)
  family = family or ""
  local f = family:sub(1, 1)
  if f == "m" or f == "M" or family == "Courier" or family == "mono" then
    return 0.6
  end
  if family == "serif" or family == "Times" then
    if face == 2 or face == 4 then return 0.52 end
    return 0.48
  end
  if face == 2 or face == 4 then return 0.56 end
  return 0.53
end

-- Count UTF-8 code points (lead bytes), matching the C implementation.
local function utf8_len(s)
  local n = 0
  for i = 1, #s do
    local b = s:byte(i)
    if b < 0x80 or b >= 0xC0 then n = n + 1 end
  end
  return n
end

--- Build a metrics_response table for a metrics_request message.
--- `dpi` (default 96) scales points->device pixels to match the device's
--- cra convention (cra = ratio * ps * dpi/72, ipr = 1/dpi). Without this,
--- text is ~dpi/72 too small and R lays it out with too-tight advances.
function M.response(req, dpi, font_scale)
  local gc = req.gc or {}
  local font = gc.font or {}
  local size = (font.size or 12) * ((dpi or 96) / 72) * (font_scale or 1)
  local face = font.face or 1
  local family = font.family
  local cw = avg_char_width(family, face)

  local width, ascent, descent = 0, 0, 0
  if req.kind == "strWidth" then
    width = utf8_len(req.str or "") * cw * size
  elseif req.kind == "metricInfo" then
    local c = req.c or 0
    width = (c == 32) and (0.25 * size) or (cw * size)
    ascent = 0.75 * size
    descent = 0.25 * size
  end

  return {
    type = "metrics_response",
    id = req.id,
    width = width,
    ascent = ascent,
    descent = descent,
  }
end

return M
