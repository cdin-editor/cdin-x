-- Vim core's own ex-commands.
--
-- These are registered through the very same registry that integrations
-- use (registry.register_command), which is what lets ex/init.lua's
-- submit() be a plain lookup instead of a 200-line if/elseif chain. There
-- is no special-casing for "core" commands: an integration's :tabnew is
-- indistinguishable from core's :w as far as dispatch is concerned.
--
-- Nothing in this file may reference another X plugin. Cross-plugin
-- behaviour is expressed in one of only two ways:
--   * command.perform("<other-plugin>:<command>") — a command name is a
--     public interface, so naming one is not a module dependency;
--   * registry.emit("<event>") — a subscription seam.
-- Anything more (requiring workspace.tab, say) belongs in an integration.
local core    = require "core"
local command = require "core.input.command"
local fs      = require "core.fs"
local registry = require "vim.registry"
local fsops   = require "vim.ex.fsops"
local help    = require "vim.ex.help"

local M = {}

local specs = {}

local function spec(names, run)
  return { names = names, run = run }
end

-- ── :q / :qa, including the unsaved-changes confirmation ────────────────
local function dirty_summary()
  local count, name = 0, nil
  for _, doc in ipairs(core.docs) do
    if doc:is_dirty() then
      count = count + 1
      name = name or doc:get_name()
    end
  end
  return count, name
end

local function close_all_views()
  local count, name = dirty_summary()
  if count > 0 then
    local question = count == 1
      and ('"%s" has unsaved changes. Close all without saving?'):format(name)
      or  ("%d docs have unsaved changes. Close all without saving?"):format(count)
    if not system.show_confirm_dialog("Unsaved Changes", question) then
      return false
    end
  end
  -- Tabs first (tab:close-others is tab core's own command), then let
  -- window core collapse whatever views remain. Neither module is
  -- required from here — only their public command names are used.
  command.perform("tab:close-others")
  command.perform("window:close-all-views")
  return true
end

function M.register()
  specs = {
    -- ── write ────────────────────────────────────────────────────────
    spec({ "w", "w!" }, function()
      command.perform("doc:save")
    end),
    spec({ "wa", "wa!" }, function()
      fsops.save_all()
    end),

    -- ── quit ─────────────────────────────────────────────────────────
    spec({ "q" }, function()
      command.perform("root:close")
    end),
    spec({ "q!" }, function()
      command.perform("window:close-force")
    end),
    spec({ "qa", "qall" }, close_all_views),
    spec({ "qa!", "qall!" }, function()
      core.quit(true)
    end),
    spec({ "wq", "x" }, function()
      command.perform("doc:save")
      command.perform("root:close")
    end),
    spec({ "wqa", "wqall", "xa" }, function()
      fsops.save_all()
      core.quit(false)
    end),
    spec({ "wqa!", "wqall!" }, function()
      fsops.save_all()
      core.quit(true)
    end),

    -- ── open / create ────────────────────────────────────────────────
    spec({ "e", "edit" }, function(arg1)
      if not arg1 then core.error("ex: :e requires a path"); return end
      fsops.open_file(arg1, false)
    end),
    spec({ "new" }, function(arg1)
      if not arg1 then core.error("ex: :new requires a path"); return end
      fsops.open_file(arg1, true)
    end),

    -- ── filesystem ───────────────────────────────────────────────────
    spec({ "mkdir" }, function(arg1)
      if not arg1 then core.error("ex: :mkdir requires a path"); return end
      local ok, err = fs.mkdir(arg1)
      if ok then core.log("mkdir: created '%s'", arg1)
      else core.error("ex: %s", err) end
    end),
    spec({ "rm", "delete" }, function(arg1)
      if not arg1 then core.error("ex: :rm requires a path"); return end
      local ok, err = fs.rm(arg1)
      if ok then core.log("rm: removed '%s'", arg1)
      else core.error("ex: %s", err) end
    end),
    spec({ "rename" }, function(arg1, arg2)
      if not arg1 or not arg2 then
        core.error("ex: :rename <old> <new>")
        return
      end
      local ok, err = fs.rename(arg1, arg2)
      if ok then
        fsops.repoint_docs(arg1, arg2)
        core.log("rename: '%s' → '%s'", arg1, arg2)
      else
        core.error("ex: %s", err)
      end
    end),
    spec({ "copy" }, function(arg1, arg2)
      if not arg1 or not arg2 then
        core.error("ex: :copy <src> <dst>")
        return
      end
      local ok, err = fs.copy(arg1, arg2)
      if ok then core.log("copy: '%s' → '%s'", arg1, arg2)
      else core.error("ex: %s", err) end
    end),
    spec({ "move" }, function(arg1, arg2)
      if not arg1 or not arg2 then
        core.error("ex: :move <src> <dst>")
        return
      end
      local ok, err = fs.move(arg1, arg2)
      if ok then
        fsops.repoint_docs(arg1, arg2)
        core.log("move: '%s' → '%s'", arg1, arg2)
      else
        core.error("ex: %s", err)
      end
    end),

    -- ── navigation / environment ─────────────────────────────────────
    spec({ "ls" }, function(arg1)
      fsops.show_ls(arg1)
    end),
    spec({ "pwd" }, function()
      core.log(fs.pwd())
    end),
    spec({ "cd" }, function(arg1)
      if fsops.cd(arg1) then core.log("cd: %s", fs.pwd()) end
    end),

    -- ── windows ──────────────────────────────────────────────────────
    -- :wincmd is core ex-mode syntax, but the character -> command table
    -- is contributed by an integration (with/window.lua) via register_wmap,
    -- exactly as Ctrl+W does in normal mode.
    spec({ "wincmd", "winc" }, function(arg1)
      local char = arg1 or ""
      local wcmd = registry.wmap_get(char)
      if not wcmd then
        core.error('ex: unknown :wincmd "%s"', char)
        return
      end
      command.perform(wcmd)
    end),

    -- ── help ─────────────────────────────────────────────────────────
    spec({ "help", "h" }, function()
      help.show()
    end),
  }

  for _, s in ipairs(specs) do
    registry.register_command(s)
  end
end

function M.unregister()
  for _, s in ipairs(specs) do
    registry.unregister_command(s)
  end
  specs = {}
end

return M
