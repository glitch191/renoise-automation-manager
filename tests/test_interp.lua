local I = require "core.interp"

local pts = {
  { t = 256, v = 0, s = 0 },
  { t = 512, v = 1, s = 0 },
  { t = 768, v = 0.5, s = 0 },
}

T.test("points mode draws steps", function()
  local xy = I.sample(pts, I.PLAYMODE_POINTS, 256, 1024)
  -- start hold, p1, (512,0), p2, (768,1), p3, end hold
  T.eq(xy, { 256, 0, 256, 0, 512, 0, 512, 1, 768, 1, 768, 0.5, 1024, 0.5 })
end)

T.test("lines mode is straight without scaling", function()
  local xy = I.sample(pts, I.PLAYMODE_LINES, 256, 1024)
  T.eq(xy, { 256, 0, 256, 0, 512, 1, 768, 0.5, 1024, 0.5 })
end)

T.test("lines mode with scaling bends but keeps the end points", function()
  local p = { { t = 256, v = 0, s = 0.5 }, { t = 512, v = 1, s = 0 } }
  local xy = I.sample(p, I.PLAYMODE_LINES, 256, 512)
  T.eq(#xy, 2 * (2 + I.SUBDIV + 1))
  T.near(xy[#xy - 1], 512)
  T.near(xy[#xy], 1)
  local mid = I.value_at(p, I.PLAYMODE_LINES, 384)
  T.ok(mid > 0.5, "positive scaling bends upward in this approximation")
end)

T.test("curves mode is monotone between points", function()
  local p = { { t = 256, v = 0 }, { t = 512, v = 0.2 }, { t = 768, v = 1 }, { t = 1024, v = 1 } }
  local xy = I.sample(p, I.PLAYMODE_CURVES, 256, 1024)
  for i = 4, #xy, 2 do
    T.ok(xy[i] >= xy[i - 2] - 1e-9, "non decreasing")
    T.ok(xy[i] <= 1 + 1e-9)
  end
end)

T.test("value_at matches each mode", function()
  T.eq(I.value_at(pts, I.PLAYMODE_POINTS, 600), 1)
  T.near(I.value_at(pts, I.PLAYMODE_LINES, 384), 0.5)
  T.eq(I.value_at(pts, I.PLAYMODE_LINES, 100), 0, "held before the first point")
  T.eq(I.value_at(pts, I.PLAYMODE_LINES, 2000), 0.5, "held after the last point")
  T.eq(I.value_at({}, I.PLAYMODE_LINES, 300), nil)
end)

T.test("single point draws a flat line", function()
  local xy = I.sample({ { t = 512, v = 0.3 } }, I.PLAYMODE_CURVES, 256, 1024)
  T.eq(xy, { 256, 0.3, 512, 0.3, 1024, 0.3 })
end)
