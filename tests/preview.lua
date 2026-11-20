-- Verification previews of the drawing logic and of the dialog layout.
-- Writes SVG files to out/previews/ for each size preset, at 100, 125 and
-- 150 % tool zoom, in the three time modes, with a fictitious document.
-- These are NOT screenshots of Renoise: toolbar and legend controls are
-- drawn as labelled boxes with the sizes the tool requests from Renoise.
--
--   luajit tests/preview.lua

package.path = "./?.lua;./tests/?.lua;" .. package.path

local L = require "core.layout"
local G = require "core.geometry"
local R = require "core.render"
local C = require "tests.svg_context"
local X = require "tests.fixtures"

local OUT = "out/previews/"
os.execute(package.config:sub(1, 1) == "\\" and 'mkdir "out\\previews" 2>nul' or "mkdir -p out/previews")

local function esc(s)
  return (string.gsub(s, "[<>&\"]", { ["<"] = "&lt;", [">"] = "&gt;", ["&"] = "&amp;", ['"'] = "&quot;" }))
end

local FONT = 'font-family="Segoe UI, Arial, sans-serif" font-size="11"'

local function box(x, y, w, h, label, fill)
  return string.format('<rect x="%d" y="%d" width="%d" height="%d" fill="%s" stroke="#555" stroke-width="1"/>' ..
    '<text x="%d" y="%d" fill="#ddd" %s>%s</text>',
    x, y, w, h, fill or "#3a3a3e", x + 4, y + h / 2 + 4, FONT, esc(label or ""))
end

local TOOLBAR_LABELS = {
  mode = "Current pattern", range = "From  To  Song", tool = "Edit|Pencil|Line|Select",
  snap = "[x] Snap  Line", interp = "Points|Lines|Curves", vectorize = "Vectorize", add_lane = "Add lane",
  lock = "Lock track", follow = "[x] Follow", fit = "Fit", legend = "Legend", settings = "Settings",
}

local function preview(name, doc, preset_index, zoom, opts)
  opts = opts or {}
  local p = L.PRESETS[preset_index]
  local d = L.compute(p.width, p.height, zoom, true)
  local parts = {}
  local W, H = d.total_w, d.total_h
  parts[#parts + 1] = string.format('<rect width="%d" height="%d" fill="#2b2b2e"/>', W, H)

  -- toolbar
  local x, y = d.margin, d.margin
  for _, item in ipairs(L.TOOLBAR) do
    local w = item.width + (item.checkbox and d.control_h or 0)
    parts[#parts + 1] = box(x, y, w, d.control_h, TOOLBAR_LABELS[item.id])
    x = x + w + d.spacing
  end
  local toolbar_end = x - d.spacing

  -- legend
  local ly = y + d.toolbar_h + d.spacing
  parts[#parts + 1] = box(d.margin, ly, d.legend_w, d.row_h, "Track 01: Example track (fictitious)", "#2b2b2e")
  local ry = ly + d.row_h + d.spacing
  for i = 1, d.legend_rows do
    local lane = doc.lanes[i]
    if lane then
      local cx = d.margin
      parts[#parts + 1] = box(cx, ry, d.checkbox_w, d.row_h, lane.hidden and "" or "x")
      cx = cx + d.checkbox_w + d.spacing
      parts[#parts + 1] = string.format('<rect x="%d" y="%d" width="%d" height="%d" fill="rgb(%d,%d,%d)"/>', cx, ry, d.swatch_w, d.row_h, lane.color[1], lane.color[2], lane.color[3])
      cx = cx + d.swatch_w + d.spacing
      local name_w = d.legend_w - d.checkbox_w - d.swatch_w - d.legend_scroll_w - 2 * d.spacing
      parts[#parts + 1] = box(cx, ry, name_w, d.row_h, lane.name, lane.key == opts.active and "#5a5a66" or "#3a3a3e")
    end
    ry = ry + d.row_h
  end

  -- canvas
  local cx0 = d.margin + d.legend_w + d.spacing
  local cy0 = ly
  local view = G.new_view(d.canvas_w, d.canvas_h, d.pad, doc.timeline.total_g)
  local ctx = C.new(d.canvas_w, d.canvas_h)
  local sel = {}
  if opts.select then sel = opts.select(doc) end
  local stats = R.draw(ctx, {
    dims = d, view = view, segments = doc.timeline.segments, lanes = doc.lanes,
    active_key = opts.active, selection = sel, inactive_alpha = 0.35, lpb = 4, cache = R.new_cache(),
    overlay = opts.overlay and opts.overlay(view) or {},
  })
  parts[#parts + 1] = ctx:to_svg(nil, nil, cx0, cy0)
  -- segment labels (Text views in the tool)
  for _, lab in ipairs(R.segment_labels(view, doc.timeline.segments, false)) do
    parts[#parts + 1] = string.format('<text x="%d" y="%d" fill="#eee" font-weight="bold" %s>%s</text>', cx0 + lab.x + 4, cy0 + 12, FONT, esc(lab.text))
  end
  -- hover label example
  if opts.hover then
    local lane = doc.lanes[1]
    local pt = lane.data[doc.timeline.segments[1].pattern].points[3]
    local hx = cx0 + G.g_to_x(view, pt.t - 256)
    local hy = cy0 + G.v_to_y(view, pt.v)
    local text = require("core.valuefmt").label(lane.name, 1, pt.t, lane.info, pt.v)
    parts[#parts + 1] = box(hx + 10 * zoom, hy - d.label_h - 8 * zoom, #text * 7 + 8, d.label_h, text, "#202024")
  end
  -- playhead child view
  local phx = cx0 + d.canvas_w * 0.37
  parts[#parts + 1] = string.format('<rect x="%d" y="%d" width="%d" height="%d" fill="#e0e0e0"/>', phx, cy0, d.playhead_w, d.canvas_h)
  -- scrollbar and status
  local sy = cy0 + d.canvas_h + d.spacing
  parts[#parts + 1] = box(cx0, sy, d.canvas_w, d.scrollbar_h, "", "#333338")
  local st = sy + d.scrollbar_h + d.spacing
  parts[#parts + 1] = string.format('<text x="%d" y="%d" fill="#aaa" %s>%s</text>', d.margin, st + d.status_h - 4, FONT,
    esc(string.format("Preview %s, %s, zoom %d %%: %d curves, %d points (fictitious data, not a Renoise screenshot)", name, p.name, zoom * 100, stats.lanes, stats.points)))

  local svg = string.format('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">%s</svg>', W, H, W, H, table.concat(parts, "\n"))
  local file = string.format("%s%s-%s-%d.svg", OUT, name, string.lower(p.name), zoom * 100)
  local f = assert(io.open(file, "w"))
  f:write(svg)
  f:close()
  local overflow = toolbar_end > W - d.margin
  return file, overflow, d
end

local current = X.single(64, { lanes = 8, points = 10 })
current.lanes[4].hidden = true
local range = X.doc({
  { seq = 1, pattern = 1, lines = 32 },
  { seq = 2, pattern = 2, lines = 32 },
  { seq = 3, pattern = 1, lines = 32 },
  { seq = 4, pattern = 3, lines = 64, track_alias = true },
}, { lanes = 6, points = 8 })
local neighbours = X.doc({
  { seq = 2, pattern = 2, lines = 32 },
  { seq = 3, pattern = 3, lines = 32 },
  { seq = 4, pattern = 4, lines = 32 },
}, { lanes = 5, points = 8, editable = function(seq) return seq == 3 end })

local problems = 0
for pi = 1, #L.PRESETS do
  for _, zoom in ipairs({ 1.0, 1.25, 1.5 }) do
    local runs = {
      { "current", current, { active = "lane2", hover = true, select = function(doc)
        local pts = doc.lanes[2].data[1].points
        return { [1] = { [pts[4].t] = true, [pts[5].t] = true } }
      end } },
      { "range", range, { active = "lane1", overlay = function(view)
        return { rect = { view.width * 0.55, view.height * 0.2, view.width * 0.7, view.height * 0.8 } }
      end } },
      { "neighbours", neighbours, { active = "lane3" } },
    }
    for _, r in ipairs(runs) do
      local file, overflow = preview(r[1], r[2], pi, zoom, r[3])
      if overflow then
        problems = problems + 1
        print("OVERFLOW " .. file)
      end
    end
  end
end
print(string.format("Previews written to %s (%d layout problems).", OUT, problems))
