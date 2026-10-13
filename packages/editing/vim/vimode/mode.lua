-- Vim's per-view mode (normal / insert / visual / visual line) and its label.
--
-- Visual and visual-line are separate modes rather than one mode with a flag,
-- because `Esc` out of them does different work — character-wise leaves the
-- selection alone to be replaced by whatever comes next, while line-wise has to
-- turn the selection back into whole lines — and because the status pill has to
-- be able to say which one you are in.
local core = require "core"

local M = {
  NORMAL      = "normal",
  INSERT      = "insert",
  VISUAL      = "visual",
  VISUAL_LINE = "visual_line",
}

function M.get(view)
  return view.vim_mode or M.NORMAL
end

function M.set(view, mode)
  view.vim_mode = mode
  core.redraw = true
end

function M.is_visual(mode)
  return mode == M.VISUAL or mode == M.VISUAL_LINE
end

-- "[NORMAL]" / "[INSERT]" / "[VISUAL]" / "[VISUAL LINE]", or nil when vim mode
-- is off or no document is active.
function M.label(view)
  local mode = M.get(view)
  if     mode == M.INSERT      then return "[INSERT]"
  elseif mode == M.VISUAL      then return "[VISUAL]"
  elseif mode == M.VISUAL_LINE then return "[VISUAL LINE]"
  else                              return "[NORMAL]"
  end
end

return M