local config = require "core.config"

local M = {}

if config.vim_ex_history_max == nil then
  config.vim_ex_history_max = 100
end

M.history = {}
M.position = nil   -- 1-based index into history; nil means "not navigating"

function M.push(text)
  M.position = nil
  if text == nil or text == "" then return end
  -- don't record the same command twice in a row
  if M.history[#M.history] == text then return end
  M.history[#M.history + 1] = text
  while #M.history > config.vim_ex_history_max do
    table.remove(M.history, 1)
  end
end

function M.clear()
  M.history = {}
  M.position = nil
end

-- Step one entry back through history. Returns nil when there is nothing
-- to show, which the caller renders as an empty command line.
function M.prev()
  if #M.history == 0 then return nil end
  if not M.position then
    M.position = #M.history
  else
    M.position = math.max(1, M.position - 1)
  end
  return M.history[M.position]
end

-- Step forward again. Stepping past the newest entry clears the line and
-- returns nil, matching vim.
function M.next()
  if #M.history == 0 or not M.position then return nil end
  M.position = M.position + 1
  if M.position > #M.history then
    M.position = nil
    return nil
  end
  return M.history[M.position]
end

return M
