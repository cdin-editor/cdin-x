-- Commands for the vim menu.
--
-- Both names are kept because "fmenu" is what vim calls this and readers
-- expect it; "vim-menu:open" is the namespaced form.
local command = require "core.input.command"

local M = {}

local MAP = {
  ["vim-menu:open"] = function() require("menu.impl").open("vim.main") end,
  ["vim-fmenu:open"] = function() require("menu.impl").open("vim.main") end,
}

local NAMES = { "vim-menu:open", "vim-fmenu:open" }

function M.register()
  command.add(nil, MAP, true)
end

function M.unregister()
  command.remove(NAMES)
end

return M
