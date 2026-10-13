-- File and directory operations behind the vim menu.
--
-- Every one of these changes something on disk and then has to tell the
-- project scanner about it, so they all funnel through refresh_project().
-- The directory-changing ones go through vim's shared cd helper, which
-- additionally emits "cwd_changed" so the file tree and git status follow
-- along.
local core   = require "core"
local common = require "core.utils.common"
local fs     = require "core.fs"
local fsops  = require "vim.ex.fsops"

local M = {}

local function basename(path)
  return path and (path:match("[^\\/]+$") or path) or nil
end
local function dirname(path)
  return path and (path:match("^(.*)[\\/][^\\/]+$") or ".") or "."
end

M.basename = basename
M.dirname = dirname

function M.refresh_project()
  require("core.project").request_rescan(core)
  core.redraw = true
end

-- Move to a directory and refresh everything that depends on the working
-- directory. Returns success so callers can report the error themselves.
function M.change_dir(path)
  if not fsops.cd(path) then return false end
  core.log("vim-menu: cd %s", fs.pwd())
  return true
end

-- Prompt for a path, defaulting to `path` when it already exists, and
-- hand the chosen one to `fn`.
local function with_path(prompt, path, start_dir, fn)
  if path and fs.exists(path) then fn(path); return end
  local base = (start_dir and start_dir ~= ".") and (start_dir .. PATHSEP) or ""
  core.command_view:enter(prompt, function(chosen)
    if chosen == "" then return end
    if not fs.exists(chosen) then
      core.error("vim-menu: no such file or directory: %s", chosen)
      return
    end
    fn(chosen)
  end, function(partial) return common.path_suggest(base .. partial) end)
end

-- Ask for a name, then resolve it against `dir`.
local function prompt_for(prompt, dir, fn)
  local base = (dir and dir ~= ".") and (dir .. PATHSEP) or ""
  core.command_view:enter(prompt, function(name)
    if name == "" then return end
    fn(base .. name)
  end, function(partial) return common.path_suggest(base .. partial) end)
end

function M.new_file(dir)
  prompt_for("New file name", dir, function(path)
    local ok, err = fs.touch(path)
    if not ok then core.error("vim-menu: %s", err); return end
    M.refresh_project()
    core.try(function() core.root_view:open_doc(core.open_doc(path)) end)
  end)
end

function M.new_dir(dir)
  prompt_for("New directory name", dir, function(path)
    local ok, err = fs.mkdir(path)
    if not ok then core.error("vim-menu: %s", err); return end
    M.refresh_project()
  end)
end

function M.open_file(dir)
  prompt_for("Open file", dir, function(path)
    if not fs.exists(path) then core.error("vim-menu: no such file: %s", path); return end
    core.try(function() core.root_view:open_doc(core.open_doc(path)) end)
  end)
end

function M.rename(path, dir)
  with_path("Rename — select target", path, dir, function(src)
    local old = basename(src)
    core.command_view:enter("Rename '" .. old .. "' to", function(new_name)
      new_name = new_name:match("^%s*(.-)%s*$")
      if new_name == "" or new_name == old then return end
      local d = dirname(src)
      local dst = (d ~= ".") and (d .. PATHSEP .. new_name) or new_name
      local ok, err = fs.rename(src, dst)
      if not ok then core.error("vim-menu: %s", err); return end
      fsops.repoint_docs(src, dst)
      M.refresh_project()
    end, function() return {} end)
    core.command_view:set_text(old, true)
  end)
end

function M.copy(path, dir)
  with_path("Copy — select source", path, dir, function(src)
    core.command_view:enter("Copy '" .. basename(src) .. "' to", function(dst)
      dst = dst:match("^%s*(.-)%s*$")
      if dst == "" then return end
      local ok, err = fs.copy(src, dst)
      if not ok then core.error("vim-menu: %s", err); return end
      M.refresh_project()
    end, function(partial) return common.path_suggest(partial) end)
  end)
end

function M.move(path, dir)
  with_path("Move — select source", path, dir, function(src)
    core.command_view:enter("Move '" .. basename(src) .. "' to", function(dst)
      dst = dst:match("^%s*(.-)%s*$")
      if dst == "" then return end
      local ok, err = fs.move(src, dst)
      if not ok then core.error("vim-menu: %s", err); return end
      fsops.repoint_docs(src, dst)
      M.refresh_project()
    end, function(partial) return common.path_suggest(partial) end)
  end)
end

function M.delete(path, dir)
  with_path("Delete — select target", path, dir, function(target)
    local kind = fs.is_dir(target) and "directory" or "file"
    core.command_view:enter(("Delete %s '%s'? [y/n]"):format(kind, basename(target)),
      function(answer)
        local a = answer:lower():match("^%s*(.-)%s*$")
        if a ~= "y" and a ~= "yes" then return end
        local ok, err = fs.rm(target)
        if not ok then core.error("vim-menu: %s", err); return end
        M.refresh_project()
      end, function() return { { text = "y" }, { text = "n" } } end)
  end)
end

return M
