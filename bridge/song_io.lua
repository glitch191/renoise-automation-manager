-- Reads the song into the editor document and writes editor commits back.
-- This is the only module, with the UI, that touches renoise.Song objects.
-- It never reads or writes parameter.value or value_string.

local P = require "core.points"
local TL = require "core.timeline"
local Pal = require "core.palette"

local IO = {}

IO.PLAYMODE_LINES = 2

-- Stable lane key: device path, rank of that device among identical devices
-- of the track, parameter index.
function IO.lane_key(device_path, occurrence, param_index)
  return string.format("%s#%d:%d", device_path, occurrence, param_index)
end

-- Pattern index that really holds the data of a pattern track (resolves
-- pattern track aliases). Returns pattern_index, is_alias.
function IO.resolve_pattern(song, pattern_index, track_index)
  local pi = pattern_index
  local alias = false
  for _ = 1, 8 do
    local pattern = song.patterns[pi]
    if not pattern then break end
    local pt = pattern.tracks[track_index]
    if not pt or not pt.is_alias or pt.alias_pattern_index == 0 then break end
    pi = pt.alias_pattern_index
    alias = true
  end
  return pi, alias
end

-- Timeline entries for the sequence range [from, to] of a track.
function IO.entries(song, track_index, from, to)
  local seq = song.sequencer.pattern_sequence
  return TL.entries_for_range(seq, from, to, function(pi)
    local resolved, alias = IO.resolve_pattern(song, pi, track_index)
    local pattern = song.patterns[resolved] or song.patterns[pi]
    return pattern.number_of_lines, resolved, alias
  end)
end

-- Iterate over the parameters of a track: fn(device, device_index, occurrence, param, param_index)
local function each_param(track, fn)
  local occ = {}
  local devices = track.devices
  for di = 1, #devices do
    local dev = devices[di]
    local path = dev.device_path
    occ[path] = (occ[path] or 0) + 1
    local params = dev.parameters
    for pi = 1, #params do
      if fn(dev, di, occ[path], params[pi], pi) == false then return end
    end
  end
end

local function info_of(dev, param)
  return {
    name = param.name,
    device_path = dev.device_path,
    value_min = param.value_min,
    value_max = param.value_max,
    value_quantum = param.value_quantum,
  }
end

-- Build the editor document for a track over the given timeline entries.
-- td_track: the per-track part of the tool data (hidden, colors); it is
-- updated with colors for new lanes. Returns doc, colors_changed.
function IO.build_doc(song, track_index, entries, td_track, editable)
  local tl = TL.build(entries, { editable = editable })
  local track = song.tracks[track_index]
  local doc = { timeline = tl, lanes = {}, track_index = track_index }
  if not track then return doc, false end

  local patterns, seen = {}, {}
  for i = 1, #tl.segments do
    local pi = tl.segments[i].pattern
    if not seen[pi] then
      seen[pi] = true
      patterns[#patterns + 1] = pi
    end
  end

  local keys = {}
  each_param(track, function(dev, di, occ, param, pidx)
    if param.is_automated then
      local lane = nil
      for k = 1, #patterns do
        local pi = patterns[k]
        local pattern = song.patterns[pi]
        local pt = pattern and pattern.tracks[track_index]
        local a = pt and pt:find_automation(param)
        if a then
          if not lane then
            lane = {
              key = IO.lane_key(dev.device_path, occ, pidx),
              name = dev.display_name .. ": " .. param.name,
              device_index = di, param_index = pidx,
              info = info_of(dev, param),
              data = {},
              hidden = false,
              playmode = nil,
            }
          end
          lane.data[pi] = {
            points = P.from_renoise(a.points),
            exists = true,
            rev = 1,
            lines = pattern.number_of_lines,
            playmode = a.playmode,
          }
          lane.playmode = lane.playmode or a.playmode
        end
      end
      if lane then
        lane.playmode = lane.playmode or IO.PLAYMODE_LINES
        doc.lanes[#doc.lanes + 1] = lane
        keys[#keys + 1] = lane.key
      end
    end
  end)

  local colors, changed = Pal.assign(td_track.colors, keys)
  td_track.colors = colors
  for i = 1, #doc.lanes do
    local lane = doc.lanes[i]
    lane.color = Pal.color(colors[lane.key])
    lane.hidden = td_track.hidden[lane.key] == true
  end
  return doc, changed
end

-- Re-read only the points and playmodes of the lanes already in the document.
-- Returns true when something differs from the document.
function IO.refresh_points(song, doc)
  local changed = false
  local ti = doc.track_index
  local track = song.tracks[ti]
  if not track then return false end
  for i = 1, #doc.lanes do
    local lane = doc.lanes[i]
    local dev = track.devices[lane.device_index]
    local param = dev and dev.parameters[lane.param_index]
    if param then
      for pi, data in pairs(lane.data) do
        local pattern = song.patterns[pi]
        local pt = pattern and pattern.tracks[ti]
        local a = pt and pt:find_automation(param)
        if a then
          local pts = P.from_renoise(a.points)
          local same = (#pts == #data.points) and data.playmode == a.playmode and data.exists
          if same then
            for k = 1, #pts do
              local p, q = pts[k], data.points[k]
              if p.t ~= q.t or p.v ~= q.v or p.s ~= q.s then
                same = false
                break
              end
            end
          end
          if not same then
            data.points = pts
            data.playmode = a.playmode
            data.exists = true
            data.rev = (data.rev or 0) + 1
            changed = true
          end
        elseif data.exists or #data.points > 0 then
          data.points = {}
          data.exists = false
          data.rev = (data.rev or 0) + 1
          changed = true
        end
      end
    end
  end
  return changed
end

function IO.lane_param(song, doc, lane)
  local track = song.tracks[doc.track_index]
  local dev = track and track.devices[lane.device_index]
  return dev and dev.parameters[lane.param_index], dev
end

-- Write an editor commit into the song as one undo step.
-- Returns ok, error message.
function IO.apply_commit(song, doc, commit)
  if not commit or #commit.writes == 0 then return true end
  if commit.batch then
    song:describe_batch_undo(commit.description, 1500)
  else
    song:describe_undo(commit.description)
  end
  local errors = {}
  for i = 1, #commit.writes do
    local w = commit.writes[i]
    local ok, err = pcall(function()
      local lane
      for k = 1, #doc.lanes do
        if doc.lanes[k].key == w.key then lane = doc.lanes[k] end
      end
      assert(lane, "lane not found: " .. tostring(w.key))
      local param = IO.lane_param(song, doc, lane)
      assert(param, "parameter not found for " .. lane.name)
      local pattern = song.patterns[w.pattern]
      assert(pattern, "pattern not found: " .. tostring(w.pattern))
      local pt = pattern.tracks[doc.track_index]
      local a = pt:find_automation(param)
      if w.delete then
        if a then pt:delete_automation(param) end
        return
      end
      if not a then
        assert(param.is_automatable, lane.name .. " is not automatable")
        a = pt:create_automation(param)
      end
      if w.playmode then a.playmode = w.playmode end
      if w.points then a.points = P.to_renoise(w.points) end
    end)
    if not ok then errors[#errors + 1] = tostring(err) end
  end
  if #errors > 0 then return false, table.concat(errors, "; ") end
  return true
end

-- Automatable parameters of a track without automation in the given pattern,
-- grouped by device for the Add lane menu.
function IO.addable_params(song, track_index, pattern_index)
  local track = song.tracks[track_index]
  local pattern = song.patterns[pattern_index]
  if not track or not pattern then return {} end
  local pt = pattern.tracks[track_index]
  local out = {}
  each_param(track, function(dev, di, occ, param, pidx)
    if param.is_automatable and not pt:find_automation(param) then
      out[#out + 1] = {
        device_name = dev.display_name, device_index = di, param_index = pidx,
        param_name = param.name, key = IO.lane_key(dev.device_path, occ, pidx),
      }
    end
  end)
  return out
end

function IO.create_lane(song, track_index, pattern_index, device_index, param_index)
  local track = song.tracks[track_index]
  local dev = track and track.devices[device_index]
  local param = dev and dev.parameters[param_index]
  if not param then return false, "Parameter not found." end
  local pt = song.patterns[pattern_index].tracks[track_index]
  if pt:find_automation(param) then return true end
  if not param.is_automatable then return false, param.name .. " is not automatable." end
  song:describe_undo("Multi Automation: Add lane")
  local ok, err = pcall(function() pt:create_automation(param) end)
  if not ok then return false, tostring(err) end
  return true
end

return IO
