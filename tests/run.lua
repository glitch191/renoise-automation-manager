-- Minimal test runner for LuaJIT / Lua 5.1. Run from the repository root:
--   luajit tests/run.lua            (all test files)
--   luajit tests/run.lua points     (only tests/test_points.lua)
-- Exit code is 1 when a test fails.

package.path = "./?.lua;./tests/?.lua;" .. package.path

local FILES = {
  "points", "timeline", "geometry", "interp", "hittest", "palette",
  "valuefmt", "tooldata", "layout", "render", "editor", "bridge", "ui",
}

local T = {}
local current = { name = "", failures = 0, count = 0 }
local results = { passed = 0, failed = 0, errors = {} }

local function fmt(v)
  if type(v) == "string" then return string.format("%q", v) end
  if type(v) ~= "table" then return tostring(v) end
  local parts = {}
  local n = #v
  for i = 1, n do parts[#parts + 1] = fmt(v[i]) end
  local keys = {}
  for k in pairs(v) do
    if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then keys[#keys + 1] = k end
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. "=" .. fmt(v[k]) end
  return "{" .. table.concat(parts, ", ") .. "}"
end
T.fmt = fmt

local function deep_eq(a, b, eps)
  if type(a) == "number" and type(b) == "number" then
    return math.abs(a - b) <= (eps or 0)
  end
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do
    if not deep_eq(v, b[k], eps) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end
T.deep_eq = deep_eq

local function fail(msg, level)
  error({ test_failure = msg }, (level or 1) + 1)
end

function T.eq(actual, expected, msg)
  if not deep_eq(actual, expected) then
    fail((msg and (msg .. ": ") or "") .. "expected " .. fmt(expected) .. ", got " .. fmt(actual), 2)
  end
end

function T.near(actual, expected, eps, msg)
  if not deep_eq(actual, expected, eps or 1e-9) then
    fail((msg and (msg .. ": ") or "") .. "expected ~" .. fmt(expected) .. ", got " .. fmt(actual), 2)
  end
end

function T.ok(cond, msg)
  if not cond then fail(msg or "condition is false", 2) end
end

function T.raises(fn, msg)
  local ok = pcall(fn)
  if ok then fail(msg or "expected an error", 2) end
end

function T.test(name, fn)
  current.count = current.count + 1
  local ok, err = xpcall(fn, function(e)
    if type(e) == "table" and e.test_failure then return e.test_failure end
    return debug.traceback(tostring(e), 2)
  end)
  if ok then
    results.passed = results.passed + 1
  else
    results.failed = results.failed + 1
    results.errors[#results.errors + 1] = current.name .. " > " .. name .. "\n    " .. tostring(err)
  end
end

_G.T = T

local only = arg and arg[1]
for _, name in ipairs(FILES) do
  if not only or only == name then
    current.name = name
    current.count = 0
    local path = "tests/test_" .. name .. ".lua"
    local chunk, err = loadfile(path)
    if not chunk then
      results.failed = results.failed + 1
      results.errors[#results.errors + 1] = name .. ": cannot load: " .. tostring(err)
    else
      local ok, e = pcall(chunk)
      if not ok then
        results.failed = results.failed + 1
        results.errors[#results.errors + 1] = name .. ": error at top level: " .. tostring(e)
      end
      io.write(string.format("%-10s %3d tests\n", name, current.count))
    end
  end
end

for _, e in ipairs(results.errors) do io.write("FAIL " .. e .. "\n") end
io.write(string.format("\n%d passed, %d failed\n", results.passed, results.failed))
os.exit(results.failed == 0 and 0 or 1)
