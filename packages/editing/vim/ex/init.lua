-- Ex mode: the ":" command line.
--
-- This module owns three things and nothing else:
--   submit(text)  — run what was typed
--   suggest(text) — completion for the command line
--   history       — the shared history buffer (ex/history.lua)
--
-- Dispatch is a registry lookup. Core's own commands and every
-- integration's commands are registered the same way
-- (registry.register_command), so there is no built-in list to keep in
-- sync and no if/elseif chain to grow. The only two things handled
-- specially are the ":!shell" prefix and a bare line number, because
-- neither is a command name.
--
-- Layout of this directory:
--   init.lua      this module — the public ex API
--   commands.lua  vim core's own ex-commands, as registry specs
--   tokenize.lua  quoted-argument tokenizer
--   history.lua   history buffer + cursor, sized by config
--   suggest.lua   command-name and path completion
--   help.lua      :help rendering
--   fsops.lua     open_file / save_all / show_ls / doc repointing
local registry  = require "vim.registry"
local tokenize  = require "vim.ex.tokenize"
local history   = require "vim.ex.history"
local commands  = require "vim.ex.commands"
local suggest   = require "vim.ex.suggest"
local shell     = require "vim.shell"

local M = {}

-- Shared so integrations that take a path argument (:tabnew <path>,
-- :split <path>) reuse core's create-if-missing behaviour instead of
-- re-implementing it. See ex/fsops.lua.
M.open_file  = require("vim.ex.fsops").open_file
M.history    = history.history

-- Forget where we were in the history, so the next Ctrl+Up starts at the
-- most recent entry. Called whenever the command line opens or is
-- submitted.
function M.reset_position()
  history.position = nil
end

-- Run a line typed at the ":" prompt. A leading ":" is tolerated so this
-- can be called from a keybinding that already includes it.
function M.submit(raw)
  local text = raw:gsub("^%s+", ""):gsub("%s+$", "")
  if text:sub(1, 1) == ":" then text = text:sub(2) end
  if text == "" then return end

  -- ":!cmd" runs a shell command. Checked before tokenizing because the
  -- whole remainder is the command line, arguments included.
  if text:sub(1, 1) == "!" then
    local shell_cmd = text:sub(2):gsub("^%s+", "")
    if shell_cmd == "" then
      require("core").error("ex: empty shell command")
      return
    end
    history.push("!" .. shell_cmd)
    shell.run_in_buffer(shell_cmd)
    return
  end

  history.push(text)

  local tokens = tokenize.tokenize(text)
  local cmd    = tokens[1] or ""

  -- A registered command wins over everything else.
  local found = registry.get_command(cmd)
  if found then
    found.run(tokens[2], tokens[3], cmd)
    return
  end

  -- A bare number is "go to that line", not a command.
  local line = text:match("^(%d+)$")
  if line then
    local core = require "core"
    local view = core.active_docview()
    if view then
      line = tonumber(line)
      view.doc:set_selection(line, 1)
      view:scroll_to_line(line, false, true)
    end
    return
  end

  require("core").error('vim: unknown command ":%s"', text)
end

function M.suggest(text)
  return suggest.suggest(text)
end

function M.register()
  commands.register()
end

function M.unregister()
  commands.unregister()
end

return M
