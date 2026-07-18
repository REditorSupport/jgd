#!/usr/bin/env bash
# Launch an ISOLATED Neovim to test the jgd image viewer (Layer D).
#
# All state (lazy plugins, cache, the jgd socket + PNG) is confined to
# nvim/test/xdg/ inside this repo. Your real ~/.config/nvim and
# ~/.local/share/nvim are never read or written.
#
#   Revert everything:  rm -rf nvim/test/xdg
#
# Usage (run from a Ghostty/Kitty terminal):
#   ./nvim/test/lab.sh
# then inside nvim:  :JgdLab   -> R opens -> plot(cars)
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
lab="$repo/nvim/test/xdg"

export JGD_REPO_NVIM="$repo/nvim"
export XDG_DATA_HOME="$lab/data"
export XDG_STATE_HOME="$lab/state"
export XDG_CACHE_HOME="$lab/cache"
mkdir -p "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"

exec nvim -u "$repo/nvim/test/init_lab.lua" "$@"
