-- Turning what the user wrote into something installable.
--
-- Two things can name a third-party package:
--
--   sources = { ["name"] = "owner/repo" }
--   sources = { ["name"] = { git = "...", rev = "v1.2.0", subdir = "elixir" } }
--   sources = { ["name"] = { dir = "~/src/cdin-name" } }
--
-- and the vetted recipes in `registry/index.lua`, which name a repository and the
-- commit CI resolved a tag to. Both end up as the same shape, because everything
-- downstream -- the transport, the lock file, the panel -- works on one shape.
--
-- Everything in this module is pure: a table in, a table out, or nil and a
-- sentence. The one thing it cannot know by itself is which names are already
-- taken by first-party packages, so the caller passes that set in; `Manager`
-- passes the running catalog and `scripts/validate.lua` passes the tree's own
-- package names, and both get the same rules from one implementation.
--
-- The one field is `rev`, for a commit, a tag or a branch -- the same field and
-- the same three meanings `Source.parse` already has. The index's separate
-- `ref` exists because CI resolved a tag and a recipe wants to say which one;
-- that is a record of a resolution, not a second way to ask for one.
local Source = require "cdinx.manager.source"
local Recipe = require "cdinx.manager.recipe"

local Spec = {}

-- The whole vocabulary of one entry. Anything else is a typo, and a typo in a
-- hand-edited file is worth naming rather than ignoring: `subdi = "x"` would
-- otherwise install the whole repository and look like it worked.
Spec.FIELDS = {
  git = true,
  dir = true,
  rev = true,
  subdir = true,
  name = true,
  kind = true,
  description = true,
}

--- Resolves one `sources` entry into a source spec.
---
--- The table key is the name, because that is the only place a name can live
--- for a key that is not a valid identifier. An explicit `name` is allowed when
--- it agrees with the key, and refused when it does not: two names for one
--- source is how the wrong one gets installed.
--- @param name string
--- @param entry any
--- @param opts table|nil  { taken = <set of first-party names> }
--- @return table|nil spec
--- @return string|nil err
function Spec.parse(name, entry, opts)
  opts = opts or {}
  local problem = Source.name_problem(name)
  if problem then return nil, string.format("sources[%q]: %s", tostring(name), problem) end
  if opts.taken and opts.taken[name] then
    return nil, string.format(
      "sources[%q]: %q is already a first-party package; a source may not claim it", name, name)
  end

  if type(entry) == "table" then
    for field in pairs(entry) do
      if type(field) == "string" and not Spec.FIELDS[field] then
        return nil, string.format(
          "sources[%q]: %q is not a field of a source; it will be ignored",
          name, field)
      end
    end
  end

  local spec, err = Source.parse(entry)
  if not spec then
    return nil, string.format("sources[%q]: %s", name, tostring(err))
  end
  if spec.name ~= nil and spec.name ~= name then
    return nil, string.format(
      "sources[%q]: the entry also names itself %q; the key is the name",
      name, spec.name)
  end
  spec.name = name
  spec.source_label = spec.source_label or name
  return spec
end

--- Resolves a vetted recipe into the same shape a `sources` entry produces.
---
--- `registry/index.lua` is already validated -- by CI before it lands, and by
--- `Recipe.check` on the way out -- so this is a renaming, not a second gate.
--- The commit stays a commit: a recipe that could float would be a recipe that
--- moves under the user between two clicks.
--- @param entry table
--- @return table|nil spec
--- @return string|nil err
function Spec.from_recipe(entry)
  local problem = Recipe.check(entry, nil)
  if problem then return nil, problem end
  return {
    kind = "git",
    name = entry.name,
    url = entry.git,
    ref = entry.rev,
    ref_kind = "sha",
    subdir = entry.subdir or "",
    recipe = true,
    source_label = entry.git,
    description = entry.description,
  }
end

--- Resolves a whole `sources` table.
---
--- One bad entry does not spoil the file: it is skipped with a sentence, because
--- a file with three good sources and one typo is three packages that work. The
--- problems come back sorted by name, because the file is hand-edited and two
--- reads of it must agree about which typo is reported first.
--- @param sources table
--- @param opts table|nil  { taken = <set of first-party names> }
--- @return table<string, table> specs
--- @return string[] problems
function Spec.resolve(sources, opts)
  local specs, problems = {}, {}
  if type(sources) ~= "table" then return specs, problems end

  local names = {}
  for name in pairs(sources) do names[#names + 1] = name end
  table.sort(names, function(a, b) return tostring(a) < tostring(b) end)

  for _, name in ipairs(names) do
    local spec, err = Spec.parse(name, sources[name], opts)
    if not spec then
      problems[#problems + 1] = tostring(err)
    else
      specs[name] = spec
    end
  end
  return specs, problems
end

--- Whether a spec is pinned to one commit.
---
--- A pinned source is not updated: `update` on it is a no-op with a line in the
--- log saying why, because "the user wrote 40 hex characters" is the most
--- explicit statement of intent this system has, and treating it as a suggestion
--- would be the one way to be sure of losing the argument.
--- @param spec table|nil
--- @return boolean
function Spec.is_pinned(spec)
  return type(spec) == "table" and spec.kind == "git"
    and type(spec.ref) == "string" and #spec.ref == 40
    and spec.ref:match("^[%x]+$") ~= nil
end

return Spec
