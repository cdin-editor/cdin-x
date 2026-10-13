-- Compares versions and answers whether a version range is satisfied.
--
-- Pure: no filesystem, no process, no host. It exists so that a range written in
-- a package.lua can be checked, and so that a range nobody can parse is reported
-- as such rather than quietly treated as satisfied or quietly treated as failed.
local Version = {}

--- @alias Comparator { op: string, parts: integer[] }
--- @alias ComparatorList Comparator[]

-- The grammar, in one place, because "what does this string mean" is the thing a
-- third-party author has to guess and the thing a wrong answer here silently
-- breaks:
--
--   "" or "*"                any version
--   "1.2.3"  "=1.2.3"        exactly that release; a missing part is a zero, so
--                             "1.2" and "1.2.0" are the same version
--   ">=1.2"  "<=1.2"  ">1.2"  "<1.2"
--   ">=1.0, <2.0"             every comma is "and"
--   "^1.2.3"                  >= 1.2.3 and < the next incompatible release: the
--                             first non-zero part is what widens, so ^1.2.3 is
--                             <2.0.0 and ^0.2.3 is <0.3.0
--   "~1.2.3"                  >= 1.2.3 and <1.3.0
--
-- A pre-release suffix ("1.2.3-rc1") is not a version here. Nothing in this file
-- can order one, and treating it as *less* than the release would refuse a package
-- against a build of the same version, so it is reported instead.
--
-- "||" is not in the grammar. It is a disjunction rather than a longer
-- conjunction, and a range using it is reported as unreadable rather than being
-- read as a conjunction that excludes everything.

--- A version as three numbers, or nil if it is not one.
---
--- Every pattern is `$`-anchored. An unanchored two-part match would read "1.2.x"
--- as 1.2.0, and a version this cannot read has to be reported rather than
--- rounded into one it can.
--- @param v string
--- @return integer[]|nil parts
function Version.parse(v)
  if type(v) ~= "string" then return nil end

  local ma, mb, mc = v:match("^(%d+)%.(%d+)%.(%d+)$")
  if not ma then
    local a, b = v:match("^(%d+)%.(%d+)$")
    local c = v:match("^(%d+)$")
    if not (a or c) then return nil end
    ma, mb, mc = a or c, b or 0, 0
  end

  local na, nb, nc = tonumber(ma), tonumber(mb), tonumber(mc)
  if not (na and nb and nc) then return nil end
  return { na, nb, nc }
end

--- @param a integer[] three numbers, as `parse` returns them
--- @param b integer[] three numbers, as `parse` returns them
--- @return integer -1, 0 or 1
function Version.compare(a, b)
  for i = 1, 3 do
    if a[i] > b[i] then return 1 end
    if a[i] < b[i] then return -1 end
  end
  return 0
end

local OPERATORS = { ">=", "<=", "==", ">", "<", "=" }

--- The operator `text` starts with, longest first, and what follows it.
---
--- Matched by trying each candidate rather than with one pattern: Lua patterns have
--- no alternation, so `^(>=|<=|...)` matches nothing at all, and then every range
--- silently reads as an exact version and nothing this module refuses ever fires.
--- @param text string
--- @return string op
--- @return string rest
local function split_operator(text)
  for _, candidate in ipairs(OPERATORS) do
    if text:sub(1, #candidate) == candidate then
      local rest = text:sub(#candidate + 1):gsub("^%s+", "")
      return candidate, rest
    end
  end
  return "=", text
end

--- The upper bound `^base` means, by widening on the first non-zero part.
--- @param base integer[]
--- @return integer[]
local function caret_upper(base)
  if base[1] > 0 then
    return { base[1] + 1, 0, 0 }
  end
  if base[2] > 0 then
    return { 0, base[2] + 1, 0 }
  end
  return { 0, 0, base[3] + 1 }
end

--- One piece of a range, expanded to one or two comparators.
--- @param text string
--- @return ComparatorList|nil
local function one_piece(text)
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" or text == "*" then
    return { { op = ">=", parts = { 0, 0, 0 } } }
  end

  local op, rest = split_operator(text)

  local widened = rest:match("^%^%s*(.+)$")
  if widened then
    local base = Version.parse(widened)
    if not base then return nil end
    return {
      { op = ">=", parts = base },
      { op = "<", parts = caret_upper(base) },
    }
  end

  local tilde = rest:match("^~%s*(.+)$")
  if tilde then
    local base = Version.parse(tilde)
    if not base then return nil end
    return {
      { op = ">=", parts = base },
      { op = "<", parts = { base[1], base[2] + 1, 0 } },
    }
  end

  local parts = Version.parse(rest)
  if not parts then return nil end
  return { { op = op, parts = parts } }
end

--- Every comparator in `range`, or nil plus the reason it could not be read.
--- @param range string
--- @return ComparatorList|nil comparators
--- @return string|nil err
function Version.comparators(range)
  if type(range) ~= "string" then return nil, "not a string" end

  if range:find("||", 1, true) then
    return nil, "'||' is a disjunction, which this range grammar does not have"
  end

  local stripped = range:gsub("%s", "")
  if stripped == "" or stripped == "*" then
    return { { op = ">=", parts = { 0, 0, 0 } } }
  end

  local out = {}
  for piece in range:gmatch("[^,]+") do
    local comps = one_piece(piece)
    if not comps then
      return nil, string.format("%q is not a comparator", piece)
    end
    for _, c in ipairs(comps) do out[#out + 1] = c end
  end
  if #out == 0 then return nil, "no comparators in it" end
  return out
end

local function holds(order, op)
  if op == "<" then return order < 0 end
  if op == "<=" or op == "=" or op == "==" then return order <= 0 end
  if op == ">" then return order > 0 end
  return order >= 0
end

--- Whether `version` satisfies `range`.
---
--- nil plus a reason for anything unreadable, and that is deliberately not the
--- same answer as false: a range nobody can check is a promise nobody can enforce,
--- so it is reported rather than enforced in either direction.
--- @param version string
--- @param range string
--- @return boolean|nil satisfied
--- @return string|nil err
function Version.satisfies(version, range)
  local have = Version.parse(version)
  if not have then
    return nil, string.format("%q is not a version", tostring(version))
  end

  local comps, cerr = Version.comparators(range)
  if not comps then
    return nil, string.format("range %q: %s", tostring(range), tostring(cerr))
  end

  for _, c in ipairs(comps) do
    if not holds(Version.compare(have, c.parts), c.op) then return false end
  end
  return true
end

--- A one-line reason, for a skip reason in the panel.
--- @param name string
--- @param range string
--- @param version string|nil
--- @return string
function Version.mismatch(name, range, version)
  return string.format("%s needs version %s, and %s is installed",
    tostring(name), tostring(range), tostring(version or "an unknown version"))
end

return Version