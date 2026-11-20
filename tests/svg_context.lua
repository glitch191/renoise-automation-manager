-- Simulated canvas context that records drawing calls and exports them as SVG.
-- Used by the renderer tests and by tests/preview.lua. These SVG files are
-- verification previews of the drawing logic, not screenshots of Renoise.

local C = {}
C.__index = C

local THEME_GREYS = setmetatable({}, { __index = function() return { 128, 128, 128 } end })

local function color_of(c, alpha)
  if type(c) == "string" then c = THEME_GREYS[c] end
  local a = (c[4] or 255) / 255 * (alpha / 255)
  return string.format("rgb(%d,%d,%d)", c[1], c[2], c[3]), a
end

local function num(x)
  return string.format("%.2f", x)
end

function C.new(width, height)
  local self = setmetatable({}, C)
  self.size = { width = width, height = height }
  self.pixel_size = { width = width, height = height }
  self.fill_color = { 0, 0, 0, 255 }
  self.stroke_color = { 0, 0, 0, 255 }
  self.line_width = 1
  self.global_alpha = 255
  self.line_join = "miter"
  self.line_cap = "butt"
  self.dash = {}
  self.path = {}
  self.elements = {}
  self.defs = {}
  self.stack = {}
  self.open_groups = 0
  self.log = {}
  return self
end

function C:_record(op, extra)
  local entry = { op = op, alpha = self.global_alpha, line_width = self.line_width,
    stroke = self.stroke_color, fill = self.fill_color }
  if extra then for k, v in pairs(extra) do entry[k] = v end end
  self.log[#self.log + 1] = entry
end

function C:save()
  self.stack[#self.stack + 1] = {
    fill_color = self.fill_color, stroke_color = self.stroke_color, line_width = self.line_width,
    global_alpha = self.global_alpha, dash = self.dash, groups = self.open_groups,
  }
end

function C:restore()
  local s = table.remove(self.stack)
  if not s then return end
  while self.open_groups > s.groups do
    self.elements[#self.elements + 1] = "</g>"
    self.open_groups = self.open_groups - 1
  end
  self.fill_color, self.stroke_color, self.line_width = s.fill_color, s.stroke_color, s.line_width
  self.global_alpha, self.dash = s.global_alpha, s.dash
end

function C:set_line_dash(segments)
  self.dash = segments or {}
end

function C:begin_path() self.path = {} end
function C:move_to(x, y) self.path[#self.path + 1] = "M" .. num(x) .. " " .. num(y) end
function C:line_to(x, y) self.path[#self.path + 1] = "L" .. num(x) .. " " .. num(y) end
function C:close_path() self.path[#self.path + 1] = "Z" end
function C:rect(x, y, w, h)
  self.path[#self.path + 1] = string.format("M%s %sh%sv%sh%sZ", num(x), num(y), num(w), num(h), num(-w))
end
function C:arc(x, y, r)
  self.path[#self.path + 1] = string.format("M%s %sa%s %s 0 1 0 %s 0a%s %s 0 1 0 %s 0", num(x - r), num(y), num(r), num(r), num(2 * r), num(r), num(r), num(-2 * r))
end

function C:_dash_attr()
  if #self.dash == 0 then return "" end
  local parts = {}
  for i = 1, #self.dash do parts[i] = num(self.dash[i]) end
  return ' stroke-dasharray="' .. table.concat(parts, " ") .. '"'
end

function C:stroke()
  if #self.path == 0 then return end
  local col, a = color_of(self.stroke_color, self.global_alpha)
  self.elements[#self.elements + 1] = string.format('<path d="%s" fill="none" stroke="%s" stroke-opacity="%.3f" stroke-width="%s" stroke-linejoin="round"%s/>',
    table.concat(self.path, ""), col, a, num(self.line_width), self:_dash_attr())
  self:_record("stroke", { segments = #self.path })
end

function C:fill()
  if #self.path == 0 then return end
  local col, a = color_of(self.fill_color, self.global_alpha)
  self.elements[#self.elements + 1] = string.format('<path d="%s" fill="%s" fill-opacity="%.3f"/>', table.concat(self.path, ""), col, a)
  self:_record("fill")
end

function C:fill_rect(x, y, w, h)
  local col, a = color_of(self.fill_color, self.global_alpha)
  self.elements[#self.elements + 1] = string.format('<rect x="%s" y="%s" width="%s" height="%s" fill="%s" fill-opacity="%.3f"/>', num(x), num(y), num(w), num(h), col, a)
  self:_record("fill_rect", { x = x, y = y, w = w, h = h })
end

function C:stroke_rect(x, y, w, h)
  local col, a = color_of(self.stroke_color, self.global_alpha)
  self.elements[#self.elements + 1] = string.format('<rect x="%s" y="%s" width="%s" height="%s" fill="none" stroke="%s" stroke-opacity="%.3f" stroke-width="%s"%s/>', num(x), num(y), num(w), num(h), col, a, num(self.line_width), self:_dash_attr())
  self:_record("stroke_rect")
end

function C:clear_rect() end

function C:clip()
  local id = "c" .. (#self.defs + 1)
  self.defs[#self.defs + 1] = string.format('<clipPath id="%s"><path d="%s"/></clipPath>', id, table.concat(self.path, ""))
  self.elements[#self.elements + 1] = string.format('<g clip-path="url(#%s)">', id)
  self.open_groups = self.open_groups + 1
end

function C:set_transform() end
function C:translate() end
function C:scale() end

-- Embed raw SVG markup (used by the preview to draw texts and UI boxes).
function C:raw(markup)
  self.elements[#self.elements + 1] = markup
end

function C:to_svg(width, height, offset_x, offset_y)
  while self.open_groups > 0 do
    self.elements[#self.elements + 1] = "</g>"
    self.open_groups = self.open_groups - 1
  end
  return string.format('<g transform="translate(%d,%d)"><defs>%s</defs>%s</g>', offset_x or 0, offset_y or 0,
    table.concat(self.defs, ""), table.concat(self.elements, "\n"))
end

function C:count(op, filter)
  local n = 0
  for _, e in ipairs(self.log) do
    if e.op == op and (not filter or filter(e)) then n = n + 1 end
  end
  return n
end

return C
