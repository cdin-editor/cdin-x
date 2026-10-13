-- Normal-mode key binding for the vim menu: "m".
--
-- "m" was hardcoded in X/core/vim/vimode.lua as
-- `if k == "m" then vimapi.call("menu") end`. It belongs here: the menu is
-- a separate capability, and vim core should not know that pressing "m"
-- means "open a menu".
--
-- "m" works with no document open too, which is the whole point of
-- binding it through the registry — vim mode offers plugin keys on the
-- home screen, where there is nothing for its own keys to do.
local registry = require "vim.registry"

local M = {}

local KEYS = {
  m = function()
    return require("core.input.command").perform("vim-fmenu:open")
  end,
}

function M.register()
  registry.register_key(KEYS)
end

function M.unregister()
  registry.unregister_key(KEYS)
end

return M
