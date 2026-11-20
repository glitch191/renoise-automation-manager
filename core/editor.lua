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

E.TOOLS = { "edit", "pencil", "line", "range" }
E.TOOL_LABELS = { "Edit", "Pencil", "Line", "Range" }
E.TOOL_KEYS = { e = "edit", p = "pencil", l = "line", r = "range", s = "range" }
-- Snap grid resolutions in sub-units: 1 line, 1/2, 1/4, 1/8, free.
E.GRIDS = { 256, 128, 64, 32, 1 }
E.GRID_LABELS = { "Line", "1/2", "1/4", "1/8", "Free" }

E.MSG_NO_LANE = "No automation on this track. Use Add lane to create one."
E.MSG_NO_ACTIVE = "No active lane. Click a curve or a legend row first."
E.MSG_READ_ONLY = "Neighbor patterns are read only. Edit the center pattern."
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
  -- live writes: drags and pencil strokes are written to the song while the
  -- mouse moves (throttled), all in one batch undo step
  self.live_writes = (opts.live_writes ~= false)
  self.clock = opts.clock or os.clock
  self.random = opts.random or math.random
  -- Link patterns: keep the curve continuous across pattern borders
  self.link_patterns = opts.link_patterns == true
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

  -- a left click in a read only (gray) pattern selects that pattern in
  -- Renoise, which makes it the editable center of the view
  if ev.button == "left" and not ev.mods.alt then
    local seg = T.locate(self.doc.timeline, self:clamp_g(G.x_to_g(self.view, x)))
    if seg and not seg.editable then
      self.selection = {}
      self.line_anchor = nil
      fx.goto_seq = seg.seq
      fx.status = string.format("Pattern %d (sequence %d) selected.", seg.pattern - 1, seg.seq - 1)
      fx.redraw = true
      return fx
    end
  end

  if ev.button == "right" then
    -- context menu (like the native Automation editor); a right click on a
    -- point of the active lane selects it first
    local p = self:hit_point(x, y)
    if p and p.seg.editable and not (self.selection[p.pattern] and self.selection[p.pattern][p.t]) then
      self.selection = { [p.pattern] = { [p.t] = true } }
      fx.redraw = true
    end
    -- the menu opens on release: opened on press, the release could land
    -- on the menu and close it at once
    self.menu_pending = true
    return fx
  end
  -- delete: Alt + left click on a point of the active lane
  if ev.button == "left" and ev.mods.alt then
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
    return fx
  end
  if ev.button ~= "left" then return fx end

  local tool = self.tool
  if tool == "range" then
    -- time range over every visible lane
    if ev.button ~= "left" then return fx end
    local g = self:clamp_g(P.snap_t(G.x_to_g(self.view, x), self:grid_now(ev.mods)))
    self.range = nil
    self.drag = { kind = "range", g0 = g, g1 = g, x0 = x }
    fx.overlay = false
    fx.redraw = true
    return fx
  end
  if tool == "edit" then
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
      -- moved points in global time, so they can cross pattern borders
      local snap, times, items = {}, {}, {}
      for pattern, set in pairs(self.selection) do
        local data = p.lane.data[pattern]
        local seg = (pattern == p.pattern) and p.seg or self:first_segment_of(pattern, true)
        if data and seg then
          snap[pattern] = P.copy(data.points)
          times[pattern] = list_of(set)
          for i = 1, #data.points do
            local q = data.points[i]
            if set[q.t] then
              items[#items + 1] = { pattern = pattern, t = q.t, g = T.global(seg, q.t), v = q.v, s = q.s or 0,
                anchor = (pattern == p.pattern and q.t == p.t) }
            end
          end
        end
      end
      local r0, r1 = self:editable_run(p.seg)
      self.drag = { kind = "move", x0 = x, y0 = y, snap = snap, times = times, items = items,
        run = { r0, r1 },
        anchor = { pattern = p.pattern, t = p.t, v = p.v, lines = p.seg.lines, seg = p.seg,
          g = T.global(p.seg, p.t) },
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
    if not ev.mods.shift then
      local mg, mv, hit = self:magnet(g, v, lane)
      if hit then gs, v = mg, mv end
    end
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

-- First and last global time of the run of contiguous editable segments
-- that contains seg.
function E:editable_run(seg)
  local segs = self:segments()
  local idx
  for i = 1, #segs do
    if segs[i] == seg then idx = i end
  end
  if not idx then return seg.offset, seg.offset + seg.len_g - 1 end
  local a, b = idx, idx
  while a > 1 and segs[a - 1].editable do a = a - 1 end
  while b < #segs and segs[b + 1].editable do b = b + 1 end
  return segs[a].offset, segs[b].offset + segs[b].len_g - 1
end

-- Move the drag items by (dt, dv) from their snapshots. Points may land in
-- another pattern of the editable run. Returns the new selection.
function E:apply_move(lane, d, dt, dv)
  dt = math.floor(dt + 0.5)
  local tl = self.doc.timeline
  local base, moved = {}, {}
  -- remove the moved points from their source patterns
  for pattern, pts in pairs(d.snap) do
    local set = set_of(d.times[pattern] or {})
    local keep = {}
    for i = 1, #pts do
      if not set[pts[i].t] then keep[#keep + 1] = { t = pts[i].t, v = pts[i].v, s = pts[i].s or 0 } end
    end
    base[pattern] = keep
  end
  -- place them at their new global time
  for i = 1, #d.items do
    local it = d.items[i]
    local seg, t = T.locate(tl, it.g + dt)
    if seg and seg.editable then
      local data = ensure_data(lane, seg)
      if not d.snap[seg.pattern] then d.snap[seg.pattern] = P.copy(data.points) end
      if not base[seg.pattern] then base[seg.pattern] = P.copy(d.snap[seg.pattern]) end
      t = P.clamp_t(t, seg.lines)
      it.dest = { pattern = seg.pattern, t = t }
      local list = moved[seg.pattern] or {}
      list[#list + 1] = { t = t, v = P.clamp_v(it.v + dv), s = it.s }
      moved[seg.pattern] = list
    else
      it.dest = nil
    end
  end
  local sel = {}
  for pattern, keep in pairs(base) do
    local list = moved[pattern] or {}
    local taken = {}
    for i = 1, #list do taken[list[i].t] = true end
    local out = {}
    for i = 1, #keep do
      if not taken[keep[i].t] then out[#out + 1] = keep[i] end
    end
    local set = {}
    for i = 1, #list do
      out[#out + 1] = list[i]
      set[list[i].t] = true
    end
    set_points(lane, pattern, P.sort(out))
    if next(set) then sel[pattern] = set end
  end
  return sel
end

-- Link patterns. Renoise plays each pattern's automation on its own: the
-- value holds after the last point of a pattern and before the first point
-- of the next one. When linking is on, the tool keeps two border points
-- (last 1/256 of the first pattern, first position of the next) on the
-- straight line between the last point before the border and the first
-- point after it, so the two patterns read as one continuous line. Only
-- editable patterns are written; repeated patterns are left alone.

-- Border points of one lane for every pair of adjacent patterns. Adds the
-- writes to commit c (creating it when nil). Returns c.
function E:link_lane(c, lane)
  local segs = self:segments()
  for i = 1, #segs - 1 do
    local A, B = segs[i], segs[i + 1]
    local da, db = lane.data[A.pattern], lane.data[B.pattern]
    if A.offset + A.len_g == B.offset and A.pattern ~= B.pattern and (A.editable or B.editable)
        and da and db and da.exists and db.exists then
      local a_end, b_start = P.max_t(A.lines), P.min_t()
      local pa, pb
      for k = #da.points, 1, -1 do
        if da.points[k].t < a_end then pa = da.points[k] break end
      end
      for k = 1, #db.points do
        if db.points[k].t > b_start then pb = db.points[k] break end
      end
      if pa and pb then
        local ga, gb = T.global(A, pa.t), T.global(B, pb.t)
        local function at(g) return pa.v + (pb.v - pa.v) * (g - ga) / (gb - ga) end
        local ends = {
          { seg = A, data = da, t = a_end, v = at(T.global(A, a_end)) },
          { seg = B, data = db, t = b_start, v = at(T.global(B, b_start)) },
        }
        for _, e in ipairs(ends) do
          if e.seg.editable then
            local cur = nil
            for k = 1, #e.data.points do
              if e.data.points[k].t == e.t then cur = e.data.points[k] end
            end
            if not cur or math.abs(cur.v - e.v) > 1e-9 then
              c = c or new_commit("Link patterns")
              set_points(lane, e.seg.pattern, P.add(e.data.points, e.t, P.clamp_v(e.v), 0))
              put_write(c, lane, e.seg.pattern, e.data.points)
            end
          end
        end
      end
    end
  end
  return c
end

-- Add the border points of the lanes a commit touches (same undo step).
function E:add_links(c)
  if not self.link_patterns or not c then return c end
  local seen = {}
  local writes = {}
  for i = 1, #c.writes do writes[i] = c.writes[i] end
  for _, w in ipairs(writes) do
    if not w.delete and not seen[w.key] then
      seen[w.key] = true
      local lane = self:lane(w.key)
      if lane then self:link_lane(c, lane) end
    end
  end
  return c
end

-- Link every visible lane now (when the option is turned on).
function E:link_all()
  local c
  for _, lane in ipairs(self:visible_lanes()) do c = self:link_lane(c, lane) end
  return c
end

-- Magnet to pattern borders, like the native editor: a time within a few
-- pixels of a pattern start or end goes exactly onto it (the end is the
-- last 1/256 of the last line), and the value then sticks to the value of
-- the neighboring pattern at that border. Returns g, v, hit.
E.MAGNET_PX = 8

function E:magnet(g, v, lane)
  local view = self.view
  local zoom = (self.dims and self.dims.zoom) or 1
  local tol = E.MAGNET_PX * zoom
  local segs = self:segments()
  local x = G.g_to_x(view, g)
  local best, best_d, side, idx
  for i = 1, #segs do
    local sg = segs[i]
    local b0, b1 = sg.offset, sg.offset + sg.len_g - 1
    local d0 = math.abs(G.g_to_x(view, b0) - x)
    local d1 = math.abs(G.g_to_x(view, b1) - x)
    if d0 <= tol and (not best_d or d0 < best_d) then best, best_d, side, idx = b0, d0, "start", i end
    if d1 <= tol and (not best_d or d1 < best_d) then best, best_d, side, idx = b1, d1, "end", i end
  end
  if not best then return g, v, false end
  -- value of the neighboring pattern at the shared border
  lane = lane or self:active_lane()
  local nv
  if lane then
    local cur = segs[idx]
    if side == "end" then
      local nxt = segs[idx + 1]
      local data = nxt and nxt.offset == cur.offset + cur.len_g and lane.data[nxt.pattern]
      if data and #data.points > 0 then
        nv = I.value_at(data.points, data.playmode or lane.playmode, P.min_t())
      end
    else
      local prv = segs[idx - 1]
      local data = prv and prv.offset + prv.len_g == cur.offset and lane.data[prv.pattern]
      if data and #data.points > 0 then
        nv = I.value_at(data.points, data.playmode or lane.playmode, P.max_t(prv.lines))
      end
    end
  end
  if nv and math.abs(G.v_to_y(view, nv) - G.v_to_y(view, v)) <= tol then v = nv end
  return best, v, true
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
    local lane = self:active_lane()
    if not lane then return fx end
    local dt = 0
    local grid = self:grid_now(ev.mods)
    if dx ~= 0 then
      local target = P.snap_t(a.g + dx * view.span_g / view.width, grid)
      dt = target - a.g
    end
    -- keep every moved point inside the editable run around the anchor,
    -- on the grid when possible
    local gmin, gmax
    for i = 1, #d.items do
      local g = d.items[i].g
      gmin = gmin and math.min(gmin, g) or g
      gmax = gmax and math.max(gmax, g) or g
    end
    if gmin then
      if gmin + dt < d.run[1] then
        dt = d.run[1] - gmin
        if grid > 1 then
          local snapped = math.ceil((a.g + dt) / grid) * grid - a.g
          if gmax + snapped <= d.run[2] then dt = snapped end
        end
      end
      if gmax + dt > d.run[2] then
        dt = d.run[2] - gmax
        if grid > 1 then
          local snapped = math.floor((a.g + dt) / grid) * grid - a.g
          if gmin + snapped >= d.run[1] then dt = snapped end
        end
      end
    end
    if not ev.mods.shift and gmin then
      -- the magnet looks at the raw mouse time, not the grid snapped one
      local raw = a.g + dx * view.span_g / view.width
      local mg, mv, hit = self:magnet(raw, P.clamp_v(a.v + dv), lane)
      if hit then
        local mdt = mg - a.g
        if gmin + mdt >= d.run[1] and gmax + mdt <= d.run[2] then
          dt = mdt
          if not ev.mods.control or dy ~= 0 then dv = mv - a.v end
        end
      end
    end
    local anchor_pattern, anchor_t = a.pattern, a.t
    local new_sel = self:apply_move(lane, d, dt, dv)
    for i = 1, #d.items do
      local it = d.items[i]
      if it.anchor and it.dest then anchor_pattern, anchor_t = it.dest.pattern, it.dest.t end
    end
    self.selection = new_sel
    d.dt, d.dv = dt, dv
    fx.commit = self:live_commit("Move points", lane, d.snap)
    local av = P.clamp_v(a.v + dv)
    local ag = a.g + dt
    fx.hover = {
      x = G.g_to_x(view, ag), y = G.v_to_y(view, av),
      text = self:label_for(lane, anchor_pattern, anchor_t, av), color = lane.color,
    }
    self.hover_id = "drag"
    fx.redraw = true
  elseif d.kind == "range" then
    d.g1 = self:clamp_g(P.snap_t(G.x_to_g(view, ev.x), self:grid_now(ev.mods)))
    self.range = { math.min(d.g0, d.g1), math.max(d.g0, d.g1) }
    fx.status = self:range_message()
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
    local y = ev.y
    if not ev.mods.shift then
      local mg, mv, hit = self:magnet(self:clamp_g(G.x_to_g(view, ev.x)), G.y_to_v(view, ev.y))
      if hit then g, y = mg, G.v_to_y(view, mv) end
    end
    d.x1, d.y1 = G.g_to_x(view, g), y
    fx.overlay = { line = { G.g_to_x(view, d.g0), G.v_to_y(view, d.v0), d.x1, d.y1 } }
    fx.redraw = true
  end
  return fx
end

function E:on_up(ev, fx)
  if ev.button == "right" and self.menu_pending then
    self.menu_pending = false
    fx.menu = "context"
    return fx
  end
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
  elseif d.kind == "range" then
    if d.g0 == d.g1 then
      self.range = nil
    else
      self.range = { math.min(d.g0, d.g1), math.max(d.g0, d.g1) }
      fx.status = self:range_message()
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
      local g1 = self:clamp_g(G.x_to_g(self.view, d.x1))
      local mg, _, hit = self:magnet(g1, 0)
      g1 = hit and mg or self:clamp_g(P.snap_t(g1, d.grid))
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
  if ev.button ~= "left" or self.tool ~= "edit" then return fx end
  if self.just_activated then return fx end
  -- double-click on a point deletes it, like the native editor
  local hit = self:hit_point(ev.x, ev.y)
  if hit then
    if not hit.seg.editable then
      fx.status = E.MSG_READ_ONLY
      return fx
    end
    self.drag = nil
    local c = new_commit("Delete point")
    set_points(hit.lane, hit.pattern, P.remove_times(hit.lane.data[hit.pattern].points, { hit.t }))
    put_write(c, hit.lane, hit.pattern, hit.lane.data[hit.pattern].points)
    if self.selection[hit.pattern] then self.selection[hit.pattern][hit.t] = nil end
    self.hover_id = nil
    fx.hover = false
    fx.commit = c
    fx.status = self:alias_message(c)
    fx.redraw = true
    return fx
  end
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
  if not ev.mods.shift then
    local mg, mv, hit = self:magnet(g, v, lane)
    if hit then
      local mseg, mt = T.locate(self.doc.timeline, mg)
      if mseg == seg then t, v = mt, mv end
    end
  end
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

--------------------------------------------------------------------------------
-- Range tool: a time range over every visible lane. Copy, cut, paste,
-- delete and shift work on all those lanes at once (one undo step).

function E:range_message()
  local r = self.range
  if not r then return nil end
  local s0, t0 = T.locate(self.doc.timeline, r[1])
  local s1, t1 = T.locate(self.doc.timeline, r[2])
  if not s0 or not s1 then return nil end
  return string.format("Range: Pat %d line %d to Pat %d line %d, %d lanes. Del, Ctrl + C, X, V, Left, Right, right-click menu.",
    s0.pattern - 1, math.floor(t0 / P.UNITS) - 1, s1.pattern - 1, math.floor(t1 / P.UNITS) - 1, #self:visible_lanes())
end

-- Points of every visible lane inside [g0, g1], relative to g0.
function E:range_items(g0, g1)
  local out = {}
  local segs = self:segments()
  for _, lane in ipairs(self:visible_lanes()) do
    local items, seen = {}, {}
    for i = 1, #segs do
      local s = segs[i]
      local data = lane.data[s.pattern]
      if data and s.offset + s.len_g > g0 and s.offset <= g1 then
        for k = 1, #data.points do
          local p = data.points[k]
          local g = T.global(s, p.t)
          if g >= g0 and g <= g1 and not seen[g] then
            seen[g] = true
            items[#items + 1] = { dg = g - g0, v = p.v, s = p.s or 0 }
          end
        end
      end
    end
    table.sort(items, function(a, b) return a.dg < b.dg end)
    out[lane.key] = items
  end
  return out
end

-- Replace [g, g + span] of one lane with items, in every editable pattern.
function E:replace_lane_range(c, lane, g, span, items)
  local g_end = g + span
  local segs = self:segments()
  for i = 1, #segs do
    local s = segs[i]
    local s0, s1 = s.offset, s.offset + s.len_g - 1
    if s.editable and g_end >= s0 and g <= s1 then
      local a, b = math.max(g, s0), math.min(g_end, s1)
      local local_items = {}
      for k = 1, #items do
        local ig = g + items[k].dg
        if ig >= a and ig <= b then
          local_items[#local_items + 1] = { t = T.local_t(s, ig), v = items[k].v, s = items[k].s }
        end
      end
      local data = lane.data[s.pattern]
      if (data and data.exists) or #local_items > 0 then
        data = ensure_data(lane, s)
        set_points(lane, s.pattern, P.replace_range(data.points, T.local_t(s, a), T.local_t(s, b), local_items))
        put_write(c, lane, s.pattern, data.points)
      end
    end
  end
end

function E:copy_range()
  local r = self.range
  if not r then return false end
  self.clipboard.range = { span = r[2] - r[1], lanes = self:range_items(r[1], r[2]) }
  self.clipboard.last = "range"
  return true
end

function E:delete_range(desc)
  local r = self.range
  if not r then return nil end
  local c = new_commit(desc or "Delete range")
  for _, lane in ipairs(self:visible_lanes()) do
    self:replace_lane_range(c, lane, r[1], r[2] - r[1], {})
  end
  if #c.writes == 0 then return nil end
  return c
end

function E:cut_range()
  if not self:copy_range() then return nil end
  return self:delete_range("Cut range")
end

function E:paste_range(g)
  local clip = self.clipboard.range
  if not clip then return nil end
  g = g or self:clamp_g(P.snap_t(self.cursor_g or self.view.start_g, self:grid_now(nil)))
  local c = new_commit("Paste range")
  for key, items in pairs(clip.lanes) do
    local lane = self:lane(key)
    if lane and not lane.hidden then self:replace_lane_range(c, lane, g, clip.span, items) end
  end
  self.range = { g, math.min(self:total_g() - 1, g + clip.span) }
  if #c.writes == 0 then return nil end
  return c
end

-- Move the range content by dt (sub-units) in every visible lane.
function E:shift_range(dt)
  local r = self.range
  if not r then return nil end
  local span = r[2] - r[1]
  local g = math.max(0, math.min(self:total_g() - 1 - span, r[1] + dt))
  if g == r[1] then return nil end
  local items = self:range_items(r[1], r[2])
  local c = new_commit("Shift range")
  for _, lane in ipairs(self:visible_lanes()) do
    self:replace_lane_range(c, lane, r[1], span, {})
  end
  for _, lane in ipairs(self:visible_lanes()) do
    self:replace_lane_range(c, lane, g, span, items[lane.key] or {})
  end
  self.range = { g, g + span }
  if #c.writes == 0 then return nil end
  return c
end

--------------------------------------------------------------------------------
-- Context menu operations, modelled on the native Automation editor menu.
-- They work in global time on the active lane (or, with a range of the
-- Range tool, on every visible lane for the clipboard and time operations).

-- Selected time span: the range, or the span of the selected points of the
-- active lane. Returns g0, g1 or nil.
function E:op_span()
  if self.range then return self.range[1], self.range[2] end
  local lane = self:active_lane()
  if not lane or not self:has_selection() then return nil end
  local g0, g1
  for pattern, set in pairs(self.selection) do
    local seg = self:first_segment_of(pattern, true)
    if seg then
      for t in pairs(set) do
        local g = T.global(seg, t)
        g0 = g0 and math.min(g0, g) or g
        g1 = g1 and math.max(g1, g) or g
      end
    end
  end
  if g0 and g1 > g0 then return g0, g1 end
  return nil
end

-- Editable segment under global time g (or nil).
function E:editable_segment_at(g)
  local seg = T.locate(self.doc.timeline, g)
  if seg and seg.editable then return seg end
  return nil
end

-- Span used by the Process commands: the selected time, or the editable
-- pattern under the mouse, or the first editable pattern.
function E:process_span()
  local g0, g1 = self:op_span()
  if g0 then return g0, g1 end
  local seg = self.cursor_g and self:editable_segment_at(self.cursor_g)
  if not seg then
    for _, s in ipairs(self:segments()) do
      if s.editable then seg = s break end
    end
  end
  if not seg then return nil end
  return seg.offset, seg.offset + seg.len_g - 1
end

-- Points of a lane between g0 and g1 (global), editable patterns only.
function E:lane_items(lane, g0, g1)
  local out, seen = {}, {}
  for _, s in ipairs(self:segments()) do
    local data = lane.data[s.pattern]
    if s.editable and data and s.offset + s.len_g > g0 and s.offset <= g1 then
      for k = 1, #data.points do
        local p = data.points[k]
        local g = T.global(s, p.t)
        if g >= g0 and g <= g1 and not seen[g] then
          seen[g] = true
          out[#out + 1] = { g = g, v = p.v, s = p.s or 0 }
        end
      end
    end
  end
  table.sort(out, function(a, b) return a.g < b.g end)
  return out
end

-- Replace [g0, g1] of a lane with absolute items { g, v, s }.
function E:write_span(c, lane, g0, g1, items)
  local rel = {}
  for i = 1, #items do
    local it = items[i]
    if it.g >= g0 and it.g <= g1 then rel[#rel + 1] = { dg = it.g - g0, v = P.clamp_v(it.v), s = it.s or 0 } end
  end
  self:replace_lane_range(c, lane, g0, g1 - g0, rel)
end

-- Step between generated points: the snap grid, a quarter line when free.
function E:curve_step()
  local g = self.grid or 256
  if not self.snap or g < 16 then g = 64 end
  return g
end

-- Process commands on the active lane: flip, mirror, humanize, random,
-- exponential, linear, sine. One undo step each.
E.PROCESS_LABELS = {
  flip = "Flip selection", mirror = "Mirror selection", humanize = "Humanize selection",
  random = "Create random points", exponential = "Create exponential curve",
  linear = "Create linear curve", sine = "Create sine curve",
}

function E:process(kind)
  local lane = self:active_lane()
  if not lane then return nil end
  local g0, g1 = self:process_span()
  if not g0 then return nil end
  local items = {}
  if kind == "flip" or kind == "mirror" or kind == "humanize" then
    local cur = self:lane_items(lane, g0, g1)
    if #cur == 0 then return nil end
    for i = 1, #cur do
      local it = cur[i]
      if kind == "flip" then
        items[i] = { g = it.g, v = 1 - it.v, s = it.s }
      elseif kind == "mirror" then
        items[i] = { g = g0 + g1 - it.g, v = it.v, s = 0 }
      else
        items[i] = { g = it.g, v = P.clamp_v(it.v + (self.random() * 2 - 1) * 0.05), s = it.s }
      end
    end
  else
    local step = self:curve_step()
    local span = math.max(1, g1 - g0)
    if kind == "linear" then
      items = { { g = g0, v = 0 }, { g = g1, v = 1 } }
    else
      local g = g0
      while g <= g1 do
        local f = (g - g0) / span
        local v
        if kind == "random" then v = self.random()
        elseif kind == "exponential" then v = f * f * f
        else v = 0.5 + 0.5 * math.sin(2 * math.pi * f) end
        items[#items + 1] = { g = g, v = v }
        g = g + step
      end
      if items[#items].g < g1 and kind ~= "random" then
        local f = 1
        items[#items + 1] = { g = g1, v = (kind == "exponential") and 1 or (0.5 + 0.5 * math.sin(2 * math.pi * f)) }
      end
    end
  end
  local c = new_commit(E.PROCESS_LABELS[kind] or "Process")
  self:write_span(c, lane, g0, g1, items)
  self.selection = {}
  if #c.writes == 0 then return nil end
  return c
end

-- Lanes and items of the clipboard: the range clip for every visible lane
-- it holds, or the point clip for the active lane. Returns list, span.
function E:clip_targets()
  local cb = self.clipboard
  local out = {}
  if cb.last == "range" and cb.range then
    for key, items in pairs(cb.range.lanes) do
      local lane = self:lane(key)
      if lane and not lane.hidden then out[#out + 1] = { lane = lane, items = items } end
    end
    table.sort(out, function(a, b) return a.lane.key < b.lane.key end)
    return out, cb.range.span
  elseif cb.clip and #cb.clip.items > 0 then
    local lane = self:active_lane()
    if lane then out[1] = { lane = lane, items = cb.clip.items } end
    return out, cb.clip.span
  end
  return out, 0
end

function E:paste_position()
  return self:clamp_g(P.snap_t(self.cursor_g or self.view.start_g, self:grid_now(nil)))
end

-- Paste the clipboard again and again from the mouse position to the end
-- of the pattern under it.
function E:paste_continuously()
  local targets, span = self:clip_targets()
  if #targets == 0 then return nil end
  local g = self:paste_position()
  local seg = self:editable_segment_at(g)
  if not seg then return nil end
  local seg_end = seg.offset + seg.len_g - 1
  local period = span + self:curve_step()
  local c = new_commit("Paste continuously")
  for _, tg in ipairs(targets) do
    local items = {}
    local base = g
    while base <= seg_end do
      for k = 1, #tg.items do
        local it = tg.items[k]
        local ig = base + it.dg
        if ig <= seg_end then items[#items + 1] = { g = ig, v = it.v, s = it.s } end
      end
      base = base + period
    end
    self:write_span(c, tg.lane, g, seg_end, items)
  end
  self.selection = {}
  if #c.writes == 0 then return nil end
  return c
end

-- Paste at the mouse position and push the later points of that pattern to
-- the right by the clipboard length (points pushed past the end are lost).
function E:insert_paste()
  local targets, span = self:clip_targets()
  if #targets == 0 then return nil end
  local g = self:paste_position()
  local seg = self:editable_segment_at(g)
  if not seg then return nil end
  local seg_end = seg.offset + seg.len_g - 1
  local period = span + self:curve_step()
  local c = new_commit("Insert paste")
  for _, tg in ipairs(targets) do
    local items = {}
    for _, it in ipairs(self:lane_items(tg.lane, g, seg_end)) do
      if it.g + period <= seg_end then items[#items + 1] = { g = it.g + period, v = it.v, s = it.s } end
    end
    for k = 1, #tg.items do
      local it = tg.items[k]
      if g + it.dg <= seg_end then items[#items + 1] = { g = g + it.dg, v = it.v, s = it.s } end
    end
    self:write_span(c, tg.lane, g, seg_end, items)
  end
  self.selection = {}
  if #c.writes == 0 then return nil end
  return c
end

-- Copy the selected time, remove it and pull the later points of each
-- pattern to the left (range: every visible lane; else the active lane).
function E:cut_time()
  local g0, g1 = self:op_span()
  if not g0 then return nil end
  local lanes
  if self.range then
    self:copy_range()
    lanes = self:visible_lanes()
  else
    self:copy()
    lanes = { self:active_lane() }
  end
  local c = new_commit("Cut selected time")
  for _, lane in ipairs(lanes) do
    for _, sg in ipairs(self:segments()) do
      local s0, s1 = sg.offset, sg.offset + sg.len_g - 1
      if sg.editable and g1 >= s0 and g0 <= s1 then
        local a, b = math.max(g0, s0), math.min(g1, s1)
        local cut = b - a + 1
        local items = {}
        for _, it in ipairs(self:lane_items(lane, s0, s1)) do
          if it.g < a then items[#items + 1] = it
          elseif it.g > b then items[#items + 1] = { g = it.g - cut, v = it.v, s = it.s } end
        end
        local data = lane.data[sg.pattern]
        if data and data.exists then self:write_span(c, lane, s0, s1, items) end
      end
    end
  end
  self.range = nil
  self.selection = {}
  if #c.writes == 0 then return nil end
  return c
end

-- Delete the automation of the active lane in every editable pattern.
function E:delete_envelope()
  local lane = self:active_lane()
  if not lane then return nil end
  local c = new_commit("Delete envelope")
  local done = {}
  for _, sg in ipairs(self:segments()) do
    local data = lane.data[sg.pattern]
    if sg.editable and data and data.exists and not done[sg.pattern] then
      done[sg.pattern] = true
      c.writes[#c.writes + 1] = { key = lane.key, pattern = sg.pattern, delete = true }
      data.points = {}
      data.exists = false
      data.rev = (data.rev or 0) + 1
    end
  end
  self.selection = {}
  if #c.writes == 0 then return nil end
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
  self.clipboard.last = "points"
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
  if self.clipboard.last == "range" and self.clipboard.range then return self:paste_range() end
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
  if self.range and not self.drag then
    self.range = nil
    return true
  end
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
  local fx = { redraw = true }
  if mods.control and not mods.alt then
    if name == "c" and self.range then
      if self:copy_range() then fx.status = "Copied the range of every visible lane." end
      return fx
    elseif name == "x" and self.range then
      fx.commit = self:cut_range()
      return fx
    elseif name == "p" then
      fx.commit = self:paste_continuously()
      return fx
    elseif name == "i" then
      fx.commit = self:insert_paste()
      return fx
    elseif name == "k" then
      fx.commit = self:cut_time()
      return fx
    elseif name == "f" then
      fx.commit = mods.shift and self:process("mirror") or self:process("flip")
      return fx
    elseif name == "r" then
      fx.commit = self:process("humanize")
      return fx
    elseif name == "c" then
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
  elseif (name == "del" or name == "back") and self.range then
    fx.commit = self:delete_range()
    return fx
  elseif (name == "left" or name == "right") and self.range then
    local step = math.max(self:grid_now(mods), mods.shift and 1 or 16)
    fx.commit = self:shift_range((name == "left") and -step or step)
    fx.status = self:range_message()
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
  elseif not mods.shift and E.TOOL_KEYS[name] then
    self.tool = E.TOOL_KEYS[name]
    if self.tool ~= "range" then self.range = nil end
    self.line_anchor = nil
    fx.tool = self.tool
    return fx
  end
  return nil
end

return E
