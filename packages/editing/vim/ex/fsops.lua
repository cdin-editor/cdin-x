-- Filesystem helpers behind vim's ex-commands.
--
-- These live in vim core because opening, listing and mutating a path is
-- part of ex-mode's own vocabulary (:e, :new, :ls, :mkdir, :rm, …), not
-- something a plugin contributes. open_file in particular is exported on
-- the ex module so integrations that take a path argument — :tabnew
-- <path>, :split <path> — reuse it instead of each re-implementing the
-- "create it if missing" dance.
local core = require "core"
local Doc  = require "core.doc"
local fs   = require "core.fs"

local M = {}

-- Open `path` in the active tab. When `create` is true a missing file is
-- created first (that is what :new does, as opposed to :e).
function M.open_file(path, create)
  if not fs.exists(path) then
    if create then
      local ok, err = fs.touch(path)
      if not ok then core.error("ex: %s", err); return false end
    else
      core.error("ex: no such file: %s", path)
      return false
    end
  end
  core.try(function()
    core.root_view:open_doc(core.open_doc(path))
  end)
  return true
end

-- Save every dirty document that has a filename on disk.
function M.save_all()
  for _, doc in ipairs(core.docs) do
    if doc.filename and doc:is_dirty() then
      doc:save()
    end
  end
end

-- Render a directory listing into a scratch buffer, the way :ls does in
-- vim. Returns the buffer name it used.
function M.show_ls(path)
  path = path or "."
  local entries, err = fs.ls(path)
  if not entries then core.error("ex: %s", err); return end

  local lines = { ("-- ls %s\n"):format(fs.pwd() .. PATHSEP .. path) }
  for _, e in ipairs(entries) do
    local marker = e.type == "dir" and "/" or ""
    local size   = e.type == "file" and ("  [%d bytes]"):format(e.size) or ""
    lines[#lines + 1] = e.name .. marker .. size
  end
  lines[#lines + 1] = ""

  local doc = Doc()
  doc:text_input(table.concat(lines, "\n"))
  doc:set_selection(1, 1)
  -- This is command *output*, not a file the user is editing. Faking
  -- get_name() alone was not enough: text_input() moved the undo index, so
  -- the doc stayed dirty forever, had no filename to save to, and every
  -- :q afterwards asked whether to discard "unsaved changes" to a listing
  -- that is not theirs to change. clean() is the runtime's own answer to
  -- "this doc is not modified".
  doc:clean()
  function doc:get_name() return "ls " .. path end
  core.root_view:open_doc(doc)
end

-- Change the working directory and tell everyone who cares.
--
-- This is the single place the working directory moves, whether that was
-- :cd, the menu's "change directory", or "up one level". Doing it in one
-- place is what makes the "cwd_changed" event trustworthy: the project
-- scan is refreshed, and any plugin that caches paths (the file tree, git
-- status) is notified, without vim core naming any of them.
function M.cd(path)
  if not path then core.error("ex: :cd requires a path"); return false end
  local ok, err = fs.cd(path)
  if not ok then
    core.error("ex: %s", err)
    return false
  end
  require("core.project").request_rescan(core)
  require("vim.registry").emit("cwd_changed", fs.pwd())
  return true
end

-- After a doc's filename changes underneath an open document, repoint
-- the doc at its new path. Shared by :rename and :move.
function M.repoint_docs(old_path, new_path)
  local abs_old = system.absolute_path(old_path)
  for _, doc in ipairs(core.docs) do
    if doc.filename and system.absolute_path(doc.filename) == abs_old then
      doc.filename = new_path
    end
  end
end

return M
