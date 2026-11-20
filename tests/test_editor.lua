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

T.test("right click opens the menu without deleting; Alt click deletes", function()
  local doc = one_lane_doc(pts({ 256, 0.1, 512, 0.2, 768, 0.3 }))
  local ed = setup(doc)
  local x, y = pos(ed, 1, 512, 0.2)
  local fx = ed:mouse(ev("down", x, y, "right"))
  T.eq(fx.commit, nil, "nothing deleted")
  T.eq(fx.menu, nil, "not on press")
  T.eq(ed:mouse(ev("up", x, y, "right")).menu, "context", "menu on release")
  T.ok(ed.selection[1][512], "the point under the mouse is selected")
  T.eq(#doc.lanes[1].data[1].points, 3)
  ed:mouse(ev("down", 10, 10, "right"))
  T.eq(ed:mouse(ev("up", 10, 10, "right")).menu, "context", "menu on empty space too")
  local x2, y2 = pos(ed, 1, 768, 0.3)
  local fx2 = ed:mouse(ev("down", x2, y2, "left", { alt = true }))
  T.eq(fx2.commit.writes[1].points, pts({ 256, 0.1, 512, 0.2 }))
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

T.test("neighbor patterns are read only: a click selects them instead of editing", function()
  local doc = X.doc({
    { seq = 1, pattern = 1, lines = 16 },
    { seq = 2, pattern = 2, lines = 16 },
  }, { lanes = 1, editable = function(seq) return seq == 2 end })
  local ed = setup(doc)
  local p = doc.lanes[1].data[1].points[2]
  local x, y = pos(ed, 1, p.t, p.v)
  local fx = ed:mouse(ev("down", x, y))
  T.eq(fx.goto_seq, 1)
  T.eq(fx.commit, nil)
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
  T.eq(ed:key("s", {}).tool, "range")
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

T.test("neighbor patterns stay read only when moving", function()
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

local function two_lane_range_doc()
  local doc = X.doc({
    { seq = 1, pattern = 1, lines = 16 },
    { seq = 2, pattern = 2, lines = 16 },
  }, { lanes = 2, points = 0 })
  for i = 1, 2 do
    local lane = doc.lanes[i]
    lane.playmode = 2
    lane.data[1] = { points = pts({ 256, 0.1 * i, 256 * 5, 0.2 * i, 256 * 9, 0.3 * i }), exists = true, rev = 1, lines = 16, playmode = 2 }
    lane.data[2] = { points = pts({ 256, 0.4 }), exists = true, rev = 1, lines = 16, playmode = 2 }
  end
  return doc
end

T.test("Range tool selects a time range over every visible lane", function()
  local doc = two_lane_range_doc()
  local ed = setup(doc, { tool = "range" })
  local xa = G.g_to_x(ed.view, 3 * 256)
  local xb = G.g_to_x(ed.view, 6 * 256)
  ed:mouse(ev("down", xa, 50))
  ed:mouse(ev("drag", xb, 50))
  local fx = ed:mouse(ev("up", xb, 50))
  T.eq(ed.range, { 3 * 256, 6 * 256 })
  T.ok(fx.status:find("^Range: Pat 0 line 3 to Pat 0 line 6, 2 lanes"), fx.status)
  -- delete removes the line 4 point of both lanes in one commit
  fx = ed:key("del", {})
  T.eq(fx.commit.description, "Multi Automation: Delete range")
  T.eq(#fx.commit.writes, 2)
  for _, w in ipairs(fx.commit.writes) do T.eq(#w.points, 2) end
end)

T.test("Range copy and paste moves a passage of every lane", function()
  local doc = two_lane_range_doc()
  local ed = setup(doc, { tool = "range" })
  ed.range = { 4 * 256, 9 * 256 }
  ed:key("c", { control = true })
  T.eq(ed.clipboard.last, "range")
  ed.cursor_g = 16 * 256 + 2 * 256 -- line 2 of pattern 2
  local fx = ed:key("v", { control = true })
  T.eq(fx.commit.description, "Multi Automation: Paste range")
  local by = {}
  for _, w in ipairs(fx.commit.writes) do by[w.key .. ":" .. w.pattern] = w.points end
  T.eq(by["lane1:2"], pts({ 256, 0.4, 256 * 3, 0.2, 256 * 7, 0.3 }))
  T.eq(by["lane2:2"], pts({ 256, 0.4, 256 * 3, 0.4, 256 * 7, 0.6 }))
end)

T.test("Range shift moves the content and the range", function()
  local doc = two_lane_range_doc()
  local ed = setup(doc, { tool = "range" })
  ed.range = { 4 * 256, 4 * 256 + 255 }
  local fx = ed:key("right", {})
  T.eq(fx.commit.description, "Multi Automation: Shift range")
  T.eq(ed.range[1], 5 * 256)
  local p = doc.lanes[1].data[1].points
  T.eq(p, pts({ 256, 0.1, 256 * 6, 0.2, 256 * 9, 0.3 }))
end)

T.test("hidden lanes are left out of range edits; Esc clears the range", function()
  local doc = two_lane_range_doc()
  doc.lanes[2].hidden = true
  local ed = setup(doc, { tool = "range" })
  ed.range = { 3 * 256, 6 * 256 }
  local fx = ed:key("del", {})
  T.eq(#fx.commit.writes, 1)
  T.eq(fx.commit.writes[1].key, "lane1")
  ed:key("esc", {})
  T.eq(ed.range, nil)
end)

T.test("process: flip, mirror and humanize the selection", function()
  local doc = one_lane_doc(pts({ 256, 0.1, 512, 0.2, 768, 0.9, 1024, 0.5 }))
  local ed = setup(doc)
  ed.selection = { [1] = { [256] = true, [768] = true } }
  local c = ed:process("flip")
  T.eq(c.description, "Multi Automation: Flip selection")
  local p = c.writes[1].points
  T.near(p[1].v, 0.9, 1e-9)
  T.near(p[2].v, 0.8, 1e-9)
  T.near(p[3].v, 0.1, 1e-9)
  T.near(p[4].v, 0.5, 1e-9, "outside the span: untouched")
  doc = one_lane_doc(pts({ 256, 0.1, 512, 0.2, 1024, 0.9 }))
  ed = setup(doc)
  ed.range = { 0, 768 }
  p = ed:process("mirror").writes[1].points
  T.eq(p, pts({ 256, 0.9, 768, 0.2, 1024, 0.1 }))
  ed.random = function() return 1 end
  p = ed:process("humanize").writes[1].points
  T.near(p[1].v, 0.95, 1e-9)
end)

T.test("process: create curves over the selected time or the pattern", function()
  local doc = one_lane_doc(pts({ 256, 0.5 }), 16)
  local ed = setup(doc, { snap = true, grid = 256 })
  ed.range = { 0, 256 * 4 }
  local p = ed:process("linear").writes[1].points
  T.eq(p, pts({ 256, 0, 256 * 5, 1 }))
  p = ed:process("exponential").writes[1].points
  T.eq(#p, 5)
  T.near(p[3].v, 0.125, 1e-9)
  T.eq(p[5].v, 1)
  p = ed:process("sine").writes[1].points
  T.near(p[2].v, 1, 1e-9, "quarter period at the top")
  ed.range = nil
  ed.random = function() return 0.25 end
  p = ed:process("random").writes[1].points
  T.eq(#p, 16, "one point per line over the whole pattern")
  T.eq(p[1].v, 0.25)
end)

T.test("paste continuously and insert paste", function()
  local doc = one_lane_doc(pts({ 256, 0.1, 512, 0.2, 256 * 12, 0.7 }), 16)
  local ed = setup(doc, { snap = true, grid = 256 })
  ed.selection = { [1] = { [256] = true, [512] = true } }
  ed:copy()
  ed.cursor_g = 256 * 8
  local c = ed:paste_continuously()
  T.eq(c.description, "Multi Automation: Paste continuously")
  local p = c.writes[1].points
  -- clip of 2 points, period 2 lines: lines 8, 9, 10, 11, 12, 13, 14, 15
  T.eq(#p, 2 + 8)
  T.eq(p[#p].t, 256 * 16)
  doc = one_lane_doc(pts({ 256, 0.1, 512, 0.2, 256 * 5, 0.7 }), 16)
  ed = setup(doc, { snap = true, grid = 256 })
  ed.selection = { [1] = { [256] = true, [512] = true } }
  ed:copy()
  ed.cursor_g = 256 * 2
  c = ed:insert_paste()
  T.eq(c.description, "Multi Automation: Insert paste")
  p = c.writes[1].points
  T.eq(p, pts({ 256, 0.1, 512, 0.2, 256 * 3, 0.1, 256 * 4, 0.2, 256 * 7, 0.7 }), "line 4 point pushed 2 lines right")
end)

T.test("cut selected time pulls the rest to the left", function()
  local doc = one_lane_doc(pts({ 256, 0.1, 256 * 3, 0.2, 256 * 4, 0.3, 256 * 9, 0.7 }), 16)
  local ed = setup(doc)
  ed.range = { 256 * 2, 256 * 3 + 255 }
  local c = ed:cut_time()
  T.eq(c.description, "Multi Automation: Cut selected time")
  T.eq(c.writes[1].points, pts({ 256, 0.1, 256 * 7, 0.7 }))
  T.eq(ed.clipboard.last, "range")
  T.eq(ed.range, nil)
end)

T.test("delete envelope removes the automation of the editable patterns", function()
  local doc = one_lane_doc(pts({ 256, 0.1 }))
  local ed = setup(doc)
  local c = ed:delete_envelope()
  T.eq(c.description, "Multi Automation: Delete envelope")
  T.eq(c.writes[1].delete, true)
  T.eq(doc.lanes[1].data[1].exists, false)
end)

T.test("context shortcuts: Ctrl + K, F, Shift + F, R, P, I", function()
  local doc = one_lane_doc(pts({ 256, 0.1, 512, 0.2, 768, 0.9 }), 16)
  local ed = setup(doc)
  ed.range = { 256, 768 }
  T.eq(ed:key("f", { control = true }).commit.description, "Multi Automation: Flip selection")
  T.eq(ed:key("f", { control = true, shift = true }).commit.description, "Multi Automation: Mirror selection")
  T.eq(ed:key("r", { control = true }).commit.description, "Multi Automation: Humanize selection")
  T.eq(ed:key("k", { control = true }).commit.description, "Multi Automation: Cut selected time")
  ed.cursor_g = 256 * 4
  T.eq(ed:key("p", { control = true }).commit.description, "Multi Automation: Paste continuously")
  T.eq(ed:key("i", { control = true }).commit.description, "Multi Automation: Insert paste")
end)

local function two_pattern_doc(a_points, b_points)
  local doc = X.doc({
    { seq = 1, pattern = 1, lines = 16 },
    { seq = 2, pattern = 2, lines = 16 },
  }, { lanes = 1, points = 0 })
  local lane = doc.lanes[1]
  lane.playmode = 2
  lane.data[1] = { points = pts(a_points), exists = true, rev = 1, lines = 16, playmode = 2 }
  lane.data[2] = { points = pts(b_points), exists = true, rev = 1, lines = 16, playmode = 2 }
  return doc
end

T.test("magnet: a point dragged near the pattern end sticks to the border and the next value", function()
  local doc = two_pattern_doc({ 256, 0.2, 256 * 14, 0.5 }, { 256, 0.8, 256 * 8, 0.1 })
  local ed = setup(doc, { snap = true, grid = 256 })
  ed.live_writes = false
  local x, y = pos(ed, 1, 256 * 14, 0.5)
  ed:mouse(ev("down", x, y))
  -- 3 px before the border, a little under the next pattern's first value
  local bx = G.g_to_x(ed.view, 16 * 256 - 1) - 3
  local by = G.v_to_y(ed.view, 0.8) + 3
  ed:mouse(ev("drag", bx, by))
  local fx = ed:mouse(ev("up", bx, by))
  local p
  for _, w in ipairs(fx.commit.writes) do if w.pattern == 1 then p = w.points end end
  T.eq(p[#p].t, P.max_t(16), "on the last 1/256 of the pattern")
  T.eq(p[#p].v, 0.8, "value of the next pattern at the border")
end)

T.test("magnet: Shift turns it off; far from a border nothing changes", function()
  local doc = two_pattern_doc({ 256, 0.2, 256 * 14, 0.5 }, { 256, 0.8 })
  local ed = setup(doc, { snap = true, grid = 256 })
  local g, v, hit = ed:magnet(8 * 256, 0.3)
  T.eq(hit, false)
  T.eq(g, 8 * 256)
  g, v, hit = ed:magnet(16 * 256 + 2, 0.31)
  T.eq(hit, true)
  T.eq(g, 16 * 256, "start of the second pattern")
  T.eq(v, 0.31, "value too far from the previous pattern's end: kept")
end)

T.test("link patterns: border points on the line between the two patterns", function()
  -- last point of pattern 1 at line 12 (0.2), first of pattern 2 at line 4 (0.6)
  local doc = two_pattern_doc({ 256, 0.1, 256 * 13, 0.2 }, { 256 * 5, 0.6, 256 * 9, 0.4 })
  local ed = setup(doc)
  ed.link_patterns = true
  local c = ed:link_all()
  T.eq(c.description, "Multi Automation: Link patterns")
  local a, b = doc.lanes[1].data[1].points, doc.lanes[1].data[2].points
  local ga, gb = 12 * 256, 16 * 256 + 4 * 256
  local function on_line(g) return 0.2 + 0.4 * (g - ga) / (gb - ga) end
  T.eq(a[#a].t, P.max_t(16))
  T.near(a[#a].v, on_line(16 * 256 - 1), 1e-9)
  T.eq(b[1].t, P.min_t())
  T.near(b[1].v, on_line(16 * 256), 1e-9)
  T.eq(ed:link_all(), nil, "already linked")
  -- an edit of the last real point updates the border points in the same commit
  ed.selection = { [1] = { [256 * 13] = true } }
  local s = ed:shift_selection(-256)
  ed:add_links(s)
  local pa = nil
  for _, w in ipairs(s.writes) do if w.pattern == 2 then pa = w end end
  T.ok(pa, "pattern 2 border updated in the same undo step")
end)

T.test("link patterns: neighbor patterns stay read only", function()
  local doc = X.doc({
    { seq = 1, pattern = 1, lines = 16 },
    { seq = 2, pattern = 2, lines = 16 },
  }, { lanes = 1, points = 0, editable = function(seq) return seq == 1 end })
  local lane = doc.lanes[1]
  lane.data[1] = { points = pts({ 256 * 13, 0.2 }), exists = true, rev = 1, lines = 16, playmode = 2 }
  lane.data[2] = { points = pts({ 256 * 5, 0.6 }), exists = true, rev = 1, lines = 16, playmode = 2 }
  local ed = setup(doc)
  ed.link_patterns = true
  local c = ed:link_all()
  T.eq(#c.writes, 1)
  T.eq(c.writes[1].pattern, 1)
  T.eq(#lane.data[2].points, 1, "neighbor untouched")
end)

T.test("double-click on a point deletes it, on empty space adds one", function()
  local doc = one_lane_doc(pts({ 256, 0.1, 512 + 256, 0.5, 2048, 0.3 }))
  local ed = setup(doc)
  local x, y = pos(ed, 1, 768, 0.5)
  -- a double-click arrives after a down / up pair on the same spot
  ed:mouse(ev("down", x, y))
  ed:mouse(ev("up", x, y))
  local fx = ed:mouse(ev("double", x, y))
  T.eq(fx.commit.description, "Multi Automation: Delete point")
  T.eq(fx.commit.writes[1].points, pts({ 256, 0.1, 2048, 0.3 }))
  local x2, y2 = pos(ed, 1, 1280, 0.7)
  fx = ed:mouse(ev("double", x2, y2))
  T.eq(fx.commit.description, "Multi Automation: Add point")
end)

T.test("a click in a gray neighbor pattern asks to select it", function()
  local doc = X.doc({
    { seq = 1, pattern = 1, lines = 16 },
    { seq = 2, pattern = 4, lines = 16 },
  }, { lanes = 1, points = 0, editable = function(seq) return seq == 1 end })
  doc.lanes[1].data[1] = { points = pts({ 256, 0.2 }), exists = true, rev = 1, lines = 16, playmode = 2 }
  local ed = setup(doc)
  local fx = ed:mouse(ev("down", G.g_to_x(ed.view, 20 * 256), 100))
  T.eq(fx.goto_seq, 2)
  T.eq(fx.status, "Pattern 3 (sequence 1) selected.")
  T.eq(fx.commit, nil)
  fx = ed:mouse(ev("down", G.g_to_x(ed.view, 4 * 256), 100))
  T.eq(fx.goto_seq, nil, "editable pattern: normal click")
end)
