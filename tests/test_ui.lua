-- Smoke test of main.lua and ui/app.lua against stubbed Renoise application
-- objects (ViewBuilder, dialogs, menus, tool) and the song mock. It does not
-- prove the window looks right in Renoise; it catches errors in the UI code
-- paths: opening, mouse and key handling, idle, rebuilds, song changes.

local M = require "tests.mock_renoise"
local C = require "tests.svg_context"

local NATIVE = "Audio/Effects/Native/"

local function make_song()
  local cutoff, reso = M.param("Cutoff"), M.param("Resonance")
  local filter = M.device(NATIVE .. "Filter", "Filter", { cutoff, reso })
  local song = M.song({
    tracks = { { name = "Bass", devices = { filter } }, { name = "Lead", devices = {} } },
    patterns = { 16, 16 },
    sequence = { 1, 2, 1 },
  })
  M.automate(song, 1, 1, cutoff, { { 1, 0.2 }, { 9, 0.8 } })
  M.automate(song, 2, 1, reso, { { 1, 0.5 } })
  return song, cutoff
end

--------------------------------------------------------------------------------
-- stubs

local function stub_view(kind, props)
  local v = { kind = kind, views = {} }
  for k, val in pairs(props or {}) do v[k] = val end
  if props and props.views then
    v.views = {}
    for i, child in ipairs(props.views) do v.views[i] = child end
  end
  if v.visible == nil then v.visible = true end
  function v:add_view(child) self.views[#self.views + 1] = child end
  function v:remove_view() end
  function v:update() self.updates = (self.updates or 0) + 1 end
  return v
end

local function new_vb()
  local vb = { views = {} }
  return setmetatable(vb, { __index = function(_, kind)
    return function(_, props)
      -- the props table itself may be a list of child views (vb:row { a, b })
      if props and props[1] and not props.views then
        local children = {}
        for i, c in ipairs(props) do children[i] = c end
        props.views = children
      end
      return stub_view(kind, props)
    end
  end })
end

local function new_doc(_)
  return function(tbl)
    local doc = {}
    for k, v in pairs(tbl) do
      doc[k] = { value = v, add_notifier = function() end }
    end
    return doc
  end
end

local env = { dialogs = {}, menus = {}, entries = {}, bindings = {} }

local function install(song)
  env.dialogs, env.menus, env.entries, env.bindings = {}, {}, {}, {}
  env.song = song
  env.tool = {
    bundle_path = "./",
    preferences = nil,
    app_idle_observable = M.observable(),
    app_new_document_observable = M.observable(),
    app_release_document_observable = M.observable(),
    app_will_save_document_observable = M.observable(),
  }
  function env.tool:add_menu_entry(e) env.entries[#env.entries + 1] = e end
  function env.tool:add_keybinding(e) env.bindings[#env.bindings + 1] = e end
  env.app = {
    theme = { color = function(_, name) return { 50, 60, 70 } end },
    theme_observable = M.observable(),
  }
  function env.app:show_custom_dialog(title, content, key_handler)
    local d = { title = title, content = content, key_handler = key_handler, visible = true }
    function d:close() self.visible = false end
    function d:show() self.visible = true end
    env.dialogs[#env.dialogs + 1] = d
    return d
  end
  function env.app:show_menu(dialog, entries) env.menus[#env.menus + 1] = entries end
  function env.app:show_status() end
  _G.renoise = {
    tool = function() return env.tool end,
    app = function() return env.app end,
    song = function() return env.song end,
    ViewBuilder = new_vb,
    Document = { create = new_doc },
  }
end

local function find(view, pred)
  if pred(view) then return view end
  for _, c in ipairs(view.views or {}) do
    local r = find(c, pred)
    if r then return r end
  end
  return nil
end

local function canvas_of(dialog)
  return find(dialog.content, function(v) return v.kind == "canvas" and v.mouse_handler ~= nil end)
end

local function render(canvas)
  local ctx = C.new(canvas.width, canvas.height)
  canvas.render(ctx)
  return ctx
end

local function mouse(canvas, type, x, y, button, mods)
  return canvas.mouse_handler({ type = type, position = { x = x, y = y }, button = button or "left",
    modifier_flags = mods or {}, button_flags = {} })
end

--------------------------------------------------------------------------------

local logs = {}
local real_print = print

local function load_tool(song)
  install(song)
  logs = {}
  print = function(...) local t = {} for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end logs[#logs + 1] = table.concat(t, " ") end
  for _, m in ipairs({ "ui.app", "bridge.session", "bridge.prefs" }) do package.loaded[m] = nil end
  local chunk = assert(loadfile("main.lua"))
  chunk()
  print = real_print
end

local function run(fn)
  print = function(...) local t = {} for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end logs[#logs + 1] = table.concat(t, " ") end
  local ok, err = pcall(fn)
  print = real_print
  if os.getenv("DEBUG_UI") then io.stderr:write(table.concat(logs, "\n") .. "\n") end
  if not ok then error(err, 0) end
end

local function no_errors()
  T.eq(logs, {}, "nothing logged to the scripting console")
end

T.test("main registers menus and key bindings", function()
  load_tool(make_song())
  local names = {}
  for _, e in ipairs(env.entries) do names[#names + 1] = e.name end
  T.eq(names, {
    "Main Menu:Tools:Multi Automation View...",
    "Track Automation:Multi Automation View...",
    "Pattern Editor:Multi Automation View...",
  })
  T.eq(env.bindings[1].name, "Global:Tools:Toggle Multi Automation View")
  T.ok(env.tool.preferences ~= nil, "preferences assigned at load")
  T.eq(env.tool.preferences.ui_zoom.value, 1.25)
end)

T.test("open, render, edit with the mouse, keys and idle", function()
  local song, cutoff = make_song()
  load_tool(song)
  run(function()
    env.entries[1].invoke()
    local dlg = env.dialogs[#env.dialogs]
    T.eq(dlg.title, "renoise-automation-manager")
    local canvas = canvas_of(dlg)
    T.ok(canvas, "canvas present")
    local ctx = render(canvas)
    T.ok(#ctx.log > 10, "something drawn")
    -- double click adds a point in the center of the canvas
    T.eq(mouse(canvas, "double", canvas.width / 4, canvas.height / 2), nil)
    local a = song.patterns[1].tracks[1]:find_automation(cutoff)
    T.eq(#a.points, 3)
    T.eq(song._undo[#song._undo].desc, "Multi Automation: Add point")
    mouse(canvas, "move", 10, 10)
    mouse(canvas, "wheel", 100, 10, nil, { control = true })
    mouse(canvas, "down", 5, 5)
    mouse(canvas, "drag", 300, 100)
    mouse(canvas, "up", 300, 100)
    mouse(canvas, "exit", 0, 0)
    -- keys: tool switch, unhandled key is passed back, zoom rebuilds the window
    T.eq(dlg.key_handler(dlg, { name = "p", modifier_flags = {} }), nil)
    local space = { name = "space", modifier_flags = {} }
    T.ok(dlg.key_handler(dlg, space) == space, "space goes back to Renoise")
    local count = #env.dialogs
    dlg.key_handler(dlg, { name = "+", modifier_flags = { control = true } })
    T.eq(#env.dialogs, count + 1, "zoom change rebuilds the window")
    T.eq(env.tool.preferences.ui_zoom.value, 1.5)
    local dlg2 = env.dialogs[#env.dialogs]
    dlg2.key_handler(dlg2, { name = "0", modifier_flags = { control = true } })
    T.eq(env.tool.preferences.ui_zoom.value, 1.25, "Ctrl + 0 resets to 125 %")
    for _ = 1, 3 do env.tool.app_idle_observable:fire() end
    render(canvas_of(env.dialogs[#env.dialogs]))
  end)
  no_errors()
end)

T.test("track change, playback, song change and closing", function()
  local song = make_song()
  load_tool(song)
  run(function()
    env.entries[1].invoke()
    song:select_track(2)
    env.tool.app_idle_observable:fire()
    local dlg = env.dialogs[#env.dialogs]
    local empty = find(dlg.content, function(v) return v.kind == "text" and v.text and v.text:find("No automation") end)
    T.ok(empty and empty.visible, "empty state shown")
    song:select_track(1)
    song.transport.playing = true
    song.transport.playback_pos = { sequence = 1, line = 5 }
    env.tool.app_idle_observable:fire()
    -- new song
    env.tool.app_release_document_observable:fire()
    env.song = make_song()
    env.tool.app_new_document_observable:fire()
    env.tool.app_idle_observable:fire()
    render(canvas_of(env.dialogs[#env.dialogs]))
    -- closing with the window button releases the session on idle
    env.dialogs[#env.dialogs].visible = false
    env.tool.app_idle_observable:fire()
  end)
  no_errors()
end)

T.test("toolbar actions: modes, lock, legend, add lane, settings", function()
  local song = make_song()
  load_tool(song)
  run(function()
    env.entries[1].invoke()
    local dlg = env.dialogs[#env.dialogs]
    local popup = find(dlg.content, function(v) return v.kind == "popup" and v.items and v.items[1] == "Current pattern" end)
    popup.notifier(2)
    env.tool.app_idle_observable:fire()
    popup.notifier(3)
    env.tool.app_idle_observable:fire()
    local lock = find(dlg.content, function(v) return v.kind == "button" and v.text == "Lock track" end)
    lock.notifier()
    T.ok(lock.text:find("Locked"), lock.text)
    local add = find(dlg.content, function(v) return v.kind == "button" and v.text == "Add lane" end)
    add.notifier()
    local menu = env.menus[#env.menus]
    T.ok(menu and #menu >= 0)
    local settings = find(dlg.content, function(v) return v.kind == "button" and v.text == "Settings" end)
    settings.notifier()
    local legend = find(dlg.content, function(v) return v.kind == "button" and v.text == "Legend" end)
    legend.notifier()
    T.eq(env.tool.preferences.legend_visible.value, false)
    render(canvas_of(env.dialogs[#env.dialogs]))
  end)
  no_errors()
end)

T.test("reopening the window on the same song shows the whole range", function()
  local song = make_song()
  load_tool(song)
  run(function()
    local function zoom_text(dlg)
      local z = find(dlg.content, function(v) return v.kind == "text" and v.text and (v.text:find("^View:") or v.text:find("^Zoom")) end)
      return z and z.text
    end
    env.entries[1].invoke()
    local dlg = env.dialogs[#env.dialogs]
    T.eq(zoom_text(dlg), "View: all 16 lines")
    local fit = find(dlg.content, function(v) return v.kind == "button" and v.text == "Fit" end)
    T.eq(fit.color, "selected_button_back", "Fit lit while fitted")
    -- close with the window button, then open again
    dlg.visible = false
    env.tool.app_idle_observable:fire()
    env.entries[1].invoke()
    local dlg2 = env.dialogs[#env.dialogs]
    T.ok(dlg2 ~= dlg, "new dialog")
    T.eq(zoom_text(dlg2), "View: all 16 lines")
    -- zoom in: Fit turns normal
    local canvas = canvas_of(dlg2)
    canvas.mouse_handler({ type = "wheel", direction = "up", position = { x = 100, y = 10 }, modifier_flags = { control = true }, button_flags = {} })
    local fit2 = find(dlg2.content, function(v) return v.kind == "button" and v.text == "Fit" end)
    T.eq(fit2.color, { 0, 0, 0 })
    T.ok(zoom_text(dlg2):find("^Zoom"), zoom_text(dlg2))
  end)
  no_errors()
end)

T.test("the corner grip resizes the window while dragging", function()
  local song = make_song()
  load_tool(song)
  run(function()
    env.entries[1].invoke()
    local dlg = env.dialogs[#env.dialogs]
    local function grip_of(d)
      return find(d.content, function(v) return v.kind == "canvas" and v.cursor == "resize_edge_diagonal_right" end)
    end
    local grip = grip_of(dlg)
    T.ok(grip, "grip present")
    render(grip)
    local canvas = canvas_of(dlg)
    local w0 = canvas.width
    local function m(g, type, x, y)
      return g.mouse_handler({ type = type, position = { x = x, y = y }, button = "left", modifier_flags = {}, button_flags = {} })
    end
    -- positions are relative to the grip, which follows the corner
    m(grip, "down", 5, 5)
    m(grip, "drag", -295, -95)
    T.eq(canvas.width, w0 - 300, "canvas resized live, no rebuild")
    local status = find(dlg.content, function(v) return v.kind == "text" and v.text and v.text:find("^Window size") end)
    T.ok(status and status.text:find("1500 x 420"), status and status.text)
    local count = #env.dialogs
    m(grip, "up", 5, 5)
    T.eq(env.tool.preferences.width.value, 1500)
    T.eq(env.tool.preferences.height.value, 420)
    T.eq(env.tool.preferences.size_preset.value, 4, "custom size")
    env.tool.app_idle_observable:fire()
    T.eq(#env.dialogs, count, "shrinking needs no rebuild")
    render(canvas)
    -- growing taller needs more legend rows: rebuilt once on release
    m(grip, "down", 5, 5)
    m(grip, "up", 205, 305)
    env.tool.app_idle_observable:fire()
    T.eq(#env.dialogs, count + 1, "rebuilt for the new legend rows")
    T.eq(env.tool.preferences.height.value, 720)
    -- a tiny size is clamped
    local grip2 = grip_of(env.dialogs[#env.dialogs])
    m(grip2, "down", 0, 0)
    m(grip2, "up", -5000, -5000)
    local L = require "core.layout"
    local mw, mh = L.min_size(1.25, true)
    T.eq(env.tool.preferences.width.value, mw)
    T.eq(env.tool.preferences.height.value, mh)
  end)
  no_errors()
end)

T.test("right-click menu like the native editor", function()
  local song = make_song()
  load_tool(song)
  run(function()
    env.entries[1].invoke()
    local dlg = env.dialogs[#env.dialogs]
    local canvas = canvas_of(dlg)
    mouse(canvas, "down", 50, 50, "right")
    local menu = env.menus[#env.menus]
    T.ok(menu, "menu shown")
    local names = {}
    for _, e in ipairs(menu) do names[e.name] = e end
    for _, n in ipairs({ "Cut (Ctrl + X)", "Paste Continuously (Ctrl + P)", "Insert Paste (Ctrl + I)",
      "---Cut Selected Time (Ctrl + K)", "Delete Envelope", "---Process:Flip Selection (Ctrl + F)",
      "---Process:Create Sine Curve", "---Lock Zoom", "Zoom Out Fully", "Zoom To Current",
      "Draw Tool (P)", "Line Tool (L)" }) do
      T.ok(names[n], "entry " .. n)
    end
    -- separators: dashes directly followed by the text (no space), and one
    -- single path for the whole Process submenu
    for _, e in ipairs(menu) do
      T.ok(not e.name:find("^%-+ "), "no space after the separator dashes: " .. e.name)
      if e.name:find("Process:", 1, true) then
        T.eq(e.name:match("^(.-)Process:"), "---", "same Process path: " .. e.name)
      end
    end
    names["---Process:Create Linear Curve"].invoke()
    T.eq(song._undo[#song._undo].desc, "Multi Automation: Create linear curve")
    names["Zoom To Current"].invoke()
    names["---Lock Zoom"].invoke()
    T.eq(env.tool.preferences.lock_zoom.value, true)
    names["Line Tool (L)"].invoke()
    names["Delete Envelope"].invoke()
    T.eq(song._undo[#song._undo].desc, "Multi Automation: Delete envelope")
    env.tool.app_idle_observable:fire()
    render(canvas_of(env.dialogs[#env.dialogs]))
  end)
  no_errors()
end)
