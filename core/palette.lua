-- Fixed curve palette and stable color assignment.
--
-- 16 hues with medium lightness and saturation so that every color stays
-- readable on dark and on light Renoise themes. No gradients, no glow.

local Pal = {}

Pal.COLORS = {
  { 232, 76, 61 },   -- red
  { 243, 156, 18 },  -- orange
  { 222, 204, 36 },  -- yellow
  { 124, 196, 56 },  -- lime
  { 39, 166, 96 },   -- green
  { 26, 188, 166 },  -- teal
  { 52, 168, 232 },  -- sky
  { 74, 101, 226 },  -- blue
  { 142, 89, 224 },  -- violet
  { 206, 82, 198 },  -- magenta
  { 238, 110, 150 }, -- pink
  { 166, 116, 66 },  -- brown
  { 128, 144, 160 }, -- slate grey
  { 176, 52, 104 },  -- wine
  { 112, 136, 40 },  -- olive
  { 96, 96, 176 },   -- indigo
}

function Pal.color(index)
  local n = #Pal.COLORS
  return Pal.COLORS[((index - 1) % n) + 1]
end

-- Assign palette indices to keys. `assigned` (key -> index) is kept as is;
-- new keys receive the least used index, lowest index first.
-- Returns a new map and true when something was added.
function Pal.assign(assigned, keys)
  local out, usage, changed = {}, {}, false
  for i = 1, #Pal.COLORS do usage[i] = 0 end
  for k, idx in pairs(assigned or {}) do
    out[k] = idx
    if usage[idx] then usage[idx] = usage[idx] + 1 end
  end
  for i = 1, #keys do
    local k = keys[i]
    if not out[k] then
      local best, best_use = 1, math.huge
      for idx = 1, #Pal.COLORS do
        if usage[idx] < best_use then best, best_use = idx, usage[idx] end
      end
      out[k] = best
      usage[best] = usage[best] + 1
      changed = true
    end
  end
  return out, changed
end

return Pal
