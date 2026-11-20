local G = require "core.geometry"
local TL = require "core.timeline"

T.test("time and value to pixels round trip", function()
  local v = G.new_view(1000, 200, 10, 64 * 256)
  T.near(G.g_to_x(v, 0), 0)
  T.near(G.g_to_x(v, 64 * 256), 1000)
  T.near(G.x_to_g(v, 500), 32 * 256)
  T.near(G.v_to_y(v, 1), 10)
  T.near(G.v_to_y(v, 0), 190)
  T.near(G.y_to_v(v, 100), 0.5)
  T.eq(G.y_to_v(v, -50), 1, "clamped")
  T.eq(G.y_to_v(v, 500), 0, "clamped")
end)

T.test("zoom keeps the time under the cursor", function()
  local total = 64 * 256
  local v = G.new_view(1000, 200, 10, total)
  local g_before = G.x_to_g(v, 250)
  G.zoom_at(v, 2, 250, total)
  T.near(v.span_g, total / 2)
  T.near(G.x_to_g(v, 250), g_before, 1e-6)
end)

T.test("zoom is clamped to the timeline and minimum span", function()
  local total = 16 * 256
  local v = G.new_view(1000, 200, 10, total)
  G.zoom_at(v, 0.1, 500, total)
  T.eq(v.span_g, total)
  T.eq(v.start_g, 0)
  for _ = 1, 50 do G.zoom_at(v, 2, 500, total) end
  T.eq(v.span_g, G.MIN_SPAN)
end)

T.test("scroll is clamped", function()
  local total = 64 * 256
  local v = G.new_view(1000, 200, 10, total)
  G.zoom_at(v, 4, 0, total)
  G.scroll(v, -9999, total)
  T.eq(v.start_g, 0)
  G.scroll(v, 1e9, total)
  T.near(v.start_g + v.span_g, total)
end)

T.test("fit and ensure_visible", function()
  local total = 64 * 256
  local v = G.new_view(1000, 200, 10, total)
  G.zoom_at(v, 4, 0, total)
  T.ok(G.ensure_visible(v, 60 * 256, total))
  T.ok(v.start_g <= 60 * 256 and v.start_g + v.span_g >= 60 * 256)
  T.ok(not G.ensure_visible(v, 60 * 256, total))
  G.fit(v, total)
  T.eq(v.start_g, 0)
  T.eq(v.span_g, total)
end)

T.test("grid lines mark patterns and beats", function()
  local tl = TL.build({
    { seq = 1, pattern = 1, lines = 16 },
    { seq = 2, pattern = 2, lines = 16 },
  })
  local v = G.new_view(3200, 200, 10, tl.total_g)
  local lines = G.grid_lines(v, tl.segments, 4, 6)
  local kinds = {}
  for _, l in ipairs(lines) do kinds[l.kind] = (kinds[l.kind] or 0) + 1 end
  T.eq(kinds.pattern, 3, "start of each pattern plus the end")
  T.eq(kinds.beat, 6, "beats at lines 4, 8, 12 in each pattern")
  T.eq(kinds.line, 2 * 12)
  T.ok((kinds.sub or 0) > 0, "100 px per line shows sub lines")
end)

T.test("grid thins out when zoomed out", function()
  local tl = TL.build({ { seq = 1, pattern = 1, lines = 512 } })
  local v = G.new_view(500, 200, 10, tl.total_g)
  local lines = G.grid_lines(v, tl.segments, 4, 6)
  for _, l in ipairs(lines) do
    T.ok(l.kind ~= "line" and l.kind ~= "sub", "no line or sub grid at 1 px per line")
  end
end)
