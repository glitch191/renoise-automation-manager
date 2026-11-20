local L = require "core.layout"

-- Usable dialog content area per screen, leaving room for the taskbar,
-- the dialog title bar and borders (Renoise UI scaling at 100 %).
local SCREENS = {
  Compact = { 1280 - 40, 720 - 90 },
  Wide = { 1920 - 40, 1080 - 90 },
  Ultrawide = { 3440 - 40, 1440 - 90 },
}

T.test("zoom clamp and steps", function()
  T.eq(L.clamp_zoom(nil), 1.25)
  T.eq(L.clamp_zoom(0.5), 1.0)
  T.eq(L.clamp_zoom(3), 2.0)
  T.eq(L.clamp_zoom(1.3), 1.25)
  T.eq(L.clamp_zoom(1.4), 1.5)
end)

T.test("default preset is Wide", function()
  T.eq(L.PRESETS[L.DEFAULT_PRESET].name, "Wide")
end)

for _, preset in ipairs(L.PRESETS) do
  for _, zoom in ipairs({ 1.0, 1.25, 1.5, 1.75, 2.0 }) do
    T.test(string.format("%s at %d %% fits its screen and the toolbar fits", preset.name, zoom * 100), function()
      local d = L.compute(preset.width, preset.height, zoom, true)
      local scr = SCREENS[preset.name]
      T.ok(d.total_w <= scr[1], "width " .. d.total_w .. " > " .. scr[1])
      T.ok(d.total_h <= scr[2], "height " .. d.total_h .. " > " .. scr[2])
      T.ok(d.toolbar_w <= preset.width - 2 * d.margin, "toolbar " .. d.toolbar_w)
      T.ok(d.canvas_w >= L.MIN_CANVAS_W and d.canvas_h >= L.MIN_CANVAS_H)
      T.ok(d.legend_rows >= 3, "legend rows " .. d.legend_rows)
      T.ok(d.hit_radius >= 8, "hit area at least 8 px")
    end)
  end
end

T.test("ultrawide gives more time, not bigger controls", function()
  local w = L.compute(L.PRESETS[2].width, L.PRESETS[2].height, 1.25, true)
  local u = L.compute(L.PRESETS[3].width, L.PRESETS[3].height, 1.25, true)
  T.eq(w.toolbar_h, u.toolbar_h)
  T.eq(w.legend_w, u.legend_w)
  T.eq(w.toolbar_w, u.toolbar_w)
  T.ok(u.canvas_w > 1.8 * w.canvas_w)
end)

T.test("hiding the legend gives its width to the canvas", function()
  local a = L.compute(1800, 520, 1.25, true)
  local b = L.compute(1800, 520, 1.25, false)
  T.eq(b.canvas_w, a.canvas_w + a.legend_w + a.spacing)
end)

T.test("zoom scales tool dimensions", function()
  local a = L.compute(1800, 520, 1.0, true)
  local b = L.compute(1800, 520, 2.0, true)
  T.eq(b.control_h, 2 * a.control_h)
  T.eq(b.point_size, 2 * a.point_size)
  T.near(b.line_active, 2 * a.line_active)
end)
