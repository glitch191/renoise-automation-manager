-- renoise-automation-manager: overlaid multi automation view for Renoise.
-- Entry point: registers menu entries, the key binding and tool notifiers.
-- Everything else lives in core/ (pure logic), bridge/ (Renoise song access)
-- and ui/ (window).

local function bundle_path()
  local p = renoise.tool().bundle_path
  local last = string.sub(p, -1)
  if last ~= "/" and last ~= "\\" then p = p .. "/" end
  return p
end

package.path = bundle_path() .. "?.lua;" .. package.path

-- Development only: auto reload when files change. Enabled when a file named
-- dev.flag exists in the tool folder (created by scripts/install-dev.ps1 and
-- never included in the published .xrnx).
do
  local f = io.open(bundle_path() .. "dev.flag", "r")
  if f then
    f:close()
    _AUTO_RELOAD_DEBUG = true
  end
end

local App = require "ui.app"

local app = nil

local function get_app()
  if not app then app = App.new() end
  return app
end

local function safe(fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then App.log(err) end
  end
end

local function show()
  get_app():open()
end

local function toggle()
  get_app():toggle()
end

local MENU_LABEL = "Multi Automation View..."

renoise.tool():add_menu_entry { name = "Main Menu:Tools:" .. MENU_LABEL, invoke = safe(show) }
renoise.tool():add_menu_entry { name = "Track Automation:" .. MENU_LABEL, invoke = safe(show) }
renoise.tool():add_menu_entry { name = "Pattern Editor:" .. MENU_LABEL, invoke = safe(show) }

renoise.tool():add_keybinding { name = "Global:Tools:Toggle Multi Automation View", invoke = safe(function() toggle() end) }
renoise.tool():add_keybinding {
  name = "Global:Tools:Toggle Multi Automation View Diagnostics",
  invoke = safe(function()
    local a = get_app()
    a:set_diagnostics(not a.prefs.diagnostics.value)
  end),
}

local tool = renoise.tool()

tool.app_idle_observable:add_notifier(safe(function()
  if app then app:idle() end
end))

tool.app_new_document_observable:add_notifier(safe(function()
  if app then app:on_new_document() end
end))

tool.app_release_document_observable:add_notifier(safe(function()
  if app then app:on_release_document() end
end))

tool.app_will_save_document_observable:add_notifier(safe(function()
  if app then app:on_will_save() end
end))

-- Preferences are loaded by Renoise as soon as they are assigned, so create
-- them at load time: the zoom and size are known before the first window.
get_app()
