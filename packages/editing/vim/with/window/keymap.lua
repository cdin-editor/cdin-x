-- Normal-mode key bindings owned by with/window.lua.
--
-- Two kinds:
--
--   Ctrl+W {c}  the wincmd prefix. Both the Ctrl+W prefix in normal mode
--                and the :wincmd {c} ex-command resolve the character
--                through registry.wmap_get(), which is why both are listed
--                from one table here. The table maps a character to a cdin
--                *command name*; neither vim core nor ex mode knows what
--                "v" or "o" mean.
--
--   Tab         move to the next pane, which is what Tab does in every
--                other editor. Declared through registry.register_key, so
--                vim mode offers it only after declining its own keys.
local registry = require "vim.registry"

local M = {}

-- character -> cdin command name, for Ctrl+W and :wincmd
local WMAP = {
  v = "window:vsplit",
  s = "window:split",
  o = "window:only",
  c = "window:close",
  n = "window:focus-next",
  p = "window:focus-prev",
  h = "window:focus-left",
  j = "window:focus-down",
  k = "window:focus-up",
  l = "window:focus-right",
  w = "window:focus-next",
  q = "window:close",
  ["="] = "window:equalize",
  [">"] = "window:increase-width",
  ["<"] = "window:decrease-width",
}

-- single normal-mode keys
local KEYS = {
  tab = function()
    return require("core.input.command").perform("window:focus-next")
  end,
}

function M.register()
  registry.register_wmap(WMAP)
  registry.register_key(KEYS)
end

function M.unregister()
  registry.unregister_key(KEYS)
  registry.unregister_wmap(WMAP)
end

return M
