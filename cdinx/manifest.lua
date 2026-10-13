-- Reads a package's `package.lua`, and reports the legacy form instead of running it.
--
-- `package.lua` is the form, and it is pure data read through the sandbox in
-- cdinx/schema.lua. A directory with no `package.lua` is the legacy form -- the
-- manifest returned by `init.lua`, or by a `manifest.lua` beside it -- and it is
-- **not executed to be listed**. It is reported. That is a change in behaviour
-- and it is the point: a manifest read by running it means listing the catalog
-- runs every package's code, and for anything fetched from a network that is
-- running whatever arrived inside the editor.
--
-- A legacy package is therefore *visible but not loadable from the store*: it is
-- in the panel, its name comes from the directory, and installing it puts the
-- files on disk where `runtime.load_plugin` can dofile its entry point the way it
-- always has. It is the listing that no longer runs it. First-party packages all
-- carry a `package.lua`, so this reports nothing in a correct tree.
--
-- The result is the shape the rest of the kernel already uses: `type` rather
-- than `kind`, and `dependencies` as a sorted list rather than a range map.
-- Whatever the manifest said is kept alongside, so nothing is guessed twice.
local Host   = require "cdinx.host"
local Schema = require "cdinx.schema"

local Manifest = {}

--- @class PackageMeta
--- @field name string
--- @field type string
--- @field dependencies string[]
--- @field entry string
--- @field category string|nil
--- @field _package_file string|nil set when the manifest was a package.lua
--- @field _legacy boolean|nil the directory has no package.lua and was not run
--- @field spec PackageSpec|nil the validated package.lua, when there was one

--- Reads `package.lua` from `dir`, or nil plus the reason.
--- @param dir string
--- @return PackageSpec|nil spec
--- @return string|nil err
function Manifest.read_package(dir)
  local file = dir .. "/package.lua"
  if not Host.fs.is_file(file) then return nil end
  return Schema.read(file)
end

--- Whether `dir` carries the legacy form, and so cannot be listed by reading it.
--- @param dir string
--- @return boolean
function Manifest.is_legacy(dir)
  if Host.fs.is_file(dir .. "/package.lua") then return false end
  return Host.fs.is_file(dir .. "/manifest.lua") or Host.fs.is_file(dir .. "/init.lua")
end

--- The manifest of the package rooted at `plugin_path`, or the legacy report.
--- @param plugin_path string
--- @return PackageMeta|nil meta
--- @return string|nil err
function Manifest.load(plugin_path)
  local spec, perr = Manifest.read_package(plugin_path)
  if perr then return nil, perr end
  if not spec then
    return {
      name = Host.fs.basename(plugin_path),
      type = "plugin",
      dependencies = {},
      entry = "init.lua",
      _legacy = true,
    }
  end

  return {
    name = spec.name,
    version = spec.version,
    description = spec.description,
    type = spec.kind,
    dependencies = Schema.dependency_names(spec),
    entry = Schema.entry_of(spec),
    -- Carried through so a declared category reaches the panel. The catalog falls
    -- back to the domain directory for a package that states none, so a package
    -- that declares one keeps the grouping it has always had.
    category = spec.category,
    spec = spec,
    _package_file = plugin_path .. "/package.lua",
  }
end

function Manifest.validate(m)
  local errors = {}

  -- A bundle decides what a build carries; no package decides that about itself.
  -- The field is gone from the tree, and a package that still sets it is reading
  -- an older document and expecting a guarantee it no longer gets.
  if m.essential ~= nil then
    errors[#errors + 1] = "essential is not a manifest field: name a bundle " ..
      "in bundles/<name>.lua instead"
  end

  if type(m.name) ~= "string" or m.name == "" then
    errors[#errors + 1] = "name is required"
  end
  if type(m.version) ~= "string" or m.version == "" then
    if not m._legacy then errors[#errors + 1] = "version is required" end
  end
  if type(m.description) ~= "string" then
    if not m._legacy then errors[#errors + 1] = "description is required" end
  end

  -- `category` groups a package in the panel and decides where a build puts it.
  -- The inline form has always carried it and is held to it; a package.lua may
  -- state it and falls back to the catalog's own grouping, which is the domain
  -- directory it sits in.
  if type(m.category) ~= "string" or m.category == "" then
    if m.spec then
      m.category = "unknown"
    elseif not m._legacy then
      errors[#errors + 1] = "category is required"
    end
  end

  if m.type ~= nil and m.type ~= "plugin" and m.type ~= "theme" then
    errors[#errors + 1] = "type must be 'plugin' or 'theme'"
  end
  if m.dependencies ~= nil and type(m.dependencies) ~= "table" then
    errors[#errors + 1] = "dependencies must be a table"
  end

  return #errors == 0, errors
end

return Manifest