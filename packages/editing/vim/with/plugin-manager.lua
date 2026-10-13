-- The normal-mode "M" key, and the menu section that points at the extension
-- panel.
--
-- This was a package of its own (`with/plugin-manager.lua`) that declared a dependency
-- on `with/menus.lua` purely so that `vim.main` would exist before it extended it. That
-- trap cannot be fallen into now: `vim/init.lua` defines `vim.main`, and init runs
-- before any with-entry is offered, so the menu is there every time.
--
-- The menu part is still guarded, because the `menu` package may be absent for
-- reasons `with` cannot see — `menu` being loaded is what made this entry offered
-- at all, but the assertion `menu.extend` makes is not worth betting an entire
-- entry on when a missing menu is a one-line skip. The key always works; only the
-- menu section is dropped.
local command = require "core.input.command"

local M = {}

local SECTION_ID = "extensions"
local MENU_ORDER = 80

local keymap = nil
local menu = nil

local enabled = false

function M.enable()
  if enabled then return end
  enabled = true

  keymap = require "vim.with.plugin-manager.keymap"
  keymap.register()

  local ok, registry = pcall(require, "menu.impl")
  if ok and type(registry) == "table" and registry.menus and registry.menus["vim.main"] then
    menu = registry
    menu.extend("vim.main", SECTION_ID, function()
      return {
        header = "CDIN-X",
        entries = {
          {
            key = "X", label = "Extensions", info = "install, remove, inspect",
            action = function() command.perform("cdin-x:menu") end,
          },
        },
      }
    end, MENU_ORDER)
  end
end

function M.disable()
  if not enabled then return end
  enabled = false
  -- The menu first: it holds a closure over the keymap module's table, and letting
  -- the keymap go first would leave the menu pointing at nothing.
  if menu then menu.remove_extension("vim.main", SECTION_ID); menu = nil end
  if keymap then keymap.unregister(); keymap = nil end
end

return M