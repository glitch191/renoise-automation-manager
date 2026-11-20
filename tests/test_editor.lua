local E = require "core.editor"
local G = require "core.geometry"
local X = require "tests.fixtures"
local P = require "core.points"

local function setup(doc, opts)
  opts = opts or {}
  local view, d = X.view_for(doc, 2, 1.25)
  local ed = E.new({ view = view, dims = d, snap = opts.snap, grid = opts.grid or 256 })
  ed:set_doc(doc)
  ed.active_key = opts.active or "lane1"
  ed.tool = opts.tool or "edit"
  return ed, view, d
end

-- pixel position of (segment, local t, value)
local function pos(ed, seg_index, t, v)
  local seg = ed.doc.timeline.segments[seg_index]
  return G.g_to_x(ed.view, seg.offset - 256 + t), G.v_to_y(ed.view, v)
end

local function ev(type, x, y, button, mods)
  return { type = type, x = x, y = y, button = button or "left", mods = mods or {} }
end

local function pts(list)
  local out = {}
  for i = 1, #list, 2 do out[#out + 1] = { t = list[i], v = list[i + 1], s = 0 } end
  return out
end

local function one_lane_doc(points, lines, extra_lanes)
  local doc = X.single(lines or 16, { lanes = 1 + (extra_lanes or 0) })
  doc.lanes[1].data[1].points = points
  doc.lanes[1].playmode = 2
  doc.lanes[1].data[1].playmode = 2
  return doc
end

T.test("click near an inactive curve activates it without changing points", function()
  local doc = X.single(16, { lanes = 3, points = 4 })
  for _, l in ipairs(doc.lanes) do
    l.playmode = 2
    l.data[1].playmode = 2
  end
  -- make lane 2 flat at 0.9 and the others far below
  doc.lanes[1].data[1].points = pts({ 256, 0.1, 4096, 0.1 })
  doc.lanes[2].data[1].points = pts({ 256, 0.9, 4096, 0.9 })
  doc.lanes[3].data[1].points = pts({ 256, 0.3, 4096, 0.3 })
  local ed = setup(doc)
  local before = T.fmt(doc.lanes)
  local x, y = pos(ed, 1, 8 * 256 + 100, 0.9)
  local fx = ed:mouse(ev("down", x, y + 3))
  T.eq(fx.activate, "lane2")
  T.eq(fx.commit, nil)
  ed:mouse(ev("up", x, y + 3))
  local fx2 = ed:mouse(ev("double", x, y + 3))
  T.eq(fx2.commit, nil, "double click right after activation adds nothing")
  T.eq(ed.active_key, "lane2")
  T.eq(T.fmt(doc.lanes), before, "no point changed")
end)

T.test("double click adds a snapped point on the active lane", function()
  local doc = one_lane_doc(pts({ 256, 0.5 }))
  local ed = setup(doc)
  local x, y = pos(ed, 1, 5 * 256 + 90, 0.75)
  local fx = ed:mouse(ev("double", x, y))
  T.eq(fx.commit.description, "Multi Automation: Add point")
  T.eq(#fx.commit.writes, 1)
  local w = fx.commit.writes[1]
  T.eq(w.pattern, 1)
  T.eq(#w.points, 2)
  T.eq(w.points[2].t, 5 * 256, "snapped to the line")
  T.near(w.points[2].v, 0.75, 0.01)
end)

T.test("drag moves a point in time and value with snap", function()
  local doc = one_lane_doc(pts({ 256, 0.5, 1024, 0.5, 2048, 0.5 }))
  local ed = setup(doc)
  local x, y = pos(ed, 1, 1024, 0.5)
  ed:mouse(ev("down", x, y))
  local x2, y2 = pos(ed, 1, 1536 + 40, 0.8)
  ed:mouse(ev("drag", x2, y2))
  local fx = ed:mouse(ev("up", x2, y2))
  T.eq(fx.commit.description, "Multi Automation: Move points")
  local p = fx.commit.writes[1].points
  T.eq(#p, 3)
  T.eq(p[2].t, 1536)
  T.near(p[2].v, 0.8, 0.01)
  T.ok(P.is_valid(p, 16))
end)

T.test("Shift drag is fine and not snapped", function()
  local doc = one_lane_doc(pts({ 256, 0.5, 1024, 0.5 }))
  local ed = setup(doc)
  local x, y = pos(ed, 1, 1024, 0.5)
  ed:mouse(ev("down", x, y))
  local dx = ed.view.width * 256 / ed.view.span_g -- one line in pixels
  ed:mouse(ev("drag", x + dx, y, "left", { shift = true }))
  local fx = ed:mouse(ev("up", x + dx, y, "left", { shift = true }))
  local t = fx.commit.writes[1].points[2].t
  T.ok(math.abs(t - (1024 + 26)) <= 1, "moved by a tenth of a line, got " .. t)
end)

T.test("Ctrl drag is constrained to one axis", function()
  local doc = one_lane_doc(pts({ 256, 0.5, 1024, 0.5 }))
  local ed = setup(doc)
  local x, y = pos(ed, 1, 1024, 0.5)
  ed:mouse(ev("down", x, y))
  local x2, y2 = pos(ed, 1, 1024 + 512, 0.55)
  ed:mouse(ev("drag", x2, y2, "left", { control = true }))
  local fx = ed:mouse(ev("up", x2, y2, "left", { control = true }))
  local p = fx.commit.writes[1].points[2]
  T.eq(p.t, 1536)
  T.eq(p.v, 0.5, "value unchanged")
end)

T.test("dragging over another point never creates duplicates", function()
  local doc = one_lane_doc(pts({ 256, 0.1, 512, 0.2, 768, 0.3 }))
  local ed = setup(doc)
  local x, y = pos(ed, 1, 512, 0.2)
  ed:mouse(ev("down", x, y))
  local x2 = pos(ed, 1, 768, 0.2)
  ed:mouse(ev("drag", x2, y))
  local fx = ed:mouse(ev("up", x2, y))
  T.eq(fx.commit.writes[1].points, pts({ 256, 0.1, 768, 0.2 }))
end)

T.test("drag beyond the pattern end and above 1 is clamped", function()
  local doc = one_lane_doc(pts({ 256, 0.1, 512, 0.2 }))
  local ed = setup(doc)
  local x, y = pos(ed, 1, 512, 0.2)
  ed:mouse(ev("down", x, y))
  ed:mouse(ev("drag", ed.view.width + 500, -500))
  local fx = ed:mouse(ev("up", ed.view.width + 500, -500))
  local p = fx.commit.writes[1].points[2]
  T.eq(p.t, 16 * 256, "last line of a 16 line pattern")
  T.eq(p.v, 1)
end)

T.test("right click and Alt click delete a point", function()
  local doc = one_lane_doc(pts({ 256, 0.1, 512, 0.2, 768, 0.3 }))
  local ed = setup(doc)
  local x, y = pos(ed, 1, 512, 0.2)
  local fx = ed:mouse(ev("down", x, y, "right"))
  T.eq(fx.commit.description, "Multi Automation: Delete point")
  T.eq(fx.commit.writes[1].points, pts({ 256, 0.1, 768, 0.3 }))
  local x2, y2 = pos(ed, 1, 768, 0.3)
  local fx2 = ed:mouse(ev("down", x2, y2, "left", { alt = true }))
  T.eq(fx2.commit.writes[1].points, pts({ 256, 0.1 }))
end)

T.test("pencil stroke writes grid points and replaces the drawn range", function()
  local doc = one_lane_doc(pts({ 256, 0.9, 800, 0.9, 3000, 0.9 }))
  local ed = setup(doc, { tool = "pencil" })
  local x0, y0 = pos(ed, 1, 512, 0.0)
  local x1, y1 = pos(ed, 1, 1536, 1.0)
  ed:mouse(ev("down", x0, y0))
  ed:mouse(ev("drag", x1, y1))
  local fx = ed:mouse(ev("up", x1, y1))
  T.eq(fx.commit.description, "Multi Automation: Draw")
  local p = fx.commit.writes[1].points
  T.eq(p[1].t, 256)
  T.eq(p[#p].t, 3000)
  local times = {}
  for i = 2, #p - 1 do times[#times + 1] = p[i].t end
  T.eq(times, { 512, 768, 1024, 1280, 1536 })
  T.near(p[4].v, 0.5, 0.02)
end)

T.test("line tool crosses patterns in Pattern range mode", function()
  local doc = X.doc({
    { seq = 1, pattern = 1, lines = 16 },
    { seq = 2, pattern = 2, lines = 16 },
  }, { lanes = 1 })
  doc.lanes[1].playmode = 2
  doc.lanes[1].data[1] = { points = {}, exists = true, rev = 1, lines = 16, playmode = 2 }
  doc.lanes[1].data[2] = nil -- no automation yet in pattern 2
  local ed = setup(doc, { tool = "line" })
  local x0, y0 = pos(ed, 1, 9 * 256, 0)
  local x1, y1 = pos(ed, 2, 9 * 256, 1)
  ed:mouse(ev("down", x0, y0))
  ed:mouse(ev("drag", x1, y1))
  local fx = ed:mouse(ev("up", x1, y1))
  T.eq(fx.commit.description, "Multi Automation: Draw line")
  T.eq(#fx.commit.writes, 2)
  local w1, w2 = fx.commit.writes[1], fx.commit.writes[2]
  T.eq(w1.pattern, 1)
  T.eq(w2.pattern, 2)
  T.ok(w2.create, "automation created in pattern 2")
  T.eq(w1.points[1].t, 9 * 256)
  T.eq(w1.points[2].t, 17 * 256 - 1)
  T.eq(w2.points[1].t, 256)
  T.near(w2.points[1].v, 0.5, 0.01)
  T.near(w2.points[2].v, 1, 0.01)
end)

T.test("line tool works with two clicks", function()
  local doc = one_lane_doc({})
  local ed = setup(doc, { tool = "line" })
  local x0, y0 = pos(ed, 1, 512, 0.2)
  ed:mouse(ev("down", x0, y0))
  local fx = ed:mouse(ev("up", x0, y0))
  T.eq(fx.status, E.MSG_LINE_END)
  local x1, y1 = pos(ed, 1, 1024, 0.8)
  local fx2 = ed:mouse(ev("down", x1, y1))
  T.eq(#fx2.commit.writes[1].points, 2)
  T.eq(fx2.commit.writes[1].points[2].t, 1024)
end)

T.test("line in Points playmode adds grid steps", function()
  local doc = one_lane_doc({})
  doc.lanes[1].data[1].playmode = 1
  local ed = setup(doc, { tool = "line" })
  local c = ed:commit_line(256, 0, 256 + 4 * 256, 1, 256)
  T.eq(#c.writes[1].points, 5)
end)

T.test("rectangle selection, then delete, shift and scale", function()
  local doc = one_lane_doc(pts({ 256, 0.2, 512, 0.4, 768, 0.6, 2048, 0.8 }))
  local ed = setup(doc)
  local xa, ya = pos(ed, 1, 400, 0.7)
  local xb, yb = pos(ed, 1, 900, 0.3)
  ed:mouse(ev("down", xa, ya))
  ed:mouse(ev("drag", xb, yb))
  ed:mouse(ev("up", xb, yb))
  T.ok(ed:has_selection())
  local s = ed:scale_selection(2, "center")
  T.near(s.writes[1].points[2].v, 0.3, 1e-9)
  T.near(s.writes[1].points[3].v, 0.7, 1e-9)
  local b = ed:scale_selection(0.5, "bottom")
  T.near(b.writes[1].points[2].v, 0.3, 1e-9)
  T.near(b.writes[1].points[3].v, 0.5, 1e-9)
  local sh = ed:shift_selection(256)
  T.eq(sh.description, "Multi Automation: Shift points")
  T.eq(sh.writes[1].points[2].t, 768)
  T.eq(sh.writes[1].points[3].t, 1024)
  local del = ed:delete_selection()
  T.eq(del.writes[1].points, pts({ 256, 0.2, 2048, 0.8 }))
end)

T.test("copy and paste to another lane in another pattern", function()
  local doc = X.doc({
    { seq = 1, pattern = 1, lines = 16 },
    { seq = 2, pattern = 2, lines = 16 },
  }, { lanes = 2 })
  doc.lanes[1].data[1].points = pts({ 512, 0.1, 768, 0.9 })
  doc.lanes[2].data[2] = nil
  local ed = setup(doc)
  ed.selection = { [1] = { [512] = true, [768] = true } }
  T.ok(ed:copy())
  ed:set_active("lane2")
  local c = ed:paste_at(16 * 256 + 4 * 256) -- pattern 2, line 4 (0-based)
  T.eq(c.description, "Multi Automation: Paste points")
  T.eq(#c.writes, 1)
  T.eq(c.writes[1].pattern, 2)
  T.ok(c.writes[1].create)
  T.eq(c.writes[1].points, pts({ 5 * 256, 0.1, 6 * 256, 0.9 }))
end)

T.test("cut removes the selection and fills the clipboard", function()
  local doc = one_lane_doc(pts({ 256, 0.2, 512, 0.4 }))
  local ed = setup(doc)
  ed.selection = { [1] = { [512] = true } }
  local c = ed:cut()
  T.eq(c.description, "Multi Automation: Cut points")
  T.eq(c.writes[1].points, pts({ 256, 0.2 }))
  T.eq(#ed.clipboard.clip.items, 1)
end)

T.test("paste across a pattern boundary splits the items", function()
  local doc = X.doc({
    { seq = 1, pattern = 1, lines = 16 },
    { seq = 2, pattern = 2, lines = 16 },
  }, { lanes = 1 })
  local ed = setup(doc)
  ed.clipboard.clip = { span = 512, items = { { dg = 0, v = 0.1, s = 0 }, { dg = 512, v = 0.2, s = 0 } } }
  local c = ed:paste_at(15 * 256)
  T.eq(#c.writes, 2)
end)

T.test("interpolation change writes playmode for editable patterns", function()
  local doc = one_lane_doc(pts({ 256, 0.2 }))
  local ed = setup(doc)
  local c = ed:set_playmode(3)
  T.eq(c.description, "Multi Automation: Change interpolation")
  T.eq(c.writes[1].playmode, 3)
  T.eq(ed:active_playmode(), 3)
  T.eq(ed:set_playmode(3), nil, "no change, no commit")
end)

T.test("neighbour patterns are read only", function()
  local doc = X.doc({
    { seq = 1, pattern = 1, lines = 16 },
    { seq = 2, pattern = 2, lines = 16 },
  }, { lanes = 1, editable = function(seq) return seq == 2 end })
  local ed = setup(doc)
  local p = doc.lanes[1].data[1].points[2]
  local x, y = pos(ed, 1, p.t, p.v)
  local fx = ed:mouse(ev("down", x, y))
  T.eq(fx.status, E.MSG_READ_ONLY)
  T.eq(ed.drag, nil)
  local fx2 = ed:mouse(ev("double", pos(ed, 1, 3000, 0.5)))
  T.eq(fx2.commit, nil)
end)

T.test("editing a repeated pattern warns about every occurrence", function()
  local doc = X.doc({
    { seq = 1, pattern = 1, lines = 16 },
    { seq = 2, pattern = 1, lines = 16 },
  }, { lanes = 1 })
  local ed = setup(doc)
  local x, y = pos(ed, 2, 3000, 0.5)
  local fx = ed:mouse(ev("double", x, y))
  T.ok(fx.commit)
  T.ok(fx.status and fx.status:find("every occurrence"), tostring(fx.status))
  T.eq(fx.commit.writes[1].pattern, 1)
end)

T.test("Tab cycles visible lanes", function()
  local doc = X.single(16, { lanes = 3 })
  doc.lanes[2].hidden = true
  local ed = setup(doc)
  T.eq(ed:key("tab", {}).activate, "lane3")
  T.eq(ed:key("tab", {}).activate, "lane1")
  T.eq(ed:key("tab", { shift = true }).activate, "lane3")
end)

T.test("tool keys and unhandled keys", function()
  local ed = setup(X.single(16, { lanes = 1 }))
  T.eq(ed:key("p", {}).tool, "pencil")
  T.eq(ed:key("l", {}).tool, "line")
  T.eq(ed:key("s", {}).tool, "select")
  T.eq(ed:key("e", {}).tool, "edit")
  T.eq(ed:key("space", {}), nil, "space goes back to Renoise")
  T.eq(ed:key("del", {}), nil, "nothing selected")
end)

T.test("Ctrl wheel zooms, wheel scrolls", function()
  local doc = X.single(64, { lanes = 1 })
  local ed = setup(doc)
  local span = ed.view.span_g
  local fx = ed:mouse({ type = "wheel", direction = "up", x = 100, y = 10, mods = { control = true } })
  T.ok(fx.view)
  T.ok(ed.view.span_g < span)
  local start = ed.view.start_g
  ed:mouse({ type = "wheel", direction = "down", x = 100, y = 10, mods = {} })
  T.ok(ed.view.start_g > start)
end)

T.test("Escape cancels a drag and restores points", function()
  local doc = one_lane_doc(pts({ 256, 0.5, 1024, 0.5 }))
  local ed = setup(doc)
  local x, y = pos(ed, 1, 1024, 0.5)
  ed:mouse(ev("down", x, y))
  ed:mouse(ev("drag", x + 100, y - 40))
  T.ok(doc.lanes[1].data[1].points[2].t ~= 1024)
  T.ok(ed:key("esc", {}))
  T.eq(doc.lanes[1].data[1].points, pts({ 256, 0.5, 1024, 0.5 }))
end)

T.test("hover reports the point label", function()
  local doc = one_lane_doc(pts({ 256, 0.5, 1024, 0.25 }))
  local ed = setup(doc)
  local x, y = pos(ed, 1, 1024, 0.25)
  local fx = ed:mouse(ev("move", x + 2, y + 2))
  T.ok(fx.hover and fx.hover.text:find("Pattern 0, line 3"), fx.hover and fx.hover.text)
  local fx2 = ed:mouse(ev("move", x + 2, y + 2))
  T.eq(fx2.hover, nil, "no update when unchanged")
end)

T.test("no lane: explicit empty state message", function()
  local doc = X.single(16, { lanes = 0 })
  local ed = setup(doc, { tool = "pencil" })
  ed.active_key = nil
  local fx = ed:mouse(ev("down", 10, 10))
  T.eq(fx.status, E.MSG_NO_LANE)
end)

T.test("vectorize switches a stepped lane to Lines and simplifies it", function()
  local list = {}
  for i = 0, 8 do list[#list + 1] = 256 + i * 256; list[#list + 1] = i / 8 end
  local doc = one_lane_doc(pts(list))
  doc.lanes[1].playmode = 1
  doc.lanes[1].data[1].playmode = 1
  local ed = setup(doc)
  local c, removed = ed:vectorize(0.01)
  T.eq(c.description, "Multi Automation: Vectorize")
  T.eq(#c.writes, 1)
  T.eq(c.writes[1].playmode, 2)
  T.eq(c.writes[1].points, pts({ 256, 0, 256 + 8 * 256, 1 }))
  T.eq(removed, 7)
  T.eq(ed:active_playmode(), 2)
  T.eq(E.vectorize_message(c, removed), "Vectorized: Lines, 7 points removed.")
  -- nothing left to do the second time
  T.eq(ed:vectorize(0.01), nil)
end)

T.test("vectorize with a selection only touches the selected points", function()
  local doc = one_lane_doc(pts({ 256, 0, 512, 0.25, 768, 0.5, 1024, 0.75, 1280, 1, 1536, 0 }))
  local ed = setup(doc)
  ed.selection = { [1] = { [512] = true, [768] = true } }
  local c, removed = ed:vectorize(0)
  T.eq(removed, 2)
  T.eq(c.writes[1].playmode, nil) -- already Lines
  T.eq(c.writes[1].points, pts({ 256, 0, 1024, 0.75, 1280, 1, 1536, 0 }))
  T.ok(not ed:has_selection())
end)


T.test("live writes: a drag is written while moving, throttled, as one batch", function()
  local doc = one_lane_doc(pts({ 256, 0.5, 1024, 0.5, 2048, 0.5 }))
  local ed = setup(doc)
  local now = 0
  ed.clock = function() return now end
  local x, y = pos(ed, 1, 1024, 0.5)
  ed:mouse(ev("down", x, y))
  local x2, y2 = pos(ed, 1, 1024, 0.7)
  local fx = ed:mouse(ev("drag", x2, y2))
  T.ok(fx.commit, "first drag event writes")
  T.eq(fx.commit.batch, true)
  T.eq(fx.commit.description, "Multi Automation: Move points")
  T.near(fx.commit.writes[1].points[2].v, 0.7, 0.01)
  now = 0.01
  fx = ed:mouse(ev("drag", x2, y2 - 5))
  T.eq(fx.commit, nil, "throttled")
  now = 0.1
  fx = ed:mouse(ev("drag", x2, y2 - 10))
  T.ok(fx.commit, "written again after the interval")
  fx = ed:mouse(ev("up", x2, y2 - 10))
  T.eq(fx.commit.batch, true, "final write joins the same batch")
end)

T.test("live writes off: only the final commit, not batched", function()
  local doc = one_lane_doc(pts({ 256, 0.5, 1024, 0.5 }))
  local ed = setup(doc)
  ed.live_writes = false
  local x, y = pos(ed, 1, 1024, 0.5)
  ed:mouse(ev("down", x, y))
  local fx = ed:mouse(ev("drag", x, y - 30))
  T.eq(fx.commit, nil)
  fx = ed:mouse(ev("up", x, y - 30))
  T.eq(fx.commit.batch, false)
end)

T.test("Esc after live writes restores the song", function()
  local doc = one_lane_doc(pts({ 256, 0.5, 1024, 0.5 }))
  local ed = setup(doc)
  ed.clock = function() return 0 end
  local x, y = pos(ed, 1, 1024, 0.5)
  ed:mouse(ev("down", x, y))
  ed:mouse(ev("drag", x, y - 30))
  local fx = ed:key("esc", {})
  T.ok(fx.commit, "restore commit")
  T.eq(fx.commit.writes[1].points, pts({ 256, 0.5, 1024, 0.5 }))
  T.eq(fx.commit.batch, true)
end)

T.test("live pencil stroke writes while drawing", function()
  local doc = one_lane_doc({})
  local ed = setup(doc, { tool = "pencil" })
  ed.clock = function() return 0 end
  local x, y = pos(ed, 1, 256, 0.2)
  ed:mouse(ev("down", x, y))
  local x2, y2 = pos(ed, 1, 256 * 4, 0.6)
  local fx = ed:mouse(ev("drag", x2, y2))
  T.ok(fx.commit)
  T.eq(fx.commit.description, "Multi Automation: Draw")
  T.ok(#fx.commit.writes[1].points >= 3)
end)

T.test("V shows a preview, the wheel changes the tolerance, Enter applies", function()
  local list = {}
  for i = 0, 8 do list[#list + 1] = 256 + i * 256; list[#list + 1] = (i % 2 == 0) and 0.5 or 0.53 end
  local doc = one_lane_doc(pts(list))
  doc.lanes[1].data[1].playmode = 1
  local ed = setup(doc)
  ed.vectorize_tolerance = 0.01
  local fx = ed:key("v", {})
  T.eq(fx.commit, nil, "preview does not write")
  T.ok(fx.status:find("^Vectorize preview: 9 to 9 points, tolerance 1 %%"), fx.status)
  T.eq(#ed:preview_points()[1], 9)
  -- wheel up raises the tolerance: 2 % keeps the 3 % wiggle, 3 % removes it
  fx = ed:mouse({ type = "wheel", x = 100, y = 100, direction = "up", mods = {} })
  T.near(ed.vec_preview.tol, 0.02, 1e-9)
  T.eq(fx.tolerance, 0.02)
  T.ok(#ed:preview_points()[1] > 2, "3 % wiggle still visible at 2 %")
  fx = ed:mouse({ type = "wheel", x = 100, y = 100, direction = "up", mods = {} })
  T.eq(#ed:preview_points()[1], 2)
  T.ok(fx.status:find("9 to 2 points"), fx.status)
  fx = ed:key("return", {})
  T.eq(fx.commit.description, "Multi Automation: Vectorize")
  T.eq(fx.commit.writes[1].playmode, 2)
  T.eq(#fx.commit.writes[1].points, 2)
  T.eq(ed.vec_preview, nil)
end)

T.test("Esc or right click cancels the preview without writing", function()
  local doc = one_lane_doc(pts({ 256, 0, 512, 0.5, 768, 1 }))
  local ed = setup(doc)
  ed:key("v", {})
  local fx = ed:key("esc", {})
  T.eq(fx.commit, nil)
  T.eq(ed.vec_preview, nil)
  ed:key("v", {})
  fx = ed:mouse(ev("down", 100, 100, "right"))
  T.eq(fx.commit, nil)
  T.eq(ed.vec_preview, nil)
  ed:key("v", {})
  fx = ed:mouse(ev("down", 100, 100, "left"))
  T.ok(fx.commit, "left click applies")
end)

T.test("points move across a pattern border in Pattern range mode", function()
  local doc = X.doc({
    { seq = 1, pattern = 1, lines = 16 },
    { seq = 2, pattern = 2, lines = 16 },
  }, { lanes = 1, points = 0 })
  local lane = doc.lanes[1]
  lane.playmode = 2
  lane.data[1] = { points = pts({ 256, 0.2, 256 * 15, 0.6 }), exists = true, rev = 1, lines = 16, playmode = 2 }
  lane.data[2] = { points = pts({ 256, 0.4 }), exists = true, rev = 1, lines = 16, playmode = 2 }
  local ed = setup(doc)
  ed.live_writes = false
  -- grab the point at line 14 of pattern 1 and drag it 4 lines right: line 2 of pattern 2
  local x, y = pos(ed, 1, 256 * 15, 0.6)
  ed:mouse(ev("down", x, y))
  local x2 = G.g_to_x(ed.view, 16 * 256 + 2 * 256)
  ed:mouse(ev("drag", x2, y))
  local fx = ed:mouse(ev("up", x2, y))
  local by = {}
  for _, w in ipairs(fx.commit.writes) do by[w.pattern] = w.points end
  T.eq(by[1], pts({ 256, 0.2 }), "removed from pattern 1")
  T.eq(by[2], pts({ 256, 0.4, 256 * 3, 0.6 }), "added to pattern 2 at line 2")
  T.ok(ed.selection[2] and ed.selection[2][256 * 3], "selection follows the point")
end)

T.test("neighbour patterns stay read only when moving", function()
  local doc = X.doc({
    { seq = 1, pattern = 1, lines = 16 },
    { seq = 2, pattern = 2, lines = 16 },
  }, { lanes = 1, points = 0, editable = function(seq) return seq == 1 end })
  local lane = doc.lanes[1]
  lane.data[1] = { points = pts({ 256 * 15, 0.6 }), exists = true, rev = 1, lines = 16, playmode = 2 }
  local ed = setup(doc)
  ed.live_writes = false
  local x, y = pos(ed, 1, 256 * 15, 0.6)
  ed:mouse(ev("down", x, y))
  local x2 = G.g_to_x(ed.view, 20 * 256)
  ed:mouse(ev("drag", x2, y))
  local fx = ed:mouse(ev("up", x2, y))
  T.eq(#fx.commit.writes, 1)
  T.eq(fx.commit.writes[1].pattern, 1)
  T.eq(fx.commit.writes[1].points[1].t, 16 * 256, "clamped to the last line of the editable pattern")
end)
