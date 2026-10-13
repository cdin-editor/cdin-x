-- Treeview keys in vim mode, and the Tree menu section, backed by the treeview
-- package.
--
-- A `with` entry on `treeview`. Also registers a `cwd_changed` listener, because
-- the tree caches absolute paths and has to be told when `:cd` moves the working
-- directory. That is a third thing this entry owns, and it is the reason the
-- listener is subscribed and unsubscribed by identity rather than by name.
local command  = require "core.input.command"
local core     = require "core"
local registry = require "vim.registry"

local MENU_SECTION_ID = "treeview"
local CONTEXT_ID      = "treeview"
local CONTEXT_ORDER   = 200
local MENU_ORDER      = 20

local TREE_ENTRIES = {
  { key = "e", label = "Focus Tree", info = "treeview",
    cmd = "treeview:focus" },
  { key = "R", label = "Refresh Tree", info = "re-scan",
    cmd = "treeview:focus-and-refresh" },
  { key = "h", label = "Toggle Hidden", info = "hidden files",
    cmd = "treeview:toggle-hidden" },
  { key = ".", label = "Reveal", info = "focus current item",
    cmd = "treeview:focus-and-refresh" },
}

--- Where the tree's cursor is, as { dir, file, is_dir, label }. nil when
--- no tree view is open or it has no cursor item, which lets the menu fall
--- back to its own context.
local function context()
  local view = require("treeview.api").get_view()
  if not view or not view.cursor_item then return nil end
  local item = view.cursor_item
  local path = item.abs_filename or item.filename or "."
  if item.type == "dir" then
    return { dir = path, file = nil, is_dir = true, label = item.name or path }
  end
  local dir = path:match("^(.*)[\\/][^\\/]+$") or "."
  return { dir = dir, file = path, is_dir = false, label = item.name or path }
end

--- The tree caches absolute paths, so it has to be told when :cd moves the
--- working directory. Registered as a function value so unregister can
--- hand back exactly what was subscribed.
local function on_cwd_changed()
  command.perform("treeview:refresh")
end

--- The menu registry, or nil when the `menu` package is not installed.
local function menu_registry()
  local ok, menu = pcall(require, "menu.impl")
  if not ok or type(menu) ~= "table" then return nil end
  if not (menu.menus and menu.menus["vim.main"]) then return nil end
  return menu
end

local M = {}

local commands = nil
local menu = nil
local cwd_subscribed = false

local enabled = false

function M.enable()
  if enabled then return end
  enabled = true

  commands = require "vim.with.treeview.commands"
  commands.register()
  registry.on("cwd_changed", on_cwd_changed)
  cwd_subscribed = true

  local m = menu_registry()
  if m then
    menu = m
    menu.set_context_provider("vim.main", CONTEXT_ID, context, CONTEXT_ORDER)
    menu.extend("vim.main", MENU_SECTION_ID, function()
      local entries = {}
      for _, e in ipairs(TREE_ENTRIES) do
        local cmd = e.cmd
        entries[#entries + 1] = {
          key = e.key, label = e.label, info = e.info,
          action = function() command.perform(cmd) end,
        }
      end
      return { header = "Tree", entries = entries }
    end, MENU_ORDER)
  end

  core.log("Vim — Treeview integration loaded")
end

function M.disable()
  if not enabled then return end
  enabled = false
  -- The menu providers first: they hold closures over `context`, which reads the
  -- treeview module. Taking the commands down first would leave them pointed at
  -- a package that is on its way out.
  if menu then
    menu.remove_extension("vim.main", MENU_SECTION_ID)
    menu.remove_context_provider("vim.main", CONTEXT_ID)
    menu = nil
  end
  if cwd_subscribed then registry.off("cwd_changed", on_cwd_changed); cwd_subscribed = false end
  if commands then commands.unregister(); commands = nil end
end

return M