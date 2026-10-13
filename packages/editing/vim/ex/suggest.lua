-- Completion for the ex command line.
--
-- Two kinds of suggestion:
--   * while the first token is still being typed, complete ex-command
--     names — vim core's own list plus everything any integration has
--     registered, in registration order;
--   * once a path-taking command is recognised and an argument has been
--     started, complete filesystem paths.
local common   = require "core.utils.common"
local registry = require "vim.registry"
local tokenize = require "vim.ex.tokenize"

local M = {}

-- Commands whose argument is a path, so typing one offers path
-- completion. Only core's own commands are listed; an integration that
-- takes a path (with/tab.lua's :tabnew, with/window.lua's :split) declares
-- `arg_paths = true` on its spec and is handled by the same branch.
local PATH_COMMANDS = {
  e = true, edit = true, new = true,
  mkdir = true, rm = true, delete = true,
  rename = true, copy = true, move = true, cd = true,
}

local CORE_COMMANDS = {
  "w", "wa", "q", "q!", "qa", "qa!", "wq", "x", "wqa",
  "e", "edit", "new",
  "mkdir", "rm", "delete", "rename", "copy", "move",
  "ls", "pwd", "cd", "help", "wincmd",
}

local function takes_path(cmd)
  if PATH_COMMANDS[cmd] then return true end
  local found = registry.get_command(cmd)
  return found ~= nil and found.arg_paths == true
end

function M.suggest(text)
  if text:sub(1, 1) == ":" then text = text:sub(2) end

  local tokens = tokenize.tokenize(text)
  local cmd    = tokens[1] or ""

  if #tokens >= 2 and takes_path(cmd) then
    local partial = tokens[#tokens]
    -- typing a quote as the first arg char means "the rest is one path"
    return common.path_suggest(partial)
  end

  if #tokens > 1 then return {} end

  local results, seen = {}, {}
  local function push(name)
    if not seen[name] and name:sub(1, #cmd) == cmd then
      seen[name] = true
      results[#results + 1] = { text = name }
    end
  end

  for _, name in ipairs(CORE_COMMANDS) do push(name) end
  for _, name in ipairs(registry.command_names()) do push(name) end

  return results
end

return M
