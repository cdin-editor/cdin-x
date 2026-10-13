-- Reads and validates package.lua files in a sandbox.
--
-- A package.lua is data, from a repository that may belong to anyone. It is
-- compiled with an empty environment, so `require`, `io`, `os` and every other
-- global is simply absent; there is nothing for it to reach. It is then run
-- under an instruction-count limit, so a file that never returns is stopped
-- rather than hanging the editor. The result is walked before it is believed:
-- a manifest that is not a table, or that holds a function, a userdata, a
-- thread, a cycle or a metatable, is refused with the reason.
--
-- This module is the schema for every external structure cdin-x reads:
-- package.lua now, and packages.lua, cdin-x.lock and state.lua later. It
-- depends on nothing but the standard library, so the kernel and the scripts
-- under scripts/ validate through exactly the same code.
local Schema = {}

--- The largest package.lua that will be compiled. A manifest is a table of
--- short strings; past this it is either a mistake or an attempt to make the
--- editor spend time on it.
Schema.MAX_MANIFEST_BYTES = 64 * 1024

--- How many instructions a package.lua may run. The value only has to be far
--- above "builds a table with a few dozen entries" and far below "spins".
Schema.MAX_INSTRUCTIONS = 100000

--- The entry point a package loads when it does not say.
Schema.DEFAULT_ENTRY = "init.lua"

local KINDS = { plugin = true, lang = true, theme = true, bundle = true, glue = true }

--- What each field must be. One table, so "what does package.lua look like"
--- has one answer: a new field is added here and nowhere else.
---
---   string   a non-empty string
---   number   a number
---   rangemap { <package name> = "<version range>" }
---   pathmap  { <key> = "<a file inside the package>" }
---   withmap  { <package name> = "<a file>", or = { "<a file>", ... } }
---             The key is always the *package* on the other side, never a name for
---             the seam -- that is what lets validate check what it reaches. Two
---             seams can wait on one package, hence the list form.
---   tables   { <key> = { ... } }
---   listmap  { <key> = { "<string>", ... } }
---   list     { "<string>", ... }
local FIELD_KINDS = {
  name = "string",
  kind = "string",
  version = "string",
  description = "string",
  entry = "string",
  license = "string",
  repository = "string",
  category = "string",
  min_cdin_version = "string",
  max_cdin_version = "string",
  depends = "rangemap",
  with = "withmap",
  features = "tables",
  options = "tables",
  needs = "listmap",
  activation = "listmap",
  authors = "list",
  tags = "list",
  os = "list",
  files = "list",
  optional_dependencies = "list",
  -- `ignore` pairs with `files` for the selection a package installs, and the
  -- last two are what a bundle names. Phase 7 gives `ignore` its effect; until
  -- then it is parsed and not applied.
  ignore = "list",
  includes = "list",
  optional = "list",
}

--- The fields a package may not leave out.
local STRING_REQUIRED = { "name", "kind", "version", "description" }

--- Fields that were removed and are now refused by name, because a package
--- that still sets one is reading an older document and expecting a guarantee it
--- no longer gets.
local REMOVED_FIELDS = {
  essential = "a bundle in bundles/ decides what a build carries, not the package",
}

--- @alias PackageSpec table
--- @field name string
--- @field kind string
--- @field version string
--- @field description string
--- @field entry string|nil
--- @field category string|nil
--- @field min_cdin_version string|nil
--- @field max_cdin_version string|nil
--- @field depends table<string, string>|nil
--- @field optional_dependencies string[]|nil
--- @field with table<string, string>|nil
--- @field features table<string, table>|nil
--- @field options table<string, table>|nil
--- @field activation table|nil
--- @field needs table|nil
--- @field os string[]|nil
--- @field files string[]|nil
--- @field ignore string[]|nil
--- @field includes string[]|nil
--- @field optional string[]|nil
--- @field authors string[]|nil
--- @field tags string[]|nil
--- @field license string|nil
--- @field repository string|nil

-- ── pure-data checks ──────────────────────────────────────────────────────

--- Why `value` is not plain data, or nil when it is.
--- A table with a metatable is refused: it is the one way a value read out of a
--- sandboxed file can still behave like code.
--- @param value any
--- @return string|nil
local function not_data(value)
  local t = type(value)
  if t == "function" then return "a function" end
  if t == "userdata" then return "a userdata value" end
  if t == "thread" then return "a coroutine" end
  if t ~= "table" then return nil end
  if getmetatable(value) ~= nil then return "a table with a metatable" end
  return nil
end

--- Every value in the tree, depth first, refusing anything that is not data.
--- @param value any
--- @param path string  where we are, for the message
--- @param errors string[]
--- @param seen table
local function walk(value, path, errors, seen)
  local why = not_data(value)
  if why then
    errors[#errors + 1] = path .. " is " .. why
    return
  end
  if type(value) ~= "table" then return end
  if seen[value] then
    errors[#errors + 1] = path .. " is part of a cycle"
    return
  end
  seen[value] = true
  for key, item in pairs(value) do
    -- A number is an array index; anything else has to be a name, because a
    -- table key that is a function or a table cannot have come from a file.
    local key_type = type(key)
    if key_type == "number" then
      walk(item, path .. "[" .. tostring(key) .. "]", errors, seen)
    elseif key_type == "string" then
      walk(item, path .. "." .. key, errors, seen)
    else
      errors[#errors + 1] = path .. " has a " .. key_type .. " key"
    end
  end
  seen[value] = nil
end

-- ── field checks ─────────────────────────────────────────────────────────

--- `1.2.3`, with an optional pre-release and build suffix.
local SEMVER = "^%d+%.%d+%.%d+[-+%.%w]*$"

--- Lower-case kebab-case, length checked separately: Lua patterns have `*`,
--- `+`, `-` and `?`, and no `{n,m}`.
local NAME = "^[a-z][a-z0-9%-]*$"

--- The longest a name may be, so it fits a module name and a path segment.
local NAME_MAX = 32

--- Names a package may not take, because `require` uses the name and something
--- under it already answers to that name.
---
--- The host modules are the dangerous half: a package called `fs` would have its
--- own `api.lua` found by `require "fs.api"` while every `require "fs"` in the
--- editor still got the host's, so a typo would resolve to neither. The Lua
--- standard library is the other half, for the same reason.
local RESERVED_NAMES = {
  core = true, cdinx = true, fs = true, path = true, system = true,
  renderer = true, table = true, string = true, math = true, os = true,
  io = true, utf8 = true, coroutine = true, debug = true, package = true,
}

--- A relative file inside the package: no separator, no climb.
local ENTRY = "^[%w_%-%.]+%.lua$"

local function is_list_of_strings(value)
  if type(value) ~= "table" then return false end
  local n = 0
  for key, item in pairs(value) do
    if type(key) ~= "number" or type(item) ~= "string" then return false end
    n = n + 1
  end
  return n == #value
end

local function is_range_map(value)
  for key, range in pairs(value) do
    if type(key) ~= "string" or type(range) ~= "string" then return false end
  end
  return true
end

--- Whether a `with` table maps each partner to one path or to several.
---
--- Several, because two seams can legitimately wait on the same package: vim has
--- one for the tab bindings and another for the window bindings, and both need
--- `workspace`. A plain path map can only say one, so the second would be
--- unreachable -- and keying by seam name instead would leave the partner
--- unstated, which is the one thing worth checking. So the key stays the partner
--- and the value is a path, or a list of them.
--- @param value any
--- @return boolean
local function is_with_map(value)
  for key, rel in pairs(value) do
    if type(key) ~= "string" then return false end
    if type(rel) == "string" then
      if rel == "" then return false end
    elseif type(rel) == "table" then
      -- A list of paths, and a non-empty one: `workspace = { }` declares a seam
      -- that does not exist, which is a typo rather than an intent.
      if not is_list_of_strings(rel) or #rel == 0 then return false end
    else
      return false
    end
  end
  return true
end

local function is_path_map(value)
  for key, rel in pairs(value) do
    if type(key) ~= "string" or type(rel) ~= "string" then return false end
  end
  return true
end

--- Why `value` does not match `kind`, or nil when it does.
--- @param kind string
--- @param value any
--- @return string|nil
local function wrong_kind(kind, value)
  if kind == "string" then
    if type(value) ~= "string" or value == "" then return "a non-empty string" end
  elseif kind == "number" then
    if type(value) ~= "number" then return "a number" end
  elseif kind == "list" then
    if not is_list_of_strings(value) then return "an array of strings" end
  elseif kind == "rangemap" then
    if type(value) ~= "table" or not is_range_map(value) then
      return "a package name mapped to a version range"
    end
  elseif kind == "pathmap" then
    if type(value) ~= "table" or not is_path_map(value) then
      return "a key mapped to a file inside the package"
    end
  elseif kind == "withmap" then
    if type(value) ~= "table" or not is_with_map(value) then
      return "a package name mapped to a file inside the package, or a list of them"
    end
  elseif kind == "tables" then
    if type(value) ~= "table" then return "a table" end
    for key, item in pairs(value) do
      if type(key) ~= "string" or type(item) ~= "table" then
        return "a key mapped to a table"
      end
    end
  elseif kind == "listmap" then
    if type(value) ~= "table" then return "a table" end
    for key, item in pairs(value) do
      if type(key) ~= "string" or not is_list_of_strings(item) then
        return "a key mapped to an array of strings"
      end
    end
  end
  return nil
end

--- @param spec PackageSpec
--- @param errors string[]
local function check_fields(spec, errors)
  for field, kind in pairs(FIELD_KINDS) do
    if spec[field] ~= nil then
      local wrong = wrong_kind(kind, spec[field])
      if wrong then
        errors[#errors + 1] = field .. " must be " .. wrong
      end
    end
  end

  for _, field in ipairs(STRING_REQUIRED) do
    if type(spec[field]) ~= "string" or spec[field] == "" then
      errors[#errors + 1] = field .. " is required and must be a string"
    end
  end

  for field, why in pairs(REMOVED_FIELDS) do
    if spec[field] ~= nil then
      errors[#errors + 1] = field .. " is not a package.lua field: " .. why
    end
  end

  if type(spec.name) == "string" then
    if not spec.name:match(NAME) then
      errors[#errors + 1] = string.format(
        "name %q must be lower-case kebab-case: a letter, then letters, digits or dashes",
        tostring(spec.name))
    elseif RESERVED_NAMES[spec.name] then
      errors[#errors + 1] = string.format(
        "name %q is already a module the host or Lua provides; pick another",
        spec.name)
    elseif #spec.name > NAME_MAX then
      errors[#errors + 1] = string.format(
        "name %q is %d characters; the limit is %d", spec.name, #spec.name, NAME_MAX)
    end
  end
  if type(spec.kind) == "string" and not KINDS[spec.kind] then
    local list = {}
    for kind in pairs(KINDS) do list[#list + 1] = kind end
    table.sort(list)
    errors[#errors + 1] = string.format("kind %q must be one of %s",
      spec.kind, table.concat(list, ", "))
  end
  if type(spec.version) == "string" and not spec.version:match(SEMVER) then
    errors[#errors + 1] = string.format("version %q is not a semantic version",
      spec.version)
  end
  if type(spec.entry) == "string" and not spec.entry:match(ENTRY) then
    errors[#errors + 1] = "entry must be one file inside the package, e.g. init.lua"
  end

  -- The prefixes that make a name say what it is.
  if type(spec.name) == "string" and type(spec.kind) == "string" then
    if spec.kind == "lang" and not spec.name:match("^lang%-") then
      errors[#errors + 1] = "a lang package's name starts with lang-, e.g. lang-python"
    elseif spec.kind == "theme" and not spec.name:match("^theme%-") then
      errors[#errors + 1] = "a theme package's name starts with theme-, e.g. theme-nord"
    elseif spec.kind ~= "lang" and spec.kind ~= "theme"
      and (spec.name:match("^lang%-") or spec.name:match("^theme%-")) then
      errors[#errors + 1] = string.format(
        "name %q carries a %s- prefix, which is reserved", spec.name, spec.kind)
    end
  end
end

--- Checks a table against the package schema.
--- @param spec any
--- @return boolean ok
--- @return string[] errors
function Schema.validate(spec)
  local errors = {}
  if type(spec) ~= "table" then
    return false, { "package.lua must return a table" }
  end
  walk(spec, "package.lua", errors, {})
  if #errors > 0 then return false, errors end

  check_fields(spec, errors)
  if #errors > 0 then return false, errors end
  return true, errors
end

-- ── reading ───────────────────────────────────────────────────────────────

local function read_source(path)
  local handle = io.open(path, "rb")
  if not handle then return nil, "cannot open " .. tostring(path) end
  local text = handle:read("*a")
  handle:close()
  if type(text) ~= "string" then
    return nil, "cannot read " .. tostring(path)
  end
  if #text > Schema.MAX_MANIFEST_BYTES then
    return nil, string.format("%s is %d bytes; the limit is %d",
      path, #text, Schema.MAX_MANIFEST_BYTES)
  end
  return text
end

--- Compiles `text` in an empty environment and runs it under a step limit.
--- @param text string
--- @param chunk_name string
--- @return any|nil value
--- @return string|nil err
local function run_sandboxed(text, chunk_name)
  -- Text mode only: a binary chunk would be executed as code, and the point of
  -- the empty environment is that there is nothing in it to reach for.
  local chunk, cerr = load(text, chunk_name, "t", {})
  if not chunk then return nil, tostring(cerr) end

  local spent = false
  debug.sethook(function() spent = true; error("step limit", 0) end, "",
    Schema.MAX_INSTRUCTIONS)

  local ok, value = pcall(chunk)

  debug.sethook()

  if not ok then
    if spent then
      return nil, string.format(
        "package.lua ran more than %d instructions; refusing it",
        Schema.MAX_INSTRUCTIONS)
    end
    return nil, "package.lua raised: " .. tostring(value)
  end
  return value
end

--- Reads one package.lua and returns it once it has been validated.
--- @param path string  the file to read
--- @return PackageSpec|nil spec
--- @return string|nil err
function Schema.read(path)
  local text, rerr = read_source(path)
  if not text then return nil, rerr end

  local value, eerr = run_sandboxed(text, "=package.lua")
  if value == nil and eerr then return nil, eerr end

  local ok, errors = Schema.validate(value)
  if not ok then
    return nil, string.format("%s:\n  - %s", path, table.concat(errors, "\n  - "))
  end
  return value
end

--- Reads one file of Lua data and returns whatever it produced, unvalidated.
---
--- The same sandbox as `read`, without the package schema. Two callers need
--- exactly that: a `theme.lua`, which is a table of colours and nothing else, and
--- a registry's catalog index, which is a map of maps. Neither is a package, and
--- validating either as one would demand a name, a version and a description from
--- a file that has none of those and should not.
---
--- Nothing here validates, so the caller must: this reads, the caller decides.
--- @param path string  the file to read
--- @param label string|nil  what to call the file in an error message
--- @return table|nil value
--- @return string|nil err
function Schema.read_data(path, label)
  local text, rerr = read_source(path)
  if not text then return nil, rerr end

  local value, eerr = run_sandboxed(text, "=" .. (label or path))
  if value == nil and eerr then return nil, eerr end
  if type(value) ~= "table" then
    return nil, string.format("%s must return a table, got %s", path, type(value))
  end
  return value
end
--- Runs a chunk in the sandbox and hands back whatever it produced, unvalidated.
---
--- For a file that is *not* a package manifest but wants the same guarantees: no
--- `require`, no `io`, no `os`, no threads, no metatables, and a bounded budget.
--- A user's `packages.lua` is that -- it describes their choices, and validating it
--- against a package spec would demand a name, a version and an author from a file
--- that has none of those and should not.
--- @param text string
--- @param label string|nil  what to call the file in an error message
--- @return any|nil value
--- @return string|nil err
function Schema.sandboxed(text, label)
  if type(text) ~= "string" then
    return nil, (label or "file") .. " is not text"
  end
  return run_sandboxed(text, "=" .. (label or "file"))
end

--- Reads a manifest already in hand, rather than from a path.
---
--- Split out of `read` because there are two callers with different endings: a
--- package's `package.lua`, which is on disk, and a user's `packages.lua`, which
--- the panel may have just written and which reports under a name of its own. The
--- sandbox and the validation are identical, which is the point -- two readers for
--- two shapes of the same data is how they drift apart.
--- @param text string
--- @param label string|nil  what to call the file in an error message
--- @return PackageSpec|nil spec
--- @return string|nil err
function Schema.read_text(text, label)
  if type(text) ~= "string" then
    return nil, (label or "manifest") .. " is not text"
  end
  local value, eerr = run_sandboxed(text, "=" .. (label or "package.lua"))
  if value == nil and eerr then return nil, eerr end
  local ok, errors = Schema.validate(value)
  if not ok then
    return nil, string.format("%s:\n  - %s", label or "manifest", table.concat(errors, "\n  - "))
  end
  return value
end

--- The entry point of a package: its `entry`, or the default.
--- @param spec PackageSpec
--- @return string
function Schema.entry_of(spec)
  return spec.entry or Schema.DEFAULT_ENTRY
end

--- The fields `spec` sets that this schema does not name, sorted.
---
--- Not an error: a package written against a newer schema still loads, because
--- refusing it would make adopting one a two-step edit. The caller decides what
--- to do with the answer — the validators warn, because a typo'd field is
--- otherwise silent forever and reads to its author as "the kernel ignored me".
--- @param spec PackageSpec
--- @return string[]
function Schema.unknown_fields(spec)
  local out = {}
  for field in pairs(spec) do
    if FIELD_KINDS[field] == nil then out[#out + 1] = field end
  end
  table.sort(out)
  return out
end

--- The dependency names of a package, sorted. Order is observable in load
--- order and in a lock file, so it is never left to `pairs`.
--- @param spec PackageSpec
--- @return string[]
function Schema.dependency_names(spec)
  local out = {}
  for name in pairs(spec.depends or {}) do out[#out + 1] = name end
  table.sort(out)
  return out
end

return Schema