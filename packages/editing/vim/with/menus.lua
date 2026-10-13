-- Vim's own file, shell and build menus.
--
-- This is a `with` entry on `menu` rather than part of vim unconditionally, and
-- the difference is not about the commands: `with/menus.luas:open` raises
-- `require("menu.impl").open("vim.main")` at the moment it runs, so with no menu
-- package it would open nothing. Being a with entry means it is simply not built.
--
-- What is *not* here is the definition of `vim.main`. That is in vim/init.lua, and
-- it has to be, because four things extend `vim.main` -- this entry, and the
-- search, treeview and git ones -- and `menu.extend` asserts the menu exists. If
-- the definition lived in an optional entry, whether an extender worked would
-- depend on those two optional things happening to load in the right order.
local M = {}

local commands = nil
local keymap = nil

local enabled = false

function M.enable()
  if enabled then return end
  enabled = true
  commands = require "vim.with.menus.commands"
  keymap = require "vim.with.menus.keymap"
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