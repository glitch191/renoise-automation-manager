-- Pure proximity tests in pixel space.

local H = {}

function H.dist_segment(px, py, ax, ay, bx, by)
  local dx, dy = bx - ax, by - ay
  local len2 = dx * dx + dy * dy
  local f = 0
  if len2 > 0 then
    f = ((px - ax) * dx + (py - ay) * dy) / len2
    if f < 0 then f = 0 elseif f > 1 then f = 1 end
  end
  local cx, cy = ax + f * dx - px, ay + f * dy - py
  return math.sqrt(cx * cx + cy * cy)
end

-- Distance from (x, y) to a polyline given as a flat pixel array x1, y1, x2, y2...
function H.dist_polyline(xy, x, y)
  local best = math.huge
  local n = #xy
  if n == 2 then
    local dx, dy = xy[1] - x, xy[2] - y
    return math.sqrt(dx * dx + dy * dy)
  end
  for i = 1, n - 3, 2 do
    local ax, bx = xy[i], xy[i + 2]
    -- quick reject on x: segment entirely left or right of the probe
    if not ((ax < x - best and bx < x - best) or (ax > x + best and bx > x + best)) then
      local d = H.dist_segment(x, y, ax, xy[i + 1], bx, xy[i + 3])
      if d < best then best = d end
    end
  end
  return best
end

-- Nearest item of { x, y, ... } within radius (Chebyshev box test first,
-- then euclidean distance). Returns item, distance or nil.
function H.nearest(items, x, y, radius)
  local best, best_d = nil, math.huge
  for i = 1, #items do
    local it = items[i]
    if math.abs(it.x - x) <= radius and math.abs(it.y - y) <= radius then
      local dx, dy = it.x - x, it.y - y
      local d = math.sqrt(dx * dx + dy * dy)
      if d < best_d then best, best_d = it, d end
    end
  end
  if best and best_d <= radius * 1.42 then return best, best_d end
  return nil
end

return H
