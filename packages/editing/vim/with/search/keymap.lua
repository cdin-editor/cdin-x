-- Normal-mode key bindings for the `with` entry on `search`: the / n N * family.
--
-- These four used to be hardcoded in X/core/vim/vimode.lua as
-- `if k == "/" then vimapi.call("search", "find")`. They belong here: "/"
-- in vim mode means "use the search plugin", and search is a separate
-- capability that vim core must not know about.
--
-- register_key is consulted only after vim's own keys have declined the
-- key, so adding them here cannot shadow anything vim does itself.
--
-- Nothing is required at the top of this file: the search commands are
-- reached through command.perform by name, so this module stays inert
-- until it is actually registered.
local M = {}

-- The word under the caret, or "" if there is none. * searches for it.
local function word_under_caret()
  local view = require("core").active_docview()
  if not view then return "" end
  local line, col = view.doc:get_selection()
  local text = view.doc:get_text(line, col, line, math.huge)
  return text:match("^([%w_]+)") or ""
end

local function find(command_name)
  return function()
    return require("core.input.command").perform(command_name)
  end
end

local KEYS = {
  ["/"] = find("find-replace:find"),
  ["n"] = find("find-replace:repeat-find"),
  ["shift+n"] = find("find-replace:previous-find"),

  -- * searches for the word under the cursor. Returning false when there
  -- is no word lets the key fall through unhandled instead of opening an
  -- empty search.
  ["*"] = function()
    if word_under_caret() == "" then return false end
    return require("core.input.command").perform("find-replace:find")
  end,
}

function M.register()
  require("vim.registry").register_key(KEYS)
end

function M.unregister()
  require("vim.registry").unregister_key(KEYS)
end

return M
