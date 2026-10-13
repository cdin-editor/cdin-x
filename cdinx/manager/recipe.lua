-- What a third-party recipe must be, checked without the host.
--
-- Split out of manager/registry.lua because `scripts/validate.lua` runs under
-- plain lua with no editor: anything it dofiles must not require `core`, and the
-- registry module does. The reader and the gate both call this, so one
-- implementation says what a recipe is in both places rather than two that can
-- disagree about a URL alphabet or a name rule.
local Source = require "cdinx.manager.source"

local Recipe = {}

--- The recipe kinds the index may name.
Recipe.KINDS = { plugin = true, lang = true, theme = true, glue = true }

--- Why a recipe is refused, or nil.
---
--- `taken` is the set of first-party names. A recipe claiming one is refused
--- outright rather than installed beside it: two packages with one name is an
--- error everywhere else in this system, and the index is not an exception.
--- @param entry table
--- @param taken table<string, boolean>|nil
--- @return string|nil
function Recipe.check(entry, taken)
  local name_problem = Source.name_problem(entry.name)
  if name_problem then return name_problem end
  if taken and taken[entry.name] then
    return string.format("%q is a first-party package; a recipe may not claim it",
      entry.name)
  end
  if type(entry.git) ~= "string" then
    return string.format("%q has no git URL", tostring(entry.name))
  end
  local url_problem = Source.url_problem(entry.git)
  if url_problem then return url_problem end
  -- A commit, never a tag or a branch: CI resolves the tag when the recipe is
  -- accepted, so what lands here is pinned. A tag in this file would move under
  -- the user, which is exactly the failure the lock file exists to prevent.
  if type(entry.rev) ~= "string" or not entry.rev:match("^[%x]+$") or #entry.rev ~= 40 then
    return string.format(
      "%q names rev %q; rev must be the 40-hex commit CI resolved",
      entry.name, tostring(entry.rev))
  end
  if entry.subdir ~= nil then
    local subdir_problem = Source.subdir_problem(entry.subdir)
    if subdir_problem then return entry.name .. ": " .. subdir_problem end
  end
  if entry.kind ~= nil and not Recipe.KINDS[entry.kind] then
    return string.format("%q names kind %q; kind is plugin, lang, theme or glue",
      entry.name, tostring(entry.kind))
  end
  return nil
end

return Recipe
