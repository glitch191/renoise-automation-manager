local F = require "core.valuefmt"

local native_pan = { name = "Panning", device_path = "Audio/Effects/Native/TrackVolPan", value_min = -50, value_max = 50, value_quantum = 0 }
local native_enum = { name = "Mode", device_path = "Audio/Effects/Native/Filter", value_min = 0, value_max = 4, value_quantum = 1 }
local native_vol = { name = "Volume", device_path = "Audio/Effects/Native/TrackVolPan", value_min = 0, value_max = 1.4125, value_quantum = 0 }
local plugin = { name = "Cutoff", device_path = "Audio/Effects/VST3/Some Synth", value_min = 0, value_max = 1, value_quantum = 0 }

T.test("linear native parameters show real values", function()
  T.eq(F.value(native_pan, 0.5), "0")
  T.eq(F.value(native_pan, 0.75), "25")
  T.eq(F.value(native_enum, 0.6), "2")
end)

T.test("non linear and plugin parameters show percentages", function()
  T.eq(F.value(native_vol, 0.5), "50.0 %")
  T.eq(F.value(plugin, 0.25), "25.0 %")
  T.eq(F.value(nil, 1), "100.0 %")
end)

T.test("time label is 0-based like the Pattern Editor", function()
  T.eq(F.time(1, 256), "Pattern 0, line 0")
  T.eq(F.time(3, 256 * 13 + 128), "Pattern 2, line 12 + 128/256")
end)

T.test("full label", function()
  T.eq(F.label("Filter: Mode", 1, 512, native_enum, 1), "Filter: Mode | Pattern 0, line 1 | 4")
end)

T.test("formatting never touches the parameter table", function()
  local info = { name = "Panning", device_path = "Audio/Effects/Native/TrackVolPan", value_min = -50, value_max = 50, value_quantum = 0 }
  local before = T.fmt(info)
  F.value(info, 0.3)
  F.label("x", 1, 256, info, 0.3)
  T.eq(T.fmt(info), before)
end)
