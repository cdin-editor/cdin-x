-- Ex-commands for the `with` entry on `treeview`: :tree focuses (and refreshes) the project
-- file tree.
--
-- :tree used to be hardcoded in X/core/vim/ex.lua, which meant vim mode
-- carried treeview's vocabulary and :tree silently did nothing if the
-- treeview plugin was absent. It is a registry entry here instead, so it
-- appears in :help and in ex-command completion only when treeview is
-- actually installed.
local command  = require "core.input.command"
local registry = require "vim.registry"

local M = {}

local specs = {}

function M.register()
  specs = {
    {
      names = { "tree", "trees" },
      help  = "--    :tree  focus (and refresh) the project file tree",
      run   = function() command.perform("treeview:focus-and-refresh") end,
    },
  }
  for _, spec in ipairs(specs) do registry.register_command(spec) end
end

function M.unregister()
  for _, spec in ipairs(specs) do registry.unregister_command(spec) end
  specs = {}
end

return M
