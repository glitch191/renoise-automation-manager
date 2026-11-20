-- Pure operations on automation point lists.
--
-- Internal point format: { t = integer sub-units, v = 0..1, s = scaling }.
-- Time unit: 1 line = 256 sub-units. Renoise time 1.0 (first line) is t = 256.
-- A pattern of `len` lines accepts points with t in [256, (len + 1) * 256 - 1].
-- Every function returns a new sorted list and never mutates its input.

local P = {}

P.UNITS = 256

local function copy_point(p)
  return { t = p.t, v = p.v, s = p.s or 0 }
end

function P.copy(points)
  local out = {}
  for i = 1, #points do out[i] = copy_point(points[i]) end
  return out
end

function P.sort(points)
  table.sort(points, function(a, b) return a.t < b.t end)
  return points
end

function P.clamp_v(v)
  if v ~= v then return 0 end -- NaN guard
  if v < 0 then return 0 end
  if v > 1 then return 1 end
  return v
end

function P.min_t()
  return P.UNITS
end

function P.max_t(len)
  return (len + 1) * P.UNITS - 1
end

function P.clamp_t(t, len)
  t = math.floor(t + 0.5)
  if t < P.min_t() then return P.min_t() end
  local mx = P.max_t(len)
  if t > mx then return mx end
  return t
end

-- Snap a time to the grid (grid in sub-units, 1 = free).
function P.snap_t(t, grid)
  if not grid or grid <= 1 then return math.floor(t + 0.5) end
  return math.floor(t / grid + 0.5) * grid
end

-- Snap then clamp, keeping the result on the grid when possible.
function P.snap_clamp_t(t, grid, len)
  local s = P.snap_t(t, grid)
  if grid and grid > 1 then
    local mx = P.max_t(len)
    if s > mx then s = s - grid * math.ceil((s - mx) / grid) end
    if s < P.min_t() then s = P.min_t() end
  end
  return P.clamp_t(s, len)
end

-- Conversion from and to the Renoise EnvelopePoint list format.
function P.from_renoise(list)
  local out = {}
  for i = 1, #list do
    local p = list[i]
    out[#out + 1] = { t = math.floor(p.time * P.UNITS + 0.5), v = p.value, s = p.scaling or 0 }
  end
  return P.sort(out)
end

function P.to_renoise(points)
  local out = {}
  for i = 1, #points do
    local p = points[i]
    out[i] = { time = p.t / P.UNITS, value = p.v, scaling = p.s or 0 }
  end
  return out
end

function P.index_at(points, t)
  for i = 1, #points do
    if points[i].t == t then return i end
  end
  return nil
end

-- Set of times helper: accepts a list of times, returns a lookup table.
function P.time_set(times)
  local set = {}
  for i = 1, #times do set[times[i]] = true end
  return set
end

-- Insert a point, replacing any existing point at the same time.
function P.add(points, t, v, s)
  local out = {}
  for i = 1, #points do
    if points[i].t ~= t then out[#out + 1] = copy_point(points[i]) end
  end
  out[#out + 1] = { t = t, v = P.clamp_v(v), s = s or 0 }
  return P.sort(out)
end

function P.remove_times(points, times)
  local set = P.time_set(times)
  local out = {}
  for i = 1, #points do
    if not set[points[i].t] then out[#out + 1] = copy_point(points[i]) end
  end
  return out
end

-- Remove every point with t in [t0, t1] (inclusive).
function P.clear_range(points, t0, t1)
  if t0 > t1 then t0, t1 = t1, t0 end
  local out = {}
  for i = 1, #points do
    local t = points[i].t
    if t < t0 or t > t1 then out[#out + 1] = copy_point(points[i]) end
  end
  return out
end

-- Replace the range [t0, t1] by new points (new points outside the range are kept too).
function P.replace_range(points, t0, t1, new_points)
  local out = P.clear_range(points, t0, t1)
  local set = {}
  for i = 1, #new_points do set[new_points[i].t] = true end
  local merged = {}
  for i = 1, #out do
    if not set[out[i].t] then merged[#merged + 1] = out[i] end
  end
  for i = 1, #new_points do merged[#merged + 1] = copy_point(new_points[i]) end
  return P.dedupe(P.sort(merged))
end

-- Keep only the last point for each time (input must be sorted, stable).
function P.dedupe(points)
  local out = {}
  for i = 1, #points do
    local p = points[i]
    if #out > 0 and out[#out].t == p.t then
      out[#out] = p
    else
      out[#out + 1] = p
    end
  end
  return out
end

-- Move the points whose times are in `times` by (dt, dv).
-- dt is clamped so the whole group stays inside the pattern; values are clamped
-- per point. Unselected points that end up on a moved point's time are removed.
-- Returns new_points, new_times (the moved points' new times, same order).
function P.move(points, times, dt, dv, len)
  local set = P.time_set(times)
  local tmin, tmax
  for i = 1, #points do
    local t = points[i].t
    if set[t] then
      if not tmin or t < tmin then tmin = t end
      if not tmax or t > tmax then tmax = t end
    end
  end
  if not tmin then return P.copy(points), {} end
  dt = math.floor(dt + 0.5)
  if tmin + dt < P.min_t() then dt = P.min_t() - tmin end
  if tmax + dt > P.max_t(len) then dt = P.max_t(len) - tmax end

  local moved, rest = {}, {}
  for i = 1, #points do
    local p = points[i]
    if set[p.t] then
      moved[#moved + 1] = { t = p.t + dt, v = P.clamp_v(p.v + dv), s = p.s or 0 }
    else
      rest[#rest + 1] = copy_point(p)
    end
  end
  local taken = {}
  for i = 1, #moved do taken[moved[i].t] = true end
  local out = {}
  for i = 1, #rest do
    if not taken[rest[i].t] then out[#out + 1] = rest[i] end
  end
  for i = 1, #moved do out[#out + 1] = moved[i] end
  local new_times = {}
  for i = 1, #times do
    if set[times[i]] then new_times[#new_times + 1] = times[i] + dt end
  end
  return P.sort(out), new_times
end

-- Times of the points inside a time/value rectangle (inclusive).
function P.in_rect(points, t0, t1, v0, v1)
  if t0 > t1 then t0, t1 = t1, t0 end
  if v0 > v1 then v0, v1 = v1, v0 end
  local out = {}
  for i = 1, #points do
    local p = points[i]
    if p.t >= t0 and p.t <= t1 and p.v >= v0 and p.v <= v1 then out[#out + 1] = p.t end
  end
  return out
end

-- Scale the values of the selected points.
-- mode "center": around the middle of the selected value range.
-- mode "bottom": around the lowest selected value.
-- `pivot` (optional) overrides the computed pivot, used when a selection
-- spans several patterns and must share one pivot.
function P.value_range(points, times)
  local set = P.time_set(times)
  local lo, hi
  for i = 1, #points do
    local p = points[i]
    if set[p.t] then
      if not lo or p.v < lo then lo = p.v end
      if not hi or p.v > hi then hi = p.v end
    end
  end
  return lo, hi
end

function P.scale_values(points, times, factor, mode, pivot)
  local set = P.time_set(times)
  local lo, hi = P.value_range(points, times)
  if not lo then return P.copy(points) end
  pivot = pivot or ((mode == "bottom") and lo or (lo + hi) / 2)
  local out = {}
  for i = 1, #points do
    local p = copy_point(points[i])
    if set[p.t] then p.v = P.clamp_v(pivot + (p.v - pivot) * factor) end
    out[i] = p
  end
  return out
end

-- Pencil: accumulate stroke cells. `cells` maps a time to a value.
-- Fills every grid cell between the previous and the current mouse sample
-- with a linear interpolation, so fast strokes do not leave gaps.
-- With grid <= 1 (free) only the raw sample times are stored.
function P.pencil_add(cells, t_prev, v_prev, t, v, grid)
  v = P.clamp_v(v)
  if not grid or grid <= 1 or t_prev == nil then
    local key = (grid and grid > 1) and P.snap_t(t, grid) or math.floor(t + 0.5)
    cells[key] = v
    return cells
  end
  local a, b = P.snap_t(t_prev, grid), P.snap_t(t, grid)
  if a == b then
    cells[b] = v
    return cells
  end
  local step = (b > a) and grid or -grid
  local n = math.abs(b - a) / grid
  for k = 0, n do
    local tk = a + k * step
    local f = k / n
    cells[tk] = P.clamp_v(v_prev + (v - v_prev) * f)
  end
  return cells
end

-- Pencil: apply cells to a point list, replacing the drawn range.
function P.pencil_apply(points, cells, len)
  local list = {}
  for t, v in pairs(cells) do
    if t >= P.min_t() and t <= P.max_t(len) then
      list[#list + 1] = { t = t, v = v, s = 0 }
    end
  end
  if #list == 0 then return P.copy(points) end
  P.sort(list)
  return P.replace_range(points, list[1].t, list[#list].t, list)
end

-- Line: straight ramp from (t0, v0) to (t1, v1), replacing the range.
-- `step` (sub-units) adds intermediate points, useful in Points playmode.
function P.ramp_points(t0, v0, t1, v1, step)
  if t0 > t1 then t0, v0, t1, v1 = t1, v1, t0, v0 end
  local out = { { t = t0, v = P.clamp_v(v0), s = 0 } }
  if step and step > 0 and t1 > t0 then
    local t = (math.floor(t0 / step) + 1) * step
    while t < t1 do
      local f = (t - t0) / (t1 - t0)
      out[#out + 1] = { t = t, v = P.clamp_v(v0 + (v1 - v0) * f), s = 0 }
      t = t + step
    end
  end
  if t1 ~= t0 then out[#out + 1] = { t = t1, v = P.clamp_v(v1), s = 0 } end
  return out
end

function P.line(points, t0, v0, t1, v1, step)
  local ramp = P.ramp_points(t0, v0, t1, v1, step)
  return P.replace_range(points, ramp[1].t, ramp[#ramp].t, ramp)
end

-- True when the list is sorted, has unique times and valid ranges.
-- Remove points that a straight line between their neighbours already
-- follows within `tol` (vertical value distance, 0 to 1). Ramer-Douglas-
-- Peucker on (t, v). `eligible` (optional set of times) limits the points
-- that may be removed; the first and last points always stay. Kept points
-- that were eligible get scaling 0 so the result is made of straight lines.
-- Returns the new list and the number of removed points.
function P.simplify(points, tol, eligible)
  local n = #points
  tol = math.max(0, tol or 0) + 1e-9
  local function can_go(i)
    return i > 1 and i < n and (not eligible or eligible[points[i].t])
  end
  local keep = {}
  for i = 1, n do keep[i] = not can_go(i) end
  -- simplify each run between two fixed points
  local a = 1
  for b = 2, n do
    if keep[b] then
      if b - a > 1 then
        local stack = { a, b }
        while #stack > 0 do
          local j = table.remove(stack)
          local i = table.remove(stack)
          local pi, pj = points[i], points[j]
          local worst, wk = -1, nil
          for k = i + 1, j - 1 do
            local pk = points[k]
            local f = (pk.t - pi.t) / (pj.t - pi.t)
            local d = math.abs(pk.v - (pi.v + (pj.v - pi.v) * f))
            if d > worst then worst, wk = d, k end
          end
          if wk and worst > tol then
            keep[wk] = true
            stack[#stack + 1] = i
            stack[#stack + 1] = wk
            stack[#stack + 1] = wk
            stack[#stack + 1] = j
          end
        end
      end
      a = b
    end
  end
  local out, removed = {}, 0
  for i = 1, n do
    if keep[i] then
      local p = points[i]
      local s = p.s or 0
      if not eligible or eligible[p.t] then s = 0 end
      out[#out + 1] = { t = p.t, v = p.v, s = s }
    else
      removed = removed + 1
    end
  end
  return out, removed
end

function P.is_valid(points, len)
  for i = 1, #points do
    local p = points[i]
    if p.t < P.min_t() or p.t > P.max_t(len) then return false end
    if p.v < 0 or p.v > 1 then return false end
    if i > 1 and points[i - 1].t >= p.t then return false end
  end
  return true
end

return P
