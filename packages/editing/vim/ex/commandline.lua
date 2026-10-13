-- The ex command line itself: opening it, and walking its history.
--
-- Lives beside ex/ rather than in vimode/ because it is ex's concern —
-- vimode only decides *when* a key should reach it.
local core = require "core"
local ex   = require "vim.ex"

local M = {}

-- Open the ":" prompt. Vim's own history buffer is reused, so Ctrl+Up /
-- Ctrl+Down work without vimode knowing anything about history.
function M.open()
  ex.reset_position()

  core.command_view:enter(
    "",
    function(text) ex.submit(text) end,
    function(text) return ex.suggest(text) end,
    function() ex.reset_position() end
  )

  core.command_view:set_text(":")
end

-- Older entries first. Return false when the key should fall through,
-- which happens if there is no history to show.
function M.history_prev()
  if core.active_view ~= core.command_view then return false end
  local text = ex.history.prev()
  core.command_view:set_text(text and (":" .. text) or ":")
  return true
end

function M.history_next()
  if core.active_view ~= core.command_view then return false end
  local text = ex.history.next()
  core.command_view:set_text(text and (":" .. text) or ":")
  return true
end

return M
