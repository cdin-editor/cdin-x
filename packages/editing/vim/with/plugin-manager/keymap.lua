-- Normal-mode key binding for the CDIN extension manager: "M".
--
-- "M" was hardcoded in X/core/vim/vimode.lua. It belongs here: the
-- extension manager is a separate capability, and vim core must not know
-- that shift+m opens a plugin browser.
local registry = require "vim.registry"

local M = {}

local KEYS = {
  -- Reaches the extension manager's own toggle, which is the cdin
  -- registry UI rather than the vim menu.
  ["shift+m"] = function()
    return require("core.input.command").perform("pluginmanager:toggle")
  end,
}

function M.register()
  registry.register_key(KEYS)
end

function M.unregister()
  registry.unregister_key(KEYS)
end

return M
