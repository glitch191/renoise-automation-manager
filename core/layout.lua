-- Pure dialog layout: computes every tool defined dimension from the window
-- size and the tool zoom factor (1.0 to 2.0, default 1.25).
--
-- The tool zoom multiplies heights, margins, line widths, point sizes and hit
-- areas. Renoise applies its own global UI scaling on top of that, and the
-- fonts of Renoise views are never scaled by the tool, so control widths that
-- only hold text are kept constant.

local L = {}

L.ZOOM_DEFAULT = 1.25
L.ZOOM_MIN = 1.0
L.ZOOM_MAX = 2.0
L.ZOOM_STEP = 0.25

-- Window size presets (dialog content size in Renoise view units).
L.PRESETS = {
  { name = "Compact", width = 1180, height = 420 },   -- fits 1280 x 720
  { name = "Wide", width = 1800, height = 520 },      -- fits 1920 x 1080 (default)
  { name = "Ultrawide", width = 3300, height = 640 }, -- uses 3440 x 1440
}
L.DEFAULT_PRESET = 2

L.MIN_CANVAS_W = 320
L.MIN_CANVAS_H = 100

-- Toolbar control widths (text holding controls, not scaled). The snap and
-- follow groups also hold a checkbox whose width is the scaled control height.
L.TOOLBAR = {
  { id = "mode", width = 116 },
  { id = "range", width = 142 },     -- From, To, Song (or N in neighbours mode)
  { id = "tool", width = 196 },
  { id = "snap", width = 94, checkbox = true }, -- "Snap" text 30 + grid popup 64
  { id = "interp", width = 136 },
  { id = "add_lane", width = 64 },
  { id = "lock", width = 80 },
  { id = "follow", width = 40, checkbox = true }, -- "Follow" text
  { id = "fit", width = 36 },
  { id = "legend", width = 52 },
  { id = "settings", width = 60 },
}

L.W = {}
for _, item in ipairs(L.TOOLBAR) do L.W[item.id] = item.width end

function L.clamp_zoom(z)
  z = tonumber(z) or L.ZOOM_DEFAULT
  z = math.floor(z / L.ZOOM_STEP + 0.5) * L.ZOOM_STEP
  if z < L.ZOOM_MIN then z = L.ZOOM_MIN end
  if z > L.ZOOM_MAX then z = L.ZOOM_MAX end
  return z
end

local function r(x) return math.floor(x + 0.5) end

function L.toolbar_width(s)
  local w = 0
  for i = 1, #L.TOOLBAR do
    w = w + L.TOOLBAR[i].width
    if L.TOOLBAR[i].checkbox then w = w + r(18 * s) end
  end
  return w + (#L.TOOLBAR - 1) * r(3 * s)
end

-- Returns every size needed by the dialog builder and the renderer.
function L.compute(width, height, s, legend_visible)
  s = L.clamp_zoom(s)
  local d = {}
  d.zoom = s
  d.margin = r(4 * s)
  d.spacing = r(3 * s)
  d.control_h = r(18 * s)
  d.toolbar_h = d.control_h
  d.status_h = r(16 * s)
  d.scrollbar_h = r(14 * s)
  d.row_h = r(18 * s)
  d.swatch_w = r(14 * s)
  d.checkbox_w = r(18 * s)
  d.legend_w = legend_visible and r(200 * s) or 0
  d.legend_scroll_w = r(14 * s)

  d.canvas_w = width - 2 * d.margin - ((d.legend_w > 0) and (d.legend_w + d.spacing) or 0)
  d.canvas_h = height - 2 * d.margin - d.toolbar_h - d.scrollbar_h - d.status_h - 3 * d.spacing
  if d.canvas_w < L.MIN_CANVAS_W then d.canvas_w = L.MIN_CANVAS_W end
  if d.canvas_h < L.MIN_CANVAS_H then d.canvas_h = L.MIN_CANVAS_H end

  -- Legend: one header row, then as many lane rows as fit next to the canvas.
  d.legend_h = d.canvas_h + d.spacing + d.scrollbar_h
  d.legend_rows = math.max(1, math.floor((d.legend_h - d.row_h - d.spacing) / d.row_h))

  -- Canvas drawing metrics.
  d.line_active = 2 * s
  d.line_inactive = 1.25 * s
  d.point_size = r(6 * s)
  d.hit_radius = 8 * s
  d.pad = r(8 * s)
  d.label_h = r(16 * s)
  d.playhead_w = math.max(1, r(2 * s))

  d.total_w = 2 * d.margin + d.canvas_w + ((d.legend_w > 0) and (d.legend_w + d.spacing) or 0)
  d.total_h = 2 * d.margin + d.toolbar_h + d.canvas_h + d.scrollbar_h + d.status_h + 3 * d.spacing
  d.toolbar_w = L.toolbar_width(s)
  return d
end

return L
