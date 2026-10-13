-- Vim's window commands, backed by the workspace package's window manager.
--
-- A `with` entry rather than a dependency: vim is usable without workspace, and
-- workspace is usable without vim. The commands and keys go up only while both
-- are loaded, and come down when either leaves.
--
-- Nothing here touches the menu, so nothing here depends on the `menu` package.
local M = {}

local commands = nil
local keymap = nil

local enabled = false

function M.enable()
  if enabled then return end
  enabled = true
  commands = require "vim.with.tab.commands"
  keymap = require "vim.with.tab.keymap"
  commands.register()
  keymap.register()
end

function M.disable()
  if not enabled then return end
  enabled = false
  if keymap then keymap.unregister(); keymap = nil end
  if commands then commands.unregister(); commands = nil end
end

return M