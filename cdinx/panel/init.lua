-- The extension manager panel: a view, its commands, and its keys.
local Host        = require "cdinx.host"
local Manager     = require "cdinx.manager"
local PanelView   = require "cdinx.panel.view"
local PanelCmds   = require "cdinx.panel.commands"
local PanelKeymap = require "cdinx.panel.keymap"

local M = {}

local Features = require "cdinx.manager.features"
local Packages = require "cdinx.packages"

-- The catalog, in the shape rows.lua wants.
local function catalog_notice()
  local roots = Manager.roots()
  local state = Manager.catalog_state()

  if state == "fetching" then
    return "Downloading the extension list..."
  end
  if state == "failed" then
    return "Extension list download failed (see log, ctrl+shift+l).  ctrl+r retries."
  end
  if not roots.registry then
    return "No extension list yet.  Press ctrl+r to download it."
  end
  return nil
end

-- The manager's context, for `Features.active`.
--
-- Features are read off the manager's own ctx, because that is the table the
-- runtime registers into -- a second context would answer a question about a
-- session that is not running. It is fetched through the facade rather than
-- required directly, so the panel keeps one way in.
local function ctx() return Manager.context() end

--- A feature as a panel row.
---
--- A feature is not selectable on its own. Pressing space on a *package* has to
--- keep meaning what it has always meant -- install, enable or disable the whole
--- package -- because that is the operation with a lifecycle behind it, and the one
--- users reach for. A feature is a switch inside that package, so it is a detail
--- row: it appears, it can be read, and it is turned from the package's own detail
--- view rather than from the same key that installs something.
---
--- What it does carry here is the *state*, which is the thing that was invisible:
--- before `packages.lua` there was no way for the panel to know a feature was off,
--- because nothing recorded it.
--- @param name string
--- @param plugin table
--- @return table[]
local function feature_rows(name, plugin)
  local out = {}
  local declared = plugin.spec and Features.declared(plugin.spec)
  if not declared or #declared == 0 then return out end

  local overrides = Packages.feature_overrides(name) or {}
  local active = {}
  for _, key in ipairs(Features.active(ctx, name)) do active[key] = true end

  for _, f in ipairs(declared) do
    -- The effective state, not the declared default: an override is what counts,
    -- and a feature with no opinion is on exactly when its default says so.
    local on
    if overrides[f.key] ~= nil then
      on = overrides[f.key] and true or false
    else
      on = f.default and true or false
    end
    out[#out + 1] = {
      kind        = "feature",
      name        = name,
      key         = f.key,
      label       = f.key,
      description = f.description,
      on          = on,
      -- Whether the switch has been touched. A feature that is on because the
      -- package says so is not the user's choice, and drawing the two the same way
      -- would claim credit for a default.
      chosen      = overrides[f.key] ~= nil,
      -- Running now, which is not the same as being switched on: a feature can be
      -- on and have failed to start.
      running     = active[f.key] == true,
    }
  end
  return out
end

local function collect()
  local entries = {}
  Manager.scan()

  for name, plugin in pairs(Manager.list()) do
    local status = Manager.get_status(name)
    local locked = Manager.is_locked(name)

    local group = "available"
    if locked then
      group, status = "editor", "editor"
    elseif status == "installed" or status == "disabled" then
      group = "installed"
    end

    -- In-flight work and on-disk size ride on the entry, because the row is drawn
    -- from it and there is nowhere else for either to live. Progress replaces the
    -- right column while it runs; size joins it once the package is installed.
    local progress = Manager.operation_status(name)
    local size = nil
    if status == "installed" or status == "disabled" then
      local lock = Manager.lock_info(name)
      if lock and tonumber(lock.bytes) then
        size = Manager.human_size(lock.bytes)
      end
    end

    entries[#entries + 1] = {
      name        = name,
      category    = plugin.category,
      version     = plugin.version,
      description = plugin.description,
      source      = plugin._source,
      status      = status,
      locked      = locked,
      group       = group,
      features    = feature_rows(name, plugin),
      progress    = progress,
      size        = size,
    }
  end

  table.sort(entries, function(a, b) return a.name < b.name end)
  return entries, Manager.human_size(Manager.store_bytes())
end

-- ── the instance ────────────────────────────────────────────────────────────
--
-- Built by `register` and not at require time, for two reasons. Anything that
-- touches the manager can require this module without the host ever calling
-- `init` -- and a module that splits the editor's root view when it is required
-- has rearranged the user's window as a side effect of looking at it. And
-- `unregister` has to be able to take the view back out, which it cannot do if
-- the view was never recorded as ours.
local view = nil
local registered = false
local attached_with = nil

--- Puts the panel into the layout, by whichever seam the host offers.
---
--- `attach_side_view` is the one to use: it is idempotent by construction, so a
--- second register cannot split a second pane, and the host pairs it with
--- `detach_view`, which is what gives the space back. The fallback is the older
--- `get_active_node():split()`, which is neither -- it splits whatever node is
--- active -- so the way in is remembered rather than recomputed, or `unregister`
--- would take out a pane it did not create.
--- @return string|nil  the seam used, or why there is none
local function attach()
  local rv = Host.core.root_view
  if type(rv.attach_side_view) == "function" then
    rv:attach_side_view(view, "right", { width = 0.4 })
    return "attach_side_view"
  end
  if type(rv.get_active_node) == "function" then
    local node = rv:get_active_node()
    if node and type(node.split) == "function" then
      node:split("right", view, true)
      return "split"
    end
  end
  return "this editor offers neither core.root_view:attach_side_view nor a node " ..
    "to split, so the panel's commands are registered and it has nowhere to live"
end

--- Takes the panel back out, through the seam it went in through.
local function detach()
  local rv = Host.core.root_view
  if attached_with == "attach_side_view" then
    if type(rv.detach_view) == "function" then rv:detach_view(view) end
  elseif attached_with == "split" then
    -- `Node:remove_view` is what detach_view calls anyway, so this is the same
    -- teardown through the shorter door.
    local node = rv:get_active_node()
    if node and type(node.remove_view) == "function" then
      node:remove_view(view, rv.root_node)
    end
  end
end

--- Brings the panel up.
--- @return boolean ok
function M.register()
  if registered then return true end

  Host.config.pluginmanager_size = Host.config.pluginmanager_size or 460 * Host.scale
  Host.config.pluginmanager_min = Host.config.pluginmanager_min or 300 * Host.scale

  view = PanelView(function()
    -- Three values, not two: the store total rides along so the Installed
    -- section can say how much of the disk its packages hold. `collect()` keeps
    -- returning entries first, so a caller that only wants the list is unaffected.
    local entries, total = collect()
    return entries, catalog_notice(), total
  end)
  view.target_width = Host.config.pluginmanager_size

  -- A host with neither seam still gets its commands and keys; the panel simply
  -- has nowhere to be shown, and saying so beats a boot that fails.
  attached_with = attach()
  if attached_with:find(" ", 1, true) then
    Host.core.log("cdin-x: %s", attached_with)
    attached_with = nil
  end

  PanelCmds.bind(view)
  PanelCmds.register()
  PanelKeymap.register()

  M.view = view
  registered = true
  return true
end

--- Takes the panel down.
---
--- Reverse order for the same reason a package's own unload is inside out: the
--- keys and commands refer to the view, so they go first. Each step is
--- independent -- a view that will not detach must not stop the keys being
--- withdrawn -- so a failure is logged and the teardown continues.
--- @return boolean ok
--- @return string|nil err
function M.unregister()
  if not registered then return true end
  registered = false

  local problems = {}

  local ok, err = pcall(function()
    PanelKeymap.unregister()
    PanelCmds.unregister()
  end)
  if not ok then problems[#problems + 1] = "commands and keys: " .. tostring(err) end

  if attached_with then
    ok, err = pcall(detach)
    if not ok then problems[#problems + 1] = "detach: " .. tostring(err) end
    attached_with = nil
  end

  PanelCmds.bind(nil)
  view = nil
  M.view = nil

  for _, problem in ipairs(problems) do
    Host.core.error("cdin-x: panel unload %s", problem)
  end
  if #problems > 0 then return false, problems[1] end
  return true
end

function M.toggle()
  PanelCmds.toggle()
end

M.commands = PanelCmds
M.keymap = PanelKeymap

return M
