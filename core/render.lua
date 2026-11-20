-- Pure canvas renderer. Draws a scene into any context that implements the
-- subset of renoise.Views.Canvas.Context used here (the real Renoise context
-- or the SVG recording context of the tests).
--
-- Draw order: background, read only shading, alias hatching, value guides,
-- time grid, inactive lanes (reduced opacity, no points), active lane (on top,
-- thicker, opaque, with points), selection and tool overlays.
-- Texts (pattern numbers, alias tags, value label) are separate Text views.

local G = require "core.geometry"
local I = require "core.interp"
local P = require "core.points"

local R = {}

local function rgba(c, a)
  return { c[1], c[2], c[3], a or 255 }
end

-- Default colors used when no theme is available (tests, previews).
R.DEFAULT_COLORS = {
  back = { 30, 30, 32 },
  grid = { 90, 90, 96 },
  pattern = { 170, 170, 176 },
  selection = { 240, 240, 240 },
  readonly = { 0, 0, 0 },
  alias = { 200, 160, 60 },
  point_outline = { 20, 20, 20 },
}

--------------------------------------------------------------------------------
-- sample cache: one flat polyline (local t, v) per lane and pattern

function R.new_cache()
  return { entries = {} }
end

function R.clear_cache(cache)
  cache.entries = {}
end

-- data = { points, rev, lines }
function R.samples(cache, key, pattern, data, playmode)
  local id = key .. "@" .. pattern
  local e = cache.entries[id]
  if e and e.rev == data.rev and e.playmode == playmode and e.lines == data.lines then
    return e.xy
  end
  local xy = I.sample(data.points, playmode, P.UNITS, (data.lines + 1) * P.UNITS)
  cache.entries[id] = { rev = data.rev, playmode = playmode, lines = data.lines, xy = xy }
  return xy
end

--------------------------------------------------------------------------------
-- polyline transform with culling and pixel decimation

-- Converts the cached samples of one lane in one segment into a flat pixel
-- array. Vertices left of the view are skipped (except the last one, so the
-- line enters from the edge), conversion stops after the first vertex right
-- of the view, and dense data is decimated per pixel column: each column keeps
-- its lowest and highest vertex (in drawing order) and its last vertex, so at
-- most 3 vertices per column whatever the number of points.
function R.to_pixels(view, seg, samples, out)
  out = out or {}
  local n = #samples
  if n == 0 then return out end
  local x_min, x_max = -2, view.width + 2
  local base = seg.offset - P.UNITS
  local floor = math.floor

  local function emit(x, y)
    local m = #out
    if m >= 2 and out[m - 1] == x and out[m] == y then return end
    out[m + 1] = x
    out[m + 2] = y
  end

  local col, count = nil, 0
  local lo_x, lo_y, lo_i, hi_x, hi_y, hi_i, last_x, last_y
  local function flush()
    if not col then return end
    if count == 1 then
      emit(last_x, last_y)
    else
      if lo_i < hi_i then
        emit(lo_x, lo_y)
        emit(hi_x, hi_y)
      else
        emit(hi_x, hi_y)
        emit(lo_x, lo_y)
      end
      emit(last_x, last_y)
    end
    col = nil
  end

  local prev_x, prev_y = nil, nil
  for i = 1, n - 1, 2 do
    local x = G.g_to_x(view, base + samples[i])
    local y = G.v_to_y(view, samples[i + 1])
    if x < x_min then
      prev_x, prev_y = x, y
    else
      if prev_x then
        emit(prev_x, prev_y)
        prev_x = nil
      end
      local c = floor(x)
      if c ~= col then
        flush()
        col, count = c, 1
        lo_x, lo_y, lo_i, hi_x, hi_y, hi_i = x, y, i, x, y, i
      else
        count = count + 1
        if y < lo_y then lo_x, lo_y, lo_i = x, y, i end
        if y > hi_y then hi_x, hi_y, hi_i = x, y, i end
      end
      last_x, last_y = x, y
      if x > x_max then break end
    end
  end
  flush()
  return out
end

local function stroke_poly(ctx, xy)
  if #xy < 4 then return end
  ctx:begin_path()
  ctx:move_to(xy[1], xy[2])
  for i = 3, #xy - 1, 2 do ctx:line_to(xy[i], xy[i + 1]) end
  ctx:stroke()
end

local function visible_segments(view, segments)
  local out = {}
  local g0, g1 = view.start_g, view.start_g + view.span_g
  for i = 1, #segments do
    local s = segments[i]
    if s.offset + s.len_g >= g0 and s.offset <= g1 then out[#out + 1] = s end
  end
  return out
end
R.visible_segments = visible_segments

--------------------------------------------------------------------------------
-- labels (placed by the UI as Text views)

-- Returns { x, text, alias } for each visible segment start.
function R.segment_labels(view, segments, show_single)
  local out = {}
  if #segments <= 1 and not show_single then return out end
  local vis = visible_segments(view, segments)
  for i = 1, #vis do
    local s = vis[i]
    local x = G.g_to_x(view, s.offset)
    if x < 0 then x = 0 end
    local text = string.format("%d: Pat %d", s.seq - 1, s.pattern - 1)
    if s.alias then text = text .. " (alias)" end
    out[#out + 1] = { x = x, text = text, alias = s.alias, editable = s.editable }
  end
  return out
end

-- Describes how much of the timeline the view shows, for the zoom indicator.
-- Returns { zoomed, factor, text }. Lines are 0-based like the Pattern Editor.
function R.zoom_info(view, segments, total_g)
  total_g = math.max(total_g or 256, 1)
  local factor = total_g / math.max(view.span_g, 1)
  local zoomed = view.span_g < total_g - 0.5
  local lines_total = math.floor(total_g / P.UNITS + 0.5)
  if not zoomed or #segments == 0 then
    local text = string.format("View: all %d lines", lines_total)
    if #segments > 1 then text = string.format("View: all %d patterns, %d lines", #segments, lines_total) end
    return { zoomed = false, factor = 1, text = text }
  end
  local function at(g)
    for i = 1, #segments do
      local s = segments[i]
      if g < s.offset + s.len_g or i == #segments then
        local line = math.floor(math.max(0, g - s.offset) / P.UNITS)
        return s, math.min(line, s.lines - 1)
      end
    end
  end
  local g0 = math.max(0, view.start_g)
  local g1 = math.max(g0, math.min(total_g, view.start_g + view.span_g) - 1)
  local s0, l0 = at(g0)
  local s1, l1 = at(g1)
  local zoom = factor >= 10 and string.format("x%d", math.floor(factor + 0.5)) or string.format("x%.1f", factor)
  local text
  if s0 == s1 then
    if l0 == l1 then
      text = string.format("Zoom %s: Pat %d, inside line %d of %d", zoom, s0.pattern - 1, l0, s0.lines)
    else
      text = string.format("Zoom %s: Pat %d, lines %d to %d of %d", zoom, s0.pattern - 1, l0, l1, s0.lines)
    end
  else
    text = string.format("Zoom %s: Pat %d line %d to Pat %d line %d", zoom, s0.pattern - 1, l0, s1.pattern - 1, l1)
  end
  return { zoomed = true, factor = factor, text = text .. " (Fit shows all)" }
end

--------------------------------------------------------------------------------
-- main draw

-- Returns stats { lanes, points, vertices }.
function R.draw(ctx, scene)
  local d = scene.dims
  local view = scene.view
  local colors = scene.colors or R.DEFAULT_COLORS
  local w, h = view.width, view.height
  local stats = { lanes = 0, points = 0, vertices = 0 }

  ctx.global_alpha = 255
  ctx:set_line_dash({})
  ctx.fill_color = rgba(colors.back)
  ctx:fill_rect(0, 0, w, h)

  local segments = scene.segments or {}
  local vis = visible_segments(view, segments)

  -- read only shading and alias hatching
  for i = 1, #vis do
    local s = vis[i]
    local x0 = math.max(0, G.g_to_x(view, s.offset))
    local x1 = math.min(w, G.g_to_x(view, s.offset + s.len_g))
    if x1 > x0 then
      if not s.editable then
        ctx.fill_color = rgba(colors.readonly, 90)
        ctx:fill_rect(x0, 0, x1 - x0, h)
      end
      if s.alias then
        ctx:save()
        ctx:begin_path()
        ctx:rect(x0, 0, x1 - x0, h)
        ctx:clip()
        ctx.stroke_color = rgba(colors.alias, 40)
        ctx.line_width = 1 * d.zoom
        local step = 12 * d.zoom
        ctx:begin_path()
        local x = x0 - h
        while x < x1 do
          ctx:move_to(x, h)
          ctx:line_to(x + h, 0)
          x = x + step
        end
        ctx:stroke()
        ctx:restore()
      end
    end
  end

  -- value guides at 0, 25, 50, 75 and 100 %
  ctx.line_width = 1
  for k = 0, 4 do
    local v = k / 4
    local y = math.floor(G.v_to_y(view, v)) + 0.5
    ctx.stroke_color = rgba(colors.grid, (k == 0 or k == 4) and 150 or ((k == 2) and 110 or 70))
    ctx:begin_path()
    ctx:move_to(0, y)
    ctx:line_to(w, y)
    ctx:stroke()
  end

  -- time grid
  local lines = G.grid_lines(view, segments, scene.lpb or 4, 6 * d.zoom)
  local alpha = { sub = 35, line = 70, beat = 140 }
  for kind, a in pairs(alpha) do
    ctx.stroke_color = rgba(colors.grid, a)
    ctx.line_width = 1
    ctx:begin_path()
    local any = false
    for i = 1, #lines do
      local gl = lines[i]
      if gl.kind == kind then
        local x = math.floor(G.g_to_x(view, gl.g)) + 0.5
        if x >= 0 and x <= w then
          ctx:move_to(x, 0)
          ctx:line_to(x, h)
          any = true
        end
      end
    end
    if any then ctx:stroke() end
  end
  ctx.stroke_color = rgba(colors.pattern, 220)
  ctx.line_width = math.max(1, math.floor(1.5 * d.zoom + 0.5))
  ctx:begin_path()
  for i = 1, #lines do
    local gl = lines[i]
    if gl.kind == "pattern" then
      local x = G.g_to_x(view, gl.g)
      if x >= -1 and x <= w + 1 then
        ctx:move_to(x, 0)
        ctx:line_to(x, h)
      end
    end
  end
  ctx:stroke()

  -- lanes
  local cache = scene.cache or R.new_cache()
  local active
  local lanes = scene.lanes or {}
  ctx.line_join = "rounded"
  for li = 1, #lanes do
    local lane = lanes[li]
    if lane.key == scene.active_key and not lane.hidden then
      active = lane
    elseif not lane.hidden then
      ctx.global_alpha = math.floor(255 * (scene.inactive_alpha or 0.35) + 0.5)
      ctx.stroke_color = rgba(lane.color)
      ctx.line_width = d.line_inactive
      local drawn = false
      for i = 1, #vis do
        local s = vis[i]
        local data = lane.data[s.pattern]
        if data and data.exists and #data.points > 0 then
          local xy = R.to_pixels(view, s, R.samples(cache, lane.key, s.pattern, data, data.playmode or lane.playmode))
          stroke_poly(ctx, xy)
          stats.vertices = stats.vertices + #xy / 2
          drawn = true
        end
      end
      if drawn then stats.lanes = stats.lanes + 1 end
    end
  end
  ctx.global_alpha = 255

  if active then
    stats.lanes = stats.lanes + 1
    ctx.stroke_color = rgba(active.color)
    ctx.line_width = d.line_active
    local sel = scene.selection or {}
    local ps = d.point_size
    local half = ps / 2
    for i = 1, #vis do
      local s = vis[i]
      local data = active.data[s.pattern]
      if data and data.exists and #data.points > 0 then
        local xy = R.to_pixels(view, s, R.samples(cache, active.key, s.pattern, data, data.playmode or active.playmode))
        ctx.global_alpha = s.editable and 255 or 150
        stroke_poly(ctx, xy)
        stats.vertices = stats.vertices + #xy / 2
      end
    end
    -- points
    for i = 1, #vis do
      local s = vis[i]
      local data = active.data[s.pattern]
      if data and data.exists then
        ctx.global_alpha = s.editable and 255 or 150
        local psel = sel[s.pattern] or {}
        local pts = data.points
        local base = s.offset - P.UNITS
        for k = 1, #pts do
          local p = pts[k]
          local x = G.g_to_x(view, base + p.t)
          if x >= -ps and x <= w + ps then
            local y = G.v_to_y(view, p.v)
            stats.points = stats.points + 1
            if psel[p.t] then
              ctx.fill_color = rgba(colors.selection)
              ctx:fill_rect(x - half - 1, y - half - 1, ps + 2, ps + 2)
              ctx.fill_color = rgba(active.color)
              ctx:fill_rect(x - half + 1, y - half + 1, ps - 2, ps - 2)
            else
              ctx.fill_color = rgba(colors.point_outline)
              ctx:fill_rect(x - half - 1, y - half - 1, ps + 2, ps + 2)
              ctx.fill_color = rgba(active.color)
              ctx:fill_rect(x - half, y - half, ps, ps)
            end
          end
        end
      end
    end
    ctx.global_alpha = 255
  end

  -- overlays
  local ov = scene.overlay or {}
  if ov.rect then
    local r = ov.rect
    ctx.fill_color = rgba(colors.selection, 30)
    ctx:fill_rect(math.min(r[1], r[3]), math.min(r[2], r[4]), math.abs(r[3] - r[1]), math.abs(r[4] - r[2]))
    ctx.stroke_color = rgba(colors.selection, 200)
    ctx.line_width = 1
    ctx:set_line_dash({ 4 * d.zoom, 3 * d.zoom })
    ctx:stroke_rect(math.min(r[1], r[3]), math.min(r[2], r[4]), math.abs(r[3] - r[1]), math.abs(r[4] - r[2]))
    ctx:set_line_dash({})
  end
  if ov.line and active then
    local l = ov.line
    ctx.stroke_color = rgba(active.color, 220)
    ctx.line_width = d.line_active
    ctx:set_line_dash({ 6 * d.zoom, 4 * d.zoom })
    ctx:begin_path()
    ctx:move_to(l[1], l[2])
    ctx:line_to(l[3], l[4])
    ctx:stroke()
    ctx:set_line_dash({})
  end
  return stats
end

return R
