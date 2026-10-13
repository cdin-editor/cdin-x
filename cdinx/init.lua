-- CDIN-X runtime bootstrap.
--
-- Required as `require "cdinx"`, from the entry plugin at
-- plugins/cdin-x/init.lua, and that file returns this table. The host `dofile`s
-- the entry point and calls `init(core, config)` on whatever comes back, so
-- `init` and `unload` here are the only two names the host knows about --
-- everything else is reached from those.
local Host   = require "cdinx.host"
local config = require "cdinx.config"
local cdin_x = {}
local booted = false

local function count(t)
  local n = 0
  for _ in pairs(t or {}) do n = n + 1 end
  return n
end

--- Where themes live, and why the kernel is the thing that knows.
---
--- The host adds `<data>/themes` itself, so a build's themes are already found
--- and registering that root here would list every one of them twice in the
--- picker. What the host cannot know about is a *site* install, which puts
--- themes under the site directory. Both roots the site may hold are added:
--- `X/themes` where they are today, `packages/themes` where a package tree puts
--- them. A root that does not exist costs nothing — the theme registry ignores
--- it, which is why a build has always registered one that was absent.
local function register_theme_roots()
  local ok, themes = pcall(require, "core.themes")
  if not ok then return end

  local sep = Host.sep or package.config:sub(1, 1)
  local function join(...)
    local out = {}
    for i = 1, select("#", ...) do
      local part = tostring(select(i, ...))
      if i > 1 and part ~= "" and not part:match("[/\\]$") then out[#out + 1] = sep end
      out[#out + 1] = part
    end
    return table.concat(out)
  end

  themes.add_root(join(config.site_dir, "X", "themes"))
  themes.add_root(join(config.site_dir, "packages", "themes"))
end

function cdin_x.bootstrap()
  if booted then return true end

  -- Before the manager picks anything up: config.theme is applied at style.lua
  -- load time, long before a plugin runs, so a theme that lives under the site
  -- directory has to be registered before the first frame renders or the editor
  -- draws with the fallback and then changes colour underneath the user.
  register_theme_roots()

  local Manager = require "cdinx.manager"
  local ok, err = Manager.bootstrap()
  if not ok then
    return false, err
  end

  local Command = require "cdinx.command"
  Command.register()

  require("cdinx.panel").register()

  Host.core.cdinx = cdin_x
  booted = true

  Host.core.log("cdin-x bootstrapped")
  Host.core.log("  built-in: %d", count(Manager.list_builtin()))
  Host.core.log("  installed: %d", count(Manager.list_local()))
  return true
end

--- The host's entry point: `mod.init(core, config)`, two positional arguments.
---
--- Both are accepted and neither is read. The kernel reaches the host through
--- cdinx/host.lua, which is the one adapter that knows the host's globals, so a
--- second copy of `core` passed in here would be a second way in — and the same
--- reason `menu`, `git`, `search` and `treeview` spell `init(core, config)` and
--- use neither. The names stay because they are the contract, and luacheck's
--- "unused argument" on this line is the price of saying it in the signature.
---
--- `booted` is only set once every step in `bootstrap` has succeeded, so a boot
--- that failed half way leaves the kernel retryable rather than latched into a
--- state where a second attempt does nothing.
function cdin_x.init(core, host_config)
  return cdin_x.bootstrap()
end

--- Releases everything `init` put up, innermost first.
---
--- Reverse order on purpose: the panel's commands and keys are installed after
--- the packages are loaded, so they have to come down before the packages they
--- refer to. Every step is independent — a panel that will not detach must not
--- stop the searcher being withdrawn — so a failure is logged and the teardown
--- continues, and the module cache is emptied last because every `cdinx.*` module
--- holds registration state that must not survive.
function cdin_x.unload()
  if not booted then return true end

  local problems = {}

  local ok, err = pcall(function()
    require("cdinx.panel").unregister()
  end)
  if not ok then problems[#problems + 1] = "panel: " .. tostring(err) end

  ok, err = pcall(function()
    require("cdinx.command").unregister()
  end)
  if not ok then problems[#problems + 1] = "commands: " .. tostring(err) end

  ok, err = pcall(function()
    require("cdinx.manager").unload_all()
  end)
  if not ok then problems[#problems + 1] = "packages: " .. tostring(err) end

  -- The host keeps the entry point's table (`plugins.loaded["cdin-x"]`), so the
  -- kernel's own modules cannot be left in `package.loaded`: a reload would find
  -- them cached with their registrations already made and nothing to undo.
  for name in pairs(package.loaded) do
    if type(name) == "string" and name:sub(1, 6) == "cdinx." then
      package.loaded[name] = nil
    end
  end
  package.loaded["cdinx"] = nil

  if Host.core and Host.core.cdinx == cdin_x then Host.core.cdinx = nil end
  booted = false

  for _, problem in ipairs(problems) do
    Host.core.error("cdin-x: unload %s", problem)
  end
  if #problems > 0 then return false, problems[1] end
  return true
end

function cdin_x.install(name)
  return require("cdinx.manager").install(name)
end

--- Installs something that needs the network, without blocking the editor.
---
--- `entry` is what `Source.parse` takes: `"owner/repo"`, `{ git = ..., rev = ...,
--- subdir = ... }`, or `{ dir = "~/src/x" }` for a working copy used in place.
--- `on_done(ok, result)` runs from the poller thread. This is the entry point a
--- script or a workflow uses; the panel is the one with the arguments typed in it.
--- @param entry any
--- @param on_done fun(ok: boolean, result: any)|nil
--- @return boolean started
--- @return string|nil err
function cdin_x.install_async(entry, on_done)
  return require("cdinx.manager").install_source_async(entry, on_done)
end

function cdin_x.install_local(path)
  return require("cdinx.manager").install_local(path)
end

--- Uses a directory as a package, in place.
---
--- No copy: the package *is* the directory, so an edit in it is the next reload.
--- The name comes from that directory's own `package.lua`, and the source is
--- remembered in `packages.lua` so it survives a restart.
--- @param dir string
--- @param on_done fun(ok: boolean, result: any)|nil
--- @return boolean ok
--- @return string|nil err
function cdin_x.use_dir(dir, on_done)
  return require("cdinx.manager").use_dir(dir, on_done)
end

function cdin_x.uninstall(name)
  return require("cdinx.manager").uninstall(name)
end

--- Removes a package, and optionally the `sources` entry that named it.
---
--- The `and_source` flag exists for a dev directory: removing one has to rewrite
--- `packages.lua`, which costs the comments in it, so it is never implicit.
--- @param name string
--- @param and_source boolean|nil
--- @return boolean ok
--- @return string|nil err
function cdin_x.remove(name, and_source)
  return require("cdinx.manager").remove(name, and_source)
end

function cdin_x.enable(name)
  return require("cdinx.manager").enable(name)
end

function cdin_x.disable(name)
  return require("cdinx.manager").disable(name)
end

--- Refreshes the registry clone without blocking the editor.
---
--- Async since the refresh moves a clone: `on_done(ok, rev_or_err)` runs from
--- the poller thread when it ends. A caller that needs the old synchronous
--- answer has no synchronous answer to get -- the catalog lives in the clone
--- now, and moving a clone is never instant.
--- @param on_done fun(ok: boolean, result: any)|nil
--- @return boolean started
function cdin_x.refresh(on_done)
  return require("cdinx.manager").refresh_registry(on_done)
end

function cdin_x.update(name)
  return require("cdinx.manager").update(name)
end

--- Puts every package in `cdin-x.lock` back at exactly the commit it names.
---
--- The reproducibility half of the lock file: a wiped store, a new machine, or a
--- repository that has moved on. `on_done(ok, { restored, skipped, errors })`
--- runs from the poller thread. Async because every entry is a clone.
--- @param name string|nil
--- @param on_done fun(ok: boolean, result: any)|nil
--- @return boolean started
--- @return string|nil err
function cdin_x.restore(name, on_done)
  return require("cdinx.manager").restore_async(name, on_done)
end

--- The lock as cdin-x sees it, for a panel or a `doctor`.
--- @return table|nil data
--- @return string[] problems
function cdin_x.lock()
  return require("cdinx.manager.lock").load(require("cdinx.config"))
end

function cdin_x.clean(dry_run)
  return require("cdinx.manager").clean(dry_run)
end

function cdin_x.list()
  return require("cdinx.manager").list()
end

function cdin_x.search(query)
  return require("cdinx.manager").search(query)
end

function cdin_x.get(name)
  return require("cdinx.manager").get(name)
end

function cdin_x.open_readme(name)
  return require("cdinx.manager").open_readme(name)
end

return cdin_x