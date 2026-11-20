local H = require "core.hittest"

T.test("distance to a segment", function()
  T.near(H.dist_segment(5, 5, 0, 0, 10, 0), 5)
  T.near(H.dist_segment(-3, 4, 0, 0, 10, 0), 5, 1e-9, "beyond the start")
  T.near(H.dist_segment(3, 4, 0, 0, 0, 0), 5, 1e-9, "degenerate segment")
end)

T.test("distance to a polyline", function()
  local xy = { 0, 0, 10, 0, 10, 10 }
  T.near(H.dist_polyline(xy, 12, 5), 2)
  T.near(H.dist_polyline(xy, 5, -1), 1)
  T.near(H.dist_polyline({ 3, 4 }, 0, 0), 5)
end)

T.test("nearest item within radius", function()
  local items = { { x = 0, y = 0, id = 1 }, { x = 10, y = 0, id = 2 } }
  T.eq(H.nearest(items, 8, 1, 8).id, 2)
  T.eq(H.nearest(items, 30, 30, 8), nil)
end)
