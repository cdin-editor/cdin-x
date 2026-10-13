-- Git commands in vim mode, and the Git menu section, backed by the git package.
--
-- A `with` entry on `git`: the commands need git's recipes and vim's shell escape,
-- and either package is usable alone.
local SECTION_ID = "git"
local MENU_ORDER = 30

--- The menu registry, or nil when the `menu` package is not installed.
---
--- Also checks that `vim.main` is defined, which it always is by now -- vim's init
--- registers it before any with-entry is offered -- but the check is kept because
--- `menu.extend` *asserts*, and an assertion during load takes the whole extension
--- down rather than skipping one menu.
local function menu_registry()
  local ok, menu = pcall(require, "menu.impl")
  if not ok or type(menu) ~= "table" then return nil end
  if not (menu.menus and menu.menus["vim.main"]) then return nil end
  return menu
end

local M = {}

local commands = nil
local menu = nil

local enabled = false

function M.enable()
  if enabled then return end
  enabled = true

  commands = require "vim.with.git.commands"
  commands.register()

  local m = menu_registry()
  if m then
    menu = m
    menu.extend("vim.main", SECTION_ID, function()
      return require("vim.with.git.menu").section()
    end, MENU_ORDER)
  end
end

function M.disable()
  if not enabled then return end
  enabled = false
  if menu then menu.remove_extension("vim.main", SECTION_ID); menu = nil end
  if commands then commands.unregister(); commands = nil end
end

return M