-- Pure value and time formatting for the hover / drag label.
--
-- The tool never reads or writes parameter.value or value_string to format a
-- value (that would change the sound). Real values are computed with a linear
-- mapping from the normalized automation value to value_min..value_max, and
-- only for native Renoise devices whose parameter is not known to be
-- non-linear. Everything else is shown as a percentage.

local F = {}

local NATIVE_PREFIX = "Audio/Effects/Native/"

-- Parameter names (lower case substrings) whose display scale is not linear.
F.NON_LINEAR = {
  "volume", "gain", "freq", "cutoff", "drive", "threshold", "makeup",
  "time", "delay", "decay", "release", "attack", "hold", "rate",
  "q", "resonance", "db", "width", "room", "size", "ratio", "speed",
}

local function is_non_linear(name)
  local n = string.lower(name or "")
  for i = 1, #F.NON_LINEAR do
    local w = F.NON_LINEAR[i]
    if w == "q" then
      if n == "q" then return true end
    elseif string.find(n, w, 1, true) then
      return true
    end
  end
  return false
end

-- Returns true when a real value can be shown reliably.
function F.is_reliable(info)
  if not info or not info.device_path then return false end
  if string.sub(info.device_path, 1, #NATIVE_PREFIX) ~= NATIVE_PREFIX then return false end
  if info.value_min == nil or info.value_max == nil then return false end
  if info.value_max <= info.value_min then return false end
  return not is_non_linear(info.name)
end

local function round_to(x, q)
  return math.floor(x / q + 0.5) * q
end

local function trim_number(x)
  local s = string.format("%.3f", x)
  s = string.gsub(s, "0+$", "")
  s = string.gsub(s, "%.$", "")
  if s == "-0" then s = "0" end
  return s
end

function F.percent(v)
  return string.format("%.1f %%", v * 100)
end

function F.value(info, v)
  if not F.is_reliable(info) then return F.percent(v) end
  local real = info.value_min + v * (info.value_max - info.value_min)
  local q = info.value_quantum or 0
  if q > 0 then
    real = round_to(real, q)
    if q >= 1 then return string.format("%d", math.floor(real + 0.5)) end
  end
  return trim_number(real)
end

-- Time label. Pattern and line numbers are 0-based like in the Pattern Editor.
function F.time(pattern_index, t)
  local line = math.floor(t / 256) - 1
  local sub = t % 256
  if sub == 0 then
    return string.format("Pattern %d, line %d", pattern_index - 1, line)
  end
  return string.format("Pattern %d, line %d + %d/256", pattern_index - 1, line, sub)
end

function F.label(name, pattern_index, t, info, v)
  return string.format("%s | %s | %s", name or "n/a", F.time(pattern_index, t), F.value(info, v))
end

return F
