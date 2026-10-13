-- CDIN-X extension manager — public facade.
local Host = require "cdinx.host"
local fs   = Host.fs
local config   = require "cdinx.config"

local Util      = require "cdinx.manager.util"
local Registry  = require "cdinx.manager.registry"
local State     = require "cdinx.manager.state"
local Catalog   = require "cdinx.manager.catalog"
local Runtime   = require "cdinx.manager.runtime"
local Features  = require "cdinx.manager.features"
local Packages  = require "cdinx.packages"
local Lock      = require "cdinx.manager.lock"
local Spec      = require "cdinx.manager.spec"
local Manifest  = require "cdinx.manifest"
local Lifecycle = require "cdinx.manager.lifecycle"
local Transport = require "cdinx.manager.transport"
local Source    = require "cdinx.manager.source"
local Moved     = require "cdinx.manager.moved"

local Manager = {
  available = {},
  installed = {},
  sources = {},
}

local ctx = {
  available = Manager.available,
  sources = Manager.sources,
  installed = Manager.installed,
  -- Plugins the host already loaded before cdin-x ran. The mandatory
  -- bundle is the normal case: a cdin build ships vim, the host's loader
  -- has already initialised it, and cdin-x must not initialise it again.
  provided = {},
  state = { disabled = {}, lock = {} },
  registry_external = false,
}

local bootstrapped = false

-- Background operations, owned by this facade: the queue of staged installs and
-- updates, the item being polled, whether the poller thread is alive, and whether
-- a session teardown cancelled everything. Touched only by the functions below
-- and the poller thread they start; Lua is single-threaded, so the only
-- reentrancy is a completion callback that enqueues, and the tick iterates a
-- snapshot so that is safe.
local op_queue = {}
local op_active = nil
local poller_running = false
local ops_cancelled = false

local function call_done(on_done, ok, result)
  if not on_done then return end
  local good, err = pcall(on_done, ok, result)
  if not good then
    Host.core.error("cdin-x: completion callback failed: %s", tostring(err))
  end
end

-- One tick: advance the active job, finalize it when terminal, start the next.
-- Declared up here because the catalog fetch below already needs it, and a local
-- declared later is a global to everything above. The finalizers it invokes are
-- attached to queue items by the functions further down, which only run after
-- the whole file has loaded.
local function tick_ops()
  if ops_cancelled then
    if op_active then
      op_active.op.cancelled = true
    end
    op_queue = {}
    if not op_active then return false end
  end

  if not op_active then
    op_active = table.remove(op_queue, 1)
    if not op_active then return false end
  end

  local item = op_active
  local status, payload
  -- A phase that raises is a bug, and the queue must still survive it: without
  -- this the exception unwinds through the poller coroutine, the operation is left
  -- half-done, and both its per-package lock and -- for a registry operation -- the
  -- registry lock stay on disk. The user is then told to wait ten minutes and then
  -- delete a directory by hand, for a failure they cannot see. So a raise becomes a
  -- reported failure with the same cleanup every other failure gets.
  local good, poll_status, poll_payload
  if item.check then
    good, poll_status, poll_payload = pcall(Transport.poll_check, item.op)
  else
    good, poll_status, poll_payload = pcall(Transport.poll, config, item.op)
  end
  if not good then
    Transport.abandon(config, item.op)
    Host.core.error("cdin-x: %s failed unexpectedly: %s", tostring(item.op.name),
      tostring(poll_status))
    op_active = nil
    local settled, err = pcall(item.finalize, "failed",
      "internal error: " .. tostring(poll_status))
    if not settled then
      Host.core.error("cdin-x: finalizer failed: %s", tostring(err))
    end
    return true
  end
  status, payload = poll_status, poll_payload
  if status == "running" then return true end

  op_active = nil
  local finalized, err = pcall(item.finalize, status, payload)
  if not finalized then
    Host.core.error("cdin-x: finalizer failed: %s", tostring(err))
  end
  return true
end

local function ensure_poller()
  if poller_running then return end
  poller_running = true
  Host.core.add_thread(function()
    while tick_ops() do
      coroutine.yield(0.25)
    end
    poller_running = false
  end)
end

-- ── roots ──────────────────────────────────────────────────────────────

local function user_extensions_root()
  return config.extension_dir
end

--- The user's home directory, for `dir = "~/…"` in a source.
---
--- Read once, from the same two variables `config.lua` reads it from, and only
--- because a dev directory is the one place a path in this system comes from the
--- person writing it rather than from a field the editor filled in.
--- @return string
local function home_dir()
  local home = os.getenv("USERPROFILE") or os.getenv("HOME")
  if type(home) == "string" and home ~= "" then return home end
  return "."
end

-- Where a *build's* packages are, and whether that differs from the site
-- directory's.
--
-- Two roots, because a bundled cdin and an installed cdin-x put their packages in
-- different places -- `EXEDIR/data/packages` against `<site>/packages` -- and the
-- kernel reads both so that a developer running from a checkout sees their own
-- edits without reinstalling. They were four until Phase 9 removed `X/`, which had
-- a slot in each; a missing directory is skipped by the scan, so the entries were
-- harmless, but two of them named a path that cannot exist and cost two `is_dir`
-- checks per scan to prove it.
local function builtin_roots()
  local roots = {}
  if config.bundle_dir then
    roots[#roots + 1] = Util.join(config.bundle_dir, "packages")
  end
  roots[#roots + 1] = Util.join(config.site_dir, "packages")
  return roots
end

--- The names a third-party source may not claim.
---
--- Every name the catalog already describes *except the ones this file itself
--- put there*: a dev directory and a registry recipe are resolved sources, so
--- counting them would make a source conflict with its own previous resolution.
--- That is not hypothetical -- `current_roots` asks for the specs before the merge
--- that publishes them, so the second scan of a session would see its own dev
--- directory in the catalog, refuse it as "already a first-party package", and
--- drop it again. The next scan would do the same, and the package would blink in
--- and out of the panel.
local function taken_names()
  local taken = {}
  for name, plugin in pairs(ctx.available or {}) do
    local from = plugin and plugin._source
    if from ~= "dev" and from ~= "recipe" then taken[name] = true end
  end
  for name, entry in pairs(ctx.state.lock or {}) do
    if not (type(entry) == "table" and entry.source == "dir") then
      taken[name] = true
    end
  end
  return taken
end

--- Resolves the user's sources and the registry's recipes, once per scan.
---
--- Cached per merge because resolving means reading two files through the
--- sandbox, and a panel redraw calls this several times. The cache is keyed on the
--- two things that can change its answer -- the registry index's path, and the
--- generation of `packages.lua` -- rather than on a flag somebody has to remember
--- to raise:
---
---   the index path  the recipes live in that file, and it does not exist until the
---                   registry is cloned, so a cache that ignored it would remember
---                   "no recipes" from the first scan of a session and keep saying
---                   so after `cdin-x:refresh` brought the index in
---   the generation  the sources live in `packages.lua`, and the panel writes that
---                   file itself when a switch changes. Keying on the file's own
---                   generation is what stops a switch click leaving a stale source
---                   list behind.
local spec_cache = nil

local function resolve_specs()
  local index_path = Registry.catalog_path(config)
  local generation = Packages.generation()
  if spec_cache and spec_cache.index_path == index_path
    and spec_cache.generation == generation then
    return spec_cache
  end
  local recipes = {}
  local ok, list = pcall(Registry.read_index, config, taken_names())
  if ok and type(list) == "table" then
    for _, recipe in ipairs(list) do
      local spec = Spec.from_recipe(recipe)
      if spec then recipes[recipe.name] = spec end
    end
  end
  local specs, problems = Spec.resolve(Packages.sources(), { taken = taken_names() })
  -- One answer to "what does this name resolve to", with the precedence written
  -- down: a `sources` entry is the user overriding the registry, so it wins over a
  -- recipe of the same name. `update` reads this rather than the two tables, so a
  -- recipe-installed package is pinned the way a recipe is pinned -- CI resolved a
  -- commit and the recipe cannot float.
  local effective = {}
  for name, spec in pairs(recipes) do effective[name] = spec end
  for name, spec in pairs(specs) do effective[name] = spec end
  spec_cache = { recipes = recipes, specs = specs, effective = effective,
    problems = problems, index_path = index_path, generation = generation }
  return spec_cache
end

local function current_roots()
  local resolved = resolve_specs()
  local dev = {}
  -- Only `dir` sources are roots. A git source has nothing on disk until it is
  -- installed, and what it becomes is an installed package in the store, found
  -- by the ordinary scan -- not a catalog root.
  for name, spec in pairs(resolved.specs) do
    if spec.kind == "dir" then
      dev[#dev + 1] = { name = name, dir = spec.dir, spec = spec }
    end
  end
  table.sort(dev, function(a, b) return a.name < b.name end)
  return {
    registry  = Registry.registry_root(config),
    installed = user_extensions_root(),
    -- The new store, flat like a build's `data/packages/`: `<name>/` holds only
    -- the selected runtime files. Scanned as "installed" alongside the old store,
    -- and merged after it so a package present in both resolves to the new copy.
    store     = config.store_dir,
    builtin   = builtin_roots(),
    recipes   = resolved.recipes,
    dev       = dev,
  }
end

local function merge_sources()
  local all = Catalog.merge_sources(ctx, current_roots())
  Catalog.add_provided(ctx, ctx.provided)
  Manager.available = all
  Manager.sources = ctx.sources
  return all
end

-- Lets Lifecycle refresh the catalog view after it put files on disk, without
-- reaching back into this module.
ctx.rescan = function() merge_sources() end

--- Re-reads `packages.lua`, the lock file and the registry index, and rebuilds
--- the catalog from them.
---
--- The panel writes `packages.lua` when a switch changes, and the file is not
--- re-read unless something says so -- nor are the sources resolved from it,
--- which are cached on top of it. Anything that changed a file on disk calls
--- this rather than reaching for a cache.
function Manager.rescan()
  Packages.invalidate()
  Lock.invalidate()
  spec_cache = nil
  return merge_sources()
end

local function save_state()
  return State.save(config, ctx.state)
end

local function is_disabled(name)
  return ctx.state.disabled[name] == true
end

--- Confirms every `.old` whose package is now running.
---
--- Declared up here because bootstrap calls it, and a local declared later is a
--- global to everything above it. Called after boot and after any successful load
--- that followed an update: the rollback is deleted only once the new tree proved
--- itself, and "proved itself" means loaded, not merely swapped.
local function confirm_loaded()
  for name in pairs(ctx.installed) do
    if Transport.pending(config, name) then
      Transport.confirm(config, name)
    end
  end
end

-- ── registry ───────────────────────────────────────────────────────────

--- Makes sure a catalog is on disk and re-reads it.
---
--- Takes no `force`: the only thing forcing ever meant was "refresh the
--- registry", and refreshing is a network operation now -- `refresh_registry`
--- below, which runs through the queue. A parameter that meant "do the slow
--- thing synchronously" would be the wrong thing to pass twice.
--- @return boolean ok
--- @return string|nil err
function Manager.ensure_registry()
  local ok, err = Registry.ensure(config)
  if not ok then return false, err end
  merge_sources()
  return true
end

-- One line per process, not per call: a plugin registers a syncer once at load,
-- and a log line every time would be noise rather than information.
local syncer_warned = false

--- Deprecated: the registry syncer seam is gone.
---
--- Nothing ever registered one, and the thing it would have replaced is not
--- coming back -- the registry is a persistent sparse clone managed by
--- `cdinx.manager.registry` and `cdinx.manager.transport`, and `cdin-x:refresh`
--- (or `Manager.refresh_registry`) moves that clone. The name stays because it
--- is documented public API: a plugin that calls it should get a reason rather
--- than a nil-call error.
--- @deprecated
function Manager.set_registry_syncer()
  if syncer_warned then return end
  syncer_warned = true
  Host.core.log("cdin-x: Manager.set_registry_syncer() does nothing -- the "
    .. "registry is a clone now; use Manager.refresh_registry()")
end

--- Refreshes the registry without blocking the editor.
---
--- Ensures the persistent sparse clone, fetches the tracked branch and checks it
--- out; `on_done(ok, rev_or_err)` runs from the poller thread when it ends. The
--- old synchronous refresh -- one downloaded file -- is gone with the mechanism
--- that needed it: the catalog is read out of the clone now, so refreshing means
--- moving the clone.
--- @param on_done fun(ok: boolean, result: any)|nil
--- @return boolean started
function Manager.refresh_registry(on_done)
  -- No Registry.ensure() here: "the catalog is not on disk yet" is exactly the
  -- case a refresh exists to fix.
  local op = Transport.start_refresh()
  op_queue[#op_queue + 1] = {
    op = op,
    kind = "refresh",
    finalize = function(status, payload)
      if status ~= "done" then
        call_done(on_done, false, payload)
        return
      end
      merge_sources()
      Host.core.log("cdin-x: registry refreshed at %s", tostring(payload.rev))
      call_done(on_done, true, payload.rev)
    end,
  }
  ensure_poller()
  return true
end

--- The commit the registry clone is at, or nil.
---
--- Separate from `roots()` on purpose: it spawns a process, and `roots()` runs
--- on every panel redraw, where a process per frame would be a performance bug
--- wearing a status line as a disguise. Callers are user-invoked commands only.
--- @return string|nil
function Manager.registry_commit()
  return Registry.clone_rev(config)
end

-- ── host-provided plugins ──────────────────────────────────────────────

local function collect_provided()
  local provided = {}
  local ok, plugins = pcall(require, "core.plugins")
  if ok and plugins and plugins.loaded then
    for name in pairs(plugins.loaded) do
      provided[name] = true
    end
  end

  local dir = config.bundle_dir and Util.join(config.bundle_dir, "plugins")
  for _, entry in ipairs(dir and Host.fs.list(dir) or {}) do
    if entry.type == "file" then
      local name = entry.name:match("^(.+)%.lua$")
      if name then
        provided[name] = true
      end
    elseif entry.type == "dir" then
      if fs.is_file(Util.join(dir, entry.name, "init.lua")) then
        provided[entry.name] = true
      end
    end
  end

  ctx.provided = provided
  return provided
end

-- ── boot ───────────────────────────────────────────────────────────────

function Manager.bootstrap()
  if bootstrapped then return true end

  -- Before anything is loaded: an installed extension's first require of its
  -- own modules has to find them in the extension store.
  require("cdinx.manager.loader").ensure(config.extension_dir)

  ctx.state = State.load(config)

  -- The user's own choices, read once here so the config is known before any
  -- package asks what its features should be. Problems are logged rather than
  -- raised: a packages.lua with a typo in it must not stop the editor starting.
  -- `Packages` is the module-level upvalue from the top of this file. Re-requiring
  -- it here shadowed it with a second table, and the shadowed copy is the one that
  -- gets primed with this config while `apply_feature` -- which reads the upvalue --
  -- would have found empty. The two would then disagree about whether the user had
  -- said anything, which is a switch that works when written and not when read.
  local _, problems = Packages.load(config)
  for _, problem in ipairs(problems) do
    Host.core.log("cdin-x: %s", problem)
  end

  collect_provided()
  merge_sources()

  -- Now that the catalog exists, what the user wrote can be compared against what
  -- is actually there: a name that matches nothing is inert forever and otherwise
  -- says nothing at all. Reported, never applied and never fatal.
  for _, problem in ipairs(Packages.audit(Manager.available)) do
    Host.core.log("cdin-x: %s", problem)
  end

  -- And the sources themselves: a source that could not be resolved is a package
  -- that will never install, and the reason is a sentence about one entry rather
  -- than a name in the panel that never changes.
  for _, problem in ipairs(resolve_specs().problems) do
    Host.core.log("cdin-x: %s", problem)
  end

  -- A lock file that cannot be read is rebuilt from the editor's own record
  -- rather than left broken: it is a projection, and the thing it projects from
  -- is always there.
  local lock_data, lock_problems = Lock.load(config)
  if not lock_data then
    for _, problem in ipairs(lock_problems) do
      Host.core.log("cdin-x: %s", problem)
    end
    Host.core.log("cdin-x: rebuilding the lock from the recorded installs")
    local rebuilt = Lock.rebuild(ctx.state.lock, nil)
    local ok, err = Lock.write(config, rebuilt)
    if not ok then
      Host.core.error("cdin-x: could not write the lock: %s", tostring(err))
    end
  end

  -- A previous session may have cancelled its operations on the way out; the
  -- flags belong to the session, not the module, so they are reset with it. A
  -- poller thread that outlived unload keeps ticking harmlessly -- it runs the
  -- same tick function over whatever is queued now.
  ops_cancelled = false
  op_queue = {}
  op_active = nil

  local ok = Runtime.load_all(ctx, is_disabled)
  if not ok then
    bootstrapped = false
    return false
  end

  -- Rollbacks left pending by an interrupted update are confirmed for every
  -- package that just proved itself by loading.
  confirm_loaded()

  bootstrapped = true
  return true
end

-- ── catalog / listing ──────────────────────────────────────────────────

-- Which of the roots that hold installable extensions actually exist.
--
-- Named `roots`, not `sources`: Manager.sources is the name -> origin table
-- that merge_sources() keeps replacing, and a function by that name was
-- overwritten on the first scan.
function Manager.roots()
  local roots = current_roots()
  local builtin = 0
  for _, root in ipairs(roots.builtin or {}) do
    if Host.fs.is_dir(root) then builtin = builtin + 1 end
  end
  -- "is there a catalog at all", asked of `Registry.catalog_path` rather than of a
  -- filename. It used to hard-code `X/manifest.lua`, and a sparse clone carries
  -- `registry/generated/catalog.lua` and never materialises that one -- so the
  -- check reported "no catalog" about a clone that plainly had one. Phase 9
  -- removed the old name, and asking the module that owns the answer is what stops
  -- the next one from being hard-coded here.
  return {
    registry     = Registry.catalog_path(config) ~= nil,
    installed    = Host.fs.is_dir(roots.installed),
    store        = Host.fs.is_dir(config.store_dir),
    builtin      = builtin,
    registry_dir = config.registry_dir,
  }
end

-- ── fetching the catalog ───────────────────────────────────────────────

local catalog = { status = "idle", message = nil }

-- "idle" (never tried), "fetching", "ready" or "failed", plus the reason.
function Manager.catalog_state()
  return catalog.status, catalog.message
end

-- Ensures the registry clone and refreshes it to the branch head, without
-- blocking the editor. Returns true when the work started (or was already
-- running), false plus a reason when it could not. `on_done(ok, err)` runs
-- once, from the poller thread, when it ends.
--
-- The catalog is read out of the clone, so "fetch the catalog" means "move the
-- clone": clone on first use, fetch + checkout after that. One path for the
-- panel's bootstrap and its manual refresh, rather than a download for one and
-- git for the other.
function Manager.fetch_catalog(on_done)
  if catalog.status == "fetching" then return true end

  catalog.status, catalog.message = "fetching", nil
  local op = Transport.start_refresh()
  op_queue[#op_queue + 1] = {
    op = op,
    kind = "refresh",
    finalize = function(status, payload)
      if status == "done" then
        catalog.status, catalog.message = "ready", nil
        merge_sources()
      else
        catalog.status, catalog.message = "failed", payload
      end
      call_done(on_done, status == "done", payload)
    end,
  }
  ensure_poller()
  return true
end

function Manager.scan()
  return merge_sources()
end

function Manager.list()
  merge_sources()
  return Manager.available
end

function Manager.list_builtin()
  return Catalog.list_by_source(ctx, "builtin")
end

function Manager.list_local()
  merge_sources()
  return Catalog.list_by_source(ctx, "installed")
end

-- The packages the host loaded itself, plus everything the manager loaded.
--
-- No caller in either repository. Kept for the same reason as `get_locked_names`:
-- it is the answer to a question a caller will want, and it costs one line. Unlike
-- `Manager.installed` -- which is the same table -- it does not need the caller to
-- know which field of the facade is the live one.
function Manager.list_loaded()
  return Manager.installed
end

function Manager.search(query)
  merge_sources()
  return Catalog.search(ctx, query)
end

function Manager.get(name)
  merge_sources()
  return Manager.available[name]
end

--- The live context, for a caller that has to agree with the runtime about
--- something the runtime owns.
---
--- The panel needs this to read which features are *running*, which is not a
--- question the catalog can answer: `Features.active` consults the table the
--- runtime registers into, and there is exactly one of those. Handing it out is
--- better than having the panel build a context of its own, which would answer
--- about a session that is not running -- and would say so, confidently.
--- @return table
function Manager.context()
  return ctx
end

--- What a package's row should say, in the panel's own vocabulary.
---
--- `builtin` and `installed` answer the same question -- is it here, and is it on
--- -- so they share a branch. A build-shipped package is switched off through the
--- same state flag as an installed one, because since the kernel took ownership of
--- the shipped set it is switched off the same way: the host never sees it.
--- @param name string
--- @return string
function Manager.get_status(name)
  local plugin = Manager.available[name]
  if not plugin then return "missing" end
  if plugin._source == "provided" then return "provided" end
  -- The user's own working copy answers the same question as an install -- is it
  -- here, and is it on -- so it is grouped with installed rows, and the panel
  -- draws it where a person will look for it.
  if plugin._source == "builtin" or plugin._source == "installed"
    or plugin._source == "dev" then
    if is_disabled(name) then return "disabled" end
    return "installed"
  end
  return "available"
end

--- Whether a package is one the user cannot turn off.
---
--- Only `provided`: the host loaded that before cdin-x ran, so the manager never
--- did and cannot undo it. A `builtin` package used to be in this answer too, when
--- "builtin" meant "the host's bundled root, loaded unconditionally". Since a build
--- ships its packages under `data/packages/`, which the host does not read, that
--- is no longer true, and answering yes here would draw `vim` as permanently on
--- and refuse the one switch this architecture exists to offer.
--- @param name string
--- @return boolean
function Manager.is_locked(name)
  local plugin = Manager.available[name]
  if not plugin then return false end
  return plugin._source == "provided"
end

-- Where a package's README is, or nil.
--
-- Only `open_readme` calls this, and it calls it by name rather than inlining it,
-- because a path is the kind of answer a caller will want to show rather than open:
-- the panel's details row, a log line, a third-party panel. It is public for that
-- reason, not because two callers happen to exist today.
function Manager.get_readme(name)
  local plugin = Manager.available[name]
  if not plugin then return nil end
  -- A single-file package has no directory to hold one. Asking anyway would build
  -- `.../theme.lua/README.md`, which cannot exist, so the check is the answer rather
  -- than a precaution.
  if plugin._single_file then return nil end
  local path = Util.join(plugin._path, "README.md")
  if Host.fs.is_file(path) then return path end
  return nil
end

function Manager.open_readme(name)
  local plugin = Manager.available[name]
  if not plugin then return false, "unknown extension: " .. tostring(name) end

  -- `get_readme` is inlined rather than called, which looks like a missed
  -- abstraction and is actually the opposite: it is one line, it has exactly one
  -- caller, and calling across the facade for it would mean the path question --
  -- single-file or not -- is answered in two places.
  local path = Manager.get_readme(name)
  if path then
    Host.core.root_view:open_doc(Host.core.open_doc(path))
    return true
  end

  if plugin._single_file then
    Host.core.log("%s: %s", plugin.name or name, plugin.description or "(no description)")
    return true
  end

  return false, "README not found"
end

-- Every package the user has switched off, whatever its source.
--
-- This replaces `get_essential_names`, which collected `plugin.essential == true` --
-- a field that no package may declare any more (schema, validate and check all
-- refuse it, and there is no `essential` left anywhere to set). So the function
-- returned an empty list to every caller, permanently and without complaint. It
-- was one of three places still reading a field the architecture deleted.
--
-- What the panel wants to draw as "always on" is a *build* package: something the
-- bundle shipped, which is not removable and not switchable, because the host
-- loads it. That is `is_locked`, and it is what the panel already uses.
--
-- No caller: the panel asks `is_locked` per row rather than listing them once, and
-- a set of names it does not use is a second answer to a question that already has
-- one. Kept because it is the natural shape for a caller that does want the whole
-- list, and because the alternative -- removing it and having the next person
-- rebuild it from `is_locked` -- is more work than leaving one function.
--
-- Unlike `load_plugin` and `unload_plugin`, which cdin's own `test_workflows.lua`
-- calls, this one has no caller anywhere in either repository.
function Manager.get_locked_names()
  merge_sources()
  local names = {}
  for name in pairs(Manager.available) do
    if Manager.is_locked(name) then names[#names + 1] = name end
  end
  table.sort(names)
  return names
end

-- ── features ───────────────────────────────────────────────────────────

--- Turns one feature of a loaded package on or off, now.
--
--- The panel's switch. The flag is already written to `packages.lua` by the time
--- this is called; this is the part that makes the next frame reflect it, rather
--- than the next start.
--
--- A feature is only reachable while its package is loaded, because the package's
--- `init` is what puts in place whatever the feature sits on. So turning one on
--- requires the package to be up, and turning one off requires it to still be up.
-- Both are checked rather than assumed: a switch that appears to work on an
--- unloaded package is worse than one that says it cannot.
--- @param name string
--- @param key string
--- @param on boolean
--- @return boolean ok
--- @return string|nil err
function Manager.apply_feature(name, key, on)
  -- Re-read the catalog. The panel calls this against a name it saw in the list, and
  -- between that draw and this keypress the list may have been rebuilt -- a rescan
  -- after an install, or a refresh from the panel itself. Reading a stale
  -- `Manager.available` would answer about a package that is no longer there.
  merge_sources()

  local plugin = Manager.available[name]
  if not plugin then return false, "unknown extension: " .. name end

  local spec = plugin.spec
  if not spec or not Features.has_any(spec) then
    return false, name .. " has no features"
  end

  -- Refuse an unknown key rather than reporting success. The panel can only offer a
  -- declared feature, so this is a caller error -- and a feature that "turned off"
  -- without existing is exactly the kind of thing that is never noticed.
  local declared = false
  for _, f in ipairs(Features.declared(spec)) do
    if f.key == key then declared = true break end
  end
  if not declared then
    local available = {}
    for _, f in ipairs(Features.declared(spec)) do available[#available + 1] = f.key end
    table.sort(available)
    return false, string.format("%s has no feature %q; it has %s", name, key,
      #available > 0 and table.concat(available, ", ") or "none")
  end

  if not ctx.installed[name] then
    if on then
      return false, name .. " is not loaded, so its features cannot be switched on"
    end
    -- Off, and it is already not running: the switch has nothing to undo and the
    -- answer is the one the user wanted.
    return true
  end

  if on then
    -- Enable needs the package's merged options, which is what `apply` would have
    -- passed. Recomputing here is deliberate rather than a shortcut: the options
    -- are `spec.options` plus the user's overrides, and Features owns that merge.
    local options = Features.options(spec, Packages.feature_overrides(name))
    local mod, err = Features.enable(ctx, name, key, options)
    if not mod then return false, err end
    return true
  end

  local ok, err = Features.disable(ctx, name, key)
  if not ok then return false, err end
  return true
end

-- ── runtime (load/unload) ──────────────────────────────────────────────

function Manager.load_plugin(name)
  return Runtime.load_plugin(ctx, name)
end

function Manager.unload_plugin(name)
  return Runtime.unload_plugin(ctx, name)
end

--- The counterpart of `bootstrap`: unloads every package this manager loaded.
---
--- The host calls it when the kernel entry point is unloaded, which is
--- `core:unload-plugin("cdin-x")`. After it returns, nothing the manager put up
--- is still up: the packages are down, the searcher has forgotten them, and the
--- boot flag is clear so a later `init` starts from nothing rather than from a
--- half-torn-down state.
---
--- Sorted names, not `pairs` order: the teardown order is observable in the log,
--- and a teardown that reads differently on two runs of the same tree is one
--- nobody can reason about. Packages go in the reverse of load order, which is
--- the only order that is right when one depends on another.
--- @return boolean ok
--- @return string|nil err
function Manager.unload_all()
  if not bootstrapped then return true end

  -- Operations in flight are cancelled first: their completion callbacks only
  -- log, so dropping them is safe, and a poller that outlives the session would
  -- keep touching a context nobody owns.
  ops_cancelled = true
  op_queue = {}
  if op_active then op_active.op.cancelled = true end

  local names = {}
  for name in pairs(ctx.installed) do names[#names + 1] = name end
  table.sort(names)

  local problems = {}
  for i = #names, 1, -1 do
    local name = names[i]
    local ok, err = pcall(Runtime.unload_plugin, ctx, name)
    if not ok then
      problems[#problems + 1] = string.format("%s: %s", name, tostring(err))
    end
  end

  ctx.installed = {}
  ctx.active_with = {}
  bootstrapped = false

  for _, problem in ipairs(problems) do
    Host.core.error("cdin-x: unload %s", problem)
  end
  if #problems > 0 then return false, problems[1] end
  return true
end

-- ── background operations ────────────────────────────────────────────
--
-- Installing and updating touch the network, so they run as operations: a queue
-- of transport jobs advanced by one poller thread, one package at a time. (The
-- queue itself is declared at the top of this file, next to the other session
-- state, because bootstrap resets it and lexically-later locals are globals to
-- lexically-earlier functions.)
--- A snapshot of everything in flight, for the panel.
--- @return table[]  { name, kind, status, progress }, sorted by name
function Manager.operations()
  local out = {}
  local function add(op, kind)
    if op and op.status == "running" then
      out[#out + 1] = { name = op.name, kind = kind or op.kind,
        status = op.status, progress = op.progress }
    end
  end
  if op_active then add(op_active.op, op_active.kind) end
  for _, item in ipairs(op_queue) do add(item.op, item.kind) end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

--- The progress line for `name`, or nil when nothing is running for it.
--- @param name string
--- @return string|nil
function Manager.operation_status(name)
  if op_active and op_active.op.name == name and op_active.op.status == "running" then
    return op_active.op.progress
  end
  for _, item in ipairs(op_queue) do
    if item.op.name == name and item.op.status == "running" then
      return "queued"
    end
  end
  return nil
end

--- The lock entry for `name`, for the panel's size and source display.
--- @param name string
--- @return table|nil
function Manager.lock_info(name)
  local lock = ctx.state.lock and ctx.state.lock[name]
  if type(lock) ~= "table" then return nil end
  return lock
end

--- The whole installed store's selected bytes, for the panel total.
--- @return integer bytes
function Manager.store_bytes()
  local total = 0
  for _, lock in pairs(ctx.state.lock or {}) do
    if type(lock) == "table" then total = total + (tonumber(lock.bytes) or 0) end
  end
  return total
end

--- Bytes as a person reads them. The transport owns the spelling; the panel
--- reaches it through here so there is one way to ask.
--- @param bytes number|nil
--- @return string
function Manager.human_size(bytes)
  return Transport.human(bytes)
end

--- Writes the lock entry a transport result carries, and saves the state.
---
--- The lock is the reproducibility record: source, ref, rev, version, subdir and
--- the selected file count and byte total. A commit hash authenticates the tree,
--- so no separate archive hash exists. `version` and `installed_at` stay because
--- older readers -- and the panel -- know those two.
local function record_lock(name, result)
  ctx.state.lock[name] = {
    version = result.version or "",
    installed_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    source = result.source,
    url = result.url,
    ref = result.ref,
    rev = result.rev,
    subdir = result.subdir,
    files = result.files,
    bytes = result.bytes,
  }
  save_state()
  -- The lock file is the reviewable projection of that record, so it is written
  -- in the same breath. A failure here is logged rather than raised: the install
  -- succeeded, the state file has it, and the next boot rebuilds the projection.
  local ok, err = Lock.record(config, name, result)
  if not ok then
    Host.core.error("cdin-x: could not write the lock: %s", tostring(err))
  end
end

--- Loads what staging just put on disk, and settles the update.
---
--- Shared by the install and update finalizers because the tail is the same:
--- merge, load unless it is a theme or switched off, and on a failed load after
--- an update put the old tree back and say so loudly. Returns true when the
--- package is up.
local function settle_staged(name, is_theme)
  merge_sources()
  if is_theme then return true end
  if is_disabled(name) then return true end
  local loaded, load_err = Runtime.load_plugin(ctx, name)
  if loaded then
    Transport.confirm(config, name)
    return true
  end
  if Transport.pending(config, name) then
    -- The swap happened and the new tree does not run: put the old one back,
    -- and keep prev_rev in the lock so the next update knows what was running.
    Host.core.error("cdin-x: %s failed to load after update: %s", name, tostring(load_err))
    local ok, rerr = Transport.rollback(config, name)
    merge_sources()
    if ok then
      local reloaded, rload_err = Runtime.load_plugin(ctx, name)
      if reloaded then
        Transport.confirm(config, name)
        Host.core.error("cdin-x: %s restored to the previous version", name)
      else
        Host.core.error("cdin-x: %s restored on disk but does not load: %s",
          name, tostring(rload_err))
      end
    else
      Host.core.error("cdin-x: %s could not be restored: %s", name, tostring(rerr))
    end
    local lock = ctx.state.lock[name]
    if type(lock) == "table" then
      lock.prev_rev = lock.rev
      save_state()
    end
    return false, load_err
  end
  return false, load_err
end

--- Where `name` would come from if it needs the network, or nil when it would
--- not: already installed, built in, provided, a dev directory, or materialised
--- on disk.
local function network_origin(name, plugin)
  if not plugin then return nil end
  if plugin._source == "installed" or plugin._source == "builtin"
     or plugin._source == "provided" or plugin._source == "dev" then
    return nil
  end
  -- Registry-listed but not on disk: shallow-clone the registry and take the
  -- subdir the catalog names. The subdir the lock remembers wins when there is
  -- one, because the catalog describes the tree and the lock describes this
  -- install. Otherwise it is the catalog root plus the path below it: `_relpath`
  -- alone is store-relative ("demo"), and the clone needs repo-relative
  -- ("packages/demo").
  local lock = ctx.state.lock[name]
  local subdir = (type(lock) == "table" and lock.subdir) or ""
  if subdir == "" and plugin._source_root and plugin._relpath then
    subdir = plugin._source_root .. "/" .. plugin._relpath
  elseif subdir == "" then
    subdir = plugin._relpath or ""
  end
  if type(subdir) ~= "string" then subdir = "" end
  return { kind = "registry", subdir = subdir }
end

--- The missing `depends` of `name` from the catalog, in dependency order.
---
--- Only names the catalog knows: a dependency that needs the network is itself a
--- unit below, and one the catalog does not know at all is a failure that names
--- it. Cycles fail naming the loop rather than recursing forever.
local function dep_units(name, seen, visiting, out)
  if seen[name] then return true end
  if visiting[name] then
    return false, "dependency cycle: " .. name
  end
  visiting[name] = true
  local plugin = ctx.available[name]
  local deps = (plugin and plugin.dependencies) or {}
  for _, dep in ipairs(deps) do
    if not seen[dep] and not ctx.installed[dep] then
      local ok, err = dep_units(dep, seen, visiting, out)
      if not ok then return false, err end
    end
  end
  visiting[name] = nil
  seen[name] = true
  out[#out + 1] = name
  return true
end

--- Enqueues one transport unit per missing package, dependencies first.
local function enqueue_units(names, is_update, on_done, state)
  state = state or { errors = {}, updated = {} }
  -- Resolve everything before staging anything: a unit that cannot be sourced
  -- fails the operation before the first clone, not after the third.
  local seen, ordered = {}, {}
  for _, name in ipairs(names) do
    local ok, err = dep_units(name, seen, {}, ordered)
    if not ok then
      call_done(on_done, false, err)
      return false
    end
  end

  local units = {}
  for _, name in ipairs(ordered) do
    local plugin = ctx.available[name]
    if not plugin then
      local advice = Moved.advice(name)
      call_done(on_done, false, advice or ("extension not found in catalog: " .. name))
      return false
    end
    -- Already running, or built in, or provided: nothing to stage. Everything
    -- else becomes a unit -- from the network when it must, from disk when it
    -- is already here.
    local needs_staging = not (ctx.installed[name] and not is_update)
      and plugin._source ~= "builtin" and plugin._source ~= "provided"
    if needs_staging then
      local origin = network_origin(name, plugin)
      if not origin and not plugin._path then
        call_done(on_done, false, "no files on disk for '" .. name .. "'")
        return false
      end
      units[#units + 1] = { name = name, origin = origin, plugin = plugin }
    end
  end

  if #units == 0 then
    call_done(on_done, true, state)
    return true
  end

  -- Units already on disk take the synchronous path inline: copying local files
  -- needs no job, and doing it here keeps the queue for work that does. The rest
  -- become transport operations, polled in order.
  local remote = {}
  for _, unit in ipairs(units) do
    if unit.origin == nil then
      local ok, result = Lifecycle.install(ctx, config, unit.name,
        Manager.ensure_registry, save_state)
      if not ok then
        state.errors[#state.errors + 1] = unit.name .. ": " .. tostring(result)
      else
        state.updated[#state.updated + 1] = unit.name
      end
    else
      remote[#remote + 1] = unit
    end
  end

  if #remote == 0 then
    merge_sources()
    call_done(on_done, #state.errors == 0, state)
    return true
  end

  state.pending = #remote
  for _, unit in ipairs(remote) do
    local op = Transport.start(unit.name, unit.origin, { update = is_update })
    if is_update then op.known_version = unit.plugin.version end
    op_queue[#op_queue + 1] = {
      op = op,
      kind = is_update and "update" or "install",
      finalize = function(status, payload)
        if status ~= "done" then
          state.errors[#state.errors + 1] = unit.name .. ": " .. tostring(payload)
        else
          record_lock(payload.name, payload)
          local is_theme = (ctx.available[payload.name] and
            ctx.available[payload.name].type == "theme") or unit.plugin.type == "theme"
          local ok, err = settle_staged(payload.name, is_theme)
          if ok then
            state.updated[#state.updated + 1] = payload.name
            Host.core.log("cdin-x: %s %s %s (%s, %s)",
              is_update and "updated" or "installed", payload.name,
              payload.version ~= "" and payload.version or payload.rev,
              payload.url or "registry", Transport.human(payload.bytes))
          else
            state.errors[#state.errors + 1] = unit.name .. ": " .. tostring(err)
          end
        end
        state.pending = state.pending - 1
        if state.pending == 0 then
          merge_sources()
          call_done(on_done, #state.errors == 0, state)
        end
      end,
    }
  end
  ensure_poller()
  return true
end

--- Installs `name` without blocking the editor.
---
--- Starts a background operation and returns immediately; `on_done(ok, result)`
--- runs from the poller thread when it ends. Packages that need no network take
--- the synchronous path inline and `on_done` still runs before this returns, so a
--- caller never has to know which one it was.
--- @param name string
--- @param on_done fun(ok: boolean, result: any)|nil
--- @return boolean started
--- @return string|nil err
function Manager.install_async(name, on_done)
  merge_sources()
  local plugin = ctx.available[name]
  if not plugin then
    local advice = Moved.advice(name)
    local err = advice or ("extension not found in catalog: " .. name)
    call_done(on_done, false, err)
    return false, err
  end
  if plugin._source == "builtin" then
    call_done(on_done, true, "already built-in")
    return true
  end
  if plugin._source == "provided" then
    call_done(on_done, true, "provided by the editor")
    return true
  end
  -- The user's own working copy is already what runs; there is nothing to fetch
  -- and nothing to copy, so the only honest answer is that it is in place.
  if plugin._source == "dev" then
    local loaded, err = Runtime.load_plugin(ctx, name)
    call_done(on_done, loaded, loaded and (plugin._spec.dir or "using your own copy") or err)
    return loaded, loaded and nil or err
  end
  if plugin._source == "installed" then
    local ok, err = Lifecycle.install(ctx, config, name, Manager.ensure_registry, save_state)
    call_done(on_done, ok, ok and "already installed" or err)
    return ok, err
  end
  -- A recipe is a third-party repository the registry index vetted, so it is
  -- installed the way one is -- by cloning -- rather than like a registry
  -- package, which would look for a subdir of this repository that does not exist.
  if plugin._source == "recipe" and plugin._spec then
    return Manager.stage_source(plugin._spec, on_done)
  end
  -- Anything else needs the network: resolve the closure, then stage it in the
  -- background, dependencies first.
  return enqueue_units({ name }, false, on_done)
end

--- Stages one already-resolved git spec, without waiting for it.
---
--- The seam between "something the user wrote" and "something we know where to
--- fetch": `install_source_async` parses an entry and calls this, and so does a
--- recipe from the registry index, whose spec `Source.parse` would refuse because
--- it is already a spec. One staging path, two callers, rather than two copies of
--- the queue plumbing that have to stay in step.
--- @param spec table  a `Source.parse` result, or `Spec.from_recipe`'s
--- @param on_done fun(ok: boolean, result: any)|nil
--- @return boolean started
--- @return string|nil err
function Manager.stage_source(spec, on_done)
  if type(spec) ~= "table" or spec.kind ~= "git" then
    local err = "not a git source"
    call_done(on_done, false, err)
    return false, err
  end
  local label = spec.name or spec.short or spec.url
  local op = Transport.start(label, { kind = "git", spec = spec }, {})
  op_queue[#op_queue + 1] = {
    op = op,
    kind = "install",
    finalize = function(status, payload)
      if status ~= "done" then
        call_done(on_done, false, payload)
        return
      end
      record_lock(payload.name, payload)
      local loaded, load_err = settle_staged(payload.name, false)
      if loaded then
        Host.core.log("cdin-x: installed %s %s (%s, %s)", payload.name,
          payload.version ~= "" and payload.version or payload.rev,
          payload.url, Transport.human(payload.bytes))
      end
      merge_sources()
      call_done(on_done, loaded, loaded and payload or load_err)
    end,
  }
  ensure_poller()
  return true
end

--- Installs a third-party source directly, without waiting for it.
---
--- `entry` is anything Source.parse takes: `"owner/repo"`, `{ "owner/repo",
--- rev = ... }`, `{ git = ..., subdir = ... }`, `{ dir = "~/src/x" }`. The package
--- name comes from its own `package.lua` unless `entry.name` says otherwise. A
--- `dir` source is used in place rather than copied: that is the whole point of
--- one, and a copy would be `install_local` under another name.
--- @param entry any
--- @param on_done fun(ok: boolean, result: any)|nil
--- @return boolean started
--- @return string|nil err
function Manager.install_source_async(entry, on_done)
  local spec, err = Source.parse(entry, home_dir())
  if not spec then
    call_done(on_done, false, err)
    return false, err
  end
  if spec.kind == "dir" then
    return Manager.use_dir(spec.dir, on_done)
  end
  return Manager.stage_source(spec, on_done)
end

--- Uses a directory as a package, in place.
---
--- No clone, no copy, no lock entry with a commit: the package *is* the
--- directory, so an edit in it is the next reload. That is the difference from
--- `install_local`, which snapshots the same directory into the store and is
--- right when the directory is a release and wrong when it is a working copy.
---
--- The package is loaded from the directory for the rest of the session, which is
--- why the store is not involved at all: `Runtime` reads the package root out of
--- the catalog, and the catalog entry for a dev source carries the directory.
--- @param dir string
--- @param on_done fun(ok: boolean, result: any)|nil
--- @return boolean started
--- @return string|nil err
function Manager.use_dir(dir, on_done)
  if type(dir) ~= "string" or dir == "" then
    local err = "no directory given"
    call_done(on_done, false, err)
    return false, err
  end
  if not Host.fs.is_dir(dir) then
    local err = dir .. " is not a directory"
    call_done(on_done, false, err)
    return false, err
  end

  -- The name comes from the package's own manifest, read through the sandbox: a
  -- directory called `thing` holding a package called `other` is `other`.
  local meta, meta_err = Manifest.load(dir)
  if not meta then
    call_done(on_done, false, tostring(meta_err))
    return false, meta_err
  end
  local name = meta.name
  if not name or name == "" then
    local err = dir .. " has a package.lua with no name"
    call_done(on_done, false, err)
    return false, err
  end

  -- Recorded as a dev source so `Manager.update` and the panel can say "your own
  -- copy" instead of an installed version, and so a later `uninstall` knows the
  -- difference between forgetting a directory and deleting a store tree.
  ctx.state.lock[name] = {
    version = meta.version or "",
    installed_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    source = "dir",
    dir = dir,
  }
  save_state()
  Lock.forget(config, name)

  -- Registering the source is what makes the catalog know about the directory, so
  -- the rescan happens before the load rather than after it.
  Packages.sources()[name] = { dir = dir }
  Manager.rescan()

  if is_disabled(name) then
    call_done(on_done, true, dir)
    return true
  end
  local is_theme = (ctx.available[name] and ctx.available[name].type == "theme") or false
  local loaded, load_err = settle_staged(name, is_theme)
  if not loaded then
    call_done(on_done, false, load_err)
    return false, load_err
  end
  Host.core.log("cdin-x: using %s from %s", name, dir)
  call_done(on_done, true, dir)
  return true
end

function Manager.install(name)
  merge_sources()
  local plugin = ctx.available[name]
  if not plugin then
    local advice = Moved.advice(name)
    if advice then return false, advice end
    return false, "extension not found in catalog: " .. name
  end
  -- A dev directory is the answer, not a step towards one: there is nothing to
  -- fetch and nothing to copy. Saying that is the whole response.
  if plugin._source == "dev" then
    local dir = (plugin._spec and plugin._spec.dir) or "your own copy"
    local loaded, load_err = Runtime.load_plugin(ctx, name)
    if not loaded and not is_disabled(name) then
      return false, "using " .. dir .. ": " .. tostring(load_err)
    end
    return true, dir
  end
  -- The synchronous entry point only serves what needs no network. Anything
  -- listed-but-not-materialised goes through install_async, because the staging
  -- is a detached job chain and there is nothing to wait on without blocking.
  if network_origin(name, plugin) then
    -- Naming the source, when there is one, is the difference between a dead end
    -- and a next step. A dependency reached from `install_local` lands here, and
    -- "it is not on disk" with no URL is the answer that costs an afternoon.
    local spec = resolve_specs().effective[name]
    if spec and spec.kind == "git" then
      return false, string.format(
        "%s is not on disk and is not part of the editor; it comes from %s. "
        .. "Install it from the Extensions panel first -- this call cannot fetch",
        name, tostring(spec.short or spec.url))
    end
    return false, name .. " is not on disk; install it from the Extensions panel"
  end
  local ok, result, plugin_type =
    Lifecycle.install(ctx, config, name, Manager.ensure_registry, save_state)
  if not ok then return false, result end
  merge_sources()
  if result == "copied" and plugin_type ~= "theme" then
    local loaded, load_err = Runtime.load_plugin(ctx, name)
    if not loaded then return false, "installed but load failed: " .. tostring(load_err) end
  end
  return true
end

function Manager.install_local(path)
  local ok, meta_or_err = Lifecycle.install_local(ctx, config, path, Manager.install, save_state)
  if not ok then return false, meta_or_err end
  merge_sources()
  local meta = meta_or_err
  if meta.type ~= "theme" then
    local loaded, load_err = Runtime.load_plugin(ctx, meta.name)
    if not loaded then return false, "installed but load failed: " .. tostring(load_err) end
  end
  return true
end

--- Settles one finished update unit: version gate for registry units, then the
--- shared load-or-rollback tail.
---
--- Declared before `update_async` because the finalizers it builds close over it,
--- and a local declared later is a global to them -- which luacheck catches and
--- the runtime would answer with nil.
local function finish_update_unit(unit, status, payload, finish_unit)
  if status ~= "done" then
    finish_unit(unit, false, payload)
    return
  end
  -- The transport skips the swap when the staged version matches what is on
  -- disk, and says so in the result: nothing changed, so there is nothing to
  -- load, no lock to write, and the only honest report is "up to date".
  if payload.updated == false then
    Host.core.log("cdin-x: %s is already up to date", unit.name)
    finish_unit(unit, true, nil)
    return
  end
  record_lock(payload.name, payload)
  local was_loaded = ctx.installed[payload.name] ~= nil
  if was_loaded then
    Runtime.unload_plugin(ctx, payload.name)
  end
  local ok, err = settle_staged(payload.name, false)
  if ok then
    Host.core.log("cdin-x: updated %s %s (%s, %s)", payload.name,
      payload.version ~= "" and payload.version or payload.rev,
      payload.url or "registry", Transport.human(payload.bytes))
  end
  -- On failure settle_staged already restored `.old` and recorded prev_rev; the
  -- error just needs carrying.
  finish_unit(unit, ok, ok and payload or err)
end

--- Whether `name` is a retired legacy install, looked up fresh.
local function Legacy_retired(name)
  local retired = ctx.retired
  return type(retired) == "table" and retired[name] ~= nil
end

--- Updates installed packages without blocking the editor.
---
--- `name` or nil for everything installed. A package whose source the lock
--- remembers is checked with `ls-remote` first and cloned only when the ref
--- moved; a first-party package is compared against a fresh registry clone's
--- version instead, because there is no ref to ask about. A tag that moved is
--- reported and never followed. `on_done(ok, { updated, errors })` runs from the
--- poller thread when the last unit settles.
--- @param name string|nil
--- @param on_done fun(ok: boolean, result: any)|nil
--- @return boolean started
--- @return string|nil err
function Manager.update_async(name, on_done)
  merge_sources()

  local resolved = resolve_specs()
  local targets = {}
  if name then
    targets = { name }
  else
    -- A dev directory is excluded by construction: `Catalog` gives it
    -- `_source = "dev"`, so it is never in the installed set this loop reads.
    for n, plugin in pairs(ctx.available) do
      if plugin._source == "installed" then targets[#targets + 1] = n end
    end
    table.sort(targets)
  end

  local state = { errors = {}, updated = {} }

  -- Resolve everything before staging anything, as with install: a unit that
  -- cannot be sourced fails the operation before the first clone.
  local units = {}
  for _, target in ipairs(targets) do
    local plugin = ctx.available[target]
    if not plugin or plugin._source ~= "installed" then
      state.errors[#state.errors + 1] = target .. ": not installed"
    elseif Legacy_retired(target) then
      -- A superseded copy is skipped, not updated: its replacement is already
      -- the thing that loads, and fetching a newer copy of the old one would
      -- reinstall the competition the retirement just removed.
      Host.core.log("cdin-x: skipping update of %s: superseded", target)
    else
      local lock = ctx.state.lock[target]
      local source = type(lock) == "table" and lock.source or nil
      local spec = resolved.effective[target]
      if source == "git" then
        -- Which ref to ask about, decided once and here, from the source the user
        -- wrote rather than from what the lock remembers.
        --
        -- `lock.ref` is what was *resolved* last time, and for a package installed
        -- from a commit that is the commit itself -- so falling back to it would
        -- ask the remote for a ref named after a commit, which is not a thing a
        -- server has. That is not hypothetical: it is every recipe and every
        -- 40-hex `rev`, and the answer it produced was "ref abc123… is gone".
        local check_ref = nil
        local pinned = false
        if spec and spec.kind == "git" then
          check_ref = spec.ref
          pinned = Spec.is_pinned(spec)
        elseif type(lock.ref) == "string" and lock.ref ~= "" then
          check_ref = lock.ref
          pinned = lock.ref:match("^%x+$") ~= nil and #lock.ref == 40
        end
        if pinned then
          Host.core.log("cdin-x: skipping update of %s: it is pinned to a commit%s",
            target, spec and spec.ref and (" (" .. tostring(spec.ref):sub(1, 12) .. "…)")
              or (type(lock.ref) == "string" and lock.ref ~= ""
                and (" (" .. lock.ref:sub(1, 12) .. "…)") or ""))
        else
          units[#units + 1] = { name = target, check = true, lock = {
            url = (spec and spec.url) or lock.url,
            ref = check_ref,
            rev = lock.rev,
          } }
        end
      else
        -- First-party (or an old install with no lock): the version in a fresh
        -- registry clone decides. Compared after the clone lands, not before,
        -- because there is no ref to ask about without one.
        local subdir = (type(lock) == "table" and lock.subdir)
          or plugin._relpath or ""
        units[#units + 1] = {
          name = target, check = false,
          origin = { kind = "registry", subdir = type(subdir) == "string" and subdir or "" },
          version = plugin.version or "",
        }
      end
    end
  end

  if #units == 0 then
    call_done(on_done, #state.errors == 0, state)
    return true
  end

  state.pending = #units
  local function finish_unit(unit, ok, info)
    if ok and info then
      state.updated[#state.updated + 1] = unit.name
    elseif info then
      state.errors[#state.errors + 1] = unit.name .. ": " .. tostring(info)
    end
    state.pending = state.pending - 1
    if state.pending == 0 then
      merge_sources()
      call_done(on_done, #state.errors == 0, state)
    end
  end

  for _, unit in ipairs(units) do
    if unit.check then
      local op, err = Transport.start_check(config, unit.name, unit.lock)
      if not op then
        finish_unit(unit, false, err)
      else
        op_queue[#op_queue + 1] = {
          op = op,
          kind = "check",
          check = true,
          finalize = function(status, payload)
            if status ~= "done" then
              finish_unit(unit, false, payload)
            elseif not payload.update then
              Host.core.log("cdin-x: %s is already up to date", unit.name)
              finish_unit(unit, true, nil)
            else
              -- The ref moved: stage the new commit as an update unit, chained
              -- behind this check rather than beside it. An update must not skip
              -- the swap on a matching version when the commit moved: the check
              -- already proved the ref points somewhere new, and "1.2.0 became
              -- 1.2.0 again" is a release that was reverted, which is exactly when
              -- the files have to change. So no known version is set on this op.
              local uop = Transport.start(unit.name, {
                kind = "git",
                spec = {
                  kind = "git",
                  url = unit.lock.url,
                  ref = payload.remote,
                  ref_kind = "sha",
                  subdir = unit.lock.subdir,
                  name = unit.name,
                },
              }, { update = true })
              op_queue[#op_queue + 1] = {
                op = uop,
                kind = "update",
                finalize = function(st, res)
                  finish_update_unit(unit, st, res, finish_unit)
                end,
              }
              state.pending = state.pending + 1
              ensure_poller()
            end
          end,
        }
      end
    else
      local op = Transport.start(unit.name, unit.origin, { update = true })
      -- The version remembered decides after the manifest is read: stash the
      -- check on the op and let the finalizer compare before swapping.
      op.known_version = unit.version
      op_queue[#op_queue + 1] = {
        op = op,
        kind = "update",
        finalize = function(status, payload)
          finish_update_unit(unit, status, payload, finish_unit)
        end,
      }
    end
  end
  ensure_poller()
  return true
end

--- Puts every locked package back at exactly the commit the lock names.
---
--- The answer to a wiped store, a new machine, or a repository that has moved on
--- since: not "the newest thing" but "the thing this project is pinned to". It
--- is the reason the lock exists, so it is a plain loop over the file rather than
--- anything clever -- every entry becomes one transport operation, exactly the
--- kind an update stage already is, and the queue does the rest.
---
--- Two kinds of entry, treated the same way:
---
---   git       clone at the locked commit. A commit is served by `init` + `fetch
---             <sha>` + `checkout`, so a repository that no longer has the tag
---             still restores.
---   registry  the commit is one in *this* repository, and the persistent clone is
---             shallow -- it holds the branch head and nothing else. So restoring a
---             first-party package at an older commit needs that commit fetched
---             first, which the transport cannot do to a checkout it does not own.
---             Those entries are reported as needing a refresh rather than
---             silently restoring the head instead: a restore that quietly gives
---             you a different commit is worse than one that says it cannot.
---
--- A `dir` entry is not restored -- there is nothing to restore. It is reported as
--- skipped, because "my working copy is fine" is not something the user needs to
--- be told, and "it was not restored" is.
--- @param name string|nil  one package, or nil for everything in the lock
--- @param on_done fun(ok: boolean, result: any)|nil
--- @return boolean started
--- @return string|nil err
function Manager.restore_async(name, on_done)
  local data = Lock.load(config)
  if not data then
    local err = "cdin-x.lock is unreadable; it is rebuilt on the next start"
    call_done(on_done, false, err)
    return false, err
  end

  local targets = {}
  if name then
    if data.packages[name] == nil then
      local err = name .. " is not in cdin-x.lock"
      call_done(on_done, false, err)
      return false, err
    end
    targets = { name }
  else
    for n in pairs(data.packages) do targets[#targets + 1] = n end
    table.sort(targets)
  end

  local state = { restored = {}, skipped = {}, errors = {} }
  local units = {}
  for _, target in ipairs(targets) do
    local entry = data.packages[target]
    if entry.source == "dir" then
      state.skipped[#state.skipped + 1] = target .. ": your own directory"
    elseif entry.source == "registry" then
      local registry_rev = data.registry
      if type(registry_rev) == "string" and registry_rev ~= "" then
        state.skipped[#state.skipped + 1] = string.format(
          "%s: the registry moved to %s since it was locked; "
          .. "run cdin-x:update to follow it, or restore it from a checkout of %s",
          target, registry_rev:sub(1, 12), registry_rev:sub(1, 12))
      else
        state.skipped[#state.skipped + 1] = string.format(
          "%s: the lock says which registry commit, and the clone is shallow", target)
      end
    elseif type(entry.url) == "string" and type(entry.rev) == "string"
      and entry.rev ~= "" then
      units[#units + 1] = { name = target, entry = entry }
    else
      state.errors[#state.errors + 1] = target .. ": no url and no commit to restore from"
    end
  end

  if #units == 0 then
    call_done(on_done, #state.errors == 0, state)
    return true
  end

  merge_sources()
  state.pending = #units
  for _, unit in ipairs(units) do
    local entry = unit.entry
    -- An already-installed package is restored as an update, so the swap keeps
    -- `.old` and a package that fails to load rolls itself back. A package that is
    -- not on disk is restored as an install, which is the new-machine case.
    local installed = ctx.state.lock[unit.name] ~= nil
      and Transport.installed_path(config, unit.name) ~= nil
    local op = Transport.start(unit.name, {
      kind = "git",
      spec = {
        kind = "git",
        url = entry.url,
        ref = entry.rev,
        ref_kind = "sha",
        subdir = entry.subdir or "",
        name = unit.name,
      },
    }, { update = installed })
    op_queue[#op_queue + 1] = {
      op = op,
      kind = installed and "update" or "install",
      finalize = function(status, payload)
        if status ~= "done" then
          state.errors[#state.errors + 1] = unit.name .. ": " .. tostring(payload)
        else
          record_lock(payload.name, payload)
          local loaded, load_err = settle_staged(payload.name, false)
          if loaded then
            state.restored[#state.restored + 1] = unit.name
            Host.core.log("cdin-x: restored %s at %s", payload.name,
              tostring(payload.rev):sub(1, 12))
          else
            state.errors[#state.errors + 1] = unit.name .. ": " .. tostring(load_err)
          end
        end
        state.pending = state.pending - 1
        if state.pending == 0 then
          merge_sources()
          call_done(on_done, #state.errors == 0, state)
        end
      end,
    }
  end
  ensure_poller()
  return true
end

--- Removes an installed package and the store tree behind it.
---
--- @param name string
--- @return boolean ok
--- @return string|nil err
--- The whole diagnostic report, as a list of named checks.
---
--- Nothing here fetches, writes or repairs: a diagnostic that changes the state it
--- is diagnosing cannot be trusted to report on it, so "the registry is stale" is
--- an answer and the fetch is the user's to run. The same function backs
--- `:cdin-x:doctor`, `cdin-x doctor` and CI, which is what keeps the three from
--- disagreeing about whether an installation is sound.
--- @return table[] checks
function Manager.doctor()
  return require("cdinx.manager.doctor").run(config, ctx)
end

--- Gives up on everything in flight, releasing what each operation was holding.
---
--- For a caller that is about to stop existing -- the command line, on any exit
--- path, including one that gave up mid-operation. An abandoned operation that
--- keeps its lock makes the *next* run refuse to do anything for `LOCK_TIMEOUT`, so
--- "the last run was interrupted" would become "this installation is broken for ten
--- minutes", which is a much worse thing to hand someone than a cancelled job.
---
--- Not `unload_all`: that also unloads every package, which is right when the editor
--- is going away and wrong for a process that was never running them.
function Manager.abandon_all()
  for _, item in ipairs(op_queue) do
    Transport.abandon(config, item.op)
  end
  op_queue = {}
  if op_active then
    Transport.abandon(config, op_active.op)
    op_active = nil
  end
end

function Manager.clean(dry_run)
  merge_sources()
  local ok, result = Lifecycle.clean(ctx, user_extensions_root(),
    Registry.registry_root(config), dry_run)
  if dry_run then return ok, result end
  save_state()
  merge_sources()
  return ok, result
end

--- Removes a package, and everything cdin-x recorded about it.
---
--- A dev directory is refused rather than deleted: it is the user's own working
--- copy, they own those files, and no amount of "remove" makes cdin-x the thing
--- that should delete them. What it can do is forget the source, which is what
--- `and_source` is for. A third-party install drops its lock entry here too, so
--- the lock never names a package that is not on disk.
--- @param name string
--- @param and_source boolean|nil  also forget the `sources` entry
--- @return boolean ok
--- @return string|nil err
function Manager.remove(name, and_source)
  merge_sources()
  local plugin = ctx.available[name]
  if plugin and plugin._source == "dev" then
    if not and_source then
      return false, string.format(
        "%s is your own directory (%s); nothing was deleted. Pass and_source to "
        .. "forget it, which rewrites packages.lua",
        name, (plugin._spec and plugin._spec.dir) or "a dev source")
    end
    -- Unloaded first, while the catalog still says where it is: after the source
    -- is forgotten the package is nothing, and unloading nothing leaves its
    -- commands and keys registered with no way left to name it.
    Runtime.unload_plugin(ctx, name)
    Packages.forget_source(name)
    local written, write_err = Packages.write(config)
    if not written then
      return false, "could not rewrite packages.lua: " .. tostring(write_err)
    end
    Manager.rescan()
    return true
  end

  local ok, err = Lifecycle.uninstall(ctx, name, save_state)
  if not ok then return false, err end
  Lock.forget(config, name)
  if and_source and Packages.forget_source(name) then
    local written, write_err = Packages.write(config)
    if not written then
      return false, "removed, but packages.lua could not be rewritten: "
        .. tostring(write_err)
    end
  end
  Manager.rescan()
  return true
end

function Manager.enable(name)
  return Lifecycle.enable(ctx, name, save_state)
end

function Manager.disable(name)
  return Lifecycle.disable(ctx, name, save_state)
end

--- `remove` under its older name, kept because the panel's uninstall key and the
--- documented API both say `uninstall`. One function, one name inside.
--- @param name string
--- @return boolean ok
--- @return string|nil err
function Manager.uninstall(name)
  return Manager.remove(name, false)
end

return Manager
