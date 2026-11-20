local Pal = require "core.palette"

T.test("at least 12 distinct colors", function()
  T.ok(#Pal.COLORS >= 12)
  local seen = {}
  for _, c in ipairs(Pal.COLORS) do
    local id = table.concat(c, ",")
    T.ok(not seen[id], "duplicate color " .. id)
    seen[id] = true
  end
end)

T.test("colors are far enough apart", function()
  for i = 1, #Pal.COLORS do
    for k = i + 1, #Pal.COLORS do
      local a, b = Pal.COLORS[i], Pal.COLORS[k]
      local d = math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2)
      T.ok(d > 45, string.format("colors %d and %d too close (%.1f)", i, k, d))
    end
  end
end)

T.test("assignment is stable and fills unused slots first", function()
  local m = Pal.assign({}, { "a", "b", "c" })
  T.eq(m, { a = 1, b = 2, c = 3 })
  local m2, changed = Pal.assign({ a = 1, c = 3 }, { "a", "c", "d" })
  T.eq(m2.a, 1)
  T.eq(m2.c, 3)
  T.eq(m2.d, 2, "first free index")
  T.ok(changed)
  local _, changed2 = Pal.assign(m2, { "a" })
  T.ok(not changed2)
end)

T.test("8 lanes get 8 different colors", function()
  local keys = {}
  for i = 1, 8 do keys[i] = "k" .. i end
  local m = Pal.assign({}, keys)
  local used = {}
  for _, idx in pairs(m) do
    T.ok(not used[idx])
    used[idx] = true
  end
end)

T.test("color index wraps", function()
  T.eq(Pal.color(#Pal.COLORS + 1), Pal.COLORS[1])
end)
