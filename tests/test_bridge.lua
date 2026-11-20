local M = require "tests.mock_renoise"
local IO = require "bridge.song_io"
local O = require "bridge.observers"
local S = require "bridge.session"
local D = require "core.tooldata"
local E = require "core.editor"
local X = require "tests.fixtures"

local NATIVE = "Audio/Effects/Native/"

-- Fictitious song: 2 tracks, filter + delay on track 1, 3 patterns.
local function make_song()
  local cutoff, reso = M.param("Cutoff"), M.param("Resonance")
  local fb, mix = M.param("Feedback"), M.param("Mix")
  local hidden = M.param("Hidden", { automatable = false })
  local filter = M.device(NATIVE .. "Filter", "Filter", { cutoff, reso, hidden })
  local delay = M.device(NATIVE .. "Delay", "Delay", { fb, mix })
  local song = M.song({
    tracks = { { name = "Bass", devices = { filter, delay } }, { name = "Lead", devices = {} } },
    patterns = { 16, 16, 32 },
    sequence = { 1, 2, 1, 3 },
  })
  M.automate(song, 1, 1, cutoff, { { 1, 0.2 }, { 9, 0.8 } })
  M.automate(song, 2, 1, cutoff, { { 1, 0.5 } })
  M.automate(song, 1, 1, fb, { { 5, 0.4 } }, 3)
  return song, { cutoff = cutoff, reso = reso, fb = fb, mix = mix, hidden = hidden, filter = filter, delay = delay }
end

local function settings(mode)
  return { mode = mode or S.MODE_CURRENT, range_from = 1, range_to = 4, neighbours = 1, follow_playback = true }
end

T.test("build_doc lists automated parameters with stable keys and colors", function()
  local song = make_song()
  local td = D.track(D.default(), 1)
  local doc, changed = IO.build_doc(song, 1, IO.entries(song, 1, 1, 1), td)
  T.eq(#doc.lanes, 2)
  T.eq(doc.lanes[1].name, "Filter: Cutoff")
  T.eq(doc.lanes[1].key, NATIVE .. "Filter#1:1")
  T.eq(doc.lanes[2].name, "Delay: Feedback")
  T.eq(doc.lanes[2].playmode, 3)
  T.ok(changed)
  T.eq(td.colors[doc.lanes[1].key], 1)
  T.eq(doc.lanes[1].data[1].points, { { t = 256, v = 0.2, s = 0 }, { t = 9 * 256, v = 0.8, s = 0 } })
  -- second build keeps colors
  local _, changed2 = IO.build_doc(song, 1, IO.entries(song, 1, 1, 1), td)
  T.ok(not changed2)
end)

T.test("pattern range: repeated pattern flagged, all points read", function()
  local song = make_song()
  local doc = IO.build_doc(song, 1, IO.entries(song, 1, 1, 4), D.track(D.default(), 1))
  local segs = doc.timeline.segments
  T.eq(#segs, 4)
  T.ok(segs[1].repeated and segs[3].repeated)
  T.eq(doc.timeline.total_g, (16 + 16 + 16 + 32) * 256)
  local cutoff = doc.lanes[1]
  T.eq(#cutoff.data[1].points, 2)
  T.eq(#cutoff.data[2].points, 1)
  T.eq(cutoff.data[3], nil, "no automation in pattern 3")
end)

T.test("pattern track alias is resolved to its source pattern", function()
  local song, p = make_song()
  local pt = song.patterns[3].tracks[1]
  pt.is_alias = true
  pt.alias_pattern_index = 2
  local entries = IO.entries(song, 1, 4, 4)
  T.eq(entries[1].pattern, 2)
  T.ok(entries[1].track_alias)
  local doc = IO.build_doc(song, 1, entries, D.track(D.default(), 1))
  T.eq(doc.lanes[1].data[2].points[1].v, 0.5)
end)

T.test("hidden lanes come from the tool data", function()
  local song = make_song()
  local td = D.track(D.default(), 1)
  td.hidden[NATIVE .. "Delay#1:1"] = true
  local doc = IO.build_doc(song, 1, IO.entries(song, 1, 1, 1), td)
  T.ok(doc.lanes[2].hidden)
  T.ok(not doc.lanes[1].hidden)
end)

T.test("apply_commit writes the right pattern in one undo step", function()
  local song, p = make_song()
  local doc = IO.build_doc(song, 1, IO.entries(song, 1, 1, 4), D.track(D.default(), 1))
  local commit = { description = "Multi Automation: Draw line", writes = {
    { key = doc.lanes[1].key, pattern = 1, points = { { t = 256, v = 0, s = 0 } } },
    { key = doc.lanes[1].key, pattern = 3, points = { { t = 512, v = 1, s = 0 } }, create = true, playmode = 1 },
  } }
  local ok, err = IO.apply_commit(song, doc, commit)
  T.ok(ok, err)
  T.eq(#song._undo, 1)
  T.eq(song._undo[1].desc, "Multi Automation: Draw line")
  T.eq(song.patterns[1].tracks[1]:find_automation(p.cutoff).points, { { time = 1, value = 0, scaling = 0 } })
  local a3 = song.patterns[3].tracks[1]:find_automation(p.cutoff)
  T.eq(a3.points, { { time = 2, value = 1, scaling = 0 } })
  T.eq(a3.playmode, 1)
end)

T.test("batch commits use describe_batch_undo", function()
  local song = make_song()
  local doc = IO.build_doc(song, 1, IO.entries(song, 1, 1, 1), D.track(D.default(), 1))
  IO.apply_commit(song, doc, { description = "Multi Automation: Scale points", batch = true,
    writes = { { key = doc.lanes[1].key, pattern = 1, points = {} } } })
  T.ok(song._undo[1].batch)
end)

T.test("apply_commit reports errors instead of raising", function()
  local song = make_song()
  local doc = IO.build_doc(song, 1, IO.entries(song, 1, 1, 1), D.track(D.default(), 1))
  local ok, err = IO.apply_commit(song, doc, { description = "x", writes = {
    { key = doc.lanes[1].key, pattern = 1, points = { { t = 256, v = 0 }, { t = 256, v = 1 } } },
  } })
  T.ok(not ok)
  T.ok(err:find("same time"), err)
end)

T.test("refresh_points detects external edits", function()
  local song, p = make_song()
  local doc = IO.build_doc(song, 1, IO.entries(song, 1, 1, 1), D.track(D.default(), 1))
  T.ok(not IO.refresh_points(song, doc))
  local a = song.patterns[1].tracks[1]:find_automation(p.cutoff)
  a.points = { { time = 2, value = 0.3 } }
  T.ok(IO.refresh_points(song, doc))
  T.eq(doc.lanes[1].data[1].points, { { t = 512, v = 0.3, s = 0 } })
end)

T.test("addable params skip automated and non automatable ones; create_lane", function()
  local song, p = make_song()
  local list = IO.addable_params(song, 1, 1)
  local names = {}
  for _, e in ipairs(list) do names[#names + 1] = e.device_name .. ": " .. e.param_name end
  T.eq(names, { "Filter: Resonance", "Delay: Mix" })
  local ok = IO.create_lane(song, 1, 1, 1, 2)
  T.ok(ok)
  T.ok(song.patterns[1].tracks[1]:find_automation(p.reso))
  T.eq(song._undo[#song._undo].desc, "Multi Automation: Add lane")
end)

T.test("observers catch callback errors and detach safely", function()
  local logged = {}
  local obs = O.new(function(m) logged[#logged + 1] = m end)
  local owner = {}
  local o = M.observable(owner)
  obs:add("g", o, function() error("boom") end)
  o:fire()
  T.eq(#logged, 1)
  T.eq(obs:count("g"), 1)
  owner._dead = true
  obs:clear("g") -- must not raise although the owner is gone
  T.eq(obs:count(), 0)
end)

T.test("reading values never touches parameter.value", function()
  M.stats.value_reads, M.stats.value_writes = 0, 0
  local song = make_song()
  local doc = IO.build_doc(song, 1, IO.entries(song, 1, 1, 4), D.track(D.default(), 1))
  local F = require "core.valuefmt"
  for _, lane in ipairs(doc.lanes) do F.label(lane.name, 1, 256, lane.info, 0.5) end
  IO.refresh_points(song, doc)
  T.eq(M.stats.value_reads, 0)
  T.eq(M.stats.value_writes, 0)
end)

--------------------------------------------------------------------------------
-- session

local function session(song, mode)
  local calls = { doc = 0, points = 0, activate = {} }
  local s = S.new(song, settings(mode), {
    on_doc = function() calls.doc = calls.doc + 1 end,
    on_points = function() calls.points = calls.points + 1 end,
    on_activate = function(k) calls.activate[#calls.activate + 1] = k end,
    on_status = function() end,
  }, function(m) error("unexpected log: " .. m) end)
  s:attach()
  s:rebuild()
  return s, calls
end

T.test("session follows the selected track unless locked", function()
  local song = make_song()
  local s, calls = session(song)
  T.eq(#s.doc.lanes, 2)
  song:select_track(2)
  s:idle()
  T.eq(s.doc.track_index, 2)
  T.eq(#s.doc.lanes, 0)
  song:select_track(1)
  s:idle()
  s:set_lock(true)
  s:idle()
  song:select_track(2)
  s:idle()
  T.eq(s.doc.track_index, 1, "locked on track 1")
end)

T.test("external point edits refresh the view on idle", function()
  local song, p = make_song()
  local s, calls = session(song)
  song.patterns[1].tracks[1]:find_automation(p.cutoff).points = { { time = 3, value = 1 } }
  T.ok(s.dirty.points)
  s:idle()
  T.eq(calls.points, 1)
  T.eq(s.doc.lanes[1].data[1].points[1].t, 768)
end)

T.test("own commits do not trigger a refresh loop", function()
  local song = make_song()
  local s, calls = session(song)
  local before = calls.doc
  s:commit({ description = "Multi Automation: Move points", writes = {
    { key = s.doc.lanes[1].key, pattern = 1, points = { { t = 512, v = 0.1, s = 0 } } } } })
  T.ok(not s.dirty.points)
  s:idle()
  T.eq(calls.points, 0)
  T.eq(calls.doc, before)
end)

T.test("cross selection works both ways without loops", function()
  local song, p = make_song()
  local s, calls = session(song)
  -- tool -> Renoise
  s:set_active(s.doc.lanes[2].key)
  T.ok(rawequal(song.selected_automation_parameter, p.fb))
  T.ok(not s.dirty.selection, "own assignment ignored")
  -- the same lane again: no second assignment
  local n = song.selection_assignments
  s:set_active(s.doc.lanes[2].key)
  T.eq(song.selection_assignments, n)
  -- Renoise -> tool
  song:select_param(p.cutoff)
  s:idle()
  T.eq(calls.activate[1], s.doc.lanes[1].key)
  T.eq(s.active_key, s.doc.lanes[1].key)
end)

T.test("selection on another track is ignored when the view is locked", function()
  local song, p = make_song()
  local s, calls = session(song)
  s:set_lock(true)
  s:idle()
  song.selected_track_index = 2
  song:select_param(p.cutoff)
  s:idle()
  T.eq(#calls.activate, 0)
end)

T.test("mode changes rebuild without comparing parameters with ==", function()
  local song, p = make_song()
  song:select_param(p.fb)
  for _, mode in ipairs({ S.MODE_RANGE, S.MODE_NEIGHBOURS, S.MODE_CURRENT }) do
    local s = session(song, mode)
    T.eq(s.active_key, NATIVE .. "Delay#1:1", "selected parameter restored as active lane")
  end
end)

T.test("deleting a track, a device or an automation never raises", function()
  local song, p = make_song()
  local s = session(song, S.MODE_RANGE)
  song:delete_device(1, 2) -- delay
  s:idle()
  T.eq(#s.doc.lanes, 1)
  song.patterns[1].tracks[1]:delete_automation(p.cutoff)
  s:idle()
  song:delete_track(1)
  s:idle()
  T.eq(s.doc.track_index, 1)
  T.eq(#s.doc.lanes, 0, "former track 2 has no automation")
  s:detach()
  T.eq(s.observers:count(), 0)
end)

T.test("locked track deleted: lock released", function()
  local song = make_song()
  local s = session(song)
  song:select_track(2)
  s:idle()
  s:set_lock(true)
  song:delete_track(2)
  s:idle()
  T.ok(not s:locked())
end)

T.test("neighbours mode: only the center pattern is editable", function()
  local song = make_song()
  song.selected_sequence_index = 2
  local s = session(song, S.MODE_NEIGHBOURS)
  local segs = s.doc.timeline.segments
  T.eq(#segs, 3)
  T.ok(not segs[1].editable and segs[2].editable and not segs[3].editable)
end)

T.test("current mode follows the selected sequence position", function()
  local song = make_song()
  local s = session(song)
  song.selected_sequence_index = 4
  song.selected_sequence_index_observable:fire()
  s:idle()
  T.eq(s.doc.timeline.segments[1].pattern, 3)
end)

T.test("playhead position in range mode", function()
  local song = make_song()
  local s = session(song, S.MODE_RANGE)
  song.transport.playing = true
  song.transport.playback_pos = { sequence = 2, line = 5 }
  T.eq(s:playhead_g(), 16 * 256 + 4 * 256)
end)

T.test("tool data is saved only when it changed and survives a reload", function()
  local song = make_song()
  local s = session(song)
  s:set_hidden(s.doc.lanes[2].key, true)
  s:save_tool_data()
  T.ok(type(song.tool_data) == "string")
  local s2 = session(song)
  T.ok(s2.doc.lanes[2].hidden, "hidden state restored")
  T.eq(s2.doc.lanes[1].color, s.doc.lanes[1].color, "same color after reload")
end)

T.test("add lane creates the automation and activates it", function()
  local song, p = make_song()
  local s = session(song)
  local key = IO.lane_key(NATIVE .. "Filter", 1, 2)
  local ok = s:add_lane(1, 2, key)
  T.ok(ok)
  T.eq(s.active_key, key)
  T.ok(s:lane(key))
end)

T.test("editor commit through the session lands in the song", function()
  local song, p = make_song()
  local s = session(song, S.MODE_RANGE)
  local view, dims = X.view_for(s.doc)
  local ed = E.new({ view = view, dims = dims })
  ed:set_doc(s.doc)
  ed.active_key = s.doc.lanes[1].key
  ed.tool = "line"
  local c = ed:commit_line(8 * 256, 0, 24 * 256, 1, 256)
  T.ok(s:commit(c))
  local a1 = song.patterns[1].tracks[1]:find_automation(p.cutoff)
  local a2 = song.patterns[2].tracks[1]:find_automation(p.cutoff)
  T.eq(a1.points[#a1.points].time, 17 - 1 / 256)
  T.eq(a2.points[1].time, 1)
  T.eq(#song._undo, 1)
end)

T.test("hidden lanes and colors follow a moved track", function()
  local song = make_song()
  local s = session(song)
  local key = s.doc.lanes[1].key
  s:set_hidden(key, true)
  local color = s:track_data().colors[key]
  song:swap_tracks(1, 2)
  song:select_track(2)
  s:idle()
  T.eq(s.doc.track_index, 2)
  T.eq(s.doc.lanes[1].hidden, true, "hidden state followed the track")
  T.eq(s:track_data().colors[key], color)
  T.eq(s.td.tracks[1], nil, "nothing left on the track now at index 1")
end)

T.test("a delete write removes the automation and rebuilds the lanes", function()
  local song, p = make_song()
  local s = session(song)
  local key = s.doc.lanes[1].key
  local ok = s:commit({ description = "Multi Automation: Delete envelope", batch = false,
    writes = { { key = key, pattern = 1, delete = true } } })
  T.ok(ok)
  T.eq(song.patterns[1].tracks[1]:find_automation(p.cutoff), nil)
  T.eq(song._undo[#song._undo].desc, "Multi Automation: Delete envelope")
  s:idle()
  T.eq(s.doc.lanes[1].name, "Delay: Feedback", "Cutoff lane gone from the current pattern")
end)
