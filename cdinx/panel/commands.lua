-- Every panel command, in one file, with its predicate.
local Host     = require "cdinx.host"
local common   = require "core.utils.common"
local command  = require "core.input.command"
local Manager  = require "cdinx.manager"
local Command  = require "cdinx.command"
local Packages = require "cdinx.packages"
local config   = require "cdinx.config"

local M = {}

local view = nil
function M.bind(panel_view)
  view = panel_view
end

local function is_active()
  return view ~= nil and Host.core.active_view == view
end

-- Browsing: the panel has focus and no search is being typed.
function M.browsing()
  return is_active() and not view.searching
end

-- Searching: the panel has focus and every key belongs to the query.
function M.searching()
  return is_active() and view.searching
end

local function current()
  local entry = view and view:entry_at_cursor()
  if not entry then
    Host.core.log("extensions: nothing selected")
  end
  return entry
end

--- The feature row under the cursor, or nil.
---
--- Separate from `current` because the two are different targets: `entry_at_cursor`
--- skips a feature row and lands on the package above it, which is right for the
--- package commands and wrong for this one. Asking the row directly is what makes
--- the difference visible instead of guessed.
local function feature_at_cursor()
  if not view or not view.row then return nil end
  return view:feature_at(view.row)
end

local function report(ok, err)
  if ok then return end
  Host.core.error("extensions: %s", tostring(err))
end

-- ── the lifecycle of the panel itself ────────────────────────────────────

local function set_visible(visible)
  local was_active = Host.core.active_view == view
  view.visible = visible
  if visible then
    view:invalidate()
    Host.core.set_active_view(view)
    M.bootstrap_catalog()
  else
    -- Closing while focused has to hand focus back, or the next keystroke
    -- goes to a panel that is no longer on screen.
    view.searching = false
    view.query = ""
    view:invalidate()
    if was_active and Host.core.last_active_view then
      Host.core.set_active_view(Host.core.last_active_view)
    end
  end
  Host.core.redraw = true
end

M.set_visible = set_visible

function M.toggle()
  set_visible(not view.visible)
end

function M.resize(dir)
  local node = Host.core.root_view:get_active_node()
  local parent = node and node:get_parent_node(Host.core.root_view.root_node)
  local width = view.target_width or Host.config.pluginmanager_size
  -- The panel owns a locked split, so its width is a pane width, and the
  -- pane is the ceiling: wider than that and it pushes the document off the
  -- window rather than showing more of a list.
  local ceiling = parent and math.max(parent.size.x - 200 * Host.scale,
    Host.config.pluginmanager_min) or width
  view.target_width = common.clamp(width + dir * 60 * Host.scale,
    Host.config.pluginmanager_min, ceiling)
  Host.core.redraw = true
end

-- ── actions on the selected extension ────────────────────────────────────

-- Turns one feature of the selected package on or off, and records it.
--
-- This is the write half of what `packages.lua` was added for. Two things have to
-- be right or the switch lies:
--
--   The change is persisted *before* the row is redrawn. A switch that works this
--   session and reverts on restart is the single most confusing thing a panel can
--   offer, and it looks exactly like a save that failed.
--
--   The package is loaded and unloaded around it. Setting the flag alone changes
--   nothing until the next start, which is the same lie in a slower form.
--
-- The row refreshes afterwards whether or not it worked, because a switch that
-- failed to save must not be left drawn in its new position.
function M.toggle_feature()
  local row = feature_at_cursor()
  if not row then
    -- The cursor is on a package rather than a feature. Space keeps meaning
    -- install/enable/disable, which is the operation people reach for; features
    -- are reached from the package's own detail view.
    local entry = current()
    if entry and #(entry.features or {}) > 0 then
      Host.core.log(
        "extensions: %s has %d feature(s) -- press enter on it to choose one",
        entry.name, #entry.features)
    end
    return
  end

  local name, key = row.feature.name, row.feature.key
  local new_value = not row.feature.on

  local data = Packages.load(config)
  local for_package = data.features[name]
  if type(for_package) ~= "table" then
    for_package = {}
    data.features[name] = for_package
  end
  for_package[key] = new_value

  local ok, err = Packages.write(config)
  if not ok then
    Host.core.error("extensions: could not save %s: %s", name, tostring(err))
    view:invalidate()
    return
  end
  Host.core.log("extensions: %s.%s %s", name, key, new_value and "on" or "off")

  -- Apply it now, so the switch is not a promise about the next session. Reload
  -- rather than push at the individual feature: `Features` owns enable and
  -- disable, and reaching past it would register a second copy of something.
  local applied = Manager.apply_feature(name, key, new_value)
  if not applied then
    Host.core.error(
      "extensions: %s.%s is now %s, but not until the next start",
      name, key, new_value and "on" or "off")
  end

  view:invalidate()
end

-- Installs without blocking: the staging is a background job chain, so the
-- command returns as soon as it starts and the completion callback reports and
-- redraws. A panel that froze while git worked would be the old `Fetch.download`
-- wait in a new place.
local function install_background(name)
  local started, err = Manager.install_async(name, function(ok, result)
    if not ok then
      report(ok, result)
    else
      Host.core.log("extensions: installed %s", name)
    end
    if view then view:invalidate() end
  end)
  if not started then
    report(started, err)
    return
  end
  Host.core.log("extensions: installing %s in the background", name)
  if view then view:invalidate() end
end

function M.toggle_cursor()
  local entry = current()
  if not entry then return end
  if entry.locked then
    Host.core.log("extensions: %s is part of the editor and is always on", entry.name)
    return
  end

  if entry.status == "installed" then
    local ok, err = Manager.disable(entry.name)
    if ok then Host.core.log("extensions: disabled %s", entry.name) end
    report(ok, err)
    view:invalidate()
  elseif entry.status == "disabled" then
    local ok, err = Manager.enable(entry.name)
    if ok then Host.core.log("extensions: enabled %s", entry.name) end
    report(ok, err)
    view:invalidate()
  else
    install_background(entry.name)
  end
end

function M.install_cursor()
  local entry = current()
  if not entry then return end
  if entry.locked then
    Host.core.log("extensions: %s ships with the editor", entry.name)
    return
  end
  install_background(entry.name)
end

function M.uninstall_cursor()
  local entry = current()
  if not entry then return end
  if entry.locked then
    -- Only `provided` reaches here now: a package the host loaded before cdin-x
    -- ran, which the manager never loaded and so cannot undo.
    Host.core.log("extensions: %s is part of the editor and cannot be removed",
      entry.name)
    return
  end
  if entry.status ~= "installed" and entry.status ~= "disabled" then
    Host.core.log("extensions: %s is not installed", entry.name)
    return
  end
  -- A dev directory is asked about rather than removed: nothing of the user's is
  -- deleted, and the only thing that can be undone here is forgetting the source,
  -- which rewrites packages.lua and costs its comments. The question is asked
  -- through the kernel's own menu so the answer is a keypress, and so the menu
  -- vocabulary stays in one file instead of gaining a second list.
  if entry.source == "dev" then
    Command.show_forget(entry.name)
    return
  end
  local ok, err = Manager.remove(entry.name, false)
  if not ok then report(ok, err) return end
  Host.core.log("extensions: removed %s", entry.name)
  view:invalidate()
end

function M.details()
  local entry = current()
  if entry then Command.show_details(entry.name) end
end

function M.readme()
  local entry = current()
  if not entry then return end
  local ok, err = Manager.open_readme(entry.name)
  if not ok then report(ok, err) end
end

-- Rescanning reads what is on disk. Updating the catalog is a download of
-- one file; ctrl+r does that.
function M.refresh()
  Manager.scan()
  view:invalidate()
  view:_ensure_rows()
  Host.core.log("extensions: %d listed", view.total)
end

function M.catalog_status()
  local roots = Manager.roots()
  local state, message = Manager.catalog_state()
  local counts = view.counts or {}

  Host.core.log("extensions: %d listed — %d in editor, %d installed, %d available",
    view.total, counts.editor or 0, counts.installed or 0, counts.available or 0)
  Host.core.log("  catalog   : %s (%s)", roots.registry_dir,
    roots.registry and "on disk" or "not downloaded")
  -- The commit, not the branch: "which registry am I reading" wants the answer
  -- that cannot move under the question. Asked here rather than on every draw,
  -- because it spawns a process and a redraw is not the place for one.
  local commit = Manager.registry_commit()
  if commit then
    Host.core.log("  commit    : %s", commit)
  end
  Host.core.log("  download  : %s%s", state, message and (" - " .. message) or "")
  Host.core.log("  installed : %s", roots.installed and "present" or "nothing installed yet")
end

function M.update_catalog()
  local started, err = Manager.fetch_catalog(function(ok, ferr)
    if ok then
      Host.core.log("extensions: catalog updated")
    else
      Host.core.error("extensions: catalog download failed: %s", tostring(ferr))
    end
    view:invalidate()
  end)
  if started then
    Host.core.log("extensions: downloading the catalog...")
  else
    Host.core.error("extensions: %s", tostring(err))
  end
  view:invalidate()
end

function M.bootstrap_catalog()
  if Manager.roots().registry then return end
  if Manager.catalog_state() ~= "idle" then return end
  M.update_catalog()
end

-- ── search ───────────────────────────────────────────────────────────────

function M.search()
  view.searching = true
  Host.core.redraw = true
end

function M.search_stop()
  view.searching = false
  Host.core.redraw = true
end

function M.search_submit()
  view:search_submit()
end

function M.search_delete()
  view:search_delete()
end

function M.search_clear()
  view:search_clear()
end

-- ── registration ─────────────────────────────────────────────────────────
local PERSISTENT = {
  ["pluginmanager:toggle"] = "toggle",
  ["pluginmanager:open"]   = function() set_visible(true) end,
  ["pluginmanager:close"]  = function() set_visible(false) end,
}

local BROWSING = {
  ["pluginmanager:select-previous"]  = function() view:move_cursor(-1) end,
  ["pluginmanager:select-next"]      = function() view:move_cursor(1) end,
  ["pluginmanager:activate-cursor"]  = "toggle_cursor",
  ["pluginmanager:toggle-cursor"]    = "toggle_cursor",
  -- On a package this is what space has always done; on a feature row it is the
  -- feature's own switch. `toggle_feature` says so in its log line when the cursor
  -- is on a package, rather than quietly doing nothing.
  ["pluginmanager:toggle-feature"]   = "toggle_feature",
  ["pluginmanager:install-cursor"]   = "install_cursor",
  ["pluginmanager:uninstall-cursor"] = "uninstall_cursor",
  ["pluginmanager:open-details"]     = "details",
  ["pluginmanager:open-readme"]      = "readme",
  ["pluginmanager:refresh"]          = "refresh",
  ["pluginmanager:catalog-status"]   = "catalog_status",
  ["pluginmanager:update-catalog"]   = "update_catalog",
  ["pluginmanager:search"]           = "search",
  ["pluginmanager:search-clear"]     = "search_clear",
  ["pluginmanager:narrow"]           = function() M.resize(-1) end,
  ["pluginmanager:widen"]            = function() M.resize(1) end,
}

local SEARCHING = {
  ["pluginmanager:search-stop"]   = "search_stop",
  ["pluginmanager:search-submit"] = "search_submit",
  ["pluginmanager:search-delete"] = "search_delete",
}

local function resolve(map)
  local out = {}
  for name, fn in pairs(map) do
    local resolved = fn
    if type(fn) == "string" then
      resolved = M[fn]
      assert(resolved, "panel command " .. name .. " names a function that does not exist: " .. fn)
    end
    out[name] = resolved
  end
  return out
end

function M.register()
  command.add(nil, resolve(PERSISTENT))
  command.add(M.browsing, resolve(BROWSING))
  command.add(M.searching, resolve(SEARCHING))
end

function M.unregister()
  -- Built from the tables rather than written out, because a hand-written list
  -- drifts: `pluginmanager:menu` was in it and is registered nowhere, and
  -- `pluginmanager:open` was missing. Iterating the maps cannot be wrong in that
  -- direction, and the loop is the whole point.
  local names = {}
  for name in pairs(PERSISTENT) do names[#names + 1] = name end
  for name in pairs(BROWSING) do names[#names + 1] = name end
  for name in pairs(SEARCHING) do names[#names + 1] = name end
  command.remove(names)
end

return M
