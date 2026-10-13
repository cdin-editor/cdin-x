local keymap = require "core.input.keymap"

local M = {}

local MAP = {
  ["ctrl+alt+v"] = "vim:toggle-mode",
}

function M.register()
  keymap.add(MAP)
end

function M.unregister()
  keymap.remove(MAP)
end

return M
