-- The git section of the vim menu.
--
-- Kept apart from init.lua so the entry list reads as a menu rather than
-- as wiring. Command strings come from git's shared recipes
-- (git.recipes) so there is one spelling of each git invocation in
-- the whole repository.
local M = {}

-- Menu entry -> recipe name. Commit is handled separately because it
-- needs to ask for a message first.
local ENTRIES = {
  { key = "s", label = "Status",   info = "status",  recipe = "status" },
  { key = "l", label = "Log",      info = "-20",     recipe = "log" },
  { key = "d", label = "Diff",     info = "diff",    recipe = "diff" },
  { key = "a", label = "Add All",  info = "add .",   recipe = "add_all" },
  { key = "P", label = "Push",     info = "push",    recipe = "push" },
  { key = "p", label = "Pull",     info = "pull",    recipe = "pull" },
  { key = "b", label = "Branches", info = "-a",      recipe = "branches" },
}

-- Ask for a message, then commit with it. The message is quoted because
-- it goes straight into a shell command line.
local function commit()
  local core = require "core"
  core.command_view:enter("Commit message", function(msg)
    if msg == "" then core.error("vim-git: empty commit message"); return end
    require("vim.shell").run_in_buffer(
      'git commit -m "' .. msg:gsub('"', '\\"') .. '"')
  end, function() return {} end)
end

function M.section()
  local shell = require "vim.shell"
  local git   = require "git.api"

  local entries = {}
  for _, e in ipairs(ENTRIES) do
    local recipe = e.recipe
    entries[#entries + 1] = {
      key = e.key, label = e.label, info = e.info,
      action = function() shell.run_in_buffer(git.recipes[recipe]) end,
    }
  end
  entries[#entries + 1] = {
    key = "c", label = "Commit", info = "interactive", action = commit,
  }

  return { header = "Git", entries = entries }
end

return M
