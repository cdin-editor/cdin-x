-- Ex-commands for the `with` entry on `workspace`: :split, :vsplit, :vnew, :close, :only.
--
-- Registered into vim.registry so vim core never hardcodes the
-- window command vocabulary. :split / :vsplit / :vnew take an optional
-- path, hence arg_paths = true.
local command  = require "core.input.command"
local registry = require "vim.registry"

local M = {}

local specs = {}

-- All of these reduce to a window core command, so the integration holds
-- no layout logic of its own.
local SPLITS = {
  split  = { cmd = "window:split",  create = false },
  vsplit = { cmd = "window:vsplit", create = false },
  vnew   = { cmd = "window:vnew",   create = true },
}

local function run_split(which, arg1)
  local spec = SPLITS[which]
  command.perform(spec.cmd)
  if arg1 then
    -- :vnew implies :new, so a missing file is created; :split / :vsplit
    -- behave like :e and refuse.
    require("vim.ex").open_file(arg1, spec.create)
  end
end

function M.register()
  specs = {
    {
      names = { "split", "sp" },
      arg_paths = true,
      help = "--    :split [path] / :sp  horizontal split, optionally opening a file",
      run  = function(arg1) run_split("split", arg1) end,
    },
    {
      names = { "vsplit", "vs" },
      arg_paths = true,
      help = "--    :vsplit [path] / :vs  vertical split, optionally opening a file",
      run  = function(arg1) run_split("vsplit", arg1) end,
    },
    {
      names = { "vnew" },
      arg_paths = true,
      help = "--    :vnew [path]  vertical split with a new/existing file",
      run  = function(arg1) run_split("vnew", arg1) end,
    },
    {
      names = { "close", "clo" },
      help  = "--    :close / :clo  close the current window (split pane)",
      run   = function() command.perform("window:close") end,
    },
    {
      names = { "only", "on" },
      help  = "--    :only / :on  close all other windows (split panes)",
      run   = function() command.perform("window:only") end,
    },
  }

  for _, spec in ipairs(specs) do registry.register_command(spec) end
end

function M.unregister()
  for _, spec in ipairs(specs) do registry.unregister_command(spec) end
  specs = {}
end

return M
