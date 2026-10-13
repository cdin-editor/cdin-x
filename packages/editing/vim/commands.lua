-- Vim mode's own cdin commands.
local core     = require "core"
local config   = require "core.config"
local exline   = require "vim.ex.commandline"

local M = {}

local NAMES = {
  "vim:ex-open",
  "vim:ex-history-prev",
  "vim:ex-history-next",
  "vim:toggle-mode",
}

local MAP = {
  -- Open the ":" command line, the same as typing shift+; in normal mode.
  ["vim:ex-open"] = function()
    exline.open()
  end,
  ["vim:ex-history-prev"] = function()
    exline.history_prev()
  end,
  ["vim:ex-history-next"] = function()
    exline.history_next()
  end,

  ["vim:toggle-mode"] = function()
    config.vim_mode_enabled = not config.vim_mode_enabled
    if config.vim_mode_enabled then
      core.log("vim: normal mode on")
    else
      core.log("vim: normal mode off")
      -- drop any half-typed sequence so it cannot fire after re-enabling
      pcall(function() require("vim.vimode.keys").reset() end)
    end
    core.redraw = true
  end,
}

function M.register()
  require("core.input.command").add(nil, MAP)
end

function M.unregister()
  require("core.input.command").remove(NAMES)
end

return M
