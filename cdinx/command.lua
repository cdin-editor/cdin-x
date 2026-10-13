-- CDIN-X Plugin Manager UI.
local Host    = require "cdinx.host"
local command = require "core.input.command"
local Manager = require "cdinx.manager"
local Lock    = require "cdinx.manager.lock"
local config  = require "cdinx.config"

local Command = {}

local CATEGORY_NAMES = {
  core="CORE", syntax="SYNTAX", lsp="LSP", formatters="FORMATTERS",
  git="GIT", debug="DEBUG", ui="UI", utils="UTILS",
  optional="OPTIONAL", themes="THEMES",
}
local CATEGORY_ORDER = {
  "core","syntax","lsp","formatters","git","debug","ui","utils","optional","themes",
}

local function status(plugin)
  if Manager.is_locked(plugin.name) then
    return plugin._source == "provided" and "[H]" or "[L]"
  end
  local s = Manager.get_status(plugin.name)
  if s == "installed" then return "[X]" end
  if s == "disabled" then return "[-]" end
  return "[ ]"
end

local function filter_text(text)
  return (text or ""):match("^%s*(.-)%s*$")
end

local function open_items(title, items, submit)
  Host.core.command_view:enter(title, submit, function(text)
    local q = filter_text(text):lower()
    if q == "" then return items end
    local out = {}
    for _, item in ipairs(items) do
      if not item._header then
        if item.text:lower():find(q,1,true)
        or (item.info and item.info:lower():find(q,1,true)) then
          out[#out+1]=item
        end
      end
    end
    return out
  end)
end

local function catalog_items(include_builtins)
  Manager.ensure_registry()
  Manager.scan()

  local items={}
  local plugins=Manager.list()
  local by_category, seen_category = {}, {}
  for _, plugin in pairs(plugins) do
    if include_builtins or not Manager.is_locked(plugin.name) then
      local cat=plugin.category or "other"
      by_category[cat] = by_category[cat] or {}
      by_category[cat][#by_category[cat]+1] = plugin
    end
  end

  local ordered_categories = {}
  for _, category in ipairs(CATEGORY_ORDER) do
    if by_category[category] then
      ordered_categories[#ordered_categories+1] = category
      seen_category[category] = true
    end
  end
  local extra = {}
  for category in pairs(by_category) do
    if not seen_category[category] then extra[#extra+1] = category end
  end
  table.sort(extra)
  for _, category in ipairs(extra) do ordered_categories[#ordered_categories+1] = category end

  for _, category in ipairs(ordered_categories) do
    local group=by_category[category]
    table.sort(group,function(a,b)return a.name<b.name end)
    items[#items+1]={text="── "..(CATEGORY_NAMES[category] or category:upper()).." ──",info="",_header=true}
    for _, plugin in ipairs(group) do
      items[#items+1]={
        text=string.format("%s %s",status(plugin),plugin.name),
        info=plugin.description,
        _plugin=plugin,
      }
    end
  end
  return items
end

function Command.show_menu()
  local items={
    {text="Extensions",info="Browse and install from the CDIN-X catalog",action=Command.show_catalog},
    {text="Installed",info="Manage installed extensions",action=Command.show_installed},
    {text="Search",info="Search the extension catalog",action=Command.show_search},
    {text="Install Local",info="Install an extension from a local directory",action=Command.show_install_local},
    {text="Update All",info="Re-fetch installed extensions whose registry version changed",action=Command.show_update_all},
    {text="Clean",info="Remove installed extensions no longer in the registry",action=Command.show_clean},
    {text="Refresh Catalog",info="Update the cdin-x catalog",action=Command.show_refresh},
    {text="Restore",info="Put every locked package back at the commit it was installed from",
      action=Command.show_restore},
    {text="Doctor",info="Say whether this installation is sound, and what to do if not",
      action=Command.show_doctor},
    {text="Editor Log",info="Messages and errors from the editor and its extensions",
      action=function() command.perform("core:open-log") end},
  }
  open_items("CDIN-X",items,function(text,item)
    if item and item.action then item.action() end
  end)
end

function Command.show_catalog()
  local items=catalog_items(true)
  open_items("Extensions",items,function(text,item)
    if not item or not item._plugin then return end
    local plugin=item._plugin
    if Manager.is_locked(plugin.name) then
      Command.show_details(plugin.name)
      return
    end
    local st=Manager.get_status(plugin.name)
    if st=="installed" or st=="disabled" then
      Command.show_details(plugin.name)
    else
      local started,err=Manager.install_async(plugin.name,function(ok,result)
        if ok then Host.core.log("Installed %s",plugin.name)
        else Host.core.error("cdin-x: %s",tostring(result)) end
      end)
      if not started then Host.core.error("cdin-x: %s",tostring(err))
      else Host.core.log("Installing %s in the background",plugin.name) end
    end
  end)
end

function Command.show_details(name)
  local plugin=Manager.get(name)
  if not plugin then return end
  local installed=Manager.get_status(name)=="installed"
  local disabled=Manager.get_status(name)=="disabled"

  local items={
    {text="Open README",info=plugin.description,action=function()
      local ok,err=Manager.open_readme(name)
      if not ok then Host.core.error("cdin-x: %s",err) end
    end},
  }

  -- The trust display: where this copy came from, which commit it is, and how
  -- much of the disk it holds. Read-only -- the action only repeats it in full,
  -- because a row in a menu truncates and a commit hash must not be truncated.
  local lock=Manager.lock_info(name)
  if lock and (lock.url or lock.rev) then
    local short=(lock.url or "registry")
    if lock.ref and lock.ref~="" then short=short.." @ "..lock.ref end
    if lock.rev and lock.rev~="" then short=short.." "..lock.rev:sub(1,12) end
    if lock.bytes then short=short.." · "..Manager.human_size(lock.bytes) end
    items[#items+1]={text="Source",info=short,action=function()
      Host.core.log("extensions: %s source=%s ref=%s rev=%s files=%s bytes=%s",name,
        tostring(lock.url or "registry"),tostring(lock.ref or ""),
        tostring(lock.rev or ""),tostring(lock.files or ""),tostring(lock.bytes or ""))
    end}
  end

  -- `or plugin.essential` was dead weight: no package may declare that field, so
  -- it was always false. `is_locked` is the whole test.
  if Manager.is_locked(name) then
    items[#items+1]={text="Locked",info="Part of the editor, and cannot be removed",action=function()
      Host.core.log("%s is built into the editor",name)
    end}
  elseif installed or disabled then
    items[#items+1]={text=disabled and "Enable" or "Disable",
      info=disabled and "Load on this and future sessions" or "Stop loading without uninstalling",
      action=function()
        local ok,err
        if disabled then ok,err=Manager.enable(name) else ok,err=Manager.disable(name) end
        if not ok then Host.core.error("cdin-x: %s",err) else Host.core.log("%s updated",name) end
      end}
    items[#items+1]={text="Update",info="Re-fetch from the registry if a newer version exists",
      action=function()
        local started,err=Manager.update_async(name,function(ok,result)
          if ok and result.updated and #result.updated>0 then Host.core.log("Updated %s",name)
          elseif ok then Host.core.log("%s is already up to date",name)
          else Host.core.error("cdin-x: %s",result.errors and table.concat(result.errors,"; ") or tostring(result)) end
        end)
        if not started then Host.core.error("cdin-x: %s",tostring(err))
        else Host.core.log("Updating %s in the background",name) end
      end}
    -- A build-shipped package can be updated like any installed one; it cannot
    -- be uninstalled, and `Manager.uninstall` is the one that says so.
    items[#items+1]={text="Uninstall",info="Remove the installed extension",
      action=function()
        local ok,err=Manager.uninstall(name)
        if not ok then Host.core.error("cdin-x: %s",err) else Host.core.log("Uninstalled %s",name) end
      end}
  else
    -- Show where it comes from while it is still only an idea: the URL, the ref
    -- and the commit are the trust display, and the panel is where a source that
    -- is neither first-party nor indexed gets its confirmation.
    items[#items+1]={text="Install",info="Fetch with git and install the selected files",
      action=function()
        local started,err=Manager.install_async(name,function(ok,result)
          if not ok then Host.core.error("cdin-x: %s",tostring(result)) else Host.core.log("Installed %s",name) end
        end)
        if not started then Host.core.error("cdin-x: %s",tostring(err))
        else Host.core.log("Installing %s in the background",name) end
      end}
  end

  items[#items+1]={text="Back",info="",action=Command.show_catalog}
  open_items(name.."  "..plugin.version,items,function(text,item)
    if item and item.action then item.action() end
  end)
end

function Command.show_installed()
  Manager.scan()
  local items={}
  local local_plugins=Manager.list_local()
  local names={}
  for name in pairs(local_plugins) do names[#names+1]=name end
  table.sort(names)
  for _,name in ipairs(names) do
    local plugin=local_plugins[name]
    items[#items+1]={text=string.format("%s %s",status(plugin),name),info=plugin.description,_plugin=plugin}
  end
  if #items==0 then items[1]={text="No installed extensions",info="Use Extensions to browse the catalog"} end
  open_items("Installed",items,function(text,item)
    if item and item._plugin then Command.show_details(item._plugin.name) end
  end)
end

function Command.show_search()
  Host.core.command_view:enter("Search CDIN-X",function(text,item)
    if item and item._plugin then Command.show_details(item._plugin.name) end
  end,function(text)
    local results=Manager.search(filter_text(text))
    local items={}
    for _,p in pairs(results) do
      items[#items+1]={text=status(p).." "..p.name,info=p.description,_plugin=p}
    end
    table.sort(items,function(a,b)return a.text<b.text end)
    return items
  end)
end

function Command.show_install_local()
  Host.core.command_view:enter("Install local extension path",function(path)
    path=filter_text(path)
    if path=="" then return end
    local ok,err=Manager.install_local(path)
    if not ok then Host.core.error("cdin-x: %s",err) else Host.core.log("Installed local extension") end
  end,function(text)
    return require("core.utils.common").path_suggest(text or "")
  end)
end

function Command.show_update_all()
  -- Background, like every install: the check is one `ls-remote` per package and
  -- the staging is a clone per package, and neither happens on the frame thread.
  local started,err=Manager.update_async(nil,function(ok,result)
    if not ok and type(result)=="string" then
      Host.core.error("cdin-x: %s",result)
      return
    end
    result=result or {updated={},errors={}}
    if #result.updated>0 then
      Host.core.log("cdin-x: updated %s",table.concat(result.updated,", "))
    else
      Host.core.log("cdin-x: everything installed is already up to date")
    end
    if not ok then
      Host.core.error("cdin-x: %s",table.concat(result.errors,"; "))
    end
  end)
  if not started then
    Host.core.error("cdin-x: %s",tostring(err))
  else
    Host.core.log("cdin-x: checking for updates in the background")
  end
end

function Command.show_clean()
  local ok,orphaned=Manager.clean(true)
  if not ok then Host.core.error("cdin-x: %s",tostring(orphaned)); return end
  if #orphaned==0 then
    Host.core.log("cdin-x: nothing to clean — no orphaned installed extensions")
    return
  end

  local items={}
  items[#items+1]={text=string.format("Remove %d orphaned extension(s)",#orphaned),
    info=table.concat(orphaned,", "),
    action=function()
      local rok,result=Manager.clean(false)
      if #result.removed>0 then Host.core.log("cdin-x: removed %s",table.concat(result.removed,", ")) end
      if not rok then Host.core.error("cdin-x: %s",table.concat(result.errors,"; ")) end
    end}
  items[#items+1]={text="Cancel",info="",action=function() Host.core.log("cdin-x: clean cancelled") end}
  open_items("Clean CDIN-X",items,function(text,item)
    if item and item.action then item.action() end
  end)
end

function Command.show_refresh()
  -- Background like every other network operation: refreshing moves the registry
  -- clone, and the catalog is re-read when it lands.
  local started,err=Manager.refresh_registry(function(ok,rev)
    if ok then
      Host.core.log("cdin-x catalog refreshed")
      Command.show_catalog()
    else
      Host.core.error("cdin-x: %s",tostring(rev))
    end
  end)
  if not started then
    Host.core.error("cdin-x: %s",tostring(err))
  else
    Host.core.log("cdin-x: refreshing the catalog in the background")
  end
end

--- Asks before forgetting a dev directory.
---
--- The panel's remove key reaches here for a package that is the user's own working
--- copy, because the two things "remove" could mean are not the same and only one
--- of them is reversible: forgetting the source rewrites `packages.lua` and costs
--- its comments, and deleting the directory is not cdin-x's to do. So it is
--- offered as a menu item that says both, rather than a flag nobody reads.
--- @param name string
function Command.show_forget(name)
  local plugin = Manager.get(name)
  local dir = (plugin and plugin._spec and plugin._spec.dir) or "a directory of yours"
  local items = {
    {
      text = string.format("Forget %s and stop using %s", name, dir),
      info = string.format(
        "packages.lua is rewritten, so its comments are lost. Nothing in %s is deleted.",
        dir),
      action = function()
        local ok, err = Manager.remove(name, true)
        if not ok then Host.core.error("cdin-x: %s", tostring(err)) return end
        Host.core.log("cdin-x: no longer using %s; %s is untouched", name, dir)
        Command.show_installed()
      end,
    },
    { text = "Cancel", info = "", action = function() end },
  }
  open_items("Remove " .. name, items, function(_, item)
    if item and item.action then item.action() end
  end)
end

--- Says whether this installation is sound, and what to do about it if not.
---
--- Printed to the log rather than opened as a menu, because the answer is read
--- once and then acted on: a menu of checks is a menu to dismiss, and a block of
--- lines in the log is something to copy a line of into a fix. The same report is
--- what `cdin-x doctor` prints, so a bug report can quote either.
function Command.show_doctor()
  local Doctor = require "cdinx.manager.doctor"
  local checks = Manager.doctor()
  for _, line in ipairs(Doctor.lines(checks)) do
    Host.core.log("%s", line)
  end
  if Doctor.failed(checks) then
    Host.core.error("cdin-x: something above will not work; each line says what to do")
  else
    Host.core.log("cdin-x: nothing above is broken")
  end
end

--- Puts every locked package back at the commit `cdin-x.lock` names.
---
--- Async like every other network operation, and offered as a menu item rather
--- than fired straight away: a restore overwrites the store for every third-party
--- package at once, and the one question worth asking first is how many there are.
function Command.show_restore()
  local data, problems = Lock.load(config)
  if not data then
    Host.core.error("cdin-x: cdin-x.lock is not readable: %s", tostring(problems[1]))
    return
  end
  local names = {}
  for name, entry in pairs(data.packages) do
    -- A dev directory has nothing to restore, so listing it would be asking the
    -- user to confirm work that cannot happen.
    if entry.source ~= "dir" then names[#names + 1] = name end
  end
  table.sort(names)

  if #names == 0 then
    Host.core.log("cdin-x: nothing to restore -- cdin-x.lock lists no installed package")
    return
  end

  local items = {}
  items[#items + 1] = {
    text = string.format("Restore %d package(s) at their locked commits", #names),
    info = table.concat(names, ", "),
    action = function() Command.run_restore() end,
  }
  items[#items + 1] = {
    text = "Cancel", info = "", action = function() Host.core.log("cdin-x: restore cancelled") end,
  }
  open_items("Restore CDIN-X", items, function(text, item)
    if item and item.action then item.action() end
  end)
end

function Command.run_restore()
  local started, err = Manager.restore_async(nil, function(ok, result)
    for _, line in ipairs(result.restored or {}) do
      Host.core.log("cdin-x: restored %s", line)
    end
    for _, line in ipairs(result.skipped or {}) do
      Host.core.log("cdin-x: skipped %s", line)
    end
    for _, line in ipairs(result.errors or {}) do
      Host.core.error("cdin-x: %s", line)
    end
    if ok and #(result.restored or {}) == 0 and #(result.errors or {}) == 0 then
      Host.core.log("cdin-x: everything was already where it should be")
    end
  end)
  if not started then
    Host.core.error("cdin-x: %s", tostring(err))
  else
    Host.core.log("cdin-x: restoring in the background...")
  end
end

-- The kernel's own commands, and the name list that takes them back.
--
-- Both derived from one table, because a hand-written second list drifts: this
-- repository already shipped `pluginmanager:menu` registered nowhere. Iterating
-- the map cannot be wrong in that direction, and the loop is the whole point.
--
-- The host's `command.remove` takes names, not the table it was given, so the
-- list is built here rather than being a table field somebody has to maintain.
local COMMANDS = {
  ["cdin-x:menu"]       = Command.show_menu,
  ["pluginmanager:menu"] = Command.show_menu,
  ["cdin-x:catalog"]    = Command.show_catalog,
  ["cdin-x:update"]     = Command.show_update_all,
  ["cdin-x:clean"]      = Command.show_clean,
  ["cdin-x:refresh"]    = Command.show_refresh,
  ["cdin-x:restore"]    = Command.show_restore,
  ["cdin-x:doctor"]     = Command.show_doctor,
}

local NAMES = {}
for name in pairs(COMMANDS) do NAMES[#NAMES + 1] = name end
table.sort(NAMES)

function Command.register()
  command.add(nil, COMMANDS)
end

function Command.unregister()
  command.remove(NAMES)
end

Command.names = NAMES

return Command
