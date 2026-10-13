-- Two packages that need each other without depending on each other.
--
-- A `with` entry is one file, named in `package.lua` against the *other* package:
--
--   with = { session = "with/themes.lua" }
--
-- and it runs only while both packages are active. It goes up when the second of
-- the two arrives and comes down when the first of them leaves.
--
-- The difference from `dependencies` is the whole point. A dependency says "load
-- this first", which means neither package is usable alone, so installing one
-- without the other is a broken install. A `with` entry says "if both are here,
-- wire them up", which means either can be installed, or uninstalled, on its own.
-- `themes` pushes the chosen theme into the session's saved state, and a user with
-- themes but no session wants the switcher to keep working.
--
-- So a `with` entry is not a dependency and does not sort the load order: the file
-- is required at the moment both are up, and by then there is nothing to sort.
-- That is also why it is allowed to reach the other package's internals, which is
-- why it lives in its own directory -- the path is the evidence, and check.lua can
-- tell a `with` file from an ordinary module by where it is.
--
-- The contract is a feature's contract: `enable()` registers, `disable()` undoes it
-- with the same table. Not checkable from here, so the shape is checked instead
-- (check.lua R8) and the symmetry is what `disable_all` relies on.
local Seam = require "cdinx.manager.seam"

local With = {}

--- @class WithSpec
--- @field other string   the package this entry wires itself to
--- @field path string    where the file is, relative to the package

--- The `with` entries a package declares, sorted by partner then by path.
---
--- A partner may carry a list of paths, because two seams can wait on the same
--- package: vim has one for the tab bindings and one for the window bindings, and
--- both need `workspace`. Flattening here is what lets every later step work on
--- one entry per seam rather than on the manifest's shape.
---
--- Sorted so the order is the same on every run and in every log. The path is the
--- tiebreak because a partner may carry more than one seam, and `pairs` order
--- between them is not reproducible. They do not depend on each other, so either
--- order is correct; what matters is that it is the *same* order every time, or a
--- bug in one of them reproduces once a week.
--- @param spec PackageSpec
--- @return WithSpec[]
function With.declared(spec)
  local out = {}
  for other, rel in pairs(spec.with or {}) do
    if type(rel) == "table" then
      for _, one in ipairs(rel) do
        out[#out + 1] = { other = other, path = one }
      end
    else
      out[#out + 1] = { other = other, path = rel }
    end
  end
  table.sort(out, function(a, b)
    if a.other ~= b.other then return a.other < b.other end
    return a.path < b.path
  end)
  return out
end

--- Whether a package declares any `with` entry, so the common case -- which is
--- almost every package -- costs one table read.
--- @param spec PackageSpec
--- @return boolean
function With.has_any(spec)
  return spec.with ~= nil and next(spec.with) ~= nil
end

--- Whether a package is up right now, and therefore whether an entry naming it
--- can run.
---
--- `provided` counts, and has to: the host loaded some packages itself, and those
--- are exactly the ones a `with` entry must be able to see as present. A seam
--- wired to a partner the host already started is still a seam that is wired.
--- @param ctx table
--- @param name string
--- @return boolean
function With.is_active(ctx, name)
  if ctx.installed and ctx.installed[name] then return true end
  local provided = ctx.provided
  return type(provided) == "table" and provided[name] ~= nil
end

--- The partners a package is currently wired to, one row per entry, sorted.
---
--- One row per *entry*, not per partner. Two entries can name the same package --
--- a vim integration for tabs and another for windows both need `workspace` -- and
--- collapsing them onto one key would leave whichever was written first wired and
--- the other silently doing nothing. So this list may repeat a name.
--- @param ctx table
--- @param name string
--- @return string[]
function With.active(ctx, name)
  local entry = ctx.active_with and ctx.active_with[name]
  if not entry then return {} end
  local out = {}
  for _, rec in pairs(entry) do
    if rec.mod then out[#out + 1] = rec.other end
  end
  table.sort(out)
  return out
end

--- Turns a declared relative path into the module name the loader resolves.
---
--- `with/themes.lua` inside `themes` is `themes.with.themes`. The name comes from
--- the *path*, not from the partner key: `with = { session = ... }` is named after
--- the package on the other side, and keying the module name on that would file
--- this package's seam under the other package's namespace -- which is the thing
--- the whole mechanism exists to avoid.
--- @param name string      the declaring package
--- @param rel string       the path as written in package.lua
--- @return string|nil module_name
--- @return string|nil err
local function module_name_of(name, rel)
  if type(rel) ~= "string" or rel == "" then
    return nil, string.format("%s: with entry is %s, not a path",
      name, type(rel) == "string" and "an empty string" or tostring(rel))
  end
  if rel:find("\\", 1, true) or rel:find("..", 1, true) or rel:find("^/") then
    return nil, string.format("%s: with entry %q must be a plain relative path", name, rel)
  end

  local stem = rel:gsub("%.lua$", ""):gsub("/", "."):gsub("%.init$", "")
  return name .. "." .. stem
end

--- Requires one `with` file and calls `enable` on it.
---
--- Required by name, through the same searcher as every other module, for the same
--- two reasons as a feature: the file lands in `package.loaded` under a name the
--- unload path already knows how to clear, and no absolute path is left behind for
--- something to trip over later.
--- @param ctx table
--- @param name string       the package that declares the entry
--- @param entry WithSpec
--- @return table|nil module
--- @return string|nil err
function With.enable(ctx, name, entry)
  ctx.active_with = ctx.active_with or {}
  ctx.active_with[name] = ctx.active_with[name] or {}

  -- Keyed by the path, which is unique inside a package, rather than by the
  -- partner: two entries may name the same partner (a vim integration for tabs
  -- and one for windows, both needing `workspace`) and each still has to be its
  -- own enabled thing.
  if ctx.active_with[name][entry.path] then
    return nil, string.format("%s: with %q is already enabled", name, entry.other)
  end

  local module_name, name_err = module_name_of(name, entry.path)
  if not module_name then return nil, name_err end

  -- The load/validate/forget half of the lifecycle belongs to seam.lua, and it is
  -- the half that drifted: this file has always cleared the cached module when
  -- enable() raises, and features.lua did not. What stays here is what is this
  -- module's business: turning a path into a module name, the record written on
  -- success, and the fact that a with entry is called with no argument at all.
  local mod, raise_err =
    Seam.raise(module_name, { pkg = name, kind = "with", name = entry.other, file = entry.path })
  if not mod then
    return nil, raise_err
  end

  ctx.active_with[name][entry.path] = { mod = mod, other = entry.other }
  return mod
end

--- Takes one `with` entry back down.
--- @param ctx table
--- @param name string
--- @param path string       the entry's path, as written in package.lua
--- @return boolean ok
--- @return string|nil err
function With.disable(ctx, name, path)
  local entry = ctx.active_with and ctx.active_with[name]
  local rec = entry and entry[path]
  if not rec then
    return true -- never enabled, or already down: nothing to undo
  end

  if type(rec.mod.disable) ~= "function" then
    -- Left recorded as still up, because there is nothing to call: dropping the
    -- entry would make `active` claim a seam that is down, and the caller has no
    -- other way to know.
    return false, string.format("%s: the with %q entry (%s) has no disable()",
      name, rec.other, path)
  end

  local ok, err = pcall(rec.mod.disable)
  entry[path] = nil
  if not ok then
    return false, string.format("%s: with %q failed to disable: %s",
      name, rec.other, tostring(err))
  end
  return true
end

--- Takes every `with` entry of a package down.
---
--- Called from the package's `unload`, and again when a *partner* unloads -- a
--- `with` entry belongs to neither side alone, so whichever leaves first takes it
--- with it. Reverse order for the same reason features use: an entry enabled later
--- may sit on one enabled earlier.
--- @param ctx table
--- @param name string
--- @return string[] problems
function With.disable_all(ctx, name)
  local problems = {}
  local entry = ctx.active_with and ctx.active_with[name]
  if not entry then return problems end

  local order = {}
  for path in pairs(entry) do order[#order + 1] = path end
  -- `_order` is written by `apply` onto the module, and what `enable` puts in
  -- this table is a record around that module -- so it is read through the
  -- record's `mod`. Reading `entry[a]._order` finds nil on every entry, the
  -- comparator is never true, and `table.sort` returns whatever order `pairs`
  -- produced: not the reverse of the order these went up in, and not the same
  -- twice. Every stored record came from a successful `enable` (the only caller
  -- of which is `apply`, which stamps `_order`), and `disable` below already
  -- treats `rec.mod` as a table, so reading through it adds no new assumption.
  table.sort(order, function(a, b)
    return (entry[a].mod._order or 0) > (entry[b].mod._order or 0)
  end)

  for _, path in ipairs(order) do
    local ok, err = With.disable(ctx, name, path)
    if not ok then problems[#problems + 1] = tostring(err) end
  end
  ctx.active_with[name] = nil
  return problems
end

--- Raises one package's entries whose partner is *already* up.
---
--- This is one half of the mechanism. `apply` handles "I just loaded and my partner
--- was here first"; `partner_arrived` handles "my partner just loaded and I was
--- here first". Between them an entry runs whichever order the two arrived in,
--- which is the only definition of "both are active" that does not depend on load
--- order -- and load order here is `pairs` order, which is not something to build
--- a mechanism on.
--- @param ctx table
--- @param name string
--- @param spec PackageSpec|nil  nil to look it up in the catalog
--- @return string[] problems
function With.apply(ctx, name, spec)
  local problems = {}
  spec = spec or (ctx.available and ctx.available[name] and ctx.available[name].spec)
  if not spec or not With.has_any(spec) then return problems end

  local order = 0
  for _, entry in ipairs(With.declared(spec)) do
    if With.is_active(ctx, entry.other) then
      order = order + 1
      local mod, err = With.enable(ctx, name, entry)
      if mod then
        mod._order = order
      else
        problems[#problems + 1] = tostring(err)
      end
    end
  end
  return problems
end

--- The loaded packages that named `other` in a `with` entry, sorted.
---
--- Sorted because two packages that both declared an entry against the same
--- partner would otherwise be offered it in `pairs` order, and the order two seams
--- go up in is the one thing that has to be reproducible to be debuggable.
--- @param ctx table
--- @param other string
--- @return string[]
local function waiters(ctx, other)
  local out = {}
  if type(ctx.installed) ~= "table" then return out end
  for name in pairs(ctx.installed) do
    if name ~= other then
      local spec = ctx.available and ctx.available[name] and ctx.available[name].spec
      if spec and With.has_any(spec) then
        for _, entry in ipairs(With.declared(spec)) do
          if entry.other == other then
            out[#out + 1] = name
            break
          end
        end
      end
    end
  end
  table.sort(out)
  return out
end

--- A partner just came up: raise the entries waiting on it.
---
--- An entry that fails takes itself down. The partner is untouched, because a seam
--- that cannot be built is the seam's problem and not a reason to unload the two
--- packages either of them belongs to.
--- @param ctx table
--- @param other string
--- @return string[] problems
function With.partner_arrived(ctx, other)
  local problems = {}
  for _, name in ipairs(waiters(ctx, other)) do
    for _, p in ipairs(With.apply(ctx, name)) do
      problems[#problems + 1] = p
    end
  end
  return problems
end

--- A partner just left: take down the entries that were waiting on it.
---
--- The reverse of `partner_arrived`, and for the same reason: whichever of the two
--- goes first, the seam goes with it. An entry left up over a partner that is gone
--- is a file holding a subscription to a table nothing else uses -- and if that
--- partner comes back, `partner_arrived` would try to enable an entry that thinks
--- it is already on.
--- @param ctx table
--- @param other string
--- @return string[] problems
function With.partner_left(ctx, other)
  local problems = {}
  for _, name in ipairs(waiters(ctx, other)) do
    -- By path, not by partner: a package may have two entries naming the same
    -- partner, and both of them lose their partner at the same moment.
    local spec = ctx.available and ctx.available[name] and ctx.available[name].spec
    if spec then
      local paths = {}
      for _, entry in ipairs(With.declared(spec)) do
        if entry.other == other then paths[#paths + 1] = entry.path end
      end
      table.sort(paths)
      for _, path in ipairs(paths) do
        local ok, err = With.disable(ctx, name, path)
        if not ok then problems[#problems + 1] = tostring(err) end
      end
    end
  end
  return problems
end

return With