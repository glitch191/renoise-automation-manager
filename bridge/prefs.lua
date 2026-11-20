-- Tool preferences (global settings), saved by Renoise in preferences.xml
-- inside the tool bundle.

local L = require "core.layout"

local M = {}

M.TIME_MODES = { "Current pattern", "Pattern range", "Pattern + neighbours" }

function M.create()
  local p = L.PRESETS[L.DEFAULT_PRESET]
  return renoise.Document.create("RenoiseAutomationManagerPreferences") {
    ui_zoom = L.ZOOM_DEFAULT,      -- tool zoom factor, 1.0 to 2.0
    size_preset = L.DEFAULT_PRESET, -- 1 Compact, 2 Wide, 3 Ultrawide, 4 Custom
    width = p.width,
    height = p.height,
    time_mode = 1,                 -- index in TIME_MODES
    neighbours = 1,                -- N patterns before and after (1 to 4)
    tool = 1,                      -- default tool index (Edit)
    snap_enabled = true,
    snap_grid = 1,                 -- index in editor GRIDS (1 = line)
    inactive_opacity = 35,         -- percent
    live_writes = true,            -- write drags and pencil strokes while the mouse moves
    follow_playback = true,
    legend_visible = true,
    diagnostics = false,
  }
end

-- Dialog size for the current preferences.
function M.size(prefs)
  local idx = prefs.size_preset.value
  local preset = L.PRESETS[idx]
  if preset then return preset.width, preset.height end
  return prefs.width.value, prefs.height.value
end

return M
