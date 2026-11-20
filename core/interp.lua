-- Approximate envelope interpolation for drawing.
--
-- Renoise does not document its exact Curves formula nor the shape used by
-- the point `scaling` in Lines mode. This module uses documented
-- approximations that are close enough for editing:
--   Points: the value holds until the next point (step).
--   Lines : straight line; a non zero scaling of the left point bends the
--           segment with a power curve x^(2^(-2 * scaling)).
--   Curves: monotone cubic Hermite interpolation (Fritsch-Carlson), which
--           never overshoots between points.
-- Before the first point and after the last point the value is held.

local I = {}

I.PLAYMODE_POINTS = 1
I.PLAYMODE_LINES = 2
I.PLAYMODE_CURVES = 3

I.SUBDIV = 12

local function clamp01(v)
  if v < 0 then return 0 end
  if v > 1 then return 1 end
  return v
end

function I.scaling_shape(x, s)
  if not s or s == 0 then return x end
  if s > 1 then s = 1 elseif s < -1 then s = -1 end
  return x ^ (2 ^ (-2 * s))
end

-- Fritsch-Carlson tangents for monotone cubic interpolation.
local function monotone_tangents(points)
  local n = #points
  local m, d = {}, {}
  for i = 1, n - 1 do
    local dt = points[i + 1].t - points[i].t
    d[i] = (points[i + 1].v - points[i].v) / dt
  end
  if n == 1 then return { 0 } end
  m[1] = d[1]
  m[n] = d[n - 1]
  for i = 2, n - 1 do
    if d[i - 1] * d[i] <= 0 then
      m[i] = 0
    else
      m[i] = (d[i - 1] + d[i]) / 2
    end
  end
  for i = 1, n - 1 do
    if d[i] == 0 then
      m[i] = 0
      m[i + 1] = 0
    else
      local a, b = m[i] / d[i], m[i + 1] / d[i]
      local h = a * a + b * b
      if h > 9 then
        local tau = 3 / math.sqrt(h)
        m[i] = tau * a * d[i]
        m[i + 1] = tau * b * d[i]
      end
    end
  end
  return m
end

local function hermite(p0, p1, m0, m1, f)
  local dt = p1.t - p0.t
  local f2, f3 = f * f, f * f * f
  local h00 = 2 * f3 - 3 * f2 + 1
  local h10 = f3 - 2 * f2 + f
  local h01 = -2 * f3 + 3 * f2
  local h11 = f3 - f2
  return h00 * p0.v + h10 * dt * m0 + h01 * p1.v + h11 * dt * m1
end

-- Sample the envelope as a polyline of { t, v } vertices from t_start to t_end
-- (local sub-units). Vertices are returned as a flat array: t1, v1, t2, v2, ...
function I.sample(points, playmode, t_start, t_end)
  local out = {}
  local n = #points
  if n == 0 then return out end
  local function push(t, v)
    out[#out + 1] = t
    out[#out + 1] = v
  end
  push(t_start, points[1].v)
  if playmode == I.PLAYMODE_POINTS then
    for i = 1, n do
      local p = points[i]
      if i > 1 then push(p.t, points[i - 1].v) end
      push(p.t, p.v)
    end
  elseif playmode == I.PLAYMODE_CURVES and n > 2 then
    local m = monotone_tangents(points)
    push(points[1].t, points[1].v)
    for i = 1, n - 1 do
      local p0, p1 = points[i], points[i + 1]
      for k = 1, I.SUBDIV do
        local f = k / I.SUBDIV
        push(p0.t + (p1.t - p0.t) * f, clamp01(hermite(p0, p1, m[i], m[i + 1], f)))
      end
    end
  else
    -- Lines (and Curves with 2 points, which are straight)
    push(points[1].t, points[1].v)
    for i = 1, n - 1 do
      local p0, p1 = points[i], points[i + 1]
      local s = (playmode == I.PLAYMODE_LINES) and (p0.s or 0) or 0
      if s ~= 0 then
        for k = 1, I.SUBDIV do
          local f = k / I.SUBDIV
          push(p0.t + (p1.t - p0.t) * f, p0.v + (p1.v - p0.v) * I.scaling_shape(f, s))
        end
      else
        push(p1.t, p1.v)
      end
    end
  end
  push(t_end, points[n].v)
  return out
end

-- Value of the approximated envelope at local time t.
function I.value_at(points, playmode, t)
  local n = #points
  if n == 0 then return nil end
  if t <= points[1].t then return points[1].v end
  if t >= points[n].t then return points[n].v end
  for i = 1, n - 1 do
    local p0, p1 = points[i], points[i + 1]
    if t >= p0.t and t < p1.t then
      local f = (t - p0.t) / (p1.t - p0.t)
      if playmode == I.PLAYMODE_POINTS then return p0.v end
      if playmode == I.PLAYMODE_CURVES and n > 2 then
        local m = monotone_tangents(points)
        return clamp01(hermite(p0, p1, m[i], m[i + 1], f))
      end
      local s = (playmode == I.PLAYMODE_LINES) and (p0.s or 0) or 0
      return p0.v + (p1.v - p0.v) * I.scaling_shape(f, s)
    end
  end
  return points[n].v
end

return I
