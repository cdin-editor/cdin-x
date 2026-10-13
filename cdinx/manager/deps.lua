local Catalog = require "cdinx.manager.catalog"
local Version = require "cdinx.version"

local Deps = {}

-- A plugin the host already loaded counts as available: it is running, so
-- an integration that depends on it can load against it. The host strips
-- it from ctx.available, so it has to be recognised here explicitly or every
-- integration that declares `dependencies = { "vim", … }` would fail with
-- "dependency 'vim' is not installed" on a completely stock install.
local function is_provided(ctx, name)
  return ctx.provided ~= nil and ctx.provided[name] == true
end

-- "Can this name be loaded right now?" -- running in the host, shipped in the
-- build, or present in the user's extension store. A name that is only listed
-- in the catalog index (not downloaded) is NOT usable.
local function is_usable(ctx, name)
  return is_provided(ctx, name)
    or Catalog.is_builtin(ctx, name)
    or Catalog.is_installed(ctx, name)
end

--- The range `plugin` asked for `dep`, or nil when it asked without one.
---
--- `depends` is a range map, so the names alone -- which is all
--- `Schema.dependency_names` hands back -- cannot be checked against anything. The
--- range is the promise, and dropping it is what made the field inert.
local function wanted_range(plugin, dep)
  local depends = plugin.spec and plugin.spec.depends
  if type(depends) ~= "table" then return nil end
  local range = depends[dep]
  if type(range) ~= "string" or range == "" then return nil end
  return range
end

--- Whether the available version of `dep` satisfies what `plugin` asked for.
---
--- Always a boolean. A range nobody can read is `true` with a reason, not nil:
--- nil here would reach the caller's `not in_range` test and be treated as a
--- failure, which is the one reading an unverifiable promise must never get.
--- @param ctx table
--- @param plugin table
--- @param dep string
--- @return boolean ok
--- @return string|nil unreadable  set when the range could not be read at all
local function range_ok(ctx, plugin, dep)
  -- A dependency the host is running is not this kernel's to check. The host
  -- does not report versions, and a range against something we cannot see would
  -- refuse every package that names it.
  if is_provided(ctx, dep) then return true end

  local range = wanted_range(plugin, dep)
  if not range then return true end

  local entry = ctx.available[dep]
  local version = entry and entry.version
  if type(version) ~= "string" or version == "" then return true end

  local ok, err = Version.satisfies(version, range)
  if ok == nil then return true, err end
  return ok, nil
end--- Every name in the cycle that closes at `name`, sorted.
---
--- One name is not an answer: a user who sees "dependency cycle involving c" has
--- to go and find which three packages are involved, and the walk that found it
--- already knows. `order` is the visit stack, so the members are the tail from
--- where `name` first appeared.
local function cycle_members(order, name)
  local first = 1
  for i, entry in ipairs(order) do
    if entry == name then first = i break end
  end
  local members = {}
  for i = first, #order do members[#members + 1] = order[i] end
  table.sort(members)
  return members
end

--- Orders `names` so every plugin comes after the plugins it depends on.
---
--- Returns `ordered, skipped`.
---
--- A plugin that cannot be loaded (a dependency is not installed, the installed
--- version is outside the range asked for, or there is a cycle) is *skipped*,
--- never fatal: it lands in `skipped[name]` as
---   { reason = "<text>", missing = { "<dep>", ... } }
--- and so does everything that depends on it. One extension with unmet
--- dependencies must not take the manager -- and with it every other
--- extension -- down.
---
--- `optional_dependencies` only influence ordering: if an optional dependency
--- is part of this load it goes first, if it is absent nothing happens.
--- @param ctx table
--- @param names string[]
--- @return string[] ordered
--- @return table<string, {reason: string, missing: string[]}> skipped
--- @return string[] notes  things worth saying that are not failures
function Deps.topological_order(ctx, names)
  local ordered, skipped, notes = {}, {}, {}
  local visiting, visited = {}, {}
  local order = {}
  local noted = {}

  local wanted = {}
  for _, name in ipairs(names) do wanted[name] = true end

  local function note(text)
    if noted[text] then return end
    noted[text] = true
    notes[#notes + 1] = text
  end

  local function fail(name, reason, missing)
    skipped[name] = { reason = reason, missing = missing or {} }
    return false, reason
  end

  local function visit(name)
    -- Already running in the host: nothing to order, nothing to load.
    if is_provided(ctx, name) then
      visited[name] = true
      return true
    end
    if visited[name] then return true end
    if skipped[name] then return false, skipped[name].reason end
    if visiting[name] then
      local members = cycle_members(order, name)
      return fail(name, "dependency cycle: " .. table.concat(members, " -> "), members)
    end

    local plugin = ctx.available[name]
    if not plugin then
      return fail(name, "missing dependency: " .. name, { name })
    end

    visiting[name] = true
    order[#order + 1] = name

    -- Collect every problem instead of stopping at the first, so the user
    -- sees "needs git, menu, with/menus.lua" once, not three restarts' worth.
    local missing, blocked = {}, {}
    for _, dep in ipairs(plugin.dependencies or {}) do
      local in_range, unreadable = range_ok(ctx, plugin, dep)
      if unreadable then
        note(string.format("%s declares depends.%s = %q, which cannot be checked",
          name, dep, tostring(unreadable)))
      end
      if not is_usable(ctx, dep) then
        missing[#missing + 1] = dep
      elseif not in_range then
        blocked[#blocked + 1] = Version.mismatch(dep, wanted_range(plugin, dep),
          ctx.available[dep] and ctx.available[dep].version)
      else
        local ok, err = visit(dep)
        if not ok then
          blocked[#blocked + 1] = string.format("%s (%s)", dep, tostring(err))
        end
      end
    end

    -- Soft dependencies: ordering only, and only when they are being loaded
    -- anyway. Failure here is ignored on purpose.
    for _, dep in ipairs(plugin.optional_dependencies or {}) do
      if wanted[dep] and is_usable(ctx, dep) and not visiting[dep] then
        visit(dep)
      end
    end

    order[#order] = nil
    visiting[name] = nil

    if #missing > 0 or #blocked > 0 then
      local parts = {}
      if #missing > 0 then
        parts[#parts + 1] = "missing dependencies: " .. table.concat(missing, ", ")
      end
      if #blocked > 0 then
        parts[#parts + 1] = "dependencies that could not load: " .. table.concat(blocked, ", ")
      end
      return fail(name, table.concat(parts, "; "), missing)
    end

    visited[name] = true
    ordered[#ordered + 1] = name
    return true
  end

  for _, name in ipairs(names) do
    visit(name)
  end
  return ordered, skipped, notes
end

-- Exported so Runtime.load_plugin can skip a host-provided plugin reached
-- by a name rather than through the load order.
Deps.is_provided = is_provided
Deps.is_usable   = is_usable

return Deps