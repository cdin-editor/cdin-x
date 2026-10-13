-- Git commands for vim mode.
--
-- Each one runs a recipe from git.recipes through vim's shell
-- capability, so the output shows up in a scratch buffer exactly as :!git
-- status would.
--
-- The vim-shell:* names are kept because the commands read naturally in
-- the palette and are the documented spelling; they are the same
-- operations under the shell's namespace.
--
-- git and the shell are required inside the closures rather than at the
-- top of the file: the extension catalog dofiles init.lua to read the
-- manifest, and a top-level require would load (and start) git for a
-- plugin that may never be installed.
local M = {}

local function run(recipe)
  return function()
    local git = require "git.api"
    require("vim.shell").run_in_buffer(git.recipes[recipe])
  end
end

local MAP = {
  ["vim-git:status"]  = run("status"),
  ["vim-git:log"]     = run("log"),
  ["vim-git:diff"]    = run("diff"),
  ["vim-git:add-all"] = run("add_all"),

  ["vim-shell:git-status"] = run("status"),
  ["vim-shell:git-log"]    = run("log"),
  ["vim-shell:git-diff"]   = run("diff"),
}

local NAMES = {
  "vim-git:status", "vim-git:log", "vim-git:diff", "vim-git:add-all",
  "vim-shell:git-status", "vim-shell:git-log", "vim-shell:git-diff",
}

function M.register()
  require("core.input.command").add(nil, MAP, true)
end

function M.unregister()
  require("core.input.command").remove(NAMES)
end

return M
