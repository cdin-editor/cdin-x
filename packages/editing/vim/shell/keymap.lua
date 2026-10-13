-- Key bindings for the shell capability.
--
-- Only the one command that is useless without a key gets one:
-- vim-shell:open-terminal has no other way to be reached, since it does
-- not open a buffer and so is not visible in the command palette. Every
-- other vim-shell:* command is reachable through :commands and stays
-- unbound, so no default stroke is taken away from the user for it.
--
-- ctrl+shift+; is unused by cdin's default keymap (see
-- the host's default keymap) and by every plugin here, so binding it
-- here cannot shadow an existing shortcut.
local keymap = require "core.input.keymap"

local M = {}

local MAP = {
  ["ctrl+shift+;"] = "vim-shell:open-terminal",
}

function M.register()
  keymap.add(MAP)
end

function M.unregister()
  keymap.remove(MAP)
end

return M
