-- Fictitious documents for the tests and previews (no real song data).

local TL = require "core.timeline"
local Pal = require "core.palette"
local L = require "core.layout"
local G = require "core.geometry"

local X = {}

X.LANE_NAMES = {
  "Filter: Cutoff", "Filter: Resonance", "Delay: Feedback", "Delay: Mix",
  "Chorus: Rate", "Distortion: Drive", "EQ 5: Gain 2", "TrackVolPan: Panning",
  "Reverb: Size", "Gainer: Gain", "Flanger: Depth", "Comp: Threshold",
}

-- Deterministic pseudo random generator.
local function rng(seed)
  local s = seed
  return function()
    s = (s * 1103515245 + 12345) % 2147483648
    return s / 2147483648
  end
end

-- entries: list of { seq, pattern, lines, track_alias }
-- opts.lanes (count), opts.points (per lane and pattern), opts.editable(seq)
function X.doc(entries, opts)
  opts = opts or {}
  local tl = TL.build(entries, { editable = opts.editable })
  local lanes = {}
  local n = opts.lanes or 8
  local keys = {}
  for i = 1, n do keys[i] = "lane" .. i end
  local colors = Pal.assign({}, keys)
  local rand = rng(opts.seed or 7)
  for i = 1, n do
    local lane = {
      key = keys[i],
      name = X.LANE_NAMES[((i - 1) % #X.LANE_NAMES) + 1],
      color = Pal.color(colors[keys[i]]),
      hidden = false,
      playmode = ((i - 1) % 3) + 1,
      info = { name = "Param", device_path = "Audio/Effects/Native/Filter", value_min = 0, value_max = 1, value_quantum = 0 },
      data = {},
    }
    local done = {}
    for _, e in ipairs(entries) do
      if not done[e.pattern] then
        done[e.pattern] = true
        local pts = {}
        local count = opts.points or 6
        local phase = rand()
        for k = 1, count do
          local line = math.floor((k - 1) * e.lines / count) + 1
          local t = line * 256
          local v = 0.5 + 0.4 * math.sin(phase * 6.28 + k * 0.9 + i * 0.7)
          pts[#pts + 1] = { t = t, v = math.max(0, math.min(1, v)), s = 0 }
        end
        lane.data[e.pattern] = { points = pts, exists = true, rev = 1, lines = e.lines, playmode = lane.playmode }
      end
    end
    lanes[i] = lane
  end
  return { timeline = tl, lanes = lanes }
end

function X.single(lines, opts)
  return X.doc({ { seq = 1, pattern = 1, lines = lines or 64 } }, opts)
end

-- View and dims for a canvas of the given preset and zoom.
function X.view_for(doc, preset_index, zoom)
  local p = L.PRESETS[preset_index or L.DEFAULT_PRESET]
  local d = L.compute(p.width, p.height, zoom or 1.25, true)
  local view = G.new_view(d.canvas_w, d.canvas_h, d.pad, doc.timeline.total_g)
  return view, d
end

return X
