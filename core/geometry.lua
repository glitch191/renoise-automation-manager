-- Pure coordinate transforms between global time / value and canvas pixels.
--
-- view = { start_g = first visible global sub-unit, span_g = visible sub-units,
--          width, height = canvas size, pad = vertical padding in pixels }

local G = {}

G.MIN_SPAN = 64 -- a quarter of a line

function G.new_view(width, height, pad, total_g)
  return { start_g = 0, span_g = math.max(total_g or 256, G.MIN_SPAN), width = width, height = height, pad = pad or 6 }
end

function G.g_to_x(view, g)
  return (g - view.start_g) * view.width / view.span_g
end

function G.x_to_g(view, x)
  return view.start_g + x * view.span_g / view.width
end

function G.v_to_y(view, v)
  local h = view.height - 2 * view.pad
  return view.pad + (1 - v) * h
end

function G.y_to_v(view, y)
  local h = view.height - 2 * view.pad
  if h <= 0 then return 0 end
  local v = 1 - (y - view.pad) / h
  if v < 0 then return 0 end
  if v > 1 then return 1 end
  return v
end

-- Keep the visible window inside [0, total_g].
function G.clamp(view, total_g)
  total_g = math.max(total_g, G.MIN_SPAN)
  if view.span_g > total_g then view.span_g = total_g end
  if view.span_g < G.MIN_SPAN then view.span_g = G.MIN_SPAN end
  if view.start_g < 0 then view.start_g = 0 end
  if view.start_g + view.span_g > total_g then view.start_g = total_g - view.span_g end
  return view
end

function G.fit(view, total_g)
  view.start_g = 0
  view.span_g = math.max(total_g, G.MIN_SPAN)
  return view
end

-- Zoom by `factor` (> 1 zooms in) keeping the time under pixel x fixed.
function G.zoom_at(view, factor, x, total_g)
  local g = G.x_to_g(view, x)
  view.span_g = view.span_g / factor
  if view.span_g < G.MIN_SPAN then view.span_g = G.MIN_SPAN end
  if view.span_g > total_g then view.span_g = math.max(total_g, G.MIN_SPAN) end
  view.start_g = g - x * view.span_g / view.width
  return G.clamp(view, total_g)
end

function G.scroll(view, dg, total_g)
  view.start_g = view.start_g + dg
  return G.clamp(view, total_g)
end

-- Make sure global time g is visible, paging the view when it leaves it.
-- Returns true when the view moved.
function G.ensure_visible(view, g, total_g)
  if g >= view.start_g and g <= view.start_g + view.span_g then return false end
  view.start_g = g - view.span_g * 0.1
  G.clamp(view, total_g)
  return true
end

-- Grid lines for the visible window.
-- Returns a list of { g = global time, kind = "pattern" | "beat" | "line" | "sub" }.
-- Line density adapts so that lines are at least min_px apart.
function G.grid_lines(view, segments, lpb, min_px)
  lpb = math.max(lpb or 4, 1)
  min_px = min_px or 6
  local px_per_line = view.width * 256 / view.span_g
  local out = {}
  local g_end = view.start_g + view.span_g
  local sub_step = nil
  if px_per_line / 4 >= min_px then sub_step = 64 end
  local line_ok = px_per_line >= min_px
  local beat_every = lpb
  while px_per_line * beat_every < min_px do beat_every = beat_every * 2 end
  for i = 1, #segments do
    local s = segments[i]
    local s0, s1 = s.offset, s.offset + s.len_g
    if s1 >= view.start_g and s0 <= g_end then
      out[#out + 1] = { g = s0, kind = "pattern" }
      local first_line = math.max(0, math.floor((view.start_g - s0) / 256))
      local last_line = math.min(s.lines, math.ceil((g_end - s0) / 256))
      for line = first_line, last_line - 1 do
        local g = s0 + line * 256
        if line > 0 then
          if line % beat_every == 0 then
            out[#out + 1] = { g = g, kind = "beat" }
          elseif line_ok then
            out[#out + 1] = { g = g, kind = "line" }
          end
        end
        if sub_step then
          for k = sub_step, 255, sub_step do
            out[#out + 1] = { g = g + k, kind = "sub" }
          end
        end
      end
    end
  end
  if #segments > 0 then
    local last = segments[#segments]
    out[#out + 1] = { g = last.offset + last.len_g, kind = "pattern" }
  end
  return out
end

return G
