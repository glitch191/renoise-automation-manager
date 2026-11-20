local P = require "core.points"

local function pts(list)
  local out = {}
  for i = 1, #list, 2 do out[#out + 1] = { t = list[i], v = list[i + 1], s = 0 } end
  return out
end

T.test("renoise conversion round trip", function()
  local r = { { time = 1, value = 0.5, scaling = 0 }, { time = 2.5, value = 1, scaling = 0.25 } }
  local p = P.from_renoise(r)
  T.eq(p, { { t = 256, v = 0.5, s = 0 }, { t = 640, v = 1, s = 0.25 } })
  T.eq(P.to_renoise(p), r)
end)

T.test("from_renoise sorts unsorted input", function()
  local p = P.from_renoise({ { time = 3, value = 0 }, { time = 1, value = 1 } })
  T.eq(p[1].t, 256)
  T.eq(p[2].t, 768)
end)

T.test("clamp and bounds", function()
  T.eq(P.clamp_v(-0.2), 0)
  T.eq(P.clamp_v(1.7), 1)
  T.eq(P.clamp_v(0 / 0), 0)
  T.eq(P.clamp_t(10, 64), 256)
  T.eq(P.clamp_t(99999, 64), 65 * 256 - 1)
  T.eq(P.max_t(16), 17 * 256 - 1)
end)

T.test("snap to grid resolutions", function()
  T.eq(P.snap_t(300, 256), 256)
  T.eq(P.snap_t(400, 256), 512)
  T.eq(P.snap_t(300, 128), 256)
  T.eq(P.snap_t(330, 64), 320)
  T.eq(P.snap_t(333, 32), 320)
  T.eq(P.snap_t(333.4, 1), 333)
end)

T.test("snap_clamp keeps the result inside the pattern", function()
  -- 16 lines: max t = 17*256-1 = 4351; snapping to a line must give 4096
  T.eq(P.snap_clamp_t(4351, 256, 16), 4096)
  T.eq(P.snap_clamp_t(-50, 256, 16), 256)
  T.eq(P.snap_clamp_t(4351, 1, 16), 4351)
end)

T.test("add inserts sorted and replaces same time", function()
  local p = pts({ 256, 0, 1024, 1 })
  local a = P.add(p, 512, 0.5)
  T.eq(a, pts({ 256, 0, 512, 0.5, 1024, 1 }))
  local b = P.add(a, 512, 0.75)
  T.eq(b, pts({ 256, 0, 512, 0.75, 1024, 1 }))
  T.eq(#p, 2, "input not mutated")
end)

T.test("add clamps value", function()
  T.eq(P.add({}, 256, 3)[1].v, 1)
end)

T.test("remove_times and clear_range", function()
  local p = pts({ 256, 0, 512, 0.5, 768, 1 })
  T.eq(P.remove_times(p, { 512 }), pts({ 256, 0, 768, 1 }))
  T.eq(P.clear_range(p, 500, 800), pts({ 256, 0 }))
  T.eq(P.clear_range(p, 800, 500), pts({ 256, 0 }))
end)

T.test("move a single point in time and value", function()
  local p = pts({ 256, 0, 512, 0.5, 768, 1 })
  local np, nt = P.move(p, { 512 }, 64, 0.25, 16)
  T.eq(np, pts({ 256, 0, 576, 0.75, 768, 1 }))
  T.eq(nt, { 576 })
end)

T.test("move removes duplicates: the moved point wins", function()
  local p = pts({ 256, 0, 512, 0.5, 768, 1 })
  local np, nt = P.move(p, { 512 }, 256, 0, 16)
  T.eq(np, pts({ 256, 0, 768, 0.5 }))
  T.eq(nt, { 768 })
  T.ok(P.is_valid(np, 16))
end)

T.test("move clamps the group inside the pattern", function()
  local p = pts({ 256, 0.2, 512, 0.4 })
  local np, nt = P.move(p, { 256, 512 }, -1000, 0, 16)
  T.eq(nt, { 256, 512 }, "cannot go before line 1")
  local np2, nt2 = P.move(p, { 256, 512 }, 100000, 0, 16)
  T.eq(nt2, { 4351 - 256, 4351 })
  T.ok(P.is_valid(np2, 16))
end)

T.test("move clamps values per point", function()
  local np = P.move(pts({ 256, 0.9, 512, 0.1 }), { 256, 512 }, 0, 0.5, 16)
  T.eq(np, pts({ 256, 1, 512, 0.6 }))
end)

T.test("in_rect selects inside time and value bounds", function()
  local p = pts({ 256, 0.1, 512, 0.5, 768, 0.9 })
  T.eq(P.in_rect(p, 300, 800, 0.4, 1), { 512, 768 })
  T.eq(P.in_rect(p, 800, 300, 1, 0.4), { 512, 768 })
end)

T.test("scale values around center and bottom", function()
  local p = pts({ 256, 0.2, 512, 0.6, 768, 1 })
  local c = P.scale_values(p, { 256, 512 }, 0.5, "center")
  T.near(c[1].v, 0.3)
  T.near(c[2].v, 0.5)
  T.eq(c[3].v, 1, "unselected unchanged")
  local b = P.scale_values(p, { 256, 512 }, 2, "bottom")
  T.near(b[1].v, 0.2)
  T.near(b[2].v, 1.0)
  local pv = P.scale_values(p, { 512 }, 0, "center", 0.1)
  T.near(pv[2].v, 0.1, 1e-9, "explicit pivot")
end)

T.test("pencil fills every grid cell between samples", function()
  local cells = {}
  P.pencil_add(cells, nil, nil, 256, 0, 256)
  P.pencil_add(cells, 256, 0, 1280, 1, 256)
  local list = P.pencil_apply({}, cells, 16)
  T.eq(#list, 5)
  T.near(list[1].v, 0)
  T.near(list[3].v, 0.5)
  T.near(list[5].v, 1)
  T.eq(list[5].t, 1280)
end)

T.test("pencil replaces existing points in the drawn range only", function()
  local base = pts({ 256, 0.9, 600, 0.9, 2000, 0.9 })
  local cells = {}
  P.pencil_add(cells, nil, nil, 512, 0.2, 256)
  P.pencil_add(cells, 512, 0.2, 1024, 0.4, 256)
  local out = P.pencil_apply(base, cells, 16)
  T.near(out, pts({ 256, 0.9, 512, 0.2, 768, 0.3, 1024, 0.4, 2000, 0.9 }), 1e-9)
end)

T.test("pencil in free mode keeps raw samples", function()
  local cells = {}
  P.pencil_add(cells, nil, nil, 300, 0.1, 1)
  P.pencil_add(cells, 300, 0.1, 333, 0.2, 1)
  local out = P.pencil_apply({}, cells, 16)
  T.eq(out, pts({ 300, 0.1, 333, 0.2 }))
end)

T.test("pencil drawing backwards works", function()
  local cells = {}
  P.pencil_add(cells, nil, nil, 1024, 1, 256)
  P.pencil_add(cells, 1024, 1, 512, 0, 256)
  local out = P.pencil_apply({}, cells, 16)
  T.eq(out, pts({ 512, 0, 768, 0.5, 1024, 1 }))
end)

T.test("line ramp replaces the range with two points", function()
  local base = pts({ 256, 0.5, 700, 0.5, 900, 0.5, 2000, 0.5 })
  local out = P.line(base, 512, 0, 1024, 1)
  T.eq(out, pts({ 256, 0.5, 512, 0, 1024, 1, 2000, 0.5 }))
end)

T.test("line ramp with a step adds intermediate points", function()
  local out = P.line({}, 256, 0, 1280, 1, 256)
  T.eq(#out, 5)
  T.near(out[2].v, 0.25)
end)

T.test("line ramp accepts reversed ends", function()
  T.eq(P.line({}, 1024, 1, 512, 0), pts({ 512, 0, 1024, 1 }))
end)

T.test("is_valid detects problems", function()
  T.ok(P.is_valid(pts({ 256, 0, 512, 1 }), 16))
  T.ok(not P.is_valid(pts({ 512, 0, 256, 1 }), 16), "unsorted")
  T.ok(not P.is_valid(pts({ 256, 0, 256, 1 }), 16), "duplicate")
  T.ok(not P.is_valid(pts({ 100, 0 }), 16), "before line 1")
end)
