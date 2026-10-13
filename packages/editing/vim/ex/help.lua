local core = require "core"
local Doc  = require "core.doc"
local registry = require "vim.registry"

local M = {}

local CORE_HELP = [[
-- cdin vimode ex-commands help
-- ─────────────────────────────────────────────────────────────
--  File commands
--    :w              save current file
--    :w!             force-save (same as :w in cdin)
--    :wa             save all open files
--    :q              close current view (fails if unsaved)
--    :q!             force-close without saving
--    :qa / :qall     close ALL tabs/views
--    :qa! / :qall!   quit cdin entirely
--    :wq / :x        save then close
--    :wqa / :xa      save all then quit
--
--  Open / create
--    :e <path>       open file (error if not found)
--    :edit <path>    alias for :e
--    :new <path>     create + open a new file
--
--  Filesystem
--    :mkdir <path>   create directory (parents included)
--    :rm <path>      remove file or directory tree
--    :delete <path>  alias for :rm
--    :rename <old> <new>
--    :copy <src> <dst>
--    :move <src> <dst>
--
--  Navigation
--    :ls [path]      list directory contents in a buffer
--    :pwd            print working directory
--    :cd <path>      change working directory
--    :<number>       go to line number
--    :wincmd {c}     run a window command (see Ctrl+W in normal mode)
--
--  Shell
--    :!<cmd>         run shell command; output in a new buffer
--                    examples:  :!ls -la   :!git status   :!npm test
--
--    :help           show this help
-- ─────────────────────────────────────────────────────────────
]]

function M.show()
  local parts = { CORE_HELP }

  for _, section in ipairs(registry.command_help()) do
    parts[#parts + 1] = "\n" .. section .. "\n"
  end

  local doc = Doc()
  doc:text_input(table.concat(parts, ""))
  doc:set_selection(1, 1)
  -- Generated text, not a file the user edited: text_input() moved the undo
  -- index, which left the doc dirty, and a :q after :help then asked to
  -- discard "unsaved changes" to the help text.
  doc:clean()
  function doc:get_name() return ":help" end
  core.root_view:open_doc(doc)
end

return M
