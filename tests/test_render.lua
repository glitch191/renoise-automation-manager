local R = require "core.render"
local C = require "tests.svg_context"
local X = require "tests.fixtures"

local function scene(doc, view, d, active, extra)
  local s = {
    dims = d, view = view, segments = doc.timeline.segments, lanes = doc.lanes,
    active_key = active, inactive_alpha = 0.35, lpb = 4, cache = R.new_cache(),
  }
  for k, v in pairs(extra or {}) do s[k] = v end
  return s
end

local function lane_strokes(ctx, d)
  return ctx:count("stroke", function(e) return e.line_width == d.line_inactive or e.line_width == d.line_active end)
end

T.test("8 lanes: 8 curves drawn, active one on top with its points", function()
  local doc = X.single(64, { lanes = 8, points = 6 })
  local view, d = X.view_for(doc)
  local ctx = C.new(view.width, view.height)
  local stats = R.draw(ctx, scene(doc, view, d, "lane3"))
  T.eq(stats.lanes, 8)
  T.eq(stats.points, 6, "only the active lane shows points")
  T.eq(lane_strokes(ctx, d), 8)
  -- the last lane stroke is the active one: opaque and thicker
  local last
  for _, e in ipairs(ctx.log) do
    if e.op == "stroke" and (e.line_width == d.line_inactive or e.line_width == d.line_active) then last = e end
  end
  T.eq(last.line_width, d.line_active)
  T.eq(last.alpha, 255)
  T.eq(last.stroke[1], doc.lanes[3].color[1])
end)

T.test("inactive lanes use the reduced opacity", function()
  local doc = X.single(64, { lanes = 3 })
  local view, d = X.view_for(doc)
  local ctx = C.new(view.width, view.height)
  R.draw(ctx, scene(doc, view, d, "lane1", { inactive_alpha = 0.35 }))
  local n = ctx:count("stroke", function(e) return e.line_width == d.line_inactive end)
  T.eq(n, 2)
  T.eq(ctx:count("stroke", function(e) return e.line_width == d.line_inactive and e.alpha == 89 end), 2)
end)

T.test("hidden lanes are not drawn", function()
  local doc = X.single(64, { lanes = 8 })
  doc.lanes[2].hidden = true
  doc.lanes[5].hidden = true
  local view, d = X.view_for(doc)
  local ctx = C.new(view.width, view.height)
  local stats = R.draw(ctx, scene(doc, view, d, "lane1"))
  T.eq(stats.lanes, 6)
end)

T.test("hidden active lane draws no points", function()
  local doc = X.single(64, { lanes = 2 })
  doc.lanes[1].hidden = true
  local view, d = X.view_for(doc)
  local stats = R.draw(C.new(view.width, view.height), scene(doc, view, d, "lane1"))
  T.eq(stats.points, 0)
  T.eq(stats.lanes, 1)
end)

T.test("selected points are drawn highlighted", function()
  local doc = X.single(64, { lanes = 1, points = 4 })
  local view, d = X.view_for(doc)
  local ctx = C.new(view.width, view.height)
  local t = doc.lanes[1].data[1].points[2].t
  R.draw(ctx, scene(doc, view, d, "lane1", { selection = { [1] = { [t] = true } } }))
  local sel = ctx:count("fill_rect", function(e) return e.fill[1] == R.DEFAULT_COLORS.selection[1] and e.w == d.point_size + 2 end)
  T.eq(sel, 1)
end)

T.test("alias segments are hatched and read only segments shaded", function()
  local doc = X.doc({
    { seq = 1, pattern = 1, lines = 16 },
    { seq = 2, pattern = 2, lines = 16 },
    { seq = 3, pattern = 1, lines = 16 },
  }, { lanes = 2, editable = function(seq) return seq == 2 end })
  local view, d = X.view_for(doc)
  local ctx = C.new(view.width, view.height)
  R.draw(ctx, scene(doc, view, d, "lane1"))
  local svg = ctx:to_svg()
  T.ok(svg:find("clip%-path"), "hatching is clipped to the alias segment")
  local shades = ctx:count("fill_rect", function(e) return e.fill[4] == 90 end)
  T.eq(shades, 2, "two read only segments")
end)

T.test("segment labels mark aliases", function()
  local doc = X.doc({
    { seq = 1, pattern = 1, lines = 16 },
    { seq = 2, pattern = 1, lines = 16 },
  }, { lanes = 1 })
  local view = X.view_for(doc)
  local labels = R.segment_labels(view, doc.timeline.segments)
  T.eq(#labels, 2)
  T.eq(labels[2].text, "1: Pat 0 (alias)")
end)

T.test("sample cache is reused until the revision changes", function()
  local doc = X.single(64, { lanes = 1 })
  local cache = R.new_cache()
  local data = doc.lanes[1].data[1]
  local a = R.samples(cache, "lane1", 1, data, 2)
  local b = R.samples(cache, "lane1", 1, data, 2)
  T.ok(a == b)
  data.rev = data.rev + 1
  local c = R.samples(cache, "lane1", 1, data, 2)
  T.ok(c ~= a)
end)

T.test("pixel transform culls vertices outside the view", function()
  local doc = X.single(64, { lanes = 1, points = 64 })
  local view, d = X.view_for(doc)
  local G = require "core.geometry"
  G.zoom_at(view, 8, view.width / 2, doc.timeline.total_g)
  local seg = doc.timeline.segments[1]
  local data = doc.lanes[1].data[1]
  local xy = R.to_pixels(view, seg, R.samples(R.new_cache(), "l", 1, data, 2))
  T.ok(#xy / 2 < 64 / 8 + 6, "only the visible part is converted")
  T.ok(xy[1] <= 0 and xy[#xy - 1] >= view.width, "line reaches both edges")
end)

T.test("30 lanes x 300 points x 16 patterns stay within a vertex budget", function()
  local entries = {}
  for i = 1, 16 do entries[i] = { seq = i, pattern = i, lines = 64 } end
  local doc = X.doc(entries, { lanes = 30, points = 300 })
  local view, d = X.view_for(doc, 2, 1.25)
  local ctx = C.new(view.width, view.height)
  local t0 = os.clock()
  local stats = R.draw(ctx, scene(doc, view, d, "lane1"))
  local dt = os.clock() - t0
  T.eq(stats.lanes, 30)
  -- decimation keeps at most 3 vertices per pixel column per lane and segment
  T.ok(stats.vertices <= 30 * (view.width + 16) * 3, "vertices " .. stats.vertices)
  io.write(string.format("           render 30 x 300 x 16: %.1f ms (SVG mock, %d vertices)\n", dt * 1000, stats.vertices))
end)
