-- Small simulation of the Renoise song objects used by the bridge, for tests
-- outside Renoise. It mimics the documented behaviours that matter here:
-- points are returned as copies, duplicate times are rejected,
-- create_automation fails when one already exists, observables raise when
-- their owner was deleted, and parameter value accesses are counted.

local M = {}

--------------------------------------------------------------------------------
-- observables

local Observable = {}
Observable.__index = Observable

function M.observable(owner)
  return setmetatable({ notifiers = {}, owner = owner }, Observable)
end

local function check_alive(self)
  if self.owner and self.owner._dead then error("object is not valid anymore (deleted)", 3) end
end

function Observable:add_notifier(fn)
  check_alive(self)
  for _, f in ipairs(self.notifiers) do
    if f == fn then error("notifier already added", 2) end
  end
  self.notifiers[#self.notifiers + 1] = fn
end

function Observable:has_notifier(fn)
  check_alive(self)
  for _, f in ipairs(self.notifiers) do
    if f == fn then return true end
  end
  return false
end

function Observable:remove_notifier(fn)
  check_alive(self)
  for i, f in ipairs(self.notifiers) do
    if f == fn then
      table.remove(self.notifiers, i)
      return
    end
  end
  error("notifier not found", 2)
end

function Observable:fire()
  local copy = {}
  for i, f in ipairs(self.notifiers) do copy[i] = f end
  for _, f in ipairs(copy) do f() end
end

M.stats = { value_reads = 0, value_writes = 0 }

--------------------------------------------------------------------------------
-- parameters and devices

-- Renoise DeviceParameter and AudioDevice objects have no __eq: comparing two
-- of them with == raises. The mock does the same (one shared metamethod, so
-- Lua calls it for any two distinct mock objects).
local function no_eq()
  error("unknown property or function '__eq' for an object of type 'DeviceParameter'", 2)
end
M.no_eq = no_eq

function M.param(name, opts)
  opts = opts or {}
  local raw = {
    name = name,
    value_min = opts.min or 0, value_max = opts.max or 1, value_quantum = opts.quantum or 0,
    is_automatable = opts.automatable ~= false,
    _value = 0.5,
  }
  local p = {}
  return setmetatable(p, {
    __index = function(_, k)
      if k == "value" or k == "value_string" then
        M.stats.value_reads = M.stats.value_reads + 1
        return raw._value
      end
      if k == "is_automated" then return raw._automated_check and raw._automated_check(p) or false end
      return raw[k]
    end,
    __newindex = function(_, k, v)
      if k == "value" or k == "value_string" then
        M.stats.value_writes = M.stats.value_writes + 1
      end
      raw[k] = v
    end,
    __eq = no_eq,
  })
end

function M.device(path, display_name, params)
  return setmetatable({ device_path = path, display_name = display_name, name = display_name, parameters = params },
    { __eq = no_eq })
end

--------------------------------------------------------------------------------
-- automation

local function new_automation(param, device, lines)
  local a = { _points = {}, _playmode = 2, dest_parameter = param, dest_device = device, length = lines }
  a.points_observable = M.observable(a)
  a.playmode_observable = M.observable(a)
  local mt = {}
  mt.__index = function(_, k)
    if k == "points" then
      local out = {}
      for i, p in ipairs(a._points) do out[i] = { time = p.time, value = p.value, scaling = p.scaling } end
      return out
    elseif k == "playmode" then
      return a._playmode
    end
    return nil
  end
  mt.__newindex = function(_, k, v)
    if k == "points" then
      local seen = {}
      local list = {}
      for i, p in ipairs(v) do
        local q = math.floor(p.time * 256 + 0.5) / 256
        if seen[q] then error("multiple points for the same time", 2) end
        if q < 1 or q >= lines + 1 then error("time out of range: " .. q, 2) end
        if p.value < 0 or p.value > 1 then error("value out of range", 2) end
        seen[q] = true
        list[i] = { time = q, value = p.value, scaling = p.scaling or 0 }
      end
      table.sort(list, function(x, y) return x.time < y.time end)
      a._points = list
      a.points_observable:fire()
    elseif k == "playmode" then
      a._playmode = v
      a.playmode_observable:fire()
    else
      rawset(a, k, v)
    end
  end
  return setmetatable({}, { __index = function(_, k)
    local v = mt.__index(nil, k)
    if v ~= nil then return v end
    return a[k]
  end, __newindex = mt.__newindex })
end

local function new_pattern_track(song, pattern, track)
  local pt = { automation = {}, is_alias = false, alias_pattern_index = 0, _pattern = pattern, _track = track }
  pt.automation_observable = M.observable(pt)
  pt.alias_pattern_index_observable = M.observable(pt)
  function pt:find_automation(param)
    if self._track._dead then error("track deleted", 2) end
    for _, a in ipairs(self.automation) do
      if rawequal(a.dest_parameter, param) then return a end
    end
    return nil
  end
  function pt:create_automation(param)
    if self:find_automation(param) then error("automation already exists", 2) end
    if not param.is_automatable then error("parameter is not automatable", 2) end
    local dev
    for _, d in ipairs(self._track.devices) do
      for _, p in ipairs(d.parameters) do
        if rawequal(p, param) then dev = d end
      end
    end
    local a = new_automation(param, dev, self._pattern.number_of_lines)
    self.automation[#self.automation + 1] = a
    song._changes = song._changes + 1
    self.automation_observable:fire()
    return a
  end
  function pt:delete_automation(param)
    for i, a in ipairs(self.automation) do
      if rawequal(a.dest_parameter, param) then
        table.remove(self.automation, i)
        a.points_observable.owner = { _dead = true }
        a.playmode_observable.owner = { _dead = true }
        self.automation_observable:fire()
        return
      end
    end
    error("automation not found", 2)
  end
  return pt
end

--------------------------------------------------------------------------------
-- song

-- spec = { tracks = { { name, devices = { device... } } }, patterns = { lines... }, sequence = { pattern indices } }
function M.song(spec)
  local song = { tracks = {}, patterns = {}, _undo = {}, _changes = 0, tool_data = nil }
  song.tracks_observable = M.observable()
  song.patterns_observable = M.observable()
  song.selected_track_index_observable = M.observable()
  song.selected_sequence_index_observable = M.observable()
  song.selected_automation_parameter_observable = M.observable()
  song.selected_track_index = 1
  song.selected_sequence_index = 1
  -- selected_automation_parameter / _device behave like Renoise properties:
  -- assigning the parameter also sets its device and fires the observable.
  song._sel_param = nil
  song.selection_assignments = 0
  setmetatable(song, {
    __index = function(t, k)
      if k == "selected_automation_parameter" then return rawget(t, "_sel_param") end
      if k == "selected_automation_device" then
        local p = rawget(t, "_sel_param")
        if not p then return nil end
        for _, track in ipairs(t.tracks) do
          for _, d in ipairs(track.devices) do
            for _, q in ipairs(d.parameters) do
              if rawequal(q, p) then return d end
            end
          end
        end
        return nil
      end
      return nil
    end,
    __newindex = function(t, k, v)
      if k == "selected_automation_parameter" then
        rawset(t, "_sel_param", v)
        rawset(t, "selection_assignments", t.selection_assignments + 1)
        t.selected_automation_parameter_observable:fire()
      else
        rawset(t, k, v)
      end
    end,
  })
  song.transport = {
    playing = false, lpb = 4, follow_player = true,
    playback_pos = { sequence = 1, line = 1 },
    playing_observable = M.observable(),
    lpb_observable = M.observable(),
    follow_player_observable = M.observable(),
  }
  song.sequencer = { pattern_sequence = spec.sequence or { 1 }, pattern_sequence_observable = M.observable() }

  for ti, t in ipairs(spec.tracks) do
    local track = { name = t.name, devices = t.devices or {} }
    track.devices_observable = M.observable(track)
    song.tracks[ti] = track
  end
  for pi, lines in ipairs(spec.patterns) do
    local pattern = { number_of_lines = lines, tracks = {} }
    pattern.number_of_lines_observable = M.observable(pattern)
    for ti, track in ipairs(song.tracks) do
      pattern.tracks[ti] = new_pattern_track(song, pattern, track)
    end
    song.patterns[pi] = pattern
  end

  -- is_automated: true when any pattern track has automation for the parameter
  local function automated(param)
    for _, pattern in ipairs(song.patterns) do
      for _, pt in ipairs(pattern.tracks) do
        for _, a in ipairs(pt.automation) do
          if rawequal(a.dest_parameter, param) then return true end
        end
      end
    end
    return false
  end
  for _, track in ipairs(song.tracks) do
    for _, d in ipairs(track.devices) do
      for _, p in ipairs(d.parameters) do p._automated_check = automated end
    end
  end

  function song:describe_undo(desc)
    self._undo[#self._undo + 1] = { desc = desc, batch = false }
  end
  function song:describe_batch_undo(desc, timeout)
    self._undo[#self._undo + 1] = { desc = desc, batch = true, timeout = timeout }
  end
  function song:select_track(i)
    self.selected_track_index = i
    self.selected_track_index_observable:fire()
  end
  function song:select_param(p)
    self.selected_automation_parameter = p
  end
  function song:delete_track(i)
    local track = table.remove(self.tracks, i)
    track._dead = true
    for _, pattern in ipairs(self.patterns) do
      local pt = table.remove(pattern.tracks, i)
      pt._dead = true
      for _, a in ipairs(pt.automation) do
        a.points_observable.owner = { _dead = true }
        a.playmode_observable.owner = { _dead = true }
      end
    end
    if self.selected_track_index > #self.tracks then self.selected_track_index = #self.tracks end
    self.tracks_observable:fire()
  end
  function song:delete_device(ti, di)
    local track = self.tracks[ti]
    local dev = table.remove(track.devices, di)
    for _, pattern in ipairs(self.patterns) do
      local pt = pattern.tracks[ti]
      for k = #pt.automation, 1, -1 do
        local a = pt.automation[k]
        if rawequal(a.dest_device, dev) then
          a.points_observable.owner = { _dead = true }
          a.playmode_observable.owner = { _dead = true }
          table.remove(pt.automation, k)
        end
      end
    end
    track.devices_observable:fire()
  end
  return song
end

-- Convenience: add automation with points { {time, value}, ... }.
function M.automate(song, pattern_index, track_index, param, points, playmode)
  local pt = song.patterns[pattern_index].tracks[track_index]
  local a = pt:create_automation(param)
  local list = {}
  for i, p in ipairs(points) do list[i] = { time = p[1], value = p[2], scaling = 0 } end
  a.points = list
  if playmode then a.playmode = playmode end
  return a
end

return M
