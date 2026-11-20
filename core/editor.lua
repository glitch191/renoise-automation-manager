-- Pure edit session: mouse and keyboard gestures, tools, selection and
-- clipboard. Works on an in-memory document and never calls the Renoise API.
--
-- Every gesture updates the local document immediately (preview) and, when it
-- ends, returns a commit that the bridge writes into the song as a single undo
-- step:
--   commit = { description, batch = boolean,
--              writes = { { key, pattern, points = list | nil, playmode = n | nil,
--                           create = boolean } } }
--
-- Document:
--   doc.timeline = core.timeline result
--   doc.lanes    = { { key, name, color, hidden, playmode, info,
--                      data = { [pattern] = { points, exists, rev, lines, playmode } } } }

local P = require "core.points"
local T = require "core.timeline"
local G = require "core.geometry"
local H = require "core.hittest"
local I = require "core.interp"
local F = require "core.valuefmt"
local R = require "core.render"

local E = {}
E.__index = E

E.TOOLS = { "edit", "pencil", "line", "select" }
E.TOOL_LABELS = { "Edit", "Pencil", "Line", "Select" }
E.TOOL_KEYS = { e = "edit", p = "pencil", l = "line", s = "select" }
-- Snap grid resolutions in sub-units: 1 line, 1/2, 1/4, 1/8, free.
E.GRIDS = { 256, 128, 64, 32, 1 }
E.GRID_LABELS = { "Line", "1/2", "1/4", "1/8", "Free" }

E.MSG_NO_LANE = "No automation on this track. Use Add lane to create one."
E.MSG_NO_ACTIVE = "No active lane. Click a curve or a legend row first."
E.MSG_READ_ONLY = "Neighbour patterns are read only. Edit the center pattern."
E.MSG_LINE_END = "Line: click the end point."
E.LIVE_INTERVAL = 0.05 -- seconds between two live writes during a gesture

local DESC = "Multi Automation: "

function E.new(opts)
  opts = opts or {}
  local self = setmetatable({}, E)
  self.doc = nil
  self.view = opts.view
  self.dims = opts.dims
  self.cache = opts.cache or R.new_cache()
  self.tool = opts.tool or "edit"
  self.snap = (opts.snap ~= false)
  self.grid = opts.grid or 256
  self.active_key = nil
  self.selection = {} -- [pattern] = { [t] = true } for the active lane
  self.drag = nil
  self.hover_id = nil
  self.clipboard = opts.clipboard or { clip = nil }
  self.cursor_g = nil
  self.line_anchor = nil
  self.just_activated = false
  self.vectorize_tolerance = opts.vectorize_tolerance or 0.02
  -- live writes: drags and pencil strokes are written to the song while the
  -- mouse moves (throttled), all in one batch undo step
  self.live_writes = (opts.live_writes ~= false)
  self.clock = opts.clock or os.clock
  self.last_live = nil
  return self
end

--------------------------------------------------------------------------------
-- document helpers

function E:set_doc(doc)
  self.doc = doc
  self.drag = nil
  self.line_anchor = nil
  if self.active_key and not self:lane(self.active_key) then self.active_key = nil end
  if self.vec_preview then
    if self.vec_preview.key ~= self.active_key then
      self.vec_preview = nil
    else
      self.vec_preview.plan = self:vectorize_plan(self.vec_preview.tol)
      if not self.vec_preview.plan then self.vec_preview = nil end
    end
  end
  -- keep only selected times that still exist
  local lane = self:active_lane()
  local sel = {}
  if lane then
    for pattern, set in pairs(self.selection) do
      local data = lane.data[pattern]
      if data then
        local keep = {}
        for i = 1, #data.points do
          if set[data.points[i].t] then keep[data.points[i].t] = true end
        end
        if next(keep) then sel[pattern] = keep end
      end
    end
  end
  self.selection = sel
end

function E:lane(key)
  if not self.doc or not key then return nil end
  local lanes = self.doc.lanes
  for i = 1, #lanes do
    if lanes[i].key == key then return lanes[i] end
  end
  return nil
end

function E:active_lane()
  local lane = self:lane(self.active_key)
  if lane and not lane.hidden then return lane end
  return nil
end

function E:visible_lanes()
  local out = {}
  if not self.doc then return out end
  for i = 1, #self.doc.lanes do
    if not self.doc.lanes[i].hidden then out[#out + 1] = self.doc.lanes[i] end
  end
  return out
end

function E:set_active(key)
  if key ~= self.active_key then
    self.active_key = key
    self.selection = {}
    self.vec_preview = nil
  end
end

function E:has_selection()
  for _, set in pairs(self.selection) do
    if next(set) then return true end
  end
  return false
end

local function ensure_data(lane, seg)
  local d = lane.data[seg.pattern]
  if not d then
    d = { points = {}, exists = false, rev = 0, lines = seg.lines, playmode = lane.playmode }
    lane.data[seg.pattern] = d
  end
  return d
end

local function set_points(lane, pattern, points)
  local d = lane.data[pattern]
  d.points = points
  d.rev = (d.rev or 0) + 1
end

local function new_commit(desc, batch)
  return { description = DESC .. desc, batch = batch or false, writes = {} }
end

local function put_write(commit, lane, pattern, points)
  local d = lane.data[pattern]
  for i = 1, #commit.writes do
    local w = commit.writes[i]
    if w.key == lane.key and w.pattern == pattern then
      w.points = points
      return
    end
  end
  commit.writes[#commit.writes + 1] = {
    key = lane.key, pattern = pattern, points = points,
    create = not d.exists, playmode = (not d.exists) and (d.playmode or lane.playmode) or nil,
  }
end

local function set_of(list)
  local s = {}
  for i = 1, #list do s[list[i]] = true end
  return s
end

local function list_of(set)
  local l = {}
  for t in pairs(set) do l[#l + 1] = t end
  table.sort(l)
  return l
end

function E:segments()
  return (self.doc and self.doc.timeline.segments) or {}
end

function E:total_g()
  return (self.doc and self.doc.timeline.total_g) or 256
end

function E:clamp_g(g)
  local total = self:total_g()
  if g < 0 then return 0 end
  if g > total - 1 then return total - 1 end
  return g
end

function E:grid_now(mods)
  if self.snap and not (mods and mods.shift) then return self.grid end
  return 1
end

function E:first_segment_of(pattern, editable_only)
  local segs = self:segments()
  for i = 1, #segs do
    if segs[i].pattern == pattern and (segs[i].editable or not editable_only) then return segs[i] end
  end
  return nil
end

-- Status message when a commit touches a pattern used several times.
function E:alias_message(commit)
  local segs = self:segments()
  for i = 1, #commit.writes do
    local pattern = commit.writes[i].pattern
    for k = 1, #segs do
      local s = segs[k]
      if s.pattern == pattern and s.repeated then
        return string.format("Pattern %d is used several times in the sequence: this edit changes every occurrence.", pattern - 1)
      elseif s.pattern == pattern and s.track_alias then
        return string.format("This pattern track is an alias: the edit is written to pattern %d.", pattern - 1)
      end
    end
  end
  return nil
end

--------------------------------------------------------------------------------
-- hit testing

-- Point of the active lane under (x, y): { lane, seg, pattern, t, v, x, y }.
function E:hit_point(x, y)
  local lane = self:active_lane()
  if not lane then return nil end
  local view, r = self.view, self.dims.hit_radius
  local items = {}
  local vis = R.visible_segments(view, self:segments())
  for i = 1, #vis do
    local s = vis[i]
    local data = lane.data[s.pattern]
    if data and data.exists or (data and #data.points > 0) then
      local base = s.offset - P.UNITS
      for k = 1, #data.points do
        local p = data.points[k]
        local px = G.g_to_x(view, base + p.t)
        if math.abs(px - x) <= r then
          items[#items + 1] = { x = px, y = G.v_to_y(view, p.v), lane = lane, seg = s, pattern = s.pattern, t = p.t, v = p.v }
        end
      end
    end
  end
  return H.nearest(items, x, y, r)
end

local function lane_distance(self, lane, x, y)
  local best = math.huge
  local vis = R.visible_segments(self.view, self:segments())
  for i = 1, #vis do
    local s = vis[i]
    local data = lane.data[s.pattern]
    if data and #data.points > 0 then
      local xy = R.to_pixels(self.view, s, R.samples(self.cache, lane.key, s.pattern, data, data.playmode or lane.playmode))
      local d = H.dist_polyline(xy, x, y)
      if d < best then best = d end
    end
  end
  return best
end

-- Key of the inactive visible lane closest to (x, y) within the hit radius,
-- or nil when the active lane is at least as close.
function E:hit_lane(x, y)
  local r = self.dims.hit_radius
  local best_key, best_d = nil, math.huge
  local lanes = self:visible_lanes()
  for i = 1, #lanes do
    local d = lane_distance(self, lanes[i], x, y)
    if d < best_d then best_key, best_d = lanes[i].key, d end
  end
  if best_key and best_d <= r and best_key ~= self.active_key then
    local active = self:active_lane()
    if active and lane_distance(self, active, x, y) <= best_d then return nil end
    return best_key
  end
  return nil
end

function E:label_for(lane, pattern, t, v)
  return F.label(lane.name, pattern, t, lane.info, v)
end

--------------------------------------------------------------------------------
-- mouse

function E:mouse(ev)
  local fx = {}
  if not self.doc then return fx end
  ev.mods = ev.mods or {}
  local kind = ev.type
  if kind ~= "exit" then self.cursor_g = self:clamp_g(G.x_to_g(self.view, ev.x)) end
  local pfx = self:preview_mouse(ev)
  if pfx then return pfx end
  if kind == "move" then
    return self:on_hover(ev, fx)
  elseif kind == "exit" then
    if self.hover_id then
      self.hover_id = nil
      fx.hover = false
    end
    return fx
  elseif kind == "wheel" then
    return self:on_wheel(ev, fx)
  elseif kind == "down" then
    return self:on_down(ev, fx)
  elseif kind == "drag" then
    return self:on_drag(ev, fx)
  elseif kind == "up" then
    return self:on_up(ev, fx)
  elseif kind == "double" then
    return self:on_double(ev, fx)
  end
  return fx
end

function E:on_hover(ev, fx)
  if self.drag then return fx end
  local p = self:hit_point(ev.x, ev.y)
  local id = p and (p.pattern .. ":" .. p.t .. ":" .. p.seg.index) or nil
  if id ~= self.hover_id then
    self.hover_id = id
    if p then
      fx.hover = { x = p.x, y = p.y, text = self:label_for(p.lane, p.pattern, p.t, p.v), color = p.lane.color }
    else
      fx.hover = false
    end
  end
  return fx
end

function E:on_wheel(ev, fx)
  local total = self:total_g()
  local up = (ev.direction == "up" or ev.direction == "left")
  if ev.mods.control then
    G.zoom_at(self.view, up and 1.25 or 0.8, ev.x, total)
    fx.view = true
  elseif ev.mods.alt and self:has_selection() then
    local c = self:scale_selection(up and 1.05 or (1 / 1.05), ev.mods.shift and "bottom" or "center", true)
    if c then fx.commit = c end
    fx.redraw = true
  else
    G.scroll(self.view, (up and -1 or 1) * self.view.span_g * 0.1, total)
    fx.view = true
  end
  return fx
end

function E:on_down(ev, fx)
  local x, y = ev.x, ev.y
  local was_activated = self.just_activated
  self.just_activated = false
  if self.drag then return fx end

  -- delete: right click or Alt + left click on a point of the active lane
  if ev.button == "right" or (ev.button == "left" and ev.mods.alt) then
    local p = self:hit_point(x, y)
    if p then
      if not p.seg.editable then
        fx.status = E.MSG_READ_ONLY
        return fx
      end
      local c = new_commit("Delete point")
      set_points(p.lane, p.pattern, P.remove_times(p.lane.data[p.pattern].points, { p.t }))
      put_write(c, p.lane, p.pattern, p.lane.data[p.pattern].points)
      if self.selection[p.pattern] then self.selection[p.pattern][p.t] = nil end
      self.hover_id = nil
      fx.hover = false
      fx.commit = c
      fx.status = self:alias_message(c)
      fx.redraw = true
      return fx
    end
    if ev.button == "right" and self:has_selection() then fx.menu = "selection" end
    return fx
  end
  if ev.button ~= "left" then return fx end

  local tool = self.tool
  if tool == "edit" or tool == "select" then
    local p = self:hit_point(x, y)
    if p then
      if not p.seg.editable then
        fx.status = E.MSG_READ_ONLY
        return fx
      end
      local sel = self.selection[p.pattern]
      if not (sel and sel[p.t]) then
        if not ev.mods.shift then self.selection = {} end
        self.selection[p.pattern] = self.selection[p.pattern] or {}
        self.selection[p.pattern][p.t] = true
      end
      local snap, times = {}, {}
      for pattern, set in pairs(self.selection) do
        if p.lane.data[pattern] then
          snap[pattern] = P.copy(p.lane.data[pattern].points)
          times[pattern] = list_of(set)
        end
      end
      self.drag = { kind = "move", x0 = x, y0 = y, snap = snap, times = times,
        anchor = { pattern = p.pattern, t = p.t, v = p.v, lines = p.seg.lines, seg = p.seg },
        dt = 0, dv = 0 }
      fx.redraw = true
      return fx
    end
    local key = self:hit_lane(x, y)
    if key then
      self:set_active(key)
      self.just_activated = true
      fx.activate = key
      fx.redraw = true
      return fx
    end
    if not ev.mods.shift and self:has_selection() then
      self.selection = {}
      fx.redraw = true
    end
    self.drag = { kind = "rect", x0 = x, y0 = y, x1 = x, y1 = y, add = ev.mods.shift }
    return fx
  end

  local lane = self:active_lane()
  if not lane then
    fx.status = (#self:visible_lanes() == 0) and E.MSG_NO_LANE or E.MSG_NO_ACTIVE
    return fx
  end
  local grid = self:grid_now(ev.mods)
  local g = self:clamp_g(G.x_to_g(self.view, x))
  local v = G.y_to_v(self.view, y)
  local seg = T.locate(self.doc.timeline, g)
  if tool == "pencil" then
    if not seg or not seg.editable then
      fx.status = E.MSG_READ_ONLY
      return fx
    end
    self.drag = { kind = "pencil", cells = {}, snap = {}, grid = grid, last_g = nil, last_v = nil }
    self:pencil_sample(g, v)
    fx.redraw = true
    return fx
  elseif tool == "line" then
    local gs = self:clamp_g(P.snap_t(g, grid))
    if self.line_anchor then
      local a = self.line_anchor
      self.line_anchor = nil
      local c = self:commit_line(a.g, a.v, gs, v, grid)
      fx.commit = c
      fx.status = c and self:alias_message(c) or nil
      fx.overlay = false
      fx.redraw = true
      return fx
    end
    self.drag = { kind = "line", g0 = gs, v0 = v, x0 = x, y0 = y, x1 = x, y1 = y, grid = grid }
    return fx
  end
  return fx
end

-- Intermediate commit of a running gesture (batch undo), or nil when live
-- writes are off or the last one is too recent.
function E:live_commit(desc, lane, patterns)
  if not self.live_writes or not lane then return nil end
  local now = self.clock()
  if self.last_live and now - self.last_live < E.LIVE_INTERVAL and now >= self.last_live then return nil end
  self.last_live = now
  local c = new_commit(desc, true)
  for pattern in pairs(patterns) do
    put_write(c, lane, pattern, lane.data[pattern].points)
    lane.data[pattern].exists = true
  end
  if #c.writes == 0 then return nil end
  self.drag.live = true
  return c
end

function E:on_drag(ev, fx)
  local d = self.drag
  if not d then return fx end
  local view = self.view
  if d.kind == "move" then
    local dx, dy = ev.x - d.x0, ev.y - d.y0
    if ev.mods.shift then dx, dy = dx * 0.1, dy * 0.1 end
    if ev.mods.control then
      if math.abs(dx) >= math.abs(dy) then dy = 0 else dx = 0 end
    end
    local hpx = view.height - 2 * view.pad
    local dv = (hpx > 0) and (-dy / hpx) or 0
    local a = d.anchor
    local target = a.t
    if dx ~= 0 then
      target = P.snap_clamp_t(a.t + dx * view.span_g / view.width, self:grid_now(ev.mods), a.lines)
    end
    local dt = target - a.t
    local lane = self:active_lane()
    if not lane then return fx end
    local new_sel = {}
    local anchor_t = a.t
    for pattern, pts in pairs(d.snap) do
      local times = d.times[pattern]
      local np, nt = P.move(pts, times, dt, dv, lane.data[pattern].lines)
      set_points(lane, pattern, np)
      new_sel[pattern] = set_of(nt)
      if pattern == a.pattern then
        for i = 1, #times do
          if times[i] == a.t then anchor_t = nt[i] end
        end
      end
    end
    self.selection = new_sel
    d.dt, d.dv = dt, dv
    fx.commit = self:live_commit("Move points", lane, d.snap)
    local av = P.clamp_v(a.v + dv)
    local seg = a.seg
    fx.hover = {
      x = G.g_to_x(view, seg.offset - P.UNITS + anchor_t), y = G.v_to_y(view, av),
      text = self:label_for(lane, a.pattern, anchor_t, av), color = lane.color,
    }
    self.hover_id = "drag"
    fx.redraw = true
  elseif d.kind == "rect" then
    d.x1, d.y1 = ev.x, ev.y
    fx.overlay = { rect = { d.x0, d.y0, d.x1, d.y1 } }
    fx.redraw = true
  elseif d.kind == "pencil" then
    local g = self:clamp_g(G.x_to_g(view, ev.x))
    self:pencil_sample(g, G.y_to_v(view, ev.y))
    fx.commit = self:live_commit("Draw", self:active_lane(), d.snap)
    fx.redraw = true
  elseif d.kind == "line" then
    local g = self:clamp_g(P.snap_t(G.x_to_g(view, ev.x), d.grid))
    d.x1, d.y1 = G.g_to_x(view, g), ev.y
    fx.overlay = { line = { G.g_to_x(view, d.g0), G.v_to_y(view, d.v0), d.x1, d.y1 } }
    fx.redraw = true
  end
  return fx
end

function E:on_up(ev, fx)
  local d = self.drag
  if not d then return fx end
  self.drag = nil
  self.last_live = nil
  local lane = self:active_lane()
  if d.kind == "move" then
    self.hover_id = nil
    fx.hover = false
    if lane and (d.dt ~= 0 or d.dv ~= 0 or d.live) then
      local c = new_commit("Move points", d.live)
      for pattern in pairs(d.snap) do put_write(c, lane, pattern, lane.data[pattern].points) end
      fx.commit = c
      fx.status = self:alias_message(c)
    end
    fx.redraw = true
  elseif d.kind == "rect" then
    fx.overlay = false
    fx.redraw = true
    if lane and (math.abs(d.x1 - d.x0) > 2 or math.abs(d.y1 - d.y0) > 2) then
      local view = self.view
      local g0, g1 = G.x_to_g(view, math.min(d.x0, d.x1)), G.x_to_g(view, math.max(d.x0, d.x1))
      local v0, v1 = G.y_to_v(view, math.max(d.y0, d.y1)), G.y_to_v(view, math.min(d.y0, d.y1))
      if not d.add then self.selection = {} end
      local segs = self:segments()
      for i = 1, #segs do
        local s = segs[i]
        local data = lane.data[s.pattern]
        if s.editable and data and s.offset + s.len_g >= g0 and s.offset <= g1 then
          local times = P.in_rect(data.points, T.local_t(s, g0), T.local_t(s, g1), v0, v1)
          if #times > 0 then
            local set = self.selection[s.pattern] or {}
            for k = 1, #times do set[times[k]] = true end
            self.selection[s.pattern] = set
          end
        end
      end
    end
  elseif d.kind == "pencil" then
    if lane and next(d.snap) then
      local c = new_commit("Draw", d.live)
      for pattern in pairs(d.snap) do put_write(c, lane, pattern, lane.data[pattern].points) end
      fx.commit = c
      fx.status = self:alias_message(c)
    end
    fx.redraw = true
  elseif d.kind == "line" then
    fx.overlay = false
    fx.redraw = true
    local moved = math.abs(d.x1 - d.x0) > 3 or math.abs(d.y1 - d.y0) > 3
    if moved then
      local g1 = self:clamp_g(P.snap_t(G.x_to_g(self.view, d.x1), d.grid))
      local c = self:commit_line(d.g0, d.v0, g1, G.y_to_v(self.view, d.y1), d.grid)
      fx.commit = c
      fx.status = c and self:alias_message(c) or nil
    else
      self.line_anchor = { g = d.g0, v = d.v0 }
      fx.status = E.MSG_LINE_END
    end
  end
  return fx
end

function E:on_double(ev, fx)
  if ev.button ~= "left" or (self.tool ~= "edit" and self.tool ~= "select") then return fx end
  if self.just_activated then return fx end
  if self:hit_point(ev.x, ev.y) then return fx end
  local lane = self:active_lane()
  if not lane then
    fx.status = (#self:visible_lanes() == 0) and E.MSG_NO_LANE or E.MSG_NO_ACTIVE
    return fx
  end
  local g = self:clamp_g(G.x_to_g(self.view, ev.x))
  local seg, t = T.locate(self.doc.timeline, g)
  if not seg or not seg.editable then
    fx.status = E.MSG_READ_ONLY
    return fx
  end
  t = P.snap_clamp_t(t, self:grid_now(ev.mods), seg.lines)
  local v = G.y_to_v(self.view, ev.y)
  local data = ensure_data(lane, seg)
  local c = new_commit("Add point")
  set_points(lane, seg.pattern, P.add(data.points, t, v, 0))
  put_write(c, lane, seg.pattern, data.points)
  self.selection = { [seg.pattern] = { [t] = true } }
  fx.commit = c
  fx.status = self:alias_message(c)
  fx.redraw = true
  return fx
end

--------------------------------------------------------------------------------
-- tools

function E:pencil_sample(g, v)
  local d = self.drag
  local lane = self:active_lane()
  if not lane then return end
  P.pencil_add(d.cells, d.last_g, d.last_v, g, v, d.grid)
  d.last_g, d.last_v = g, v
  -- group cells per pattern of editable segments
  local per = {}
  for cg, cv in pairs(d.cells) do
    local seg, t = T.locate(self.doc.timeline, self:clamp_g(cg))
    if seg and seg.editable then
      local e = per[seg.pattern]
      if not e then
        e = { seg = seg, cells = {} }
        per[seg.pattern] = e
      end
      e.cells[t] = cv
    end
  end
  for pattern, e in pairs(per) do
    local data = ensure_data(lane, e.seg)
    if not d.snap[pattern] then d.snap[pattern] = P.copy(data.points) end
    set_points(lane, pattern, P.pencil_apply(d.snap[pattern], e.cells, e.seg.lines))
  end
end

-- Straight ramp between two global times, split over the patterns it crosses.
function E:commit_line(g0, v0, g1, v1, grid)
  local lane = self:active_lane()
  if not lane then return nil end
  if g0 == g1 then return nil end
  local pieces = T.split_ramp(self.doc.timeline, g0, v0, g1, v1)
  local c = new_commit("Draw line")
  for i = 1, #pieces do
    local piece = pieces[i]
    if piece.seg.editable then
      local data = ensure_data(lane, piece.seg)
      local mode = data.playmode or lane.playmode
      local step = (mode == I.PLAYMODE_POINTS and grid > 1) and grid or nil
      set_points(lane, piece.seg.pattern, P.line(data.points, piece.t0, piece.v0, piece.t1, piece.v1, step))
      put_write(c, lane, piece.seg.pattern, data.points)
    end
  end
  if #c.writes == 0 then return nil end
  return c
end

function E:delete_selection()
  local lane = self:active_lane()
  if not lane or not self:has_selection() then return nil end
  local c = new_commit("Delete points")
  for pattern, set in pairs(self.selection) do
    local data = lane.data[pattern]
    if data then
      set_points(lane, pattern, P.remove_times(data.points, list_of(set)))
      put_write(c, lane, pattern, data.points)
    end
  end
  self.selection = {}
  return c
end

function E:shift_selection(dt)
  local lane = self:active_lane()
  if not lane or not self:has_selection() then return nil end
  local c = new_commit("Shift points")
  local new_sel = {}
  for pattern, set in pairs(self.selection) do
    local data = lane.data[pattern]
    if data then
      local np, nt = P.move(data.points, list_of(set), dt, 0, data.lines)
      set_points(lane, pattern, np)
      put_write(c, lane, pattern, np)
      new_sel[pattern] = set_of(nt)
    end
  end
  self.selection = new_sel
  return c
end

function E:scale_selection(factor, mode, batch)
  local lane = self:active_lane()
  if not lane or not self:has_selection() then return nil end
  local lo, hi
  for pattern, set in pairs(self.selection) do
    local data = lane.data[pattern]
    if data then
      local a, b = P.value_range(data.points, list_of(set))
      if a then
        lo = lo and math.min(lo, a) or a
        hi = hi and math.max(hi, b) or b
      end
    end
  end
  if not lo then return nil end
  local pivot = (mode == "bottom") and lo or (lo + hi) / 2
  local c = new_commit("Scale points", batch)
  for pattern, set in pairs(self.selection) do
    local data = lane.data[pattern]
    if data then
      set_points(lane, pattern, P.scale_values(data.points, list_of(set), factor, mode, pivot))
      put_write(c, lane, pattern, data.points)
    end
  end
  return c
end

function E:copy()
  local lane = self:active_lane()
  if not lane or not self:has_selection() then return false end
  local items, gmin, gmax = {}, nil, nil
  for pattern, set in pairs(self.selection) do
    local seg = self:first_segment_of(pattern, true)
    local data = lane.data[pattern]
    if seg and data then
      for i = 1, #data.points do
        local p = data.points[i]
        if set[p.t] then
          local g = T.global(seg, p.t)
          items[#items + 1] = { g = g, v = p.v, s = p.s or 0 }
          gmin = gmin and math.min(gmin, g) or g
          gmax = gmax and math.max(gmax, g) or g
        end
      end
    end
  end
  if #items == 0 then return false end
  local clip = { span = gmax - gmin, items = {} }
  table.sort(items, function(a, b) return a.g < b.g end)
  for i = 1, #items do
    clip.items[i] = { dg = items[i].g - gmin, v = items[i].v, s = items[i].s }
  end
  self.clipboard.clip = clip
  return true
end

function E:cut()
  if not self:copy() then return nil end
  local c = self:delete_selection()
  if c then c.description = DESC .. "Cut points" end
  return c
end

-- Paste the clipboard at global time g (snapped by the caller), replacing the
-- covered range in every editable pattern it overlaps.
function E:paste_at(g)
  local lane = self:active_lane()
  local clip = self.clipboard.clip
  if not lane or not clip or #clip.items == 0 then return nil end
  local g_end = g + clip.span
  local c = new_commit("Paste points")
  local new_sel = {}
  local segs = self:segments()
  for i = 1, #segs do
    local s = segs[i]
    local s0, s1 = s.offset, s.offset + s.len_g - 1
    if s.editable and g_end >= s0 and g <= s1 then
      local a, b = math.max(g, s0), math.min(g_end, s1)
      local items = {}
      for k = 1, #clip.items do
        local it = clip.items[k]
        local ig = g + it.dg
        if ig >= a and ig <= b then
          items[#items + 1] = { t = T.local_t(s, ig), v = it.v, s = it.s }
        end
      end
      local data = ensure_data(lane, s)
      set_points(lane, s.pattern, P.replace_range(data.points, T.local_t(s, a), T.local_t(s, b), items))
      put_write(c, lane, s.pattern, data.points)
      local set = new_sel[s.pattern] or {}
      for k = 1, #items do set[items[k].t] = true end
      new_sel[s.pattern] = set
    end
  end
  if #c.writes == 0 then return nil end
  self.selection = new_sel
  return c
end

function E:paste()
  local g = self.cursor_g or self.view.start_g
  return self:paste_at(self:clamp_g(P.snap_t(g, self:grid_now(nil))))
end

-- Playmode of the active lane (first editable pattern that has automation).
function E:active_playmode()
  local lane = self:active_lane()
  if not lane then return nil end
  local segs = self:segments()
  for i = 1, #segs do
    local d = lane.data[segs[i].pattern]
    if segs[i].editable and d and d.exists then return d.playmode or lane.playmode end
  end
  return lane.playmode
end

function E:set_playmode(mode)
  local lane = self:active_lane()
  if not lane then return nil end
  local c = new_commit("Change interpolation")
  local done = {}
  local segs = self:segments()
  for i = 1, #segs do
    local s = segs[i]
    local d = lane.data[s.pattern]
    if s.editable and d and d.exists and not done[s.pattern] and d.playmode ~= mode then
      done[s.pattern] = true
      d.playmode = mode
      d.rev = (d.rev or 0) + 1
      c.writes[#c.writes + 1] = { key = lane.key, pattern = s.pattern, playmode = mode }
    end
  end
  lane.playmode = mode
  if #c.writes == 0 then return nil end
  return c
end

-- Vectorize: switch the active lane to Lines and remove the points that a
-- straight line already follows within `tol` (0 to 1). Works on the
-- selection when there is one, otherwise on every editable pattern.
-- Returns commit (or nil), removed, kept.
-- Patterns (and eligible point sets) Vectorize works on: the selection, or
-- every editable pattern of the active lane. Returns targets, order.
function E:vectorize_targets(lane)
  local targets, order = {}, {}
  if self:has_selection() then
    for pattern, set in pairs(self.selection) do
      if next(set) and lane.data[pattern] and lane.data[pattern].exists then
        targets[pattern] = set
        order[#order + 1] = pattern
      end
    end
    table.sort(order)
  else
    local segs = self:segments()
    for i = 1, #segs do
      local s = segs[i]
      local d = lane.data[s.pattern]
      if s.editable and d and d.exists and targets[s.pattern] == nil then
        targets[s.pattern] = false
        order[#order + 1] = s.pattern
      end
    end
  end
  return targets, order
end

function E:vectorize(tol)
  local lane = self:active_lane()
  if not lane then return nil, 0, 0 end
  tol = tol or self.vectorize_tolerance or 0.02
  self.vec_preview = nil
  local targets, order = self:vectorize_targets(lane)
  local c = new_commit("Vectorize")
  local removed, kept = 0, 0
  local new_sel = {}
  for _, pattern in ipairs(order) do
    local data = lane.data[pattern]
    local eligible = targets[pattern] or nil
    local np, r = P.simplify(data.points, tol, eligible)
    removed = removed + r
    local changed = r > 0
    for i = 1, #np do
      if np[i].s ~= (data.points[i] and data.points[i].s or 0) then changed = true end
    end
    if eligible then
      local set = {}
      for i = 1, #np do
        if eligible[np[i].t] then
          set[np[i].t] = true
          kept = kept + 1
        end
      end
      new_sel[pattern] = set
    else
      kept = kept + #np
    end
    if changed then
      set_points(lane, pattern, np)
      put_write(c, lane, pattern, np)
    end
    if data.playmode ~= I.PLAYMODE_LINES then
      data.playmode = I.PLAYMODE_LINES
      data.rev = (data.rev or 0) + 1
      local w
      for i = 1, #c.writes do
        if c.writes[i].pattern == pattern then w = c.writes[i] end
      end
      if not w then
        w = { key = lane.key, pattern = pattern }
        c.writes[#c.writes + 1] = w
      end
      w.playmode = I.PLAYMODE_LINES
    end
  end
  if #order > 0 then lane.playmode = I.PLAYMODE_LINES end
  if self:has_selection() then self.selection = new_sel end
  if #c.writes == 0 then return nil, removed, kept end
  return c, removed, kept
end

--------------------------------------------------------------------------------
-- Vectorize preview: shows the simplified curve before applying it. The
-- wheel changes the tolerance, Enter, V or a left click applies, Esc or a
-- right click cancels.

E.VEC_TOL_MAX = 0.25
E.VEC_TOL_STEP = 0.01

-- Simplified points per pattern for the current preview, plus counts.
function E:vectorize_plan(tol)
  local lane = self:active_lane()
  if not lane then return nil end
  local targets, order = self:vectorize_targets(lane)
  local plan = { points = {}, before = 0, after = 0 }
  for _, pattern in ipairs(order) do
    local data = lane.data[pattern]
    local np = P.simplify(data.points, tol, targets[pattern] or nil)
    plan.points[pattern] = np
    plan.before = plan.before + #data.points
    plan.after = plan.after + #np
  end
  return plan
end

function E:preview_message()
  local pv = self.vec_preview
  if not pv then return nil end
  return string.format("Vectorize preview: %d to %d points, tolerance %d %%. Wheel: tolerance. Enter or click: apply. Esc: cancel.",
    pv.plan.before, pv.plan.after, math.floor(pv.tol * 100 + 0.5))
end

function E:start_vectorize()
  local fx = { redraw = true }
  local lane = self:active_lane()
  if not lane then
    fx.status = (#self:visible_lanes() == 0) and E.MSG_NO_LANE or E.MSG_NO_ACTIVE
    return fx
  end
  local tol = self.vectorize_tolerance or 0.02
  local plan = self:vectorize_plan(tol)
  if not plan or plan.before == 0 then
    fx.status = "Vectorize: nothing to change."
    return fx
  end
  self.vec_preview = { tol = tol, plan = plan, key = lane.key }
  fx.status = self:preview_message()
  return fx
end

function E:set_preview_tolerance(tol)
  local pv = self.vec_preview
  if not pv then return nil end
  tol = math.max(0, math.min(E.VEC_TOL_MAX, math.floor(tol * 100 + 0.5) / 100))
  pv.tol = tol
  pv.plan = self:vectorize_plan(tol)
  self.vectorize_tolerance = tol
  return { redraw = true, status = self:preview_message(), tolerance = tol }
end

function E:apply_preview()
  local pv = self.vec_preview
  if not pv then return nil end
  local c, removed = self:vectorize(pv.tol)
  return { commit = c, redraw = true, status = E.vectorize_message(c, removed) }
end

function E:cancel_preview()
  if not self.vec_preview then return nil end
  self.vec_preview = nil
  return { redraw = true, status = "Vectorize cancelled." }
end

-- Points to draw for the preview: { [pattern] = points } or nil.
function E:preview_points()
  local pv = self.vec_preview
  if not pv or pv.key ~= self.active_key then return nil end
  return pv.plan and pv.plan.points
end

-- Mouse and keys while the preview is shown. Returns fx, or nil to fall
-- through to the normal handlers.
function E:preview_mouse(ev)
  if not self.vec_preview then return nil end
  if ev.type == "wheel" then
    local up = (ev.direction == "up" or ev.direction == "right")
    if ev.mods.control then return nil end -- zoom still works
    return self:set_preview_tolerance(self.vec_preview.tol + (up and E.VEC_TOL_STEP or -E.VEC_TOL_STEP))
  elseif ev.type == "down" then
    if ev.button == "left" then return self:apply_preview() end
    return self:cancel_preview()
  elseif ev.type == "move" or ev.type == "exit" then
    return nil
  end
  return {}
end

function E:preview_key(name)
  if not self.vec_preview then return nil end
  if name == "return" or name == "enter" or name == "numpad enter" or name == "v" then
    return self:apply_preview()
  elseif name == "esc" then
    return self:cancel_preview()
  elseif name == "up" or name == "right" then
    return self:set_preview_tolerance(self.vec_preview.tol + E.VEC_TOL_STEP)
  elseif name == "down" or name == "left" then
    return self:set_preview_tolerance(self.vec_preview.tol - E.VEC_TOL_STEP)
  end
  return nil
end

function E.vectorize_message(commit, removed)
  if not commit then return "Vectorize: nothing to change." end
  return string.format("Vectorized: Lines, %d point%s removed.", removed, removed == 1 and "" or "s")
end

function E:next_lane(dir)
  local lanes = self:visible_lanes()
  if #lanes == 0 then return nil end
  local idx = 0
  for i = 1, #lanes do
    if lanes[i].key == self.active_key then idx = i end
  end
  if idx == 0 then
    idx = (dir > 0) and 1 or #lanes
  else
    idx = ((idx - 1 + dir) % #lanes) + 1
  end
  self:set_active(lanes[idx].key)
  return lanes[idx].key
end

-- Returns handled, commit. The commit restores the song when the cancelled
-- gesture was already written live.
function E:cancel()
  if self.drag then
    local d = self.drag
    local lane = self:active_lane()
    local c
    if lane and d.snap then
      if d.live then c = new_commit(d.kind == "pencil" and "Draw" or "Move points", true) end
      for pattern, pts in pairs(d.snap) do
        set_points(lane, pattern, pts)
        if c then put_write(c, lane, pattern, pts) end
      end
      if d.kind == "move" then
        local sel = {}
        for pattern, times in pairs(d.times) do sel[pattern] = set_of(times) end
        self.selection = sel
      end
    end
    self.drag = nil
    self.last_live = nil
    return true, c
  end
  if self.line_anchor then
    self.line_anchor = nil
    return true
  end
  if self:has_selection() then
    self.selection = {}
    return true
  end
  return false
end

--------------------------------------------------------------------------------
-- keyboard: returns fx or nil when the key is not handled

function E:key(name, mods)
  mods = mods or {}
  if not mods.control and not mods.alt then
    local pfx = self:preview_key(name)
    if pfx then return pfx end
  end
  local fx = { redraw = true }
  if mods.control and not mods.alt then
    if name == "c" then
      if self:copy() then fx.status = "Copied." end
      return fx
    elseif name == "x" then
      fx.commit = self:cut()
      return fx
    elseif name == "v" then
      fx.commit = self:paste()
      if fx.commit then fx.status = self:alias_message(fx.commit) end
      return fx
    end
    return nil
  end
  if mods.alt then return nil end
  if name == "tab" then
    fx.activate = self:next_lane(mods.shift and -1 or 1)
    return fx
  elseif name == "del" or name == "back" then
    if not self:has_selection() then return nil end
    fx.commit = self:delete_selection()
    return fx
  elseif (name == "left" or name == "right") and self:has_selection() then
    local step = math.max(self:grid_now(mods), mods.shift and 1 or 16)
    fx.commit = self:shift_selection((name == "left") and -step or step)
    return fx
  elseif name == "esc" then
    local handled, c = self:cancel()
    if handled then
      fx.commit = c
      fx.overlay = false
      fx.hover = false
      return fx
    end
    return nil
  elseif name == "v" and not mods.shift then
    return self:start_vectorize()
  elseif not mods.shift and E.TOOL_KEYS[name] then
    self.tool = E.TOOL_KEYS[name]
    self.line_anchor = nil
    fx.tool = self.tool
    return fx
  end
  return nil
end

return E
