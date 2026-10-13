-- Installed packages that predate the package layout.
--
-- An install in the user's store is a *copy* of a package from this repository, at
-- `<extension_dir>/<category>/<name>` -- which is the same path a fresh install
-- uses, because `install_path_for` still derives the category from the manifest.
-- So an old install is not a different layout. It is the same directory holding a
-- copy that predates `package.lua`.
--
-- What that costs is one thing: identity. A package with a `package.lua` claims
-- its name, so `require "git.api"` finds it. One without is reachable only by the
-- path-shaped spelling, `X.core.git.api`, which is what the legacy branch of the
-- loader serves. Everything the package does still works -- its own files require
-- each other by that spelling, and they are all from the same era.
--
-- So this module does not migrate anything, and never rewrites a user's installed
-- files. Rewriting their home directory is a large, unreviewable edit done by an
-- editor at startup, to fix something that is not broken. The store is a copy: the
-- manager can put a correct one in place with one action, and that is the remedy
-- worth pointing at.
--
-- What it does instead is two things, and the difference between them matters:
--
--   reported  An old install whose name is still a package in the tree -- `git`,
--             `menu`, `search`, `treeview` are all still packages. It loads, and
--             the only thing wrong with it is that its modules answer to a
--             path-shaped name. Logged once, because a user who asked for that
--             package and got it should not have to read about it every start.
--
--   retired   An old install whose name is *no longer* a package, because this
--             repository folded it into another one -- `finder` is now a feature
--             of `launcher`. The replacement is already in the tree and already
--             loaded, so the old copy is not merely stale: it is competing with
--             its own successor for the same command names, and whichever the
--             load order reached first won. That was observed, not hypothesised:
--             an old `finder` and `launcher`'s `finder` feature both register
--             `core:find-file`, and `command.add` refuses the second.
--
--             So a retired install is not loaded. Nothing is deleted, and it stays
--             in the catalog and in the panel: an installed package the user can
--             see and remove is a package they can get rid of, and a package that
--             vanished from the list is one they cannot.
--
-- The mapping is `cdinx/manager/moved.lua`, which is the single record of what
-- every removed package became, and `scripts/validate.lua` checks it against the
-- tree so an entry cannot name a package that no longer exists.
local Host  = require "cdinx.host"
local Moved = require "cdinx.manager.moved"

local Legacy = {}

--- Packages in the store that answer only to their path-shaped name.
---
--- Not every package without a `package.lua` is old. A theme is a directory of
--- `<name>/theme.lua` and never had one; a syntax definition is a single file by
--- design. So the test is not "has no package.lua" but "is a runtime plugin that
--- would claim a name if it had one".
--- @param ctx table
--- @return { name: string, path: string, spelling: string }[]
function Legacy.find(ctx)
  local out = {}
  local available = ctx and ctx.available
  if type(available) ~= "table" then return out end

  local names = {}
  for name in pairs(available) do names[#names + 1] = name end
  table.sort(names)

  for _, name in ipairs(names) do
    local plugin = available[name]
    -- Only the old store can hold a retirement: the new flat store never holds a
    -- copy that predates the package layout, because everything written there
    -- went through the transport's selection.
    if plugin._source == "installed" and plugin._store ~= "new"
       and plugin.type ~= "theme"
       and not plugin._package_file and not plugin._single_file then
      out[#out + 1] = {
        name = name,
        path = plugin._path or "",
        -- What a user's own code would have to write to reach into it today.
        spelling = "X." .. tostring(plugin._relpath or plugin.name):gsub("/", ".")
                    .. ".<module>",
      }
    end
  end
  return out
end

--- Fills `ctx.retired` and returns it.
---
--- A name is retired when it is an old install *and* `moved.lua` says where it
--- went *and* the package it went to is in this catalog. All three, and the third
--- is the one that matters: without it a name that was removed from this
--- repository but whose replacement is not installed would leave the user with
--- nothing, because the old copy is exactly what we declined to load.
---
--- Recomputed on every merge rather than cached across one, because `available`
--- changes when something is installed or the registry refreshes, and a stale set
--- would keep skipping a package that now exists.
--- @param ctx table
--- @return table<string, string>  name -> the sentence to log
function Legacy.recompute(ctx)
  local retired = {}
  if type(ctx) == "table" then
    for _, entry in ipairs(Legacy.find(ctx)) do
      local moved = Moved.lookup(entry.name)
      if moved and ctx.available[moved.owner] then
        retired[entry.name] = Moved.advice(entry.name)
      end
    end
    ctx.retired = retired
  end
  return retired
end

--- Whether `name` is an old install this tree has superseded.
---
--- False rather than nil for everything else, so a caller can write
--- `if Legacy.retired(ctx, name) then` without a nil check and without the
--- function having to know about `ctx.retired` at all.
--- @param ctx table
--- @param name string
--- @return boolean
--- @return string|nil why
function Legacy.retired(ctx, name)
  local set = ctx and ctx.retired
  if type(set) ~= "table" then return false end
  local why = set[name]
  if why then return true, why end
  return false
end

--- Says what it found, once per session.
---
--- Once, because this is a fact about the store that does not change while the
--- editor runs, and a message on every frame would be a message nobody reads. The
--- return value is "did this call have anything to say": a second call answers
--- false, and so does a store with nothing old in it, because a caller that asked
--- whether it should say something must not be told yes when there was nothing.
---
--- The two sets are reported separately and for different reasons. A retired
--- install is skipped, so the log line is the *only* account the user gets of a
--- package that used to be there -- hence one line each, naming the replacement,
--- not a count. A merely-old install still works, so it gets a count.
--- @param ctx table
--- @return boolean  whether this call reported anything
function Legacy.report(ctx)
  local retired = Legacy.recompute(ctx)
  local found = Legacy.find(ctx)

  local plain = {}
  for _, entry in ipairs(found) do
    if not retired[entry.name] then plain[#plain + 1] = entry.name end
  end

  if next(retired) == nil and #plain == 0 then return false end
  if Legacy._reported then return false end
  Legacy._reported = true

  local names = {}
  for name in pairs(retired) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    Host.core.log("cdin-x: %s", retired[name])
    Host.core.log("cdin-x:   its files are still in your store and still listed "
      .. "in the panel. Remove it there when you like; nothing was deleted, and "
      .. "nothing else needs doing.")
  end

  if #plain > 0 then
    Host.core.log(
      "cdin-x: %d installed extension(s) predate the package layout: %s",
      #plain, table.concat(plain, ", "))
    Host.core.log(
      "cdin-x: their modules are reachable only as X.<category>.<name>.<module>, "
      .. "not <name>.<module>. Everything they do still works. Reinstall one from "
      .. "the Extensions panel to get the new spelling -- no other action is needed.")
  end

  return true
end

--- Forgets that anything was reported, so a test can ask twice.
function Legacy.reset()
  Legacy._reported = false
end

return Legacy