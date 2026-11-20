local D = require "core.tooldata"

T.test("empty and nil data give defaults", function()
  local d, st = D.decode(nil)
  T.eq(st, "empty")
  T.eq(d, D.default())
  local _, st2 = D.decode("")
  T.eq(st2, "empty")
end)

T.test("round trip keeps hidden lanes, colors, active lane and lock", function()
  local d = D.default()
  local tr = D.track(d, 3)
  tr.hidden["Audio/Effects/Native/Filter#1:2"] = true
  tr.colors["Audio/Effects/Native/Filter#1:2"] = 5
  tr.colors['weird "key"\n'] = 2
  tr.active = "Audio/Effects/Native/Filter#1:2"
  d.lock = { enabled = true, track = 3 }
  local s = D.encode(d)
  T.ok(string.sub(s, 1, 5) == "RAM1:")
  local back, st = D.decode(s)
  T.eq(st, "ok")
  T.eq(back.tracks[3].hidden, tr.hidden)
  T.eq(back.tracks[3].colors, tr.colors)
  T.eq(back.tracks[3].active, tr.active)
  T.eq(back.lock, { enabled = true, track = 3 })
end)

T.test("corrupt data is tolerated", function()
  local inputs = {
    "garbage", "RAM1:", "RAM1:{", "RAM1:{[1]=}", "RAM1:{[\"a\"]=1,}", "RAM1:{}}",
    "RAM1:\"unterminated", "RAM1:{[\"tracks\"]=12}", "RAM1:os.exit()", "RAM1:{[{}]=1}",
  }
  for _, s in ipairs(inputs) do
    local d, st = D.decode(s)
    T.ok(st == "corrupt" or st == "ok", s)
    T.eq(type(d.tracks), "table")
    T.eq(type(d.lock), "table")
  end
end)

T.test("wrong types are sanitized", function()
  local d = D.decode('RAM1:{["tracks"]={[2]={["hidden"]={["k"]=1,["j"]=true},["colors"]={["k"]=-3,["j"]=4.5,["m"]=7},["active"]=5}},["lock"]={["enabled"]="yes",["track"]=-2}}')
  T.eq(d.tracks[2].hidden, { j = true })
  T.eq(d.tracks[2].colors, { m = 7 })
  T.eq(d.tracks[2].active, nil)
  T.eq(d.lock, { enabled = false, track = 0 })
end)

T.test("newer versions are read tolerantly", function()
  local d, st = D.decode('RAM7:{["lock"]={["enabled"]=true,["track"]=1},["future"]={["x"]=1}}')
  T.eq(st, "newer")
  T.ok(d.lock.enabled)
end)

T.test("serializer escapes control characters and quotes", function()
  local s = D.serialize_value({ ["a\"b"] = "line\nnext\\" })
  local back = D.parse_value(s)
  T.eq(back, { ["a\"b"] = "line\nnext\\" })
end)

T.test("empty track entries are dropped on encode", function()
  local d = D.default()
  D.track(d, 4)
  local back = D.decode(D.encode(d))
  T.eq(back.tracks[4], nil)
end)

T.test("remap follows moved, inserted and deleted tracks", function()
  local data = D.default()
  data.tracks[1] = { hidden = { a = true }, colors = {}, name = "Bass", devices = "F" }
  data.tracks[2] = { hidden = {}, colors = { b = 3 }, name = "Lead", devices = "" }
  -- moved: Lead is now first
  T.eq(D.remap(data, { { name = "Lead", devices = "" }, { name = "Bass", devices = "F" } }), true)
  T.eq(data.tracks[1].colors.b, 3)
  T.eq(data.tracks[2].hidden.a, true)
  -- inserted a new track in front
  D.remap(data, { { name = "New", devices = "" }, { name = "Lead", devices = "" }, { name = "Bass", devices = "F" } })
  T.eq(data.tracks[1], nil)
  T.eq(data.tracks[2].name, "Lead")
  T.eq(data.tracks[3].name, "Bass")
  -- Lead deleted: its settings do not go to another track
  D.remap(data, { { name = "New", devices = "" }, { name = "Bass", devices = "F" } })
  T.eq(data.tracks[2].hidden.a, true)
  T.eq(data.tracks[1], nil)
  -- renamed track keeps its settings (same devices)
  D.remap(data, { { name = "New", devices = "" }, { name = "Bass 2", devices = "F" } })
  T.eq(data.tracks[2].hidden.a, true)
  T.eq(data.tracks[2].name, "Bass 2")
  -- unchanged song: nothing to do
  T.eq(D.remap(data, { { name = "New", devices = "" }, { name = "Bass 2", devices = "F" } }), false)
end)

T.test("remap keeps old data without names and survives encode", function()
  local data = D.default()
  data.tracks[2] = { hidden = { a = true }, colors = {} }
  D.remap(data, { { name = "A", devices = "" }, { name = "B", devices = "" } })
  T.eq(data.tracks[2].name, "B")
  local back = D.decode(D.encode(data))
  T.eq(back.tracks[2].name, "B")
  T.eq(back.tracks[2].hidden.a, true)
end)

T.test("remap moves the lock with its track", function()
  local data = D.default()
  data.lock = { enabled = true, track = 1, name = "Bass" }
  D.remap(data, { { name = "Lead", devices = "" }, { name = "Bass", devices = "" } })
  T.eq(data.lock.track, 2)
end)
