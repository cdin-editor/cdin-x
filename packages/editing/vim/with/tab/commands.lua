-- Ex-commands for vim-tab: :tabnew, :tabclose, :tabnext and friends.
--
-- Registered into vim.registry rather than written into ex.lua, so
-- vim core never has to know that "tabnew" is a thing. :tabnew and
-- :tabedit take an optional path, so the spec sets arg_paths = true and
-- the ex command line offers path completion for them.
local registry = require "vim.registry"

local M = {}

local specs = {}

local function tabs() return require "workspace.tab.manager" end

local function open_file(arg)
  -- core's own helper: opens the path, and does not create it unless
  -- asked. Reused instead of reimplemented so :tabnew and :e behave
  -- identically.
  return require("vim.ex").open_file(arg, false)
end

function M.register()
  specs = {
    {
      names = { "tabnew", "tabe", "tabedit" },
      arg_paths = true,
      help = "--    :tabnew [path]  open a new tab, optionally with a file\n" ..
             "--    :tabe / :tabedit  aliases for :tabnew",
      run = function(arg1)
        require("core.input.command").perform("tab:new")
        if arg1 then open_file(arg1) end
      end,
    },
    {
      names = { "tabclose", "tabc" },
      help  = "--    :tabclose / :tabc  close the current tab",
      run   = function() require("core.input.command").perform("tab:close") end,
    },
    {
      names = { "tabonly", "tabo" },
      help  = "--    :tabonly / :tabo  close all tabs except the current one",
      run   = function() require("core.input.command").perform("tab:close-others") end,
    },
    {
      names = { "tabnext", "tabn" },
      help  = "--    :tabnext [N] / :tabn  go to tab N, or the next tab",
      run   = function(arg1)
        local t = tabs()
        if arg1 then t.go_to(tonumber(arg1) or 1) else t.next() end
      end,
    },
    {
      names = { "tabprevious", "tabp", "tabNext" },
      help  = "--    :tabprevious / :tabp / :tabNext  go to the previous tab",
      run   = function() tabs().prev() end,
    },
    {
      names = { "tabfirst", "tabr", "tabrew" },
      help  = "--    :tabfirst / :tabr / :tabrew  go to the first tab",
      run   = function() require("core.input.command").perform("tab:first") end,
    },
    {
      names = { "tablast" },
      help  = "--    :tablast  go to the last tab",
      run   = function() require("core.input.command").perform("tab:last") end,
    },
    {
      names = { "tabmove", "tabm" },
      help  = "--    :tabmove N / :tabm  move the current tab to position N",
      run   = function(arg1)
        local n = tonumber(arg1)
        local t = tabs()
        if n then t.move(t.active_id, n + 1) end
      end,
    },
  }

  for _, spec in ipairs(specs) do registry.register_command(spec) end
end

function M.unregister()
  for _, spec in ipairs(specs) do registry.unregister_command(spec) end
  specs = {}
end

return M
