-- The one place a plugin asks to extend vim mode.
local M = {}

-- ── ex-commands (:tabnew, :split, …) ──────────────────────────────────────
local commands    = {}  -- name -> spec
local command_ids = {}  -- ordered list of specs, for :help and completion

function M.register_command(spec)
  assert(type(spec) == "table", "registry.register_command requires a table")
  assert(type(spec.names) == "table" and #spec.names > 0,
         "registry.register_command requires names")
  assert(type(spec.run) == "function",
         "registry.register_command requires run()")
  command_ids[#command_ids + 1] = spec
  for _, name in ipairs(spec.names) do
    commands[name] = spec
  end
  return spec
end

function M.unregister_command(spec)
  for _, name in ipairs(spec.names or {}) do
    if commands[name] == spec then commands[name] = nil end
  end
  for i, s in ipairs(command_ids) do
    if s == spec then table.remove(command_ids, i); break end
  end
end

function M.get_command(name)
  return commands[name]
end
function M.command_names()
  local out = {}
  for _, spec in ipairs(command_ids) do
    for _, name in ipairs(spec.names) do out[#out + 1] = name end
  end
  return out
end

function M.command_help()
  local out, seen = {}, {}
  for _, spec in ipairs(command_ids) do
    if spec.help and not seen[spec.help] then
      seen[spec.help] = true
      out[#out + 1] = spec.help
    end
  end
  return out
end

-- ── Ctrl+W / :wincmd character map ────────────────────────────────────────
local wmap = {}

function M.register_wmap(map)
  for k, v in pairs(map) do wmap[k] = v end
end

function M.unregister_wmap(map)
  for k, v in pairs(map) do
    if wmap[k] == v then wmap[k] = nil end
  end
end

function M.wmap_get(char)
  return wmap[char]
end

-- ── "g"-prefixed normal-mode sequences (gt, gT, …) ────────────────────────
local gmap = {}

function M.register_gmap(map)
  for k, v in pairs(map) do gmap[k] = v end
end

function M.unregister_gmap(map)
  for k, v in pairs(map) do
    if gmap[k] == v then gmap[k] = nil end
  end
end

function M.call_gmap(key, ...)
  local handler = gmap[key]
  if not handler then return false end
  return handler(...) ~= false
end

-- ── single normal-mode keys owned by other plugins ────────────────────────
local keys = {}

function M.register_key(map)
  for k, v in pairs(map) do keys[k] = v end
end

function M.unregister_key(map)
  for k, v in pairs(map) do
    if keys[k] == v then keys[k] = nil end
  end
end

function M.call_key(key, ...)
  local handler = keys[key]
  if not handler then return false end
  return handler(...) ~= false
end

-- ── single visual-mode keys owned by other plugins ────────────────────────
local visual_keys = {}

function M.register_visual_key(map)
  for k, v in pairs(map) do visual_keys[k] = v end
end

function M.unregister_visual_key(map)
  for k, v in pairs(map) do
    if visual_keys[k] == v then visual_keys[k] = nil end
  end
end

function M.call_visual_key(key, ...)
  local handler = visual_keys[key]
  if not handler then return false end
  return handler(...) ~= false
end

-- ── named actions ────────────────────────────────────────────────────────
local actions = {}

function M.register_action(id, handler)
  assert(type(id) == "string" and type(handler) == "function",
         "registry.register_action requires id + function")
  actions[id] = handler
end

function M.unregister_action(id)
  actions[id] = nil
end

function M.call_action(id, ...)
  local handler = actions[id]
  if not handler then return false end
  return handler(...)
end

-- ── events ────────────────────────────────────────────────────────────────
local listeners = {}

function M.on(event, fn)
  assert(type(event) == "string" and type(fn) == "function",
         "registry.on requires event name + function")
  listeners[event] = listeners[event] or {}
  listeners[event][fn] = true
end

function M.off(event, fn)
  local set = listeners[event]
  if set then set[fn] = nil end
end

function M.emit(event, ...)
  local set = listeners[event]
  if not set then return end
  for fn in pairs(set) do fn(...) end
end

return M
