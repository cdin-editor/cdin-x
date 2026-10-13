-- Commands for the shell capability. Split out of shell/init.lua so they
-- can be registered and unregistered as a unit, and so init.lua stays a
-- plain capability module with no command names in it.
local core   = require "core"
local shell  = require "vim.shell"
local config = require "core.config"

local M = {}

local NAMES = {
  "vim-shell:run-custom",
  "vim-shell:make",
  "vim-shell:make-test",
  "vim-shell:open-terminal",
  "vim-shell:use-cmd",
  "vim-shell:use-powershell",
  "vim-shell:use-pwsh",
}

local MAP = {
  ["vim-shell:run-custom"]    = function() shell.prompt_and_run() end,
  ["vim-shell:make"]          = function() shell.run_in_buffer("make") end,
  ["vim-shell:make-test"]     = function() shell.run_in_buffer("make test") end,
  -- separate terminal window, non-blocking
  ["vim-shell:open-terminal"] = function() shell.open_terminal() end,

  -- switch which terminal an interactive shell opens
  ["vim-shell:use-cmd"] = function()
    config.shell_win = "cmd"
    core.log("shell: interactive → cmd.exe")
  end,
  ["vim-shell:use-powershell"] = function()
    config.shell_win = "powershell"
    core.log("shell: interactive → PowerShell 5")
  end,
  ["vim-shell:use-pwsh"] = function()
    config.shell_win = "pwsh"
    core.log("shell: interactive → PowerShell 7+")
  end,
}

function M.register()
  require("core.input.command").add(nil, MAP)
end

function M.unregister()
  require("core.input.command").remove(NAMES)
end

return M
