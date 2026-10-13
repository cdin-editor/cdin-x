-- Git status badges in the project file tree.
--
-- `with` on `git`, owned by `treeview`. The owner is the package whose *behaviour*
-- changes: installing this turns treeview rows from plain names into rows carrying
-- a git letter, and uninstalling it takes those letters away again. Nothing in
-- treeview mentions git and nothing in git mentions treeview — it is a generic
-- provider registry in between, which is the whole reason a seam exists.
--
-- It was declared by `git` for a while, which works and is the wrong way round:
-- the rule is that a `with` entry belongs to whoever is affected, so that turning
-- that package off takes its seams with it for the right reason rather than by
-- accident. See docs/building/a-with-entry.md.
--
-- Everything is required inside `enable`, so a user without git never builds any
-- of this, and git's status thread does not start for them.
local M = {}

-- Single-letter git status -> badge glyph, and -> colour. Kept as data so
-- the mapping is readable and the style fallbacks stay in one place.
local ICON = {
  M = "M", A = "A", D = "D", R = "R", C = "C", U = "!", ["?"] = "?",
}

local STYLE_KEY = {
  M = "git_modified", A = "git_added", D = "git_deleted",
  U = "git_conflict", R = "git_renamed", C = "git_renamed",
  ["?"] = "git_untracked",
}

local FALLBACK = {
  M = { 0xb8, 0x9a, 0x50, 0xff },
  A = { 0x5a, 0x9a, 0x5a, 0xff },
  D = { 0xb8, 0x50, 0x50, 0xff },
  U = { 0xd0, 0x60, 0x40, 0xff },
}

local PROVIDER_ID = "git"

local function badge_color(style, status)
  local key = STYLE_KEY[status]
  if key and style[key] then return style[key] end
  return FALLBACK[status] or style.accent
end

local enabled = false

function M.enable()
  if enabled then return end
  enabled = true

  local core     = require "core"
  local style    = require "core.style"
  local git      = require "git.api"
  local treeview = require "treeview.api"

  treeview.register_badge_provider(PROVIDER_ID, function(item)
    local status = git.status.get_status(item)
    if not status then return nil end
    return ICON[status] or status, badge_color(style, status)
  end, 100)

  treeview.register_refresh_provider(PROVIDER_ID, git.status.refresh)
  -- register_vcs_provider is not callable from init(), so the status loop is
  -- deferred; see the extension contract.
  core.add_thread(git.status.thread)
end

function M.disable()
  if not enabled then return end
  enabled = false
  local treeview = require "treeview.api"
  treeview.remove_badge_provider(PROVIDER_ID)
  treeview.remove_refresh_provider(PROVIDER_ID)
end

return M