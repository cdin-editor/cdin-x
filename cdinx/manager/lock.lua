-- `cdin-x.lock`: what each installed package resolved to.
--
-- The lockfile in the npm sense, with one property the usual ones do not need:
-- it is never the only copy of anything. `<data>/extensions.lua` is what the
-- editor believes is installed, and the store holds the files; this file is the
-- reviewable projection of both, kept in the user's own config directory beside
-- `packages.lua` so it can be committed and so a second machine reproduces the
-- same tree. A lock file that is the sole authority is a lock file that can lose
-- data, so an unreadable one is rebuilt from the state file rather than being
-- the end of the line.
--
-- It exists for two jobs:
--
--   restore   put every entry back at exactly the commit it names -- a wiped
--             store, a new machine, or a repository that moved on
--   update    one pinned answer to "which commit is this?" per package, so an
--             update can tell a moved ref from an unmoved one without asking
--
-- Read through the sandbox like every other untrusted file: this one is
-- hand-editable by design, and it is validated once on the way in rather than
-- trusted afterwards.
local Host   = require "cdinx.host"
local Util   = require "cdinx.manager.util"
local Schema = require "cdinx.schema"

local Lock = {}

-- Bumped when the shape changes. A file carrying a version this build does not
-- know is rebuilt from the state file rather than guessed at: a wrong guess
-- installs the wrong commits.
Lock.VERSION = 1

-- The fields one entry may carry. `source` decides which of the rest mean
-- anything: a `git` entry's `url` is its identity, a `registry` entry's is the
-- configured registry, and a `dir` entry has neither.
local ENTRY_FIELDS = {
  source = true, url = true, ref = true, rev = true, subdir = true,
  version = true, files = true, bytes = true,
}

local cache = nil

--- Where the lock file is.
--- @param config table
--- @return string
function Lock.path(config)
  return config.lock_file
end

--- An empty, valid lock file.
--- @return table
function Lock.empty()
  return { version = Lock.VERSION, packages = {} }
end

--- Why a loaded file is refused, or nil.
---
--- Every field is checked, because the whole point of the file is that a person
--- may edit it and a person may get a field wrong. An unknown field is refused
--- rather than ignored: it is either a typo or a field from a newer cdin-x, and
--- both deserve to be said out loud instead of quietly changing the install.
--- @param data any
--- @return string[] problems
function Lock.validate(data)
  local problems = {}
  if type(data) ~= "table" then
    return { "cdin-x.lock is not a table, got " .. type(data) }
  end
  if data.version ~= Lock.VERSION then
    problems[#problems + 1] = string.format(
      "cdin-x.lock says version %s; this build writes %d",
      tostring(data.version), Lock.VERSION)
  end
  if type(data.packages) ~= "table" then
    problems[#problems + 1] = "cdin-x.lock has no packages table"
    return problems
  end

  local names = {}
  for name in pairs(data.packages) do names[#names + 1] = name end
  table.sort(names, function(a, b) return tostring(a) < tostring(b) end)

  for _, name in ipairs(names) do
    local entry = data.packages[name]
    local label = "cdin-x.lock packages." .. tostring(name)
    if type(name) ~= "string" or name == "" then
      problems[#problems + 1] = "cdin-x.lock has a package name that is not a name"
    elseif type(entry) ~= "table" then
      problems[#problems + 1] = label .. " is not a table"
    else
      for field in pairs(entry) do
        if not ENTRY_FIELDS[field] then
          problems[#problems + 1] = string.format("%s: %q is not a field here",
            label, tostring(field))
        end
      end
      if type(entry.source) ~= "string" or entry.source == "" then
        problems[#problems + 1] = label .. " says no source"
      elseif entry.source == "git" then
        if type(entry.url) ~= "string" or entry.url == "" then
          problems[#problems + 1] = label .. " is a git source with no url"
        end
        if type(entry.rev) ~= "string" or entry.rev == "" then
          problems[#problems + 1] = label .. " is a git source with no commit"
        end
      elseif entry.source == "registry" then
        if type(entry.rev) ~= "string" or entry.rev == "" then
          problems[#problems + 1] = label .. " is a registry source with no commit"
        end
      elseif entry.source == "dir" then
        -- Nothing else to check: a dev directory is used in place, so there is no
        -- commit and no bytes. It is in the lock only so `cdin-x:clean` and the
        -- panel can say where it points.
      else
        problems[#problems + 1] = string.format("%s: source %q is git, registry or dir",
          label, tostring(entry.source))
      end
    end
  end
  return problems
end

--- Reads the lock file.
---
--- A missing file is not a problem: nothing installed yet is the normal state of
--- a fresh install. Anything else that is wrong comes back as nil plus the
--- reasons, and the caller rebuilds -- see `rebuild`.
--- @param config table
--- @return table|nil data
--- @return string[] problems
function Lock.load(config)
  if cache then return cache.data, cache.problems end

  local file = Lock.path(config)
  if type(file) ~= "string" or file == "" then
    local data = Lock.empty()
    cache = { data = data, problems = {} }
    return data, {}
  end

  local fp = io.open(file, "rb")
  if not fp then
    local data = Lock.empty()
    cache = { data = data, problems = {} }
    return data, {}
  end
  local text = fp:read("*a")
  fp:close()

  local value, err = Schema.sandboxed(text, "cdin-x.lock")
  if type(value) ~= "table" then
    local problems = { "cdin-x.lock is not readable: " .. tostring(err or "not a table") }
    cache = { data = nil, problems = problems }
    return nil, problems
  end

  local problems = Lock.validate(value)
  if #problems > 0 then
    cache = { data = nil, problems = problems }
    return nil, problems
  end
  cache = { data = value, problems = {} }
  return value, {}
end

--- Forgets the loaded copy, so the next `load` reads the file again.
---
--- The writer invalidates too; this exists for `doctor` and for anything that
--- replaced the file behind cdin-x's back.
function Lock.invalidate()
  cache = nil
end

--- Writes the lock file, atomically enough for a file a person edits.
---
--- A settings file that is truncated halfway through a write is worse than one
--- that was never written: the next read finds a file that parses and says half
--- the packages are missing. So the text goes to a sibling `.tmp` and is moved
--- over the target, which on every platform this runs on is the closest thing to
--- an atomic replace available without opening the target first.
--- @param config table
--- @param data table
--- @return boolean ok
--- @return string|nil err
function Lock.write(config, data)
  local file = Lock.path(config)
  if type(file) ~= "string" or file == "" then return false, "no lock_file" end

  local names = {}
  for name in pairs(data.packages or {}) do names[#names + 1] = name end
  table.sort(names)

  local out = {}
  out[#out + 1] = "-- cdin-x.lock -- written by cdin-x. Safe to keep and to edit."
  out[#out + 1] = "--"
  out[#out + 1] = "-- One entry per installed third-party package, with the commit it"
  out[#out + 1] = "-- resolved to. `cdin-x:restore` puts every one of them back at exactly"
  out[#out + 1] = "-- that commit."
  out[#out + 1] = "return {"
  out[#out + 1] = "  version = " .. tostring(Lock.VERSION) .. ","
  if type(data.registry) == "string" and data.registry ~= "" then
    out[#out + 1] = "  registry = " .. string.format("%q", data.registry) .. ","
  end
  out[#out + 1] = "  packages = {"
  for _, name in ipairs(names) do
    local entry = data.packages[name]
    out[#out + 1] = string.format("    [%q] = {", name)
    -- A fixed field order rather than `pairs`, so two writes of the same state
    -- produce the same bytes and a diff means something.
    for _, field in ipairs({ "source", "url", "ref", "rev", "subdir",
      "version", "files", "bytes" }) do
      local value = entry[field]
      if value ~= nil and value ~= "" then
        local rendered
        if type(value) == "number" then
          rendered = tostring(math.floor(value))
        else
          rendered = string.format("%q", tostring(value))
        end
        out[#out + 1] = string.format("      %s = %s,", field, rendered)
      end
    end
    out[#out + 1] = "    },"
  end
  out[#out + 1] = "  },"
  out[#out + 1] = "}"

  local tmp = file .. ".tmp"
  local fp = io.open(tmp, "wb")
  if not fp then return false, "cannot write " .. tmp end
  fp:write(table.concat(out, "\n"), "\n")
  fp:close()

  Host.fs.mkdir(Util.parent_dir(file))
  local moved, err = Host.fs.move(tmp, file)
  if not moved then
    if Host.fs.exists(tmp) then Host.fs.rm(tmp) end
    return false, "cannot replace " .. file .. ": " .. tostring(err)
  end
  cache = { data = data, problems = {} }
  return true
end

--- The lock entry a transport result describes.
---
--- One place, so install, update and restore cannot write three slightly
--- different shapes for the same package.
--- @param result table
--- @return table entry
function Lock.entry_for(result)
  return {
    source = result.source,
    url = result.url,
    ref = result.ref,
    rev = result.rev,
    subdir = result.subdir or "",
    version = result.version or "",
    files = result.files or 0,
    bytes = result.bytes or 0,
  }
end

--- Records what one install or update resolved to, and writes the file.
---
--- Only entries with a source are recorded. A first-party package's commit is
--- the registry's, not its own, and recording it per package would make twenty
--- lines that all say the same commit and change together -- noise that looks
--- like information. The registry's commit is recorded once, at the top.
--- @param config table
--- @param name string
--- @param result table
--- @return boolean ok
--- @return string|nil err
function Lock.record(config, name, result)
  if type(name) ~= "string" or name == "" then return false, "no name to record" end
  local data = Lock.load(config)
  if not data then
    -- An unreadable file is rebuilt from the editor's own record first, so this
    -- write repairs it instead of adding to it.
    data = Lock.empty()
  end
  data.packages = data.packages or {}
  if result.source == "registry" then
    data.registry = result.rev
    -- Still recorded per package: which subdir of the registry a package came
    -- from is that package's own fact, and `restore` needs it.
    data.packages[name] = Lock.entry_for(result)
  elseif result.source == "git" then
    data.packages[name] = Lock.entry_for(result)
  else
    data.packages[name] = nil
  end
  return Lock.write(config, data)
end

--- Drops one package from the lock, and writes the file.
--- @param config table
--- @param name string
--- @return boolean ok
--- @return string|nil err
function Lock.forget(config, name)
  local data = Lock.load(config) or Lock.empty()
  data.packages = data.packages or {}
  if data.packages[name] == nil then return true end
  data.packages[name] = nil
  return Lock.write(config, data)
end

--- Rebuilds the lock from the editor's own record of what it installed.
---
--- The state file is written by the editor on every change and holds the same
--- fields plus an install timestamp, so it is the authority this file is
--- projected from. Called when the lock is unreadable and by `doctor`.
--- @param config table
--- @param state_lock table<string, table>
--- @param registry_rev string|nil
--- @return table data
function Lock.rebuild(state_lock, registry_rev)
  local data = Lock.empty()
  if type(registry_rev) == "string" and registry_rev ~= "" then
    data.registry = registry_rev
  end
  if type(state_lock) ~= "table" then return data end
  local names = {}
  for name in pairs(state_lock) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local entry = state_lock[name]
    if type(entry) == "table" and
      (entry.source == "git" or entry.source == "registry") then
      data.packages[name] = {
        source = entry.source,
        url = entry.url,
        ref = entry.ref,
        rev = entry.rev,
        subdir = entry.subdir or "",
        version = entry.version or "",
        files = tonumber(entry.files) or 0,
        bytes = tonumber(entry.bytes) or 0,
      }
    end
  end
  return data
end

return Lock
