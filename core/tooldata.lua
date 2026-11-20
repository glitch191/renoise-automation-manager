-- Versioned, tolerant serialization of the per-song settings stored in
-- song.tool_data. Uses a tiny hand written parser (no load / loadstring), so
-- data coming from a foreign song file can never execute code.
--
-- Format: "RAM<version>:" followed by a literal made of tables, strings,
-- numbers and booleans, for example: RAM1:{["lock"]={["enabled"]=false}}
--
-- Data model (version 1):
-- {
--   version = 1,
--   tracks = { [track_index] = { hidden = { [lane_key] = true },
--                                colors = { [lane_key] = palette_index },
--                                active = lane_key or nil,
--                                name = track name, devices = device paths } },
--   lock = { enabled = boolean, track = track_index, name = track name },
-- }
--
-- Renoise tracks have no stable id, so each entry also remembers the name
-- and device list of its track; D.remap moves entries to the track that now
-- has them when tracks are inserted, moved or deleted.

local D = {}

D.VERSION = 1
D.PREFIX = "RAM"
D.MAX_LENGTH = 1024 * 1024
D.MAX_DEPTH = 16

--------------------------------------------------------------------------------
-- serializer

local function quote(s)
  return '"' .. string.gsub(s, '[%c"\\]', function(c)
    return string.format("\\%03d", string.byte(c))
  end) .. '"'
end

local function serialize(v, depth)
  local tv = type(v)
  if tv == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "0" end
    if v == math.floor(v) and math.abs(v) < 2 ^ 53 then return string.format("%d", v) end
    return string.format("%.17g", v)
  elseif tv == "boolean" then
    return v and "true" or "false"
  elseif tv == "string" then
    return quote(v)
  elseif tv == "table" then
    if depth > D.MAX_DEPTH then return "{}" end
    local keys = {}
    for k in pairs(v) do
      if type(k) == "string" or type(k) == "number" then keys[#keys + 1] = k end
    end
    table.sort(keys, function(a, b)
      if type(a) == type(b) then return a < b end
      return type(a) == "number"
    end)
    local parts = {}
    for i = 1, #keys do
      local k = keys[i]
      local val = v[k]
      local tval = type(val)
      if tval == "number" or tval == "boolean" or tval == "string" or tval == "table" then
        parts[#parts + 1] = "[" .. serialize(k, depth + 1) .. "]=" .. serialize(val, depth + 1)
      end
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "false"
end

function D.serialize_value(v)
  return serialize(v, 0)
end

--------------------------------------------------------------------------------
-- parser

local function parse(str)
  local pos = 1
  local len = #str

  local function fail(msg)
    error({ parse_error = msg .. " at " .. pos }, 0)
  end

  local function skip()
    while pos <= len do
      local c = string.sub(str, pos, pos)
      if c == " " or c == "\n" or c == "\r" or c == "\t" then pos = pos + 1 else break end
    end
  end

  local value

  local function parse_string()
    pos = pos + 1 -- opening quote
    local buf = {}
    while true do
      if pos > len then fail("unterminated string") end
      local c = string.sub(str, pos, pos)
      if c == '"' then
        pos = pos + 1
        return table.concat(buf)
      elseif c == "\\" then
        local digits = string.match(str, "^%d%d%d", pos + 1)
        if not digits then fail("bad escape") end
        local code = tonumber(digits)
        if code > 255 then fail("bad escape") end
        buf[#buf + 1] = string.char(code)
        pos = pos + 4
      else
        buf[#buf + 1] = c
        pos = pos + 1
      end
    end
  end

  local function parse_number()
    local s = string.match(str, "^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
    if not s or s == "" or s == "-" then fail("bad number") end
    local n = tonumber(s)
    if not n then fail("bad number") end
    pos = pos + #s
    return n
  end

  local function parse_table(depth)
    if depth > D.MAX_DEPTH then fail("too deep") end
    pos = pos + 1 -- {
    local t = {}
    skip()
    if string.sub(str, pos, pos) == "}" then
      pos = pos + 1
      return t
    end
    while true do
      skip()
      if string.sub(str, pos, pos) ~= "[" then fail("expected [") end
      pos = pos + 1
      skip()
      local k = value(depth + 1)
      if type(k) ~= "string" and type(k) ~= "number" then fail("bad key") end
      skip()
      if string.sub(str, pos, pos) ~= "]" then fail("expected ]") end
      pos = pos + 1
      skip()
      if string.sub(str, pos, pos) ~= "=" then fail("expected =") end
      pos = pos + 1
      skip()
      t[k] = value(depth + 1)
      skip()
      local c = string.sub(str, pos, pos)
      if c == "," then
        pos = pos + 1
      elseif c == "}" then
        pos = pos + 1
        return t
      else
        fail("expected , or }")
      end
    end
  end

  value = function(depth)
    skip()
    local c = string.sub(str, pos, pos)
    if c == "{" then return parse_table(depth) end
    if c == '"' then return parse_string() end
    if string.sub(str, pos, pos + 3) == "true" then pos = pos + 4 return true end
    if string.sub(str, pos, pos + 4) == "false" then pos = pos + 5 return false end
    if string.match(c, "[-%d]") then return parse_number() end
    fail("unexpected character")
  end

  local result = value(0)
  skip()
  if pos <= len then fail("trailing data") end
  return result
end

function D.parse_value(str)
  local ok, res = pcall(parse, str)
  if ok then return res end
  return nil, (type(res) == "table" and res.parse_error) or tostring(res)
end

--------------------------------------------------------------------------------
-- data model

function D.default()
  return { version = D.VERSION, tracks = {}, lock = { enabled = false, track = 0 } }
end

local function sanitize_track(t)
  local out = { hidden = {}, colors = {}, active = nil }
  if type(t) ~= "table" then return out end
  if type(t.hidden) == "table" then
    for k, v in pairs(t.hidden) do
      if type(k) == "string" and v == true then out.hidden[k] = true end
    end
  end
  if type(t.colors) == "table" then
    for k, v in pairs(t.colors) do
      if type(k) == "string" and type(v) == "number" and v >= 1 and v == math.floor(v) then
        out.colors[k] = v
      end
    end
  end
  if type(t.active) == "string" then out.active = t.active end
  if type(t.name) == "string" then out.name = t.name end
  if type(t.devices) == "string" then out.devices = t.devices end
  return out
end

-- Normalize any parsed value into a valid data model.
function D.normalize(raw)
  local data = D.default()
  if type(raw) ~= "table" then return data end
  if type(raw.tracks) == "table" then
    for k, v in pairs(raw.tracks) do
      local idx = tonumber(k)
      if idx and idx >= 1 and idx == math.floor(idx) then
        data.tracks[idx] = sanitize_track(v)
      end
    end
  end
  if type(raw.lock) == "table" then
    data.lock.enabled = raw.lock.enabled == true
    local tr = tonumber(raw.lock.track)
    data.lock.track = (tr and tr >= 0) and math.floor(tr) or 0
    if type(raw.lock.name) == "string" then data.lock.name = raw.lock.name end
  end
  return data
end

-- Decode song.tool_data. Never fails: returns data, status where status is
-- "ok", "empty", "corrupt" or "newer" (written by a newer version, read
-- as far as the known fields go).
function D.decode(str)
  if type(str) ~= "string" or str == "" then return D.default(), "empty" end
  if #str > D.MAX_LENGTH then return D.default(), "corrupt" end
  local ver, body = string.match(str, "^" .. D.PREFIX .. "(%d+):(.*)$")
  if not ver then return D.default(), "corrupt" end
  local raw = D.parse_value(body)
  if raw == nil then return D.default(), "corrupt" end
  local data = D.normalize(raw)
  if tonumber(ver) > D.VERSION then return data, "newer" end
  return data, "ok"
end

function D.encode(data)
  local clean = D.normalize(data)
  local out = { version = D.VERSION, tracks = {}, lock = clean.lock }
  for idx, t in pairs(clean.tracks) do
    -- drop empty track entries to keep the song data small
    if next(t.hidden) or next(t.colors) or t.active then out.tracks[idx] = t end
  end
  return D.PREFIX .. D.VERSION .. ":" .. serialize(out, 0)
end

-- Move track entries to the tracks they belong to. prints[idx] = { name,
-- devices } describes the current tracks. Matching order: same index with
-- the same name and devices, then a unique track with the same name and
-- devices, the same name, the same devices (renamed track). Unmatched
-- entries stay on their index when no other entry claimed it (old data
-- without names, or a track renamed and changed at once), otherwise they
-- are dropped (deleted track). Returns true when something changed.
function D.remap(data, prints)
  local entries = {}
  for idx, t in pairs(data.tracks) do entries[#entries + 1] = { idx = idx, t = t } end
  table.sort(entries, function(a, b) return a.idx < b.idx end)
  local out, claimed, placed = {}, {}, {}
  local changed = false
  local function place(e, idx)
    out[idx] = e.t
    claimed[idx] = true
    placed[e] = true
    if idx ~= e.idx then changed = true end
  end
  local function try(match)
    for _, e in ipairs(entries) do
      if not placed[e] and e.t.name then
        local p = prints[e.idx]
        if p and not claimed[e.idx] and match(e.t, p) then
          place(e, e.idx)
        else
          local found, count = nil, 0
          for idx, q in pairs(prints) do
            if not claimed[idx] and match(e.t, q) then
              found, count = idx, count + 1
            end
          end
          if count == 1 then place(e, found) end
        end
      end
    end
  end
  try(function(t, p) return t.name == p.name and t.devices == p.devices end)
  try(function(t, p) return t.name == p.name end)
  try(function(t, p) return t.devices ~= nil and t.devices ~= "" and t.devices == p.devices end)
  for _, e in ipairs(entries) do
    if not placed[e] then
      if prints[e.idx] and not claimed[e.idx] then
        place(e, e.idx)
      else
        changed = true -- dropped
      end
    end
  end
  for idx, t in pairs(out) do
    local p = prints[idx]
    if p and (t.name ~= p.name or t.devices ~= p.devices) then
      t.name, t.devices = p.name, p.devices
      changed = true
    end
  end
  data.tracks = out
  -- lock
  local lock = data.lock
  if lock.enabled then
    local p = prints[lock.track]
    if lock.name and not (p and p.name == lock.name) then
      local found, count = nil, 0
      for idx, q in pairs(prints) do
        if q.name == lock.name then found, count = idx, count + 1 end
      end
      if count == 1 then
        lock.track = found
        changed = true
      end
    end
    local q = prints[lock.track]
    if q and lock.name ~= q.name then
      lock.name = q.name
      changed = true
    end
  end
  return changed
end

function D.track(data, idx)
  local t = data.tracks[idx]
  if not t then
    t = { hidden = {}, colors = {}, active = nil }
    data.tracks[idx] = t
  end
  return t
end

return D
