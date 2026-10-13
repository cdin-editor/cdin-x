-- Backwards-compatible alias for vim.registry.
local registry = require "vim.registry"

local M = {}

function M.register(id, handler)
  assert(type(id) == "string" and type(handler) == "function",
         "vim api registration requires id + function")
  registry.register_action(id, handler)
end

function M.unregister(id)
  registry.unregister_action(id)
end

function M.call(id, ...)
  return registry.call_action(id, ...)
end

return M
