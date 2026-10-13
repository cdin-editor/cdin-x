-- The one searcher that makes an installed package's modules resolvable.
--
-- Two spellings, and both are needed while the move out of X/ is in progress.
--
--   `X.<rest>`      an extension installed into the user's store. The store is
--                   keyed by the directory under X/ (`<extension_dir>/core/git`),
--                   so "X." has to be dropped and the rest turned into
--                   directories. This is not a package.path template, which is
--                   why it is a searcher.
--
--   `<pkg>[.<mod>]`  a package with a package.lua, whose identity is its name
--                   (architecture invariant 1). The bare form matters because it
--                   is what a bundle's `plugins/<name>.lua` shim requires, and
--                   that shim is the host's only way in.
--
-- It sits AFTER the standard Lua-file searcher, so whatever the build bundles
-- still wins and neither table only fills in what is not already there.
local Loader = {}

-- One state table shared across reloads of this module, so a reload (or two
-- copies of cdin-x) never stacks a second searcher.
local state = rawget(package, "cdinx_store")
if not state then
  state = { dir = nil, fn = nil, roots = {}, names = {}, entries = {} }
  package.cdinx_store = state
end

-- These are read through `state` on every call, never captured in locals. A local
-- would be bound to whatever table existed when this module loaded, and `ensure`
-- is called again every time a package loads and again every time one unloads --
-- so replacing the table there would leave the searcher reading a stale one and
-- every package would look absent.

local SUFFIXES = { ".lua", "/init.lua" }

--- Loads `path` and hands back the loader and its data, which is the path.
--- @param name string
--- @param path string
--- @return function|nil loader
--- @return string|nil path
--- @return string|nil err
local function load_from(name, path)
  local handle = io.open(path, "rb")
  if not handle then return nil, nil, "no file" end
  handle:close()

  -- This is the loader, not an inspection: the searcher exists to turn a module
  -- name into a chunk, and a chunk has to come from the file. The rule about not
  -- executing content applies to reading a manifest, a theme or an index -- things
  -- this file has to *understand*. A module the caller asked for is something it
  -- has already decided to run.
  local chunk, err = loadfile(path)
  if not chunk then
    error(string.format("error loading module '%s' from file '%s':\n\t%s",
      name, path, tostring(err)), 0)
  end
  return chunk, path
end

--- The message for a name the catalog knows but that is not loaded.
local function not_active(package_name)
  local active = {}
  for n in pairs(state.roots) do active[#active + 1] = n end
  table.sort(active)
  -- A different mistake from a typo, and it says so: the generic "module not
  -- found" sends the reader looking for a missing file rather than for a package
  -- they turned off.
  return string.format("\n\tcdin-x: package '%s' is not active (active: %s)",
    package_name, #active > 0 and table.concat(active, ", ") or "none")
end

--- A package's own entry point, loaded as a module.
local function load_entry(package_name)
  local root = state.roots[package_name]
  local rel = state.entries[package_name] or "init.lua"
  local base = root .. "/" .. (rel:gsub("%.lua$", ""))

  local chunk, path = load_from(package_name, base .. ".lua")
  if chunk then return chunk, path end
  chunk, path = load_from(package_name, base .. "/init.lua")
  if chunk then return chunk, path end
  -- Whatever the manifest named, if it named something with a directory in it.
  if rel ~= "init.lua" then
    chunk, path = load_from(package_name, root .. "/" .. rel)
    if chunk then return chunk, path end
  end

  return string.format("\n\tcdin-x: package '%s' has no entry point", package_name)
end

--- Turns the part of a module name after the package into a relative path,
--- refusing anything that leaves the package. A refusal is a message rather than
--- a miss: returning nil would let the next searcher try and report something
--- less true than what went wrong.
---
--- Dots become separators *first*, and the guard then walks the result. Reading
--- the raw name for ".." cannot work: `a..b` is not a traversal, it is a doubled
--- separator, and by the time it is `a//b` the two dots a caller meant to send
--- are indistinguishable from a harmless repeat. An empty segment is the same
--- shape of mistake, and reaches the filesystem as a path with a hole in it.
--- @param package_name string
--- @param rest string  everything after `<package>.`, dots not yet turned in
--- @return string|nil rel
--- @return string|nil err
local function module_relpath(package_name, rest)
  local shown = package_name .. "." .. rest

  if rest == "" then
    return nil, string.format(
      "\n\tcdin-x: package '%s' was required with an empty module name", package_name)
  end

  local rel = (rest:gsub("%.", "/"))

  -- A leading `..` is a climb out of the package, and saying so is more useful
  -- than reporting the empty segment `vim...module` turns into. It is the only
  -- shape that can still say `..` at all: two dots become two separators, so no
  -- other position in the name arrives as a `..` segment.
  if rest:sub(1, 2) == ".." then
    return nil, string.format("\n\tcdin-x: package '%s': %q climbs out of the package",
      package_name, shown)
  end

  for segment in rel:gmatch("[^/]+") do
    if segment == ".." then
      return nil, string.format("\n\tcdin-x: package '%s': %q climbs out of the package",
        package_name, shown)
    end
  end

  if rel:sub(1, 1) == "/" or rel:sub(-1) == "/" or rel:find("//", 1, true) then
    return nil, string.format("\n\tcdin-x: package '%s': %q has an empty path segment",
      package_name, shown)
  end

  return rel
end
local function search_package(name)
  local package_name, rest = name:match("^([%a][%w%-]*)%.(.+)$")

  if not package_name then
    -- No dot: either the whole name is a package, or it is not ours.
    if state.roots[name] then return load_entry(name) end
    if state.names[name] then return not_active(name) end
    return nil
  end

  local root = state.roots[package_name]
  if not root then
    if state.names[package_name] then return not_active(package_name) end
    return nil
  end

  local rel, refused = module_relpath(package_name, rest)
  if not rel then return refused end

  local notes = {}
  for _, suffix in ipairs(SUFFIXES) do
    local path = root .. "/" .. rel .. suffix
    local chunk, at = load_from(name, path)
    if chunk then return chunk, at end
    notes[#notes + 1] = "\n\tno file '" .. path .. "' (package '" .. package_name .. "')"
  end
  return table.concat(notes)
end

--- `X.<rest>`: a module in the user's extension store.
local function search_store(name)
  local rest = name:match("^X%.(.+)$")
  if not rest then return nil end

  local dir = state.dir
  if not dir or dir == "" then return nil end

  local rel = (rest:gsub("%.", "/"))
  for segment in rel:gmatch("[^/]+") do
    if segment == ".." then
      return string.format("\n\tcdin-x: %q climbs out of the extension store", name)
    end
  end

  local notes = {}
  for _, suffix in ipairs(SUFFIXES) do
    local path = dir .. "/" .. rel .. suffix
    local chunk, at = load_from(name, path)
    if chunk then return chunk, at end
    notes[#notes + 1] = "\n\tno file '" .. path .. "' (cdin-x extension store)"
  end
  return table.concat(notes)
end

--- The searcher handed to `package.searchers`.
---
--- Every branch hands back both values. A searcher that returns only the loader
--- leaves Lua with no loader data, `package.searchpath` reports no file for a
--- module that in fact loaded, and `package.loaded` holds the wrong shape.
--- @param name string
--- @return function|string|nil loader  a loader, an error message, or nil to let
---   the next searcher try
--- @return string|nil data  the file the loader came from
local function searcher(name)
  local loader, data = search_package(name)
  if loader then return loader, data end

  loader, data = search_store(name)
  if loader then return loader, data end

  return nil
end

--- Points the searcher at the packages that are active, and at the extension
--- store, and makes sure it is registered exactly once.
--- @param dir string|nil  the user's extension store
--- @param active table<string, string>|nil  package name -> its directory
--- @param known table<string, true>|nil  every package name in the catalog
--- @param entry_files table<string, string>|nil  package name -> its entry file
function Loader.ensure(dir, active, known, entry_files)
  if dir ~= nil then state.dir = dir end
  if active ~= nil then state.roots = active end
  if known ~= nil then state.names = known end
  if entry_files ~= nil then state.entries = entry_files end

  -- package.searchers, not the 5.1 spelling `package.loaders`. The host is Lua
  -- 5.4 and the 5.1 name does not exist there, so the fallback could only ever
  -- have been dead code -- and a fallback that cannot fire is a second thing to
  -- reason about for no benefit.
  local list = package.searchers
  if not list then return false end

  for _, fn in ipairs(list) do
    if fn == state.fn then return true end
  end

  state.fn = searcher
  -- After preload (1) and the Lua-file searcher (2): bundled modules win.
  table.insert(list, math.min(3, #list + 1), searcher)
  return true
end

--- Where a package's files are, for a package that has to name a path of its
--- own -- a theme root, a data directory, a file it hands to something else.
---
--- A package cannot work this out for itself: it may be a checkout, a site
--- install or a build's data tree, and those are three different paths, and
--- `config.site_dir` is only ever the second of them. Guessing from the
--- environment would work on the machine it was written on and nowhere else.
--- @param package_name string
--- @return string|nil dir
function Loader.dir_of(package_name)
  return state.roots[package_name]
end

--- Drops a package from the searcher's view and empties `package.loaded` of its
--- modules, so an unloaded package leaves nothing that a later load would reuse
--- half-built.
---
--- The bare name matters as much as the dotted ones. A package reached through its
--- bundle's `plugins/<name>.lua` shim is cached in `package.loaded` under its own
--- name, because that is what `require("<name>")` stores, so clearing only the
--- dotted prefix would leave the entry point behind and the next load would get
--- the module with its guard already set and its init already run.
--- @param package_name string
function Loader.forget(package_name)
  state.roots[package_name] = nil
  state.entries[package_name] = nil

  local prefix = package_name .. "."
  package.loaded[package_name] = nil
  for key in pairs(package.loaded) do
    if type(key) == "string" and key:sub(1, #prefix) == prefix then
      package.loaded[key] = nil
    end
  end
end

Loader.search = searcher
Loader.searcher = searcher
return Loader