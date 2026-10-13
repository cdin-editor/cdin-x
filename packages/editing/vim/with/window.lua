-- Vim's window commands and keys, backed by the workspace package's window
-- manager.
--
-- A `with` entry: see with/tab.lua for why, and the two differ only in which half
-- of workspace they reach for.
local M = {}

local commands = nil
local keymap = nil

local enabled = false

function M.enable()
  if enabled then return end
  enabled = true
  commands = require "vim.with.window.commands"
  keymap = require "vim.with.window.keymap"
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