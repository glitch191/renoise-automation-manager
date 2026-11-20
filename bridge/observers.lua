-- Notifier bookkeeping. Every notifier the tool attaches goes through here so
-- that it can be detached by group (song, content, ...) before re-subscribing.
--
-- Renoise disables a notifier that raises an error, so every callback is
-- wrapped in pcall and errors are written to the scripting console instead.
-- Detaching never fails: objects that were deleted in the meantime are
-- skipped silently.

local O = {}
O.__index = O

function O.new(log)
  local self = setmetatable({}, O)
  self.groups = {}
  self.log = log or print
  return self
end

-- Wrap a function so that it never raises.
function O.safe(fn, log, label)
  log = log or print
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then log("[" .. (label or "notifier") .. "] " .. tostring(err)) end
  end
end

function O:add(group, observable, fn, label)
  if observable == nil then return false end
  local wrapped = O.safe(fn, self.log, label or group)
  local ok, err = pcall(function() observable:add_notifier(wrapped) end)
  if not ok then
    self.log("[observers] cannot attach " .. tostring(label or group) .. ": " .. tostring(err))
    return false
  end
  local list = self.groups[group]
  if not list then
    list = {}
    self.groups[group] = list
  end
  list[#list + 1] = { observable = observable, fn = wrapped }
  return true
end

function O:clear(group)
  local list = self.groups[group]
  if not list then return end
  for i = 1, #list do
    local e = list[i]
    pcall(function()
      if e.observable:has_notifier(e.fn) then e.observable:remove_notifier(e.fn) end
    end)
  end
  self.groups[group] = nil
end

function O:clear_all()
  for group in pairs(self.groups) do self:clear(group) end
  self.groups = {}
end

function O:count(group)
  if group then return #(self.groups[group] or {}) end
  local n = 0
  for _, list in pairs(self.groups) do n = n + #list end
  return n
end

return O
