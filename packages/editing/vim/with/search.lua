-- Vim's search keys and its Search menu section, backed by the search package.
--
-- The menu part is guarded rather than required. The old integration declared a
-- dependency on the `menu` package, which meant a user who installed the search
-- bindings without menus got nothing at all -- the keys worked but the whole
-- extension was refused. Here the keys always go up and the menu section is
-- skipped, which is what the code was already written to tolerate.
--
-- The menu *definition* it extends (`vim.main`) is registered by vim's own init,
-- which has always run by the time a `with` entry is offered.
local command = require "core.input.command"

-- Menu entry -> cdin command name. Declared as data rather than as closures so
-- the menu reads as a menu, and so the command names live in exactly one place.
local ENTRIES = {
  { key = "/", label = "Find in Document", info = "find-replace",
    cmd = "find-replace:find" },
  { key = "n", label = "Repeat Find", info = "next match",
    cmd = "find-replace:repeat-find" },
  { key = "p", label = "Previous Find", info = "previous match",
    cmd = "find-replace:previous-find" },
  { key = "P", label = "Find in Project", info = "ripgrep/find",
    cmd = "project-search:find" },
  { key = "F", label = "Project Pattern", info = "pattern",
    cmd = "project-search:find-pattern" },
  { key = "f", label = "Project Fuzzy", info = "fuzzy",
    cmd = "project-search:fuzzy-find" },
}

local SECTION_ID = "search"
local MENU_ORDER = 40

--- The menu registry, or nil when the `menu` package is not installed.
local function menu_registry()
  local ok, menu = pcall(require, "menu.impl")
  if not ok or type(menu) ~= "table" then return nil end
  if not (menu.menus and menu.menus["vim.main"]) then return nil end
  return menu
end

local M = {}

local keymap = nil
local menu = nil

local enabled = false

function M.enable()
  if enabled then return end
  enabled = true

  keymap = require "vim.with.search.keymap"
  keymap.register()

  local m = menu_registry()
  if m then
    menu = m
    menu.extend("vim.main", SECTION_ID, function()
      local entries = {}
      for _, e in ipairs(ENTRIES) do
        local cmd = e.cmd
        entries[#entries + 1] = {
          key = e.key, label = e.label, info = e.info,
          action = function() command.perform(cmd) end,
        }
      end
      return { header = "Search", entries = entries }
    end, MENU_ORDER)
  end
end

function M.disable()
  if not enabled then return end
  enabled = false
  if menu then menu.remove_extension("vim.main", SECTION_ID); menu = nil end
  if keymap then keymap.unregister(); keymap = nil end
end

return M