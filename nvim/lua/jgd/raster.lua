-- jgd.raster — rasterize an SVG string to a PNG file via rsvg-convert.
-- Async; calls cb(ok, err, code) when done. resvg support can be added
-- later behind the same interface.

local M = {}

M.cmd = { "rsvg-convert", "-f", "png" }

function M.render(svg_str, out_path, cb)
  local args = vim.deepcopy(M.cmd)
  args[#args + 1] = "-o"
  args[#args + 1] = out_path
  local ok, err = pcall(function()
    vim.system(args, { stdin = svg_str }, function(res)
      vim.schedule(function() cb(res.code == 0, res.stderr, res.code) end)
    end)
  end)
  if not ok then
    vim.schedule(function() cb(false, tostring(err), -1) end)
  end
end

return M
