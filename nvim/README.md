# jgd.nvim (work in progress)

A native Neovim frontend for [jgd](../). **Neovim is the jgd server**: it
listens on a socket, R connects outward, and frames are rendered to an
image shown in a split via [image.nvim](https://github.com/3rd/image.nvim)
(Kitty graphics protocol). See the design note in
[`../SCRATCH/nvim-client-plan.md`](../SCRATCH/nvim-client-plan.md).

## Layout

```
lua/jgd/
  server.lua     libuv socket server (R connects to us)
  dispatch.lua   NDJSON decode + deferred server_info handshake
  metrics.lua    font-metrics responder (positive heuristic; no stalls)
  plot.lua       op accumulation (incremental append) + history
  svg.lua        ops -> SVG
  raster.lua     SVG -> PNG (rsvg-convert)
  view.lua       display PNG in a split via image.nvim
  discovery.lua  discovery.json writer (so R auto-connects)
  init.lua       start_server{} (headless) and setup{} (full viewer)
test/
  svg_spec.lua   Layer A: pure-Lua unit checks (no deps)
  harness_b.lua  Layer B: real R -> server -> SVG -> PNG (needs R + rsvg-convert)
  init_lab.lua   isolated config for the in-editor viewer (Layer D)
  lab.sh         launcher that confines all state to test/xdg/
```

## Testing

Layers A and B are headless and need no display:

```bash
nvim --headless -l nvim/test/svg_spec.lua     # pure Lua
nvim --headless -l nvim/test/harness_b.lua    # real R -> PNG
```

**Layer D — in-editor viewer** (run from a Ghostty/Kitty terminal):

Requirements: ImageMagick CLI (`brew install imagemagick`), R + `jgd`.

```bash
./nvim/test/lab.sh          # isolated nvim; installs image.nvim on first run
# then inside nvim:
:JgdLab                     # opens R in a bottom split, wired to the socket
# in that R console:
plot(cars)                  # renders into a right-hand split
```

The lab is fully isolated: all state (lazy plugins, cache, socket, PNG)
lives under `nvim/test/xdg/` (gitignored). It never reads or writes your
real `~/.config/nvim` or `~/.local/share/nvim`.

**Revert everything:** `rm -rf nvim/test/xdg`

## Status

- [x] Server + handshake + metrics + discovery
- [x] ops -> SVG -> PNG pipeline (base graphics)
- [x] image.nvim viewer + `setup()` wiring
- [x] Incremental "layering" (abline/lines/points accumulate onto the plot)
- [x] Resize feedback loop (viewer window -> R replays at new pixel size)
- [x] Plot history navigation (`:JgdPrev`/`:JgdNext`/`:JgdDelete`, in-buffer keys)
- [ ] R.nvim `after_R_start` auto-start integration (Option 2)
- [ ] History resize via plotIndex (currently historical plots scale locally)
- [ ] Layer C oracle diff vs. the browser renderer

## Viewer keys (when the plot split is focused)

| key | action |
| --- | --- |
| `h` / `<Left>`  | previous plot |
| `l` / `<Right>` | next plot |
| `d` / `x`       | delete current plot |
| `w`             | save/export plot (prompts for path) |
| `q`             | close viewer |
| `r`             | refresh / re-fit |

## Saving plots

`:JgdSave` (or `w` in the viewer) exports the current plot, matching the
VS Code jgd extension's defaults and behavior:

- Prompts for **`W x H inches @ DPI`** (default **`7 x 7 @ 150`**), then a path
  (default `cwd/plot.png`). Format is inferred from the extension: `.svg`
  writes vector, anything else rasterizes to PNG via rsvg-convert.
- The plot is scaled to **fit** the `W x H @ DPI` box preserving its current
  aspect (e.g. a 768x576 plot at 7x7@150 exports as 1050x788).
- Scriptable: `:JgdSave path.png` (uses defaults) or
  `:JgdSave path.svg 5 x 4 @ 300`.

Defaults are configurable via `require("jgd").setup{ export_width=7,
export_height=7, export_dpi=150 }` (mirrors VS Code's
`plot.jgd.exportWidth`/`exportHeight`/`exportDpi`).
