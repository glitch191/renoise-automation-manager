-- Synchronisation session between one song and the tool view.
--
-- Responsibilities: follow (or lock) the selected track, build the document
-- for the active time mode, subscribe to every song object the document
-- depends on, collect change notifications as dirty flags and process them
-- on idle, write editor commits as single undo steps, and keep the cross
-- selection with the native automation editor without notification loops.
--
-- The UI registers callbacks in `ui`:
--   on_doc(doc, reason)      document rebuilt (structure changed)
--   on_points()              points changed externally (redraw only)
--   on_activate(key)         Renoise selected another automated parameter
--   on_status(text)          message for the status line
--   on_redraw()              grid relevant change (LPB)

local IO = require "bridge.song_io"
local O = require "bridge.observers"
local D = require "core.tooldata"

local S = {}
S.__index = S

S.MODE_CURRENT = 1
S.MODE_RANGE = 2
S.MODE_NEIGHBOURS = 3

function S.new(song, settings, ui, log)
  local self = setmetatable({}, S)
  self.song = song
  self.log = log or print
  self.ui = ui or {}
  self.settings = settings -- { mode, range_from, range_to, neighbours, follow_playback }
  self.observers = O.new(self.log)
  self.td = D.decode(song.tool_data)
  self.dirty = { structure = true, points = false, selection = false }
  self.writing = false
  self.syncing_selection = false
  self.doc = nil
  self.current_seq = nil
  self.active_key = nil
  self.td_changed = false
  return self
end

--------------------------------------------------------------------------------
-- track and range

function S:locked()
  return self.td.lock.enabled
end

function S:track_index()
  local song = self.song
  if self.td.lock.enabled then
    local t = self.td.lock.track
    if t >= 1 and t <= #song.tracks then return t end
    self.td.lock.enabled = false
    self.td_changed = true
  end
  return song.selected_track_index
end

-- Name and device list of every track, used to follow the per-track
-- settings when tracks are inserted, moved or deleted.
function S:track_prints()
  local prints = {}
  local tracks = self.song.tracks
  for i = 1, #tracks do
    local tr = tracks[i]
    local paths = {}
    local devs = tr.devices or {}
    for k = 1, #devs do paths[k] = devs[k].device_path end
    prints[i] = { name = tr.name or "", devices = table.concat(paths, ",") }
  end
  return prints
end

function S:remap_tracks()
  local ok, changed = pcall(D.remap, self.td, self:track_prints())
  if not ok then
    self.log("[tool_data] " .. tostring(changed))
  elseif changed then
    self.td_changed = true
  end
end

function S:set_lock(enabled)
  self.td.lock.enabled = enabled and true or false
  self.td.lock.track = enabled and self.song.selected_track_index or 0
  local tr = enabled and self.song.tracks[self.td.lock.track]
  self.td.lock.name = tr and tr.name or nil
  self.td_changed = true
  self.dirty.structure = true
end

function S:track_data()
  local idx = self:track_index()
  local t = D.track(self.td, idx)
  if not t.name then
    -- remember which track the entry belongs to (see D.remap)
    local tr = self.song.tracks[idx]
    if tr then
      local paths = {}
      local devs = tr.devices or {}
      for k = 1, #devs do paths[k] = devs[k].device_path end
      t.name, t.devices = tr.name or "", table.concat(paths, ",")
    end
  end
  return t
end

-- Sequence position shown as the current pattern.
function S:center_seq()
  local song = self.song
  local tr = song.transport
  if self.settings.follow_playback and tr.playing then
    return tr.playback_pos.sequence
  end
  return song.selected_sequence_index
end

-- Returns from, to, editable(seq) for the active mode.
function S:range()
  local n = #self.song.sequencer.pattern_sequence
  local mode = self.settings.mode
  local center = self:center_seq()
  if mode == S.MODE_RANGE then
    local a = math.max(1, math.min(n, self.settings.range_from or 1))
    local b = math.max(1, math.min(n, self.settings.range_to or n))
    if a > b then a, b = b, a end
    return a, b, nil
  elseif mode == S.MODE_NEIGHBOURS then
    local k = self.settings.neighbours or 1
    return math.max(1, center - k), math.min(n, center + k), function(seq) return seq == center end
  end
  return center, center, nil
end

--------------------------------------------------------------------------------
-- subscriptions

function S:attach()
  local song = self.song
  local obs = self.observers
  local function structure() self.dirty.structure = true end
  obs:clear("song")
  obs:add("song", song.selected_track_index_observable, function()
    if not self.td.lock.enabled then self.dirty.structure = true end
  end, "selected track")
  obs:add("song", song.selected_sequence_index_observable, function()
    if self.settings.mode ~= S.MODE_RANGE then self.dirty.structure = true end
  end, "selected sequence")
  obs:add("song", song.tracks_observable, structure, "tracks")
  obs:add("song", song.patterns_observable, structure, "patterns")
  obs:add("song", song.sequencer.pattern_sequence_observable, structure, "sequence")
  obs:add("song", song.selected_automation_parameter_observable, function()
    if not self.syncing_selection then self.dirty.selection = true end
  end, "selected parameter")
  obs:add("song", song.transport.playing_observable, function()
    if self.settings.follow_playback and self.settings.mode ~= S.MODE_RANGE then self.dirty.structure = true end
  end, "playing")
  obs:add("song", song.transport.lpb_observable, function()
    if self.ui.on_redraw then self.ui.on_redraw() end
  end, "lpb")
end

function S:detach()
  self.observers:clear_all()
end

function S:subscribe_content()
  local obs = self.observers
  obs:clear("content")
  local doc = self.doc
  if not doc then return end
  local song = self.song
  local ti = doc.track_index
  local track = song.tracks[ti]
  if not track then return end
  local function structure() self.dirty.structure = true end
  local function points()
    if not self.writing then self.dirty.points = true end
  end
  obs:add("content", track.devices_observable, structure, "devices")
  local seen = {}
  local segs = doc.timeline.segments
  for i = 1, #segs do
    -- subscribe to the pattern of the sequence slot and to the resolved one
    local seq_pattern = song.sequencer.pattern_sequence[segs[i].seq]
    for _, pi in ipairs({ seq_pattern, segs[i].pattern }) do
      if pi and not seen[pi] and song.patterns[pi] then
        seen[pi] = true
        local pattern = song.patterns[pi]
        local pt = pattern.tracks[ti]
        obs:add("content", pattern.number_of_lines_observable, structure, "pattern lines")
        if pt then
          obs:add("content", pt.automation_observable, function()
            if not self.writing then self.dirty.structure = true end
          end, "automation list")
          obs:add("content", pt.alias_pattern_index_observable, structure, "alias")
        end
      end
    end
  end
  for i = 1, #doc.lanes do
    local lane = doc.lanes[i]
    local param = IO.lane_param(song, doc, lane)
    if param then
      for pi in pairs(lane.data) do
        local pt = song.patterns[pi] and song.patterns[pi].tracks[ti]
        local a = pt and pt:find_automation(param)
        if a then
          obs:add("content", a.points_observable, points, "points")
          obs:add("content", a.playmode_observable, points, "playmode")
        end
      end
    end
  end
end

--------------------------------------------------------------------------------
-- document

function S:rebuild(reason)
  self.dirty.structure = false
  self.dirty.points = false
  local song = self.song
  self:remap_tracks()
  local ti = self:track_index()
  local from, to, editable = self:range()
  self.current_seq = self:center_seq()
  local doc
  if #song.sequencer.pattern_sequence == 0 or not song.tracks[ti] then
    doc = { timeline = { segments = {}, total_g = 256 }, lanes = {}, track_index = ti }
  else
    local entries = IO.entries(song, ti, from, to)
    local changed
    doc, changed = IO.build_doc(song, ti, entries, self:track_data(), editable)
    if changed then self.td_changed = true end
  end
  self.doc = doc
  self:subscribe_content()
  -- restore the active lane: Renoise selection first, then the stored one
  local key = self:selected_lane_key()
  if not key then key = self:track_data().active end
  if key and not self:lane(key) then key = nil end
  if not key and doc.lanes[1] then
    for i = 1, #doc.lanes do
      if not doc.lanes[i].hidden then key = doc.lanes[i].key break end
    end
  end
  self.active_key = key
  if self.ui.on_doc then self.ui.on_doc(doc, reason or "structure") end
  return doc
end

function S:lane(key)
  if not self.doc then return nil end
  for i = 1, #self.doc.lanes do
    if self.doc.lanes[i].key == key then return self.doc.lanes[i] end
  end
  return nil
end

-- Key of the lane matching the parameter selected in the native Automation
-- editor. Renoise DeviceParameter and AudioDevice objects cannot be compared
-- with ==, so the match uses the device (path and display name) and the
-- parameter name, on the selected track only.
function S:selected_lane_key()
  local song, doc = self.song, self.doc
  if not doc or song.selected_track_index ~= doc.track_index then return nil end
  local param = song.selected_automation_parameter
  local dev = song.selected_automation_device
  if not param or not dev then return nil end
  local path, dname, pname = dev.device_path, dev.display_name, param.name
  for i = 1, #doc.lanes do
    local lane = doc.lanes[i]
    local p, d = IO.lane_param(song, doc, lane)
    if p and d and d.device_path == path and d.display_name == dname and p.name == pname then
      return lane.key
    end
  end
  return nil
end

--------------------------------------------------------------------------------
-- idle processing

-- Called from the tool idle notifier. Cheap when nothing changed.
function S:idle(busy)
  if busy then return end -- never rebuild under a running gesture
  local seq = self:center_seq()
  if seq ~= self.current_seq and self.settings.mode ~= S.MODE_RANGE then
    self.dirty.structure = true
  end
  if self.dirty.structure then
    self:rebuild("structure")
    self.dirty.selection = false
  elseif self.dirty.points then
    self.dirty.points = false
    if self.doc and IO.refresh_points(self.song, self.doc) then
      if self.ui.on_points then self.ui.on_points() end
    end
  end
  if self.dirty.selection then
    self.dirty.selection = false
    local key = self:selected_lane_key()
    if key and key ~= self.active_key then
      self.active_key = key
      self:track_data().active = key
      self.td_changed = true
      if self.ui.on_activate then self.ui.on_activate(key) end
    end
  end
end

--------------------------------------------------------------------------------
-- actions from the UI

function S:commit(commit)
  if not commit or not self.doc then return true end
  self.writing = true
  local ok, err = IO.apply_commit(self.song, self.doc, commit)
  self.writing = false
  -- creating an automation changes the lists we are subscribed to
  for i = 1, #commit.writes do
    if commit.writes[i].create or commit.writes[i].delete then self.dirty.structure = true end
  end
  if not ok then
    self.log("[commit] " .. tostring(err))
    if self.ui.on_status then self.ui.on_status("Could not write: " .. tostring(err)) end
    self.dirty.structure = true
  else
    -- read back what Renoise stored (it may quantize)
    IO.refresh_points(self.song, self.doc)
  end
  return ok, err
end

function S:set_active(key)
  self.active_key = key
  local tr = self:track_data()
  if tr.active ~= key then
    tr.active = key
    self.td_changed = true
  end
  local lane = self:lane(key)
  if not lane then return end
  local param = IO.lane_param(self.song, self.doc, lane)
  if param and self:selected_lane_key() ~= key then
    self.syncing_selection = true
    local ok, err = pcall(function() self.song.selected_automation_parameter = param end)
    self.syncing_selection = false
    if not ok then self.log("[selection] " .. tostring(err)) end
  end
end

function S:set_hidden(key, hidden)
  local tr = self:track_data()
  tr.hidden[key] = hidden and true or nil
  self.td_changed = true
  local lane = self:lane(key)
  if lane then lane.hidden = hidden and true or false end
end

-- Pattern that receives new lanes: the center pattern of the view.
function S:target_pattern()
  if not self.doc then return nil end
  local seq = self:center_seq()
  local segs = self.doc.timeline.segments
  for i = 1, #segs do
    if segs[i].seq == seq then return segs[i].pattern end
  end
  return segs[1] and segs[1].pattern
end

function S:add_lane(device_index, param_index, key)
  local pattern = self:target_pattern()
  if not pattern then return false, "No pattern." end
  self.writing = true
  local ok, err = IO.create_lane(self.song, self:track_index(), pattern, device_index, param_index)
  self.writing = false
  if ok then
    self:track_data().active = key
    self.td_changed = true
    self:rebuild("lane added")
    self:set_active(key)
  end
  return ok, err
end

-- Global time of the playhead in the current timeline, or nil.
function S:playhead_g()
  local tr = self.song.transport
  if not tr.playing or not self.doc then return nil end
  local pos = tr.playback_pos
  local segs = self.doc.timeline.segments
  for i = 1, #segs do
    local s = segs[i]
    if s.seq == pos.sequence then return s.offset + (pos.line - 1) * 256 end
  end
  return nil
end

function S:save_tool_data()
  if not self.td_changed then return end
  local ok, err = pcall(function() self.song.tool_data = D.encode(self.td) end)
  if ok then self.td_changed = false else self.log("[tool_data] " .. tostring(err)) end
end

return S
