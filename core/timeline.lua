-- Pure timeline model: maps a list of sequence positions onto one continuous
-- global time axis (sub-units, 0 = first line of the first segment).
--
-- Entry: { seq = sequence position (1-based), pattern = pattern index used for
--          reading and writing (alias already resolved), lines = pattern length,
--          track_alias = true when the pattern track is an alias of another one }
-- Segment adds: offset (global sub-units of local t = 256), len_g, editable,
--          repeated (pattern appears more than once), occurrence (1..n),
--          alias (repeated or track_alias).

local P = require "core.points"

local T = {}

local U = P.UNITS

-- opts.editable(seq) -> boolean, default all editable.
function T.build(entries, opts)
  opts = opts or {}
  local counts = {}
  for i = 1, #entries do
    local pi = entries[i].pattern
    counts[pi] = (counts[pi] or 0) + 1
  end
  local seen = {}
  local segments, offset = {}, 0
  for i = 1, #entries do
    local e = entries[i]
    seen[e.pattern] = (seen[e.pattern] or 0) + 1
    local seg = {
      index = i,
      seq = e.seq,
      pattern = e.pattern,
      lines = e.lines,
      offset = offset,
      len_g = e.lines * U,
      editable = (opts.editable == nil) or opts.editable(e.seq) or false,
      repeated = counts[e.pattern] > 1,
      occurrence = seen[e.pattern],
      track_alias = e.track_alias or false,
    }
    seg.alias = seg.repeated or seg.track_alias
    segments[#segments + 1] = seg
    offset = offset + seg.len_g
  end
  return { segments = segments, total_g = offset }
end

-- Entries for a sequence range [from, to] (1-based, inclusive).
-- `sequence` is a list of pattern indices; `pattern_info(pi)` returns
-- lines, resolved_pattern, track_alias.
function T.entries_for_range(sequence, from, to, pattern_info)
  local n = #sequence
  if n == 0 then return {} end
  if from < 1 then from = 1 end
  if to > n then to = n end
  if from > to then from, to = to, from end
  local out = {}
  for s = from, to do
    local lines, resolved, track_alias = pattern_info(sequence[s])
    out[#out + 1] = { seq = s, pattern = resolved or sequence[s], lines = lines, track_alias = track_alias }
  end
  return out
end

-- Global time of a local time (t, sub-units, 256 = line 1) within a segment.
function T.global(seg, t)
  return seg.offset + (t - U)
end

function T.local_t(seg, g)
  return g - seg.offset + U
end

-- Segment containing global time g (clamped to the timeline).
function T.locate(tl, g)
  local segs = tl.segments
  if #segs == 0 then return nil end
  if g < 0 then g = 0 end
  for i = 1, #segs do
    local s = segs[i]
    if g < s.offset + s.len_g then return s, T.local_t(s, g) end
  end
  local last = segs[#segs]
  return last, P.max_t(last.lines)
end

function T.segment_by_seq(tl, seq)
  for i = 1, #tl.segments do
    if tl.segments[i].seq == seq then return tl.segments[i] end
  end
  return nil
end

-- Split a straight ramp between two global times into per-segment ramps.
-- Returns a list of { seg, t0, v0, t1, v1 } in local sub-units. Each piece
-- ends on the last sub-unit of its segment, the next starts on its first one.
function T.split_ramp(tl, g0, v0, g1, v1)
  if g0 > g1 then g0, v0, g1, v1 = g1, v1, g0, v0 end
  local out = {}
  local function value_at(g)
    if g1 == g0 then return v1 end
    return v0 + (v1 - v0) * (g - g0) / (g1 - g0)
  end
  for i = 1, #tl.segments do
    local s = tl.segments[i]
    local s_start, s_end = s.offset, s.offset + s.len_g - 1
    if g1 >= s_start and g0 <= s_end then
      local a = math.max(g0, s_start)
      local b = math.min(g1, s_end)
      out[#out + 1] = {
        seg = s,
        t0 = T.local_t(s, a), v0 = value_at(a),
        t1 = T.local_t(s, b), v1 = value_at(b),
      }
    end
  end
  return out
end

-- Distinct editable patterns touched by a list of pieces (keeps first order).
function T.patterns_of(pieces)
  local seen, out = {}, {}
  for i = 1, #pieces do
    local pi = pieces[i].seg.pattern
    if not seen[pi] then
      seen[pi] = true
      out[#out + 1] = pi
    end
  end
  return out
end

return T
