-- Tool window: toolbar, collapsible legend, canvas with overlay views,
-- status line, settings dialog. Glues the pure editor (core.editor) to the
-- song session (bridge.session).

local L = require "core.layout"
local G = require "core.geometry"
local R = require "core.render"
local E = require "core.editor"
local IO = require "bridge.song_io"
local S = require "bridge.session"
local Prefs = require "bridge.prefs"
local O = require "bridge.observers"

local App = {}
App.__index = App

App.TITLE = "renoise-automation-manager"
App.LABEL_POOL = 24
App.RULER_POOL = 48
App.STATUS_SECONDS = 6

local function log(msg)
  print("[" .. App.TITLE .. "] " .. tostring(msg))
end
App.log = log

-- Theme color names used by the canvas.
local THEME = {
  back = "pattern_default_back",
  grid = "automation_grid",
  pattern = "main_font",
  selection = "selected_button_back",
  readonly = "body_back",
  alias = "automation_marker_pair",
  point_outline = "pattern_default_back",
  playhead = "automation_marker_play",
}

local function theme_color(name)
  local theme = renoise.app().theme
  local ok, c = pcall(function() return theme:color(name) end)
  if ok and type(c) == "table" then return c end
  ok, c = pcall(function() return theme.colors[name] end)
  if ok and type(c) == "table" then return c end
  return { 128, 128, 128 }
end

local function read_version()
  local path = renoise.tool().bundle_path
  if string.sub(path, -1) ~= "/" and string.sub(path, -1) ~= "\\" then path = path .. "/" end
  local f = io.open(path .. "manifest.xml", "r")
  if not f then return "n/a" end
  local text = f:read("*a")
  f:close()
  return string.match(text, "<Version>%s*(.-)%s*</Version>") or "n/a"
end

local function mods_of(flags)
  flags = flags or {}
  return { shift = flags.shift == true, control = flags.control == true, alt = flags.alt == true }
end

--------------------------------------------------------------------------------

function App.new()
  local self = setmetatable({}, App)
  self.prefs = Prefs.create()
  renoise.tool().preferences = self.prefs
  self.version = read_version()
  self.dialog = nil
  self.settings_dialog = nil
  self.session = nil
  self.editor = nil
  self.clipboard = { clip = nil }
  self.views = nil
  self.overlay = {}
  self.colors = nil
  self.cache = R.new_cache()
  self.redraw_pending = false
  self.status_time = nil
  self.diag = { renders = 0, total = 0, worst = 0, lanes = 0, points = 0, ph_count = 0, ph_rate = 0, ph_t0 = os.clock() }
  self.legend_offset = 0
  self.updating = false
  self.view_signature = nil
  self.view_state = nil
  self.app_observers = O.new(log)
  return self
end

function App:is_open()
  return self.dialog ~= nil and self.dialog.visible
end

function App:toggle()
  if self:is_open() then self:close() else self:open() end
end

function App:open()
  if self:is_open() then
    self.dialog:show()
    return
  end
  if not renoise.song() then return end
  self:start_session()
  self:build()
end

function App:close()
  if self.dialog and self.dialog.visible then self.dialog:close() end
  if self.settings_dialog and self.settings_dialog.visible then self.settings_dialog:close() end
  self:stop_session()
  self.dialog = nil
end

--------------------------------------------------------------------------------
-- session

function App:session_settings()
  local p = self.prefs
  return {
    mode = p.time_mode.value,
    range_from = 1,
    range_to = #renoise.song().sequencer.pattern_sequence,
    neighbours = p.neighbours.value,
    follow_playback = p.follow_playback.value,
  }
end

function App:start_session()
  self:stop_session()
  local song = renoise.song()
  local ui = {
    on_doc = function(doc, reason) self:on_doc(doc, reason) end,
    on_points = function() self:on_points() end,
    on_activate = function(key) self:on_activate_from_renoise(key) end,
    on_status = function(text) self:set_status(text) end,
    on_redraw = function() self:request_redraw() end,
  }
  local settings = self.session_settings_cache or self:session_settings()
  self.session = S.new(song, settings, ui, log)
  self.session:attach()
  self.session_settings_cache = settings
  local p = self.prefs
  self.editor = E.new({
    clipboard = self.clipboard,
    cache = self.cache,
    tool = E.TOOLS[p.tool.value] or "edit",
    snap = p.snap_enabled.value,
    grid = E.GRIDS[p.snap_grid.value] or 256,
    vectorize_tolerance = p.vectorize_tolerance.value / 100,
    live_writes = p.live_writes.value,
  })
  self.app_observers:clear("theme")
  self.app_observers:add("theme", renoise.app().theme_observable, function()
    self.colors = nil
    self.zoomed_state = nil
    if self.views then
      self:refresh_legend()
      self:update_labels()
    end
    self:request_redraw()
  end, "theme")
end

function App:stop_session()
  if self.session then
    self.session:save_tool_data()
    self.session:detach()
  end
  self.app_observers:clear_all()
  self.session = nil
  R.clear_cache(self.cache)
end

-- New song loaded: reconnect when the window is open.
function App:on_new_document()
  self.session_settings_cache = nil
  self.view_state = nil
  self.view_signature = nil
  if self:is_open() then
    self:start_session()
    self:build()
  end
end

function App:on_release_document()
  if self.session then
    self.session:detach()
    self.session = nil
  end
end

function App:on_will_save()
  if self.session then self.session:save_tool_data() end
end

--------------------------------------------------------------------------------
-- build the window

function App:dims()
  local w, h = Prefs.size(self.prefs)
  return L.compute(w, h, self.prefs.ui_zoom.value, self.prefs.legend_visible.value)
end

function App:build()
  if self.dialog and self.dialog.visible then self.dialog:close() end
  local vb = renoise.ViewBuilder()
  local d = self:dims()
  self.d = d
  local p = self.prefs
  local views = { vb = vb }
  self.views = views
  self.zoomed_state = nil

  local ch = d.control_h

  -- toolbar ---------------------------------------------------------------
  views.mode = vb:popup {
    items = Prefs.TIME_MODES, value = p.time_mode.value, width = L.W.mode, height = ch,
    tooltip = "Time mode: Current pattern, Pattern range (several sequence positions), Pattern + neighbours (read only neighbours)",
    notifier = function(v) self:set_mode(v) end,
  }
  views.range_from = vb:valuebox {
    min = 0, max = 0, value = 0, width = 48, height = ch,
    tooltip = "First sequence position of the range",
    notifier = function(v) self:set_range(v + 1, nil) end,
  }
  views.range_to = vb:valuebox {
    min = 0, max = 0, value = 0, width = 48, height = ch,
    tooltip = "Last sequence position of the range",
    notifier = function(v) self:set_range(nil, v + 1) end,
  }
  views.whole_song = vb:button {
    text = "Song", width = 46, height = ch,
    tooltip = "Whole song: show every sequence position",
    notifier = function() self:whole_song() end,
  }
  views.range_group = vb:row { spacing = 0, views = { views.range_from, views.range_to, views.whole_song } }
  views.neighbours = vb:valuebox {
    min = 1, max = 4, value = p.neighbours.value, width = 60, height = ch,
    tooltip = "Number of neighbour patterns shown before and after the current one (1 to 4)",
    notifier = function(v) self:set_neighbours(v) end,
  }
  views.mode_extra = vb:row { width = L.W.range, views = { views.range_group, views.neighbours } }

  views.tool = vb:switch {
    items = E.TOOL_LABELS, width = L.W.tool, height = ch,
    value = self:tool_index(),
    tooltip = "Tool: Edit (E), Pencil (P), Line (L), Select (S)",
    notifier = function(v) self:set_tool(v) end,
  }
  views.snap = vb:checkbox {
    value = p.snap_enabled.value, width = ch, height = ch,
    tooltip = "Snap to grid (hold Shift while dragging for fine, unsnapped moves)",
    notifier = function(v) self:set_snap(v) end,
  }
  views.grid = vb:popup {
    items = E.GRID_LABELS, value = p.snap_grid.value, width = 64, height = ch,
    tooltip = "Snap grid: Line, 1/2, 1/4, 1/8 of a line, or Free (1/256 line)",
    notifier = function(v) self:set_grid(v) end,
  }
  views.interp = vb:switch {
    items = { "Points", "Lines", "Curves" }, width = L.W.interp, height = ch, value = 2,
    tooltip = "Interpolation (Playmode) of the active lane in the editable patterns",
    notifier = function(v) self:set_playmode(v) end,
  }
  views.vectorize = vb:button {
    text = "Vectorize", width = L.W.vectorize, height = ch,
    tooltip = "Vectorize (V): preview the active lane (or the selection) as Lines without the points a straight line already follows. Wheel: tolerance, Enter or click: apply, Esc: cancel",
    notifier = function() self:vectorize() end,
  }
  views.add_lane = vb:button {
    text = "Add lane", width = L.W.add_lane, height = ch,
    tooltip = "Create a new automation for an automatable parameter of this track",
    notifier = function() self:add_lane_menu() end,
  }
  views.lock = vb:button {
    text = "Lock track", width = L.W.lock, height = ch,
    tooltip = "Lock track: keep showing this track when another track is selected",
    notifier = function() self:toggle_lock() end,
  }
  views.follow = vb:checkbox {
    value = p.follow_playback.value, width = ch, height = ch,
    tooltip = "Follow playback: show the playing pattern and scroll with the playhead",
    notifier = function(v) self:set_follow(v) end,
  }
  views.fit = vb:button {
    text = "Fit", width = L.W.fit, height = ch,
    tooltip = "Fit: show the whole time range (lit while the whole range is shown)",
    notifier = function() self:fit() end,
  }
  views.legend_toggle = vb:button {
    text = "Legend", width = L.W.legend, height = ch,
    tooltip = "Show or hide the legend",
    notifier = function() self:toggle_legend() end,
  }
  views.settings = vb:button {
    text = "Settings", width = L.W.settings, height = ch,
    tooltip = App.TITLE .. " version " .. self.version .. ". Zoom: Ctrl + plus, Ctrl + minus, Ctrl + 0",
    notifier = function() self:show_settings() end,
  }

  local toolbar = vb:row {
    spacing = d.spacing, height = ch,
    views = {
      views.mode, views.mode_extra, views.tool,
      vb:row { views = { views.snap, vb:text { text = "Snap", width = 30, height = ch }, views.grid } },
      views.interp, views.vectorize, views.add_lane, views.lock,
      vb:row { views = { views.follow, vb:text { text = "Follow", width = L.W.follow, height = ch } } },
      views.fit, views.legend_toggle, views.settings,
    },
  }

  -- legend ----------------------------------------------------------------
  local legend
  views.rows = {}
  if p.legend_visible.value then
    local name_w = d.legend_w - d.checkbox_w - d.swatch_w - d.legend_scroll_w - 2 * d.spacing
    local rows_col = vb:column { spacing = 0 }
    for i = 1, d.legend_rows do
      local row = {}
      row.check = vb:checkbox {
        value = true, width = d.checkbox_w, height = d.row_h,
        tooltip = "Show or hide this curve",
        notifier = function(v) self:on_legend_check(i, v) end,
      }
      row.swatch = vb:button {
        text = "", width = d.swatch_w, height = d.row_h,
        tooltip = "Make this curve active",
        notifier = function() self:on_legend_click(i) end,
      }
      row.name = vb:button {
        text = "", width = name_w, height = d.row_h, align = "left",
        tooltip = "Make this curve active (Tab: next curve, Shift + Tab: previous)",
        notifier = function() self:on_legend_click(i) end,
      }
      row.row = vb:row { spacing = d.spacing, views = { row.check, row.swatch, row.name } }
      views.rows[i] = row
      rows_col:add_view(row.row)
    end
    views.legend_scroll = vb:scrollbar {
      min = 0, max = 1, value = 0, pagestep = 1, step = 1,
      width = d.legend_scroll_w, height = d.legend_rows * d.row_h,
      notifier = function(v) self:on_legend_scroll(v) end,
    }
    views.track_name = vb:text { text = "", font = "bold", width = d.legend_w, height = d.row_h }
    legend = vb:column {
      width = d.legend_w, spacing = d.spacing,
      views = { views.track_name, vb:row { spacing = 0, views = { rows_col, views.legend_scroll } } },
    }
  end

  -- canvas and overlays ---------------------------------------------------
  views.playhead = vb:canvas {
    width = d.playhead_w, height = d.canvas_h, mode = "transparent", visible = false,
    render = function(ctx)
      ctx.fill_color = theme_color(THEME.playhead)
      ctx:fill_rect(0, 0, d.playhead_w, d.canvas_h)
    end,
  }
  local hm = d.point_size + 6
  views.hover_mark = vb:canvas {
    width = hm, height = hm, mode = "transparent", visible = false,
    render = function(ctx)
      ctx.stroke_color = theme_color(THEME.selection)
      ctx.line_width = math.max(1, d.zoom)
      ctx:stroke_rect(1, 1, hm - 2, hm - 2)
    end,
  }
  views.label_text = vb:text { text = "", font = "mono", height = d.label_h }
  views.label = vb:row { style = "plain", margin = 2, visible = false, views = { views.label_text } }
  views.empty = vb:text {
    text = E.MSG_NO_LANE, style = "strong", align = "center",
    width = d.canvas_w, height = d.label_h, visible = false,
    origin = { x = 0, y = math.floor(d.canvas_h / 2 - d.label_h / 2) },
  }
  local children = { views.playhead, views.hover_mark, views.empty }
  views.seg_labels = {}
  for i = 1, App.LABEL_POOL do
    local t = vb:text { text = "", font = "bold", style = "strong", height = d.label_h, visible = false }
    views.seg_labels[i] = t
    children[#children + 1] = t
  end
  -- time ruler (line numbers along the bottom) and value axis (left)
  views.ruler = {}
  for i = 1, App.RULER_POOL do
    local t = vb:text { text = "", font = "mono", style = "disabled", height = d.label_h, visible = false }
    views.ruler[i] = t
    children[#children + 1] = t
  end
  views.axis = {}
  for i = 1, 5 do
    local t = vb:text { text = "", font = "mono", style = "disabled", height = d.label_h, visible = false }
    views.axis[i] = t
    children[#children + 1] = t
  end
  children[#children + 1] = views.label

  views.canvas = vb:canvas {
    width = d.canvas_w, height = d.canvas_h, mode = "plain",
    render = function(ctx) self:render(ctx) end,
    mouse_handler = function(ev) return self:on_mouse(ev) end,
    mouse_events = { "down", "up", "double", "drag", "move", "wheel", "exit" },
    views = children,
  }
  views.hscroll = vb:scrollbar {
    min = 0, max = 256, value = 0, pagestep = 256, step = 1,
    width = d.canvas_w, height = d.scrollbar_h,
    notifier = function(v) self:on_hscroll(v) end,
  }
  local canvas_col = vb:column { spacing = d.spacing, views = { views.canvas, views.hscroll } }

  local main_row = vb:row { spacing = d.spacing }
  if legend then main_row:add_view(legend) end
  main_row:add_view(canvas_col)

  -- status ----------------------------------------------------------------
  views.zoom = vb:text { text = "", style = "disabled", width = math.floor(d.total_w * 0.3), height = d.status_h,
    tooltip = "How much of the time range the canvas shows. Ctrl + wheel zooms around the mouse, Fit shows everything." }
  views.status = vb:text { text = "", width = math.floor(d.total_w * 0.35), height = d.status_h }
  views.diag = vb:text { text = "", font = "mono", align = "right", width = math.floor(d.total_w * 0.35) - 2 * d.margin, height = d.status_h, visible = p.diagnostics.value }
  local status_row = vb:row { views = { views.zoom, views.status, views.diag } }

  local content = vb:column {
    margin = d.margin, spacing = d.spacing,
    views = { toolbar, main_row, status_row },
  }

  -- view model sized for the canvas
  local total = (self.session and self.session.doc and self.session.doc.timeline.total_g) or 256
  local view = G.new_view(d.canvas_w, d.canvas_h, d.pad, total)
  -- A fresh window (not a rebuild that keeps its view) must fit the first
  -- document it shows. Without this, reopening the window on an unchanged
  -- song kept the placeholder one line view.
  if not self.view_state then self.view_signature = nil end
  if self.view_state then
    view.start_g, view.span_g = self.view_state.start_g, self.view_state.span_g
    G.clamp(view, total)
  end
  self.view = view
  self.editor.view = view
  self.editor.dims = d

  self.dialog = renoise.app():show_custom_dialog(App.TITLE, content,
    function(dialog, key) return self:on_key(dialog, key) end,
    { send_key_repeat = true, send_key_release = false })

  self:update_mode_controls()
  self:update_lock_button()
  if self.session.doc then
    self:on_doc(self.session.doc, "build")
  else
    self.session:rebuild("build")
  end
end

-- Close and rebuild the window keeping state (size, zoom or legend change).
function App:rebuild_window()
  if not self:is_open() then return end
  self.view_state = { start_g = self.view.start_g, span_g = self.view.span_g }
  self:build()
end

--------------------------------------------------------------------------------
-- document callbacks

local function signature(doc)
  local parts = { tostring(doc.track_index) }
  for _, s in ipairs(doc.timeline.segments) do
    parts[#parts + 1] = s.seq .. ":" .. s.pattern .. ":" .. s.lines
  end
  return table.concat(parts, ",")
end

function App:on_doc(doc, reason)
  if not self.editor then return end
  self.editor:set_doc(doc)
  self.editor.active_key = self.session.active_key
  if not self.views then return end
  local sig = signature(doc)
  if sig ~= self.view_signature then
    self.view_signature = sig
    if self.view_state and reason == "build" then
      G.clamp(self.view, doc.timeline.total_g)
    else
      G.fit(self.view, doc.timeline.total_g)
    end
  else
    G.clamp(self.view, doc.timeline.total_g)
  end
  self.view_state = nil
  self.overlay = {}
  self:hide_hover()
  self:refresh_all()
end

function App:on_points()
  if not self.views then return end
  self.editor:set_doc(self.session.doc)
  self:refresh_interp()
  self:request_redraw()
end

function App:on_activate_from_renoise(key)
  if not self.editor then return end
  self.editor:set_active(key)
  self:refresh_legend()
  self:refresh_interp()
  self:request_redraw()
end

function App:refresh_all()
  self:update_mode_controls()
  self:update_lock_button()
  self:refresh_legend()
  self:refresh_interp()
  self:update_scrollbar()
  self:update_labels()
  self:update_empty_state()
  self:request_redraw()
end

--------------------------------------------------------------------------------
-- rendering

function App:resolve_colors()
  if self.colors then return self.colors end
  local c = {}
  for k, name in pairs(THEME) do c[k] = theme_color(name) end
  self.colors = c
  return c
end

function App:request_redraw()
  if not self.views or self.redraw_pending then return end
  self.redraw_pending = true
  self.views.canvas:update()
end

function App:render(ctx)
  self.redraw_pending = false
  local ok, err = pcall(function()
    local t0 = os.clock()
    local doc = self.session and self.session.doc
    local scene = {
      dims = self.d, view = self.view,
      segments = doc and doc.timeline.segments or {},
      lanes = doc and doc.lanes or {},
      active_key = self.editor.active_key,
      selection = self.editor.selection,
      inactive_alpha = self.prefs.inactive_opacity.value / 100,
      lpb = renoise.song().transport.lpb,
      colors = self:resolve_colors(),
      cache = self.cache,
      overlay = self.overlay,
      preview = self.editor:preview_points(),
    }
    local stats = R.draw(ctx, scene)
    local dt = os.clock() - t0
    local dg = self.diag
    dg.renders = dg.renders + 1
    dg.total = dg.total + dt
    if dt > dg.worst then dg.worst = dt end
    dg.lanes, dg.points = stats.lanes, stats.points
  end)
  if not ok then log("render: " .. tostring(err)) end
end

-- Update a scrollbar range without ever leaving value outside [min, max - pagestep].
local function set_scrollbar(sb, max, pagestep, value, step)
  sb.value = 0
  sb.min = 0
  sb.max = max
  sb.pagestep = pagestep
  if step then sb.step = step end
  sb.value = math.max(0, math.min(max - pagestep, value))
end

-- Update a valuebox range, keeping the current value valid at every step.
local function set_valuebox(box, max, value)
  if box.value > max then box.value = max end
  box.max = max
  box.value = math.max(box.min, math.min(max, value))
end

function App:update_scrollbar()
  local sb = self.views and self.views.hscroll
  if not sb then return end
  self.updating = true
  local total = math.max(1, math.floor(self.editor:total_g()))
  local span = math.max(1, math.min(total, math.floor(self.view.span_g)))
  local ok, err = pcall(set_scrollbar, sb, total, span, math.floor(self.view.start_g), math.max(1, math.floor(span / 20)))
  if not ok then log("scrollbar: " .. tostring(err)) end
  self.updating = false
end

function App:on_hscroll(v)
  if self.updating then return end
  self.view.start_g = v
  G.clamp(self.view, self.editor:total_g())
  self:after_view_change()
end

function App:after_view_change()
  self:update_labels()
  self:hide_hover()
  self:update_playhead(true)
  self:request_redraw()
end

function App:update_labels()
  local pool = self.views and self.views.seg_labels
  if not pool then return end
  local segs = self.editor:segments()
  local zinfo = R.zoom_info(self.view, segs, self.editor:total_g())
  self:update_zoom_indicator(zinfo)
  self:update_ruler(segs)
  -- when zoomed in, always name the pattern under the view, even in
  -- Current pattern mode
  local labels = R.segment_labels(self.view, segs, zinfo.zoomed)
  for i = 1, #pool do
    local lab = labels[i]
    local t = pool[i]
    if lab then
      t.text = lab.text
      t.origin = { x = math.floor(lab.x + 4 * self.d.zoom), y = 1 }
      t.visible = true
    else
      t.visible = false
    end
  end
end

-- Zoom indicator: text under the canvas, and the Fit button drawn as
-- selected (theme color, like the active tool) while the view shows the whole
-- time range. Any zoom or scroll that hides part of it turns Fit back to a
-- normal button.
function App:update_zoom_indicator(info)
  local v = self.views
  if not v or not v.zoom then return end
  v.zoom.text = info.text
  v.zoom.style = info.zoomed and "strong" or "disabled"
  if info.zoomed ~= self.zoomed_state then
    self.zoomed_state = info.zoomed
    if info.zoomed then
      pcall(function() v.fit.color = { 0, 0, 0 } end) -- theme default
    else
      local ok = pcall(function() v.fit.color = THEME.selection end)
      if not ok then
        local col = theme_color(THEME.selection)
        pcall(function() v.fit.color = { col[1], col[2], col[3] } end)
      end
    end
  end
end

function App:update_empty_state()
  if not self.views then return end
  local doc = self.session and self.session.doc
  local empty = not doc or #doc.lanes == 0
  self.views.empty.visible = empty
  if empty then
    local tr = renoise.song().tracks[doc and doc.track_index or 1]
    if not tr then
      self.views.empty.text = "No track."
    else
      self.views.empty.text = E.MSG_NO_LANE
    end
  end
end

--------------------------------------------------------------------------------
-- legend

function App:legend_lanes()
  local doc = self.session and self.session.doc
  return doc and doc.lanes or {}
end

function App:refresh_legend()
  local v = self.views
  if not v or not v.rows or #v.rows == 0 then return end
  local lanes = self:legend_lanes()
  local rows = #v.rows
  local max_off = math.max(0, #lanes - rows)
  if self.legend_offset > max_off then self.legend_offset = max_off end
  self.updating = true
  local doc = self.session.doc
  local track = doc and renoise.song().tracks[doc.track_index]
  local name = track and track.name or "n/a"
  if self.session:locked() then name = name .. " (locked)" end
  v.track_name.text = string.format("Track %02d: %s", doc and doc.track_index or 0, name)
  for i = 1, rows do
    local row = v.rows[i]
    local lane = lanes[self.legend_offset + i]
    if lane then
      row.row.visible = true
      row.check.value = not lane.hidden
      row.swatch.color = lane.color
      row.name.text = lane.name
      if lane.key == self.editor.active_key then
        row.name.color = theme_color("selected_button_back")
      else
        row.name.color = { 0, 0, 0 }
      end
    else
      row.row.visible = false
    end
  end
  local sb = v.legend_scroll
  sb.visible = #lanes > rows
  local ok, err = pcall(set_scrollbar, sb, math.max(1, #lanes), math.max(1, math.min(rows, #lanes)), self.legend_offset)
  if not ok then log("legend scrollbar: " .. tostring(err)) end
  self.updating = false
end

function App:on_legend_scroll(v)
  if self.updating then return end
  self.legend_offset = v
  self:refresh_legend()
end

function App:on_legend_check(i, value)
  if self.updating then return end
  local lane = self:legend_lanes()[self.legend_offset + i]
  if not lane then return end
  self.session:set_hidden(lane.key, not value)
  if lane.hidden and lane.key == self.editor.active_key then self:hide_hover() end
  self:refresh_legend()
  self:request_redraw()
end

function App:on_legend_click(i)
  local lane = self:legend_lanes()[self.legend_offset + i]
  if not lane then return end
  if lane.hidden then
    self.session:set_hidden(lane.key, false)
  end
  self:activate(lane.key)
end

function App:activate(key)
  if not key then return end
  self.editor:set_active(key)
  self.session:set_active(key)
  self:refresh_legend()
  self:refresh_interp()
  self:hide_hover()
  self:request_redraw()
end

-- Line numbers along the bottom of the canvas.
function App:update_ruler(segs)
  local pool = self.views and self.views.ruler
  if not pool then return end
  local d = self.d
  local labels = R.ruler_labels(self.view, segs, math.floor(44 * d.zoom), #pool)
  local y = math.max(0, d.canvas_h - d.label_h - 1)
  for i = 1, #pool do
    local lab, t = labels[i], pool[i]
    if lab and lab.x >= 0 and lab.x < d.canvas_w - 8 then
      t.text = lab.text
      t.origin = { x = math.floor(lab.x + 2), y = y }
      t.visible = true
    else
      t.visible = false
    end
  end
end

-- Real values (or percentages) of the active lane at the value guides.
function App:update_axis()
  local pool = self.views and self.views.axis
  if not pool then return end
  local lane = self.editor and self.editor:active_lane()
  local labels = lane and R.axis_labels(self.view, lane.info) or {}
  local d = self.d
  for i = 1, #pool do
    local lab, t = labels[i], pool[i]
    if lab then
      local y = math.floor(lab.y - d.label_h / 2)
      y = math.max(0, math.min(d.canvas_h - 2 * d.label_h - 2, y))
      t.text = lab.text
      t.origin = { x = math.floor(4 * d.zoom), y = y }
      t.visible = true
    else
      t.visible = false
    end
  end
end

function App:refresh_interp()
  local v = self.views
  if not v then return end
  self:update_axis()
  local mode = self.editor:active_playmode()
  self.updating = true
  v.interp.active = mode ~= nil
  if mode then v.interp.value = mode end
  self.updating = false
end

--------------------------------------------------------------------------------
-- hover, label, playhead

function App:hide_hover()
  local v = self.views
  if not v then return end
  v.hover_mark.visible = false
  v.label.visible = false
end

function App:show_hover(h)
  local v = self.views
  local d = self.d
  local hm = d.point_size + 6
  v.hover_mark.origin = { x = math.floor(h.x - hm / 2), y = math.floor(h.y - hm / 2) }
  v.hover_mark.visible = true
  v.label_text.text = h.text
  local est_w = #h.text * 7 + 8
  local lx = h.x + 10 * d.zoom
  if lx + est_w > d.canvas_w then lx = h.x - 10 * d.zoom - est_w end
  if lx < 0 then lx = 0 end
  local ly = h.y - d.label_h - 8 * d.zoom
  if ly < 0 then ly = h.y + 8 * d.zoom end
  v.label.origin = { x = math.floor(lx), y = math.floor(ly) }
  v.label.visible = true
end

function App:update_playhead(force)
  local v = self.views
  if not v or not self.session then return end
  local g = self.session:playhead_g()
  if not g then
    if v.playhead.visible then v.playhead.visible = false end
    return
  end
  if self.prefs.follow_playback.value and self.editor.drag == nil then
    if G.ensure_visible(self.view, g, self.editor:total_g()) then
      self:update_scrollbar()
      self:update_labels()
      self:request_redraw()
    end
  end
  local x = G.g_to_x(self.view, g)
  local inside = x >= 0 and x <= self.d.canvas_w
  v.playhead.visible = inside
  if inside then
    v.playhead.origin = { x = math.floor(x - self.d.playhead_w / 2), y = 0 }
  end
  local dg = self.diag
  dg.ph_count = dg.ph_count + 1
end

--------------------------------------------------------------------------------
-- input

function App:apply_fx(fx)
  if not fx then return end
  if fx.commit then
    self.session:commit(fx.commit)
    if fx.commit.writes and #fx.commit.writes > 0 then self:refresh_interp() end
  end
  if fx.activate then
    self.session:set_active(fx.activate)
    self:refresh_legend()
    self:refresh_interp()
  end
  if fx.overlay ~= nil then
    self.overlay = fx.overlay or {}
  end
  if fx.hover ~= nil then
    if fx.hover then self:show_hover(fx.hover) else self:hide_hover() end
  end
  if fx.status then self:set_status(fx.status) end
  if fx.tolerance then self.prefs.vectorize_tolerance.value = math.floor(fx.tolerance * 100 + 0.5) end
  if fx.tool then self:refresh_tool() end
  if fx.view then
    self:update_scrollbar()
    self:after_view_change()
  end
  if fx.menu == "selection" then self:selection_menu() end
  if fx.redraw then self:request_redraw() end
end

function App:on_mouse(event)
  local ok, err = pcall(function()
    if not self.editor or not self.session or not self.session.doc then return end
    local ev = {
      type = event.type,
      x = event.position and event.position.x or 0,
      y = event.position and event.position.y or 0,
      button = event.button, direction = event.direction, mods = mods_of(event.modifier_flags),
    }
    self:apply_fx(self.editor:mouse(ev))
  end)
  if not ok then log("mouse: " .. tostring(err)) end
  return nil
end

local ZOOM_IN = { ["+"] = true, ["="] = true, ["numpad +"] = true, ["plus"] = true, ["add"] = true }
local ZOOM_OUT = { ["-"] = true, ["numpad -"] = true, ["minus"] = true, ["subtract"] = true }
local ZOOM_RESET = { ["0"] = true, ["numpad 0"] = true }

function App:on_key(dialog, key)
  local handled = false
  local ok, err = pcall(function()
    local mods = mods_of(key.modifier_flags)
    local name = key.name
    if mods.control and not mods.alt then
      if ZOOM_IN[name] then
        self:set_zoom(self.prefs.ui_zoom.value + L.ZOOM_STEP)
        handled = true
        return
      elseif ZOOM_OUT[name] then
        self:set_zoom(self.prefs.ui_zoom.value - L.ZOOM_STEP)
        handled = true
        return
      elseif ZOOM_RESET[name] then
        self:set_zoom(L.ZOOM_DEFAULT)
        handled = true
        return
      end
    end
    if not self.editor or not self.session or not self.session.doc then return end
    local fx = self.editor:key(name, mods)
    if fx then
      handled = true
      self:apply_fx(fx)
      return
    end
    if name == "esc" and not mods.control and not mods.shift and not mods.alt then
      handled = true
      self:close()
    end
  end)
  if not ok then log("key: " .. tostring(err)) end
  if handled then return nil end
  return key
end

--------------------------------------------------------------------------------
-- toolbar actions

function App:tool_index()
  local t = self.editor and self.editor.tool or "edit"
  for i, name in ipairs(E.TOOLS) do
    if name == t then return i end
  end
  return 1
end

function App:refresh_tool()
  if not self.views then return end
  self.updating = true
  self.views.tool.value = self:tool_index()
  self.updating = false
end

function App:set_tool(i)
  if self.updating then return end
  self.editor.tool = E.TOOLS[i]
  self.editor.line_anchor = nil
end

function App:set_snap(v)
  self.prefs.snap_enabled.value = v
  self.editor.snap = v
end

function App:set_grid(i)
  self.prefs.snap_grid.value = i
  self.editor.grid = E.GRIDS[i]
end

function App:set_playmode(mode)
  if self.updating then return end
  local c = self.editor:set_playmode(mode)
  if c then
    self.session:commit(c)
    R.clear_cache(self.cache)
    self:request_redraw()
  end
end

function App:vectorize()
  if self.updating or not self.editor or not self.session or not self.session.doc then return end
  if not self.editor:active_lane() then
    self:set_status(E.MSG_NO_ACTIVE)
    return
  end
  if self.editor.vec_preview then
    self:apply_fx(self.editor:apply_preview())
  else
    self:apply_fx(self.editor:start_vectorize())
  end
end

function App:set_mode(v)
  if self.updating then return end
  self.prefs.time_mode.value = v
  self.session.settings.mode = v
  self:update_mode_controls()
  self.session:rebuild("mode")
end

function App:update_mode_controls()
  local v = self.views
  if not v or not self.session then return end
  local mode = self.session.settings.mode
  local n = #renoise.song().sequencer.pattern_sequence
  self.updating = true
  v.mode.value = mode
  v.range_group.visible = mode == S.MODE_RANGE
  v.neighbours.visible = mode == S.MODE_NEIGHBOURS
  local st = self.session.settings
  st.range_from = math.max(1, math.min(n, st.range_from or 1))
  st.range_to = math.max(1, math.min(n, st.range_to or n))
  set_valuebox(v.range_from, math.max(0, n - 1), st.range_from - 1)
  set_valuebox(v.range_to, math.max(0, n - 1), st.range_to - 1)
  self.updating = false
end

function App:set_range(from, to)
  if self.updating then return end
  local st = self.session.settings
  if from then st.range_from = from end
  if to then st.range_to = to end
  self.session:rebuild("range")
end

function App:whole_song()
  local st = self.session.settings
  st.range_from = 1
  st.range_to = #renoise.song().sequencer.pattern_sequence
  self:update_mode_controls()
  self.session:rebuild("range")
end

function App:set_neighbours(v)
  if self.updating then return end
  self.prefs.neighbours.value = v
  self.session.settings.neighbours = v
  self.session:rebuild("neighbours")
end

function App:set_follow(v)
  self.prefs.follow_playback.value = v
  if self.session then
    self.session.settings.follow_playback = v
    self.session.dirty.structure = true
  end
end

function App:toggle_lock()
  self.session:set_lock(not self.session:locked())
  self.session:rebuild("lock")
  self:update_lock_button()
end

function App:update_lock_button()
  local v = self.views
  if not v or not self.session then return end
  if self.session:locked() then
    v.lock.text = string.format("Locked: %02d", self.session:track_index())
    v.lock.color = theme_color("selected_button_back")
  else
    v.lock.text = "Lock track"
    v.lock.color = { 0, 0, 0 }
  end
end

function App:fit()
  G.fit(self.view, self.editor:total_g())
  self:update_scrollbar()
  self:after_view_change()
end

function App:toggle_legend()
  self.prefs.legend_visible.value = not self.prefs.legend_visible.value
  self:rebuild_window()
end

function App:set_zoom(z)
  z = L.clamp_zoom(z)
  if z == self.prefs.ui_zoom.value then return end
  self.prefs.ui_zoom.value = z
  self:set_status(string.format("Interface zoom: %d %%", math.floor(z * 100 + 0.5)))
  self:rebuild_window()
end

function App:add_lane_menu()
  local session = self.session
  local pattern = session:target_pattern()
  if not pattern then return end
  local list = IO.addable_params(renoise.song(), session:track_index(), pattern)
  if #list == 0 then
    self:set_status("Every automatable parameter of this track already has automation in this pattern.")
    return
  end
  local entries = {}
  for _, e in ipairs(list) do
    local dev = string.gsub(e.device_name, ":", "-")
    local par = string.gsub(e.param_name, ":", "-")
    entries[#entries + 1] = {
      name = string.format("%02d %s:%s", e.device_index, dev, par),
      invoke = function()
        local ok, err = session:add_lane(e.device_index, e.param_index, e.key)
        if not ok then
          self:set_status("Could not add lane: " .. tostring(err))
        else
          self.editor:set_active(e.key)
          self:refresh_all()
        end
      end,
    }
  end
  renoise.app():show_menu(self.dialog, entries, self.views.add_lane)
end

function App:selection_menu()
  local ed = self.editor
  local function run(fn)
    return function()
      local c = fn()
      self:apply_fx({ commit = c, redraw = true })
    end
  end
  local entries = {
    { name = "Copy (Ctrl + C)", invoke = function() ed:copy() end },
    { name = "Cut (Ctrl + X)", invoke = run(function() return ed:cut() end) },
    { name = "Delete (Del)", invoke = run(function() return ed:delete_selection() end) },
    { name = "--- Vectorize selection (V)", invoke = function() self:vectorize() end },
    { name = "--- Shift left by grid (Left)", invoke = run(function() return ed:shift_selection(-math.max(ed:grid_now(), 16)) end) },
    { name = "Shift right by grid (Right)", invoke = run(function() return ed:shift_selection(math.max(ed:grid_now(), 16)) end) },
  }
  for _, f in ipairs({ 50, 75, 125, 150 }) do
    entries[#entries + 1] = { name = string.format("Scale around center:%d %%", f), invoke = run(function() return ed:scale_selection(f / 100, "center") end) }
  end
  for _, f in ipairs({ 50, 75, 125, 150 }) do
    entries[#entries + 1] = { name = string.format("Scale from bottom:%d %%", f), invoke = run(function() return ed:scale_selection(f / 100, "bottom") end) }
  end
  renoise.app():show_menu(self.dialog, entries)
end

--------------------------------------------------------------------------------
-- status and diagnostics

function App:set_status(text)
  if not self.views or not text then return end
  self.views.status.text = text
  self.status_time = os.clock()
end

function App:update_diagnostics()
  local v = self.views
  if not v or not self.prefs.diagnostics.value then return end
  local dg = self.diag
  local now = os.clock()
  local elapsed = now - dg.ph_t0
  if elapsed >= 1 then
    dg.ph_rate = dg.ph_count / elapsed
    dg.ph_count = 0
    dg.ph_t0 = now
  end
  local avg = dg.renders > 0 and (dg.total / dg.renders) or 0
  v.diag.text = string.format("Curves %d | Points %d | Render avg %.1f ms, worst %.1f ms (%d) | Playhead %.1f/s",
    dg.lanes, dg.points, avg * 1000, dg.worst * 1000, dg.renders, dg.ph_rate)
end

function App:set_diagnostics(on)
  self.prefs.diagnostics.value = on
  self.diag.renders, self.diag.total, self.diag.worst = 0, 0, 0
  if self.views then self.views.diag.visible = on end
end

--------------------------------------------------------------------------------
-- idle

function App:idle()
  if not self.dialog then return end
  if not self.dialog.visible then
    -- closed with the window button: release every notifier
    self:close()
    return
  end
  local ok, err = pcall(function()
    if not self.session then return end
    self.session:idle(self.editor and self.editor.drag ~= nil)
    if self.session.td_changed then self:update_lock_button() end
    self:update_playhead(false)
    if self.status_time and os.clock() - self.status_time > App.STATUS_SECONDS then
      self.views.status.text = ""
      self.status_time = nil
    end
    self:update_diagnostics()
  end)
  if not ok then log("idle: " .. tostring(err)) end
end

--------------------------------------------------------------------------------
-- settings dialog

function App:show_settings()
  if self.settings_dialog and self.settings_dialog.visible then
    self.settings_dialog:show()
    return
  end
  local vb = renoise.ViewBuilder()
  local p = self.prefs
  local zoom_items, zoom_index = {}, 1
  local z = L.ZOOM_MIN
  local i = 1
  while z <= L.ZOOM_MAX + 1e-9 do
    zoom_items[i] = string.format("%d %%", math.floor(z * 100 + 0.5))
    if math.abs(z - p.ui_zoom.value) < 1e-6 then zoom_index = i end
    z = z + L.ZOOM_STEP
    i = i + 1
  end
  local size_items = {}
  for k, pr in ipairs(L.PRESETS) do size_items[k] = string.format("%s (%d x %d)", pr.name, pr.width, pr.height) end
  size_items[#size_items + 1] = "Custom"
  local LABEL_W = 150
  local function row(label, view)
    return vb:row { vb:text { text = label, width = LABEL_W }, view }
  end
  local width_box = vb:valuebox { min = 640, max = 4000, value = p.width.value, width = 80 }
  local height_box = vb:valuebox { min = 300, max = 1600, value = p.height.value, width = 80 }
  local content = vb:column {
    margin = 8, spacing = 4,
    row("Interface zoom", vb:popup {
      items = zoom_items, value = zoom_index, width = 120,
      tooltip = "Tool zoom on top of the Renoise UI scaling (default 125 %). Ctrl + plus, Ctrl + minus, Ctrl + 0",
      notifier = function(v) self:set_zoom(L.ZOOM_MIN + (v - 1) * L.ZOOM_STEP) end,
    }),
    row("Window size", vb:popup {
      items = size_items, value = p.size_preset.value, width = 200,
      notifier = function(v)
        p.size_preset.value = v
        if L.PRESETS[v] then
          width_box.value = L.PRESETS[v].width
          height_box.value = L.PRESETS[v].height
        end
        self:rebuild_window()
      end,
    }),
    row("Custom width, height", vb:row { width_box, height_box, vb:button {
      text = "Apply", tooltip = "Use the custom size",
      notifier = function()
        p.width.value = width_box.value
        p.height.value = height_box.value
        p.size_preset.value = #L.PRESETS + 1
        self:rebuild_window()
      end,
    } }),
    row("Default tool", vb:popup {
      items = E.TOOL_LABELS, value = p.tool.value, width = 120,
      notifier = function(v) p.tool.value = v end,
    }),
    row("Inactive curve opacity", vb:valuebox {
      min = 10, max = 90, value = p.inactive_opacity.value, width = 80,
      tostring = function(v) return string.format("%d %%", v) end,
      tonumber = function(s) return tonumber(string.match(s, "%d+")) end,
      notifier = function(v)
        p.inactive_opacity.value = v
        self:request_redraw()
      end,
    }),
    row("Snap", vb:checkbox {
      value = p.snap_enabled.value,
      notifier = function(v)
        if self.editor then self:set_snap(v) else p.snap_enabled.value = v end
        if self.views then self.views.snap.value = v end
      end,
    }),
    row("Vectorize tolerance", vb:valuebox {
      min = 0, max = 25, value = p.vectorize_tolerance.value, width = 80,
      tooltip = "Largest value error (percent of the parameter range) allowed when Vectorize removes a point. 0 removes only points exactly on a line.",
      tostring = function(v) return string.format("%d %%", v) end,
      tonumber = function(s) return tonumber(string.match(s, "%d+")) end,
      notifier = function(v)
        p.vectorize_tolerance.value = v
        if self.editor then self.editor.vectorize_tolerance = v / 100 end
      end,
    }),
    row("Write while dragging", vb:checkbox {
      value = p.live_writes.value,
      tooltip = "Write drags and pencil strokes to the song while the mouse moves (the native editor follows live, still one undo step). Off: write when the mouse button is released.",
      notifier = function(v)
        p.live_writes.value = v
        if self.editor then self.editor.live_writes = v end
      end,
    }),
    row("Follow playback", vb:checkbox {
      value = p.follow_playback.value,
      notifier = function(v)
        self:set_follow(v)
        if self.views then self.views.follow.value = v end
      end,
    }),
    row("Diagnostics", vb:checkbox {
      value = p.diagnostics.value,
      tooltip = "Show curve and point counts, render times and playhead update rate in the status line",
      notifier = function(v) self:set_diagnostics(v) end,
    }),
    vb:text { text = App.TITLE .. ", version " .. self.version, style = "disabled" },
  }
  self.settings_dialog = renoise.app():show_custom_dialog(App.TITLE .. " settings", content)
end

return App
