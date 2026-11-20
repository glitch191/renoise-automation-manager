local TL = require "core.timeline"

local function info(lines_by_pattern, alias_map)
  return function(pi)
    local resolved = alias_map and alias_map[pi]
    return lines_by_pattern[pi], resolved or pi, resolved ~= nil
  end
end

T.test("build places segments end to end", function()
  local tl = TL.build({
    { seq = 1, pattern = 1, lines = 64 },
    { seq = 2, pattern = 2, lines = 32 },
  })
  T.eq(#tl.segments, 2)
  T.eq(tl.segments[1].offset, 0)
  T.eq(tl.segments[2].offset, 64 * 256)
  T.eq(tl.total_g, 96 * 256)
end)

T.test("repeated patterns are flagged as alias with occurrence numbers", function()
  local tl = TL.build({
    { seq = 1, pattern = 3, lines = 16 },
    { seq = 2, pattern = 1, lines = 16 },
    { seq = 3, pattern = 3, lines = 16 },
  })
  T.ok(tl.segments[1].repeated and tl.segments[1].alias)
  T.ok(not tl.segments[2].alias)
  T.eq(tl.segments[3].occurrence, 2)
end)

T.test("track alias flags alias even when not repeated", function()
  local tl = TL.build({ { seq = 1, pattern = 5, lines = 16, track_alias = true } })
  T.ok(tl.segments[1].alias)
  T.ok(not tl.segments[1].repeated)
end)

T.test("editable callback", function()
  local tl = TL.build({
    { seq = 1, pattern = 1, lines = 16 },
    { seq = 2, pattern = 2, lines = 16 },
  }, { editable = function(seq) return seq == 2 end })
  T.ok(not tl.segments[1].editable)
  T.ok(tl.segments[2].editable)
end)

T.test("entries_for_range clamps and resolves aliases", function()
  local e = TL.entries_for_range({ 1, 2, 1 }, 0, 9, info({ 64, 32 }, { [2] = 1 }))
  T.eq(#e, 3)
  T.eq(e[2].pattern, 1, "track alias of pattern 2 resolved to pattern 1")
  T.ok(e[2].track_alias)
  T.eq(e[3].lines, 64)
end)

T.test("locate and global are inverse", function()
  local tl = TL.build({
    { seq = 1, pattern = 1, lines = 16 },
    { seq = 2, pattern = 2, lines = 16 },
  })
  local seg, t = TL.locate(tl, 16 * 256 + 300)
  T.eq(seg.pattern, 2)
  T.eq(t, 256 + 300)
  T.eq(TL.global(seg, t), 16 * 256 + 300)
  local s0, t0 = TL.locate(tl, -5)
  T.eq(s0.pattern, 1)
  T.eq(t0, 256)
  local s9, t9 = TL.locate(tl, 999999)
  T.eq(s9.pattern, 2)
  T.eq(t9, 17 * 256 - 1)
end)

T.test("split_ramp crosses pattern boundaries with continuous values", function()
  local tl = TL.build({
    { seq = 1, pattern = 1, lines = 16 },
    { seq = 2, pattern = 2, lines = 16 },
  })
  local g0, g1 = 8 * 256, 24 * 256
  local pieces = TL.split_ramp(tl, g0, 0, g1, 1)
  T.eq(#pieces, 2)
  local a, b = pieces[1], pieces[2]
  T.eq(a.seg.pattern, 1)
  T.eq(a.t0, 9 * 256)
  T.eq(a.t1, 17 * 256 - 1)
  T.near(a.v0, 0)
  T.near(a.v1, (16 * 256 - 1 - g0) / (g1 - g0))
  T.eq(b.seg.pattern, 2)
  T.eq(b.t0, 256)
  T.near(b.v0, 0.5)
  T.eq(b.t1, 9 * 256)
  T.near(b.v1, 1)
  T.eq(TL.patterns_of(pieces), { 1, 2 })
end)

T.test("split_ramp reversed input", function()
  local tl = TL.build({ { seq = 1, pattern = 1, lines = 16 } })
  local p = TL.split_ramp(tl, 1024, 1, 256, 0)
  T.eq(#p, 1)
  T.eq(p[1].t0, 512)
  T.near(p[1].v0, 0)
  T.eq(p[1].t1, 1280)
end)
