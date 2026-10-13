local Host   = require "cdinx.host"
local Schema = require "cdinx.schema"
local Util   = require "cdinx.manager.util"

local State = {}

function State.empty()
  return { disabled = {}, lock = {} }
end

function State.load(config)
  local file = config.state_file
  if not Host.fs.is_file(file) then
    return State.empty()
  end

  -- Read through the sandbox rather than dofile()d. The file holds no code --
  -- `save` emits a literal table and nothing else -- but it lives in a directory
  -- the user can write to, and running it to find out which packages are
  -- disabled means running it with the editor's privileges for no benefit.
  local state, err = Schema.read_data(file, "extensions.lua")
  if type(state) ~= "table" then
    Host.core.error("cdin-x: %s is not readable; starting with nothing disabled", err)
    return State.empty()
  end

  return {
    disabled = type(state.disabled) == "table" and state.disabled or {},
    lock     = type(state.lock) == "table" and state.lock or {},
  }
end

function State.save(config, state)
  Host.fs.mkdir(Util.parent_dir(config.state_file))
  local fp, err = io.open(config.state_file, "w")
  if not fp then return false, err end

  fp:write("return {\n  disabled = {\n")
  local names = {}
  for name, disabled in pairs(state.disabled or {}) do
    if disabled then names[#names + 1] = name end
  end
  table.sort(names)
  for _, name in ipairs(names) do
    fp:write("    [", string.format("%q", name), "] = true,\n")
  end
  fp:write("  },\n")

  -- The lock is the reproducibility record: source, ref, rev, subdir and the
  -- selected file count and byte total, so `restore` reinstalls exactly the
  -- locked commits. A commit hash authenticates the tree, so no separate archive
  -- hash exists. Only string and number fields are written, sorted, so the file
  -- is deterministic and stays readable -- it is still data, still sandboxed on
  -- the way back in, and still never executed.
  fp:write("  lock = {\n")
  local lock_names = {}
  for name in pairs(state.lock or {}) do lock_names[#lock_names + 1] = name end
  table.sort(lock_names)
  local lock_fields = { "version", "installed_at", "source", "url", "ref", "rev",
    "subdir", "files", "bytes", "prev_rev" }
  for _, name in ipairs(lock_names) do
    local entry = state.lock[name]
    local parts = {}
    for _, field in ipairs(lock_fields) do
      local value = entry[field]
      if type(value) == "string" and value ~= "" then
        parts[#parts + 1] = field .. " = " .. string.format("%q", value)
      elseif type(value) == "number" then
        parts[#parts + 1] = field .. " = " .. tostring(math.floor(value))
      end
    end
    fp:write("    [", string.format("%q", name), "] = { ",
      table.concat(parts, ", "), " },\n")
  end
  fp:write("  },\n}\n")
  fp:close()
  return true
end

return State
