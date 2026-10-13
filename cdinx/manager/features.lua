-- A package's features: the parts of it that can be switched off.
--
-- A feature is one file, `features/<key>.lua`, returning `enable()` and
-- `disable()`. `package.lua` names them and gives each a default:
--
--   features = { tab = { default = true, description = "Tab bar" } }
--
-- A feature is a separate file rather than a flag inside one init because that
-- is the only way the cost can be avoided: a feature nobody enabled is never
-- required, so its commands, its keymap and its module state are never built.
-- Loading all of a package to discover which third of it you want is the thing
-- this replaces.
--
-- The contract a feature file honours is the package's own (invariant 7): every
-- registration `enable` makes, `disable` takes back, with the same table. That
-- is not checkable from here — it is the author's promise — so the shape is
-- checked instead (check.lua R8) and the symmetry is what `disable_all` relies
-- on.
local Host = require "cdinx.host"
local Seam = require "cdinx.manager.seam"

local Features = {}

--- @class FeatureSpec
--- @field key string
--- @field default boolean
--- @field description string|nil

--- The features a package declares, sorted by key. A file in `features/` with no
--- entry in `package.lua` is not a feature: the manifest is what the panel shows
--- and what a user overrides, and a feature the manifest does not mention cannot
--- be turned off by name.
--- @param spec PackageSpec
--- @return FeatureSpec[]
function Features.declared(spec)
  local out = {}
  for key, info in pairs(spec.features or {}) do
    out[#out + 1] = {
      key = key,
      default = info.default == true,
      description = info.description,
    }
  end
  table.sort(out, function(a, b) return a.key < b.key end)
  return out
end

--- Whether a package carries any features at all, so the common case costs
--- nothing: no table is built and no `spec.features` is read for a package that
--- has none.
--- @param spec PackageSpec
--- @return boolean
function Features.has_any(spec)
  return spec.features ~= nil and next(spec.features) ~= nil
end

--- Which features are on: the declared defaults, then the user's overrides.
---
--- `overrides` is the user's table (`packages.lua` `features = { ... }`, or the
--- state file for the panel). An unknown key is dropped with a warning rather
--- than refused: the user is describing a package that may have had the feature
--- renamed since they last used it, and refusing the whole set over one stale
--- key would take the features they got right down with it.
--- @param name string
--- @param declared FeatureSpec[]
--- @param overrides table<string, boolean>|nil
--- @return table<string, boolean> enabled
--- @return string[] warnings
function Features.resolve(name, declared, overrides)
  local enabled, warnings = {}, {}
  local known = {}
  for _, f in ipairs(declared) do
    known[f.key] = true
    if f.default then enabled[f.key] = true end
  end

  local keys = {}
  for key in pairs(overrides or {}) do keys[#keys + 1] = key end
  table.sort(keys)

  for _, key in ipairs(keys) do
    if not known[key] then
      local available = {}
      for _, f in ipairs(declared) do available[#available + 1] = f.key end
      warnings[#warnings + 1] = string.format(
        "%s: %q is not a feature; it has %s", name, tostring(key),
        #available > 0 and table.concat(available, ", ") or "none")
    else
      enabled[key] = overrides[key] and true or false
    end
  end

  return enabled, warnings
end

--- The features that are on right now, for a loaded package.
--- @param ctx table
--- @param name string
--- @return string[]
function Features.active(ctx, name)
  local entry = ctx.active_features and ctx.active_features[name]
  if not entry then return {} end
  local out = {}
  for key in pairs(entry) do
    if entry[key] then out[#out + 1] = key end
  end
  table.sort(out)
  return out
end

--- The declared options, defaults first and the user's overrides over them.
---
--- An override of the wrong type is dropped rather than refused: the schema has
--- already checked what the manifest declared, and a user who writes
--- `show_keybinds = "yes"` wants the feature on with that key wrong rather than
--- wants the whole package gone. The declared default is kept in that case, so
--- the feature still behaves.
--- @param spec PackageSpec
--- @param overrides table<string, any>|nil
--- @return table<string, any>
function Features.options(spec, overrides)
  local out = {}
  for key, info in pairs(spec.options or {}) do
    out[key] = info.default
  end
  for key, value in pairs(overrides or {}) do
    local declared = (spec.options or {})[key]
    if declared and type(value) == declared.type then
      out[key] = value
    elseif declared then
      Host.core.log("cdin-x: %s: option %q wants a %s, got %s; keeping the default",
        tostring(spec.name), key, declared.type, type(value))
    end
  end
  return out
end

--- Requires one feature file and calls `enable` on it.
---
--- Required as `<package>.features.<key>`, not by path, so it resolves through the
--- same searcher as every other module of the package: the file is cached in
--- `package.loaded` under a name the unload path already knows how to clear, and
--- no absolute path is ever left in `package.loaded` for something to trip over
--- later. A package whose name is not resolvable cannot have features at all,
--- which is what keeps a feature from being loaded for a package the loader does
--- not know.
--- @param ctx table
--- @param name string
--- @param key string
--- @param opts table<string, any>|nil  the package's merged options
--- @return table|nil module
--- @return string|nil err
function Features.enable(ctx, name, key, opts)
  ctx.active_features = ctx.active_features or {}
  ctx.active_features[name] = ctx.active_features[name] or {}

  if ctx.active_features[name][key] then
    return nil, string.format("%s: feature %q is already enabled", name, key)
  end

  local module_name = name .. ".features." .. key
  -- The load/validate/forget half of the lifecycle belongs to seam.lua, so that
  -- it cannot drift from with.lua's copy of it again. What stays here is the
  -- part that is this module's business: the module name, the record key, and
  -- the fact that a feature is always passed the options, even a nil one.
  local mod, raise_err = Seam.raise(
    module_name,
    { pkg = name, kind = "feature", name = key, file = "features/" .. key .. ".lua" },
    opts,
    true
  )
  if not mod then
    return nil, raise_err
  end

  ctx.active_features[name][key] = mod
  return mod
end

--- Takes one feature back down.
--- @param ctx table
--- @param name string
--- @param key string
--- @return boolean ok
--- @return string|nil err
function Features.disable(ctx, name, key)
  local entry = ctx.active_features and ctx.active_features[name]
  local mod = entry and entry[key]
  if not mod then
    return true -- never enabled, or already down: nothing to undo
  end

  if type(mod.disable) ~= "function" then
    return false, string.format("%s: features/%s.lua has no disable()", name, key)
  end

  local ok, err = pcall(mod.disable)
  entry[key] = nil
  if not ok then
    return false, string.format("%s: feature %q failed to disable: %s", name, key, tostring(err))
  end
  return true
end

--- Takes every feature of a package down. Called from the package's `unload`.
---
--- Reverse order matters: a feature enabled later may depend on one enabled
--- earlier, and undoing them in the order they were raised is the only order
--- that is right without every feature knowing about every other.
--- @param ctx table
--- @param name string
--- @return string[] problems
function Features.disable_all(ctx, name)
  local problems = {}
  local entry = ctx.active_features and ctx.active_features[name]
  if not entry then return problems end

  local order = {}
  for key in pairs(entry) do order[#order + 1] = key end
  table.sort(order, function(a, b)
    return (entry[a]._order or 0) > (entry[b]._order or 0)
  end)

  for _, key in ipairs(order) do
    local ok, err = Features.disable(ctx, name, key)
    if not ok then problems[#problems + 1] = tostring(err) end
  end
  ctx.active_features[name] = nil
  return problems
end

--- Raises the features a package asked for, and reports what it could not.
---
--- A feature that fails does not take the package down: it takes itself down. The
--- package loaded, its other features are up, and the panel shows why this one is
--- not.
--- @param ctx table
--- @param name string
--- @param spec PackageSpec
--- @param overrides table<string, boolean>|nil
--- @return string[] problems
function Features.apply(ctx, name, spec, overrides)
  local problems = {}
  if not Features.has_any(spec) then return problems end

  local declared = Features.declared(spec)
  local enabled, warnings = Features.resolve(name, declared, overrides)
  local opts = Features.options(spec, overrides)

  for _, warn_msg in ipairs(warnings) do
    Host.core.log("cdin-x: %s", warn_msg)
  end

  local order = 0
  for _, f in ipairs(declared) do
    if enabled[f.key] then
      order = order + 1
      local mod, err = Features.enable(ctx, name, f.key, opts)
      if mod then
        mod._order = order
      else
        problems[#problems + 1] = tostring(err)
      end
    end
  end
  return problems
end

return Features