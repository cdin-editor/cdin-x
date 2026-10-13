-- Putting a package on disk from git, without blocking the editor.
--
-- git moves the code; `select.lua` decides what of it lands. This module is the
-- part in between: the clone, the read of `package.lua`, the selection, the
-- limits, the copy, and the swap that makes it all appear at once.
--
-- An operation is a state machine, not a function, because every step that
-- touches the network is a detached job polled from a thread. `start` only
-- validates and takes the lock; `poll` advances one step per call and never
-- waits. A caller that wants "install this" starts an op and polls it from a
-- `core.add_thread` coroutine, which is the same shape `Manager.fetch_catalog`
-- already uses -- one established pattern rather than two.
--
-- The store layout, flat like a build's `data/packages/`:
--
--   <store>/<name>/          the installed package, or nothing
--   <store>/<name>.partial/  a fresh install being built
--   <store>/<name>.new/      an update being built
--   <store>/<name>.old/      the previous version, kept until the new one loads
--   <store>/<name>.lock/     the per-package lock, with a marker file in it
--
-- A failed or interrupted install leaves `.partial` or `.new` behind, and those
-- are unambiguous debris: the next operation for that package removes them first.
-- `.old` is never debris -- it is the rollback -- so only `confirm` (after a
-- successful load) and `rollback` (on a failed one) touch it.
--
-- Nothing here reads `package.lua` by running it, and nothing here runs anything
-- from the clone except git itself. `Manifest.load` reads through the sandbox;
-- the entry point is dofile'd later, by the loader, when the user actually runs
-- the package.
local Host     = require "cdinx.host"
local Util     = require "cdinx.manager.util"
local Source   = require "cdinx.manager.source"
local Select   = require "cdinx.manager.select"
local Git      = require "cdinx.manager.git"
local Manifest = require "cdinx.manifest"

local Transport = {}

--- How long a per-package lock may be held before it is called stale.
---
--- Longer than any single job may run: a lock outlives the clone, the copy and
--- the swap together, and calling it stale while its owner is still copying
--- would be two writers in the store wearing one lock. Nothing refreshes a
--- marker, so this one number is also how long any waiter -- for a package or
--- for the shared registry -- is kept waiting before it may take over.
Transport.LOCK_TIMEOUT = 600

--- How many bytes one poll tick may copy.
---
--- The copy is the only step that does bulk local IO, and a 5 MiB package copied
--- in one tick is a frame hitch the user feels. 512 KiB a tick keeps every tick
--- in the low milliseconds on any disk this editor runs on.
Transport.COPY_BUDGET = 512 * 1024

--- How many tracked files one clone may enumerate before it is refused.
---
--- `git ls-files` on a hostile repository can list millions of entries, and each
--- one costs a stat. Twenty thousand is two orders of magnitude past any package
--- and cheap enough to count first.
Transport.MAX_ENUMERATED = 20000

local seq = 0
-- A counter, not a clock, because two operations started in the same second need
-- different cache directories and the time does not promise that. Owned here,
-- touched only by `cache_dir`, and never observed outside this module.
local function cache_dir(config, name)
  seq = seq + 1
  return Util.join(config.cache_dir, string.format("%s-%d", name, seq))
end

local function store_paths(config, name)
  local store = config.store_dir
  return {
    final   = Util.join(store, name),
    partial = Util.join(store, name .. ".partial"),
    new     = Util.join(store, name .. ".new"),
    old     = Util.join(store, name .. ".old"),
    lockdir = Util.join(store, name .. ".lock"),
  }
end

--- The lock that guards the shared registry checkout.
---
--- A *sibling* of the checkout, not a directory inside it, for one reason: a
--- corrupt checkout is deleted and cloned again, and a lock inside the thing it
--- locks would be deleted with it -- which is precisely when two editors are
--- most likely to be racing. Out here it survives the rebuild it is guarding.
--- @param config table
--- @return string lockdir
local function registry_lock_dir(config)
  return config.registry_dir .. ".lock"
end

--- "12 KiB", for the panel and the log. Bytes are exact in the lock; this is the
--- shape a person reads.
--- @param bytes number|nil
--- @return string
function Transport.human(bytes)
  bytes = tonumber(bytes) or 0
  if bytes < 1024 then return string.format("%d B", bytes) end
  if bytes < 1024 * 1024 then
    local kb = bytes / 1024
    return (kb >= 100 and string.format("%d KiB", math.floor(kb + 0.5)))
      or string.format("%.1f KiB", kb)
  end
  return string.format("%.1f MiB", bytes / (1024 * 1024))
end

-- ── the per-package lock ─────────────────────────────────────────────────

local function lock_marker(paths)
  return Util.join(paths.lockdir, "lock")
end

local function lock_age(marker)
  local info = Host.fs.stat(marker)
  if not info or type(info.mtime) ~= "number" then return nil end
  return os.time() - info.mtime
end

--- Takes the lock for `name`, or explains why not.
---
--- The directory is created first because creating it is atomic and writing the
--- marker is not: two editors racing both create the directory harmlessly, and
--- then exactly one of them finds no marker. A stale lock -- older than the
--- timeout -- is reported loudly and taken over, because the alternative is an
--- install that refuses forever after a crash. A fresh one is refused, because
--- another editor is genuinely inside the store.
---
--- The refusal also hands back the age, because the registry lock *waits* on a
--- refusal instead of failing: knowing how old the other holder is is what tells
--- the waiter whether the wait is nearly over.
--- @return boolean ok
--- @return string|nil err
--- @return number|nil age  seconds, when the refusal was because it is live
local function acquire_lock(name, paths, label)
  Host.fs.mkdir(paths.lockdir)
  local marker = lock_marker(paths)
  if Host.fs.exists(marker) then
    local age = lock_age(marker)
    if age ~= nil and age < Transport.LOCK_TIMEOUT then
      return false, string.format(
        "another install of %s is already running (lock is %d seconds old); "
        .. "if no other editor is running, remove %s and try again",
        name, age, paths.lockdir), age
    end
    Host.core.error("cdin-x: taking over a stale lock for %s (age %s); "
      .. "a previous install did not finish",
      name, (age ~= nil) and (tostring(age) .. " seconds") or "unknown")
  end
  local fp, err = io.open(marker, "w")
  if not fp then
    return false, "cannot write " .. marker .. ": " .. tostring(err)
  end
  fp:write(label or name, "\n", tostring(os.time()), "\n")
  fp:close()
  return true
end

local function release_lock(paths)
  if Host.fs.exists(paths.lockdir) then Host.fs.rm(paths.lockdir) end
end

-- ── enumeration ──────────────────────────────────────────────────────────
--
-- From git's index, not the filesystem. The host's `stat` follows symlinks and
-- exposes no lstat, so a directory walk cannot tell a link from a file -- and a
-- selection that cannot see a symlink is a selection that ships its target.
-- `git ls-files -s` reports mode 120000 for a symlink and 160000 for a submodule,
-- so both are refused before they are ever read. Untracked droppings are not
-- listed at all, which is a second edge case the same mechanism closes.

--- Parses `git ls-files -s -z` output into { mode, path } entries.
--- @param out string
--- @return table[] entries
--- @return string|nil err
local function parse_ls_files(out)
  local entries = {}
  for record in out:gmatch("([^%z]*)%z") do
    if record ~= "" then
      local mode, path = record:match("^(%d+) %x+ %d+\t(.*)$")
      if not mode or not path then
        return nil, "git ls-files returned a line this parser does not recognise"
      end
      entries[#entries + 1] = { mode = mode, path = path }
      if #entries > Transport.MAX_ENUMERATED then
        return nil, string.format(
          "the clone lists more than %d tracked files; refusing rather than "
          .. "statting a hostile tree", Transport.MAX_ENUMERATED)
      end
    end
  end
  return entries
end

--- The candidate files of the package rooted at `root`, as Select.pick wants
--- them: `{ { path, size } }` with forward slashes relative to the root.
--- @param clone string  the clone directory
--- @param subdir string  the package root inside the clone, or "" for all of it
--- @param root string  clone + subdir, on disk
--- @return table[]|nil candidates
--- @return string|nil err
local function enumerate(clone, subdir, root)
  local argv = Git.ls_files_args(clone, (subdir ~= "" and subdir) or nil)
  local ok, out, why = Git.run_now(argv)
  if not ok then
    return nil, "could not list the clone: " .. tostring(out ~= "" and out or why)
  end
  local entries, err = parse_ls_files(out)
  if not entries then return nil, err end

  local prefix = (subdir ~= "" and (subdir .. "/")) or ""
  local candidates = {}
  for _, entry in ipairs(entries) do
    -- A symlink (120000) or a submodule (160000) is never selected, never
    -- followed, never copied; another package in a monorepo is not ours, not
    -- listed, not copied. (The grammar's `.git` rule is a backstop; tracked
    -- files are never under .git in the first place.)
    local ours = entry.mode ~= "120000" and entry.mode ~= "160000"
      and (prefix == "" or entry.path:sub(1, #prefix) == prefix)
    if ours then
      local rel = (prefix ~= "") and entry.path:sub(#prefix + 1) or entry.path
      local full = root .. "/" .. rel
      local info = Host.fs.stat(full)
      if not info or info.type ~= "file" then
        return nil, "cannot read " .. full
      end
      candidates[#candidates + 1] = { path = rel, size = info.size or 0 }
    end
  end
  return candidates
end

-- ── operations ───────────────────────────────────────────────────────────

--- Starts staging `name` from `origin`.
---
--- `origin` is `{ kind = "registry", subdir = "packages/editing/vim" }` for a
--- first-party package, or `{ kind = "git", spec = <Source.parse> }` for a
--- third-party one. `opts.update` makes it an update: the staging directory is
--- `<name>.new` and the swap keeps `.old`. `opts.known_version` is the version
--- already on disk: when the staged manifest declares the same one, the swap is
--- skipped entirely rather than performed pointlessly -- an update that changed
--- nothing is not an update, and rewriting every file to prove it would be the
--- most expensive possible way to say so.
---
--- Only dependency-free starts here -- the caller resolves `depends` first,
--- because a dependency that needs the network is a second operation and two
--- operations interleave badly.
---
--- Returns the op, which is `status = "running"` and `progress` set to the first
--- step. Nothing has been cloned yet: even the lock is taken on the first poll,
--- so a caller that starts an op and never polls it has changed nothing.
--- @param name string
--- @param origin table
--- @param opts table|nil
--- @return table op
function Transport.start(name, origin, opts)
  opts = opts or {}
  return {
    name = name,
    kind = opts.update and "update" or "install",
    update = opts.update == true,
    known_version = opts.known_version,
    origin = origin,
    status = "running",
    progress = "starting",
    phase = "begin",
    job = nil,
    cache = nil,
    clone = nil,
    rev = nil,
    spec = nil,
    version = nil,
    candidates = nil,
    chosen = nil,
    copy_index = 1,
    copy_offset = 0,
    copy_fp = nil,
    result = nil,
    cancelled = false,
  }
end

local function fail(op, err)
  op.status = "failed"
  op.progress = "failed"
  return "failed", err
end

--- Whether a clone failure names the option machinery rather than the request.
---
--- Matched narrowly and only ever used to choose the plain-clone retry: a refused
--- authentication, a missing repository or a dead network must fail loudly once,
--- not twice with a slower clone in between. The match is on the log's words
--- rather than git's exit code because there is no exit code -- detached jobs
--- leave markers, not statuses.
--- @param why string|nil
--- @return boolean
local function looks_like_option_error(why)
  if type(why) ~= "string" then return false end
  local text = why:lower()
  return text:find("unknown option", 1, true) ~= nil
      or text:find("unrecognised option", 1, true) ~= nil
      or text:find("unrecognized option", 1, true) ~= nil
      or text:find("unknown switch", 1, true) ~= nil
      or (text:find("filter", 1, true) ~= nil
        and text:find("not supported", 1, true) ~= nil)
end

--- Removes everything this op built: the staging directory, the transient cache
--- clone, and the locks -- the per-package one and, when the op borrowed the
--- shared checkout, the registry one. The persistent registry checkout is never
--- deleted here; it belongs to every install, not to this one. Never touches
--- `final` and never touches `.old` -- those belong to transitions this function
--- did not start.
local function cleanup(op, paths)
  if op.copy_fp then op.copy_fp:close() op.copy_fp = nil end
  if op.staging and Host.fs.exists(op.staging) then Host.fs.rm(op.staging) end
  if op.transient and op.cache and Host.fs.exists(op.cache) then
    Host.fs.rm(op.cache)
  end
  if op.registry_locked and op.registry_lock then
    if Host.fs.exists(op.registry_lock) then Host.fs.rm(op.registry_lock) end
    op.registry_locked = false
  end
  release_lock(paths)
end

--- Advances `op` by one step. Returns its status and, when terminal, the result
--- or the reason. Never blocks: a phase that needs the network starts a job and
--- returns "running"; the next poll looks at the marker.
---
--- Two shapes of clone, and the phase tells which: a third-party `git` origin
--- clones transiently into the cache and deletes it afterwards; a `registry`
--- origin borrows the persistent sparse checkout, adding one subdir and trimming
--- it back when done. The phases after `rev` do not know which one it was, which
--- is the point: selection, limits, copy and swap are the same either way.
--- @param config table
--- @param op table
--- @return string status  "running" | "done" | "failed"
--- @return table|string|nil payload
function Transport.poll(config, op)
  if op.status ~= "running" then
    return op.status, op.result
  end
  if op.cancelled then
    cleanup(op, store_paths(config, op.name))
    return fail(op, "cancelled")
  end

  local paths = store_paths(config, op.name)
  local limits = Source.LIMITS

  -- ── begin: git, the lock, and clearing last time's debris ─────────────
  if op.phase == "begin" then
    local _, why = Git.find()
    if not _ then
      cleanup(op, paths)
      return fail(op, why)
    end
    op.progress = "preparing"
    op.phase = "lock"
    return "running"
  end

  if op.phase == "lock" then
    local ok, err = acquire_lock(op.name, paths, op.kind)
    if not ok then
      return fail(op, err)
    end
    -- A failed or interrupted install leaves `.partial` or `.new` behind, and
    -- those are unambiguous debris. `.old` is not debris -- it is the rollback --
    -- so it is never touched here.
    for _, debris in ipairs({ paths.partial, paths.new }) do
      if Host.fs.exists(debris) then Host.fs.rm(debris) end
    end
    op.staging = op.update and paths.new or paths.partial
    if op.origin.kind == "registry" then
      -- First-party packages come out of the persistent checkout, not a fresh
      -- clone. Two things gate that: the registry lock, because the checkout is
      -- shared with every other editor, and ensuring it, because it is the first
      -- network the operation may need.
      op.progress = "waiting for the registry"
      op.phase = "rlock"
    else
      op.progress = "cloning"
      op.phase = "clone"
    end
    return "running"
  end

  -- ── rlock: one editor at a time inside the shared checkout ────────────
  --
  -- Unlike the per-package lock, this one waits rather than refuses. The store
  -- lock is exclusive because two installs of *one* package cannot both be right;
  -- the registry is different -- installing `vim` is not wrong because another
  -- editor is installing `treeview` out of the same working tree, and failing it
  -- for that would make two normal installations in two editor windows a coin
  -- flip. So the waiter polls and says what it is waiting for.
  --
  -- The wait needs no timer of its own. Nothing ever rewrites a marker, so a
  -- holder's lock becomes stale exactly `LOCK_TIMEOUT` after it took it, and this
  -- poll takes it over the moment that happens -- the same takeover, with the same
  -- log line, that any other install would perform. A second timer here could only
  -- disagree with the first about when a lock is dead, and the first is the one
  -- the per-package locks already obey.
  if op.phase == "rlock" then
    local lockdir = registry_lock_dir(config)
    local ok, _, age = acquire_lock("the registry", { lockdir = lockdir }, "registry")
    if ok then
      op.registry_lock = lockdir
      op.registry_locked = true
      op.progress = "reading the registry"
      op.phase = "rensure"
      return "running"
    end
    op.progress = string.format(
      "waiting %ds for another editor to finish with the registry", age or 0)
    return "running"
  end

  -- ── rensure: the persistent registry checkout, or a fresh one ────────
  --
  -- All local checks: is it a clone, does it answer, does it fetch from the
  -- configured URL. A missing or half-built clone is deleted and cloned again --
  -- never repaired in place, because a repair would have to prove what "whole"
  -- means and a fresh clone simply is whole. A wrong remote is the same case: a
  -- clone of a fork is a different registry, not this one with a different name.
  if op.phase == "rensure" then
    local Registry = require("cdinx.manager.registry")
    local dir = Registry.root(config)
    op.clone = dir
    op.transient = false
    op.full = not Git.supports_sparse()

    local url = config.registry_url
    if not Source.valid_url(url) then
      cleanup(op, paths)
      return fail(op, "config.registry_url is not a usable git URL: " .. tostring(url))
    end
    local subdir = op.origin.subdir or ""
    if subdir ~= "" and not Source.valid_subdir(subdir) then
      cleanup(op, paths)
      return fail(op, Source.subdir_problem(subdir) or "bad subdir")
    end
    op.url, op.subdir = url, subdir

    local function run_now(argv)
      return Git.run_now(argv)
    end
    local valid, why = Registry.valid_clone(config, run_now)
    if not valid then
      -- Said out loud rather than silently: deleting a directory the user can
      -- see is the kind of thing that wants a line in the log.
      Host.core.log("cdin-x: rebuilding the registry clone: %s", tostring(why))
      if Host.fs.exists(dir) then Host.fs.rm(dir) end
      local argv, err
      if op.full then
        argv, err = Git.plain_clone_args(url, dir, nil)
      else
        argv, err = Git.sparse_clone_args(url, dir)
      end
      if not argv then
        cleanup(op, paths)
        return fail(op, err)
      end
      local job
      job, err = Git.run(argv, config.cache_dir, { label = "registry-clone" })
      if not job then
        cleanup(op, paths)
        return fail(op, err)
      end
      op.job = job
      op.progress = "cloning the registry"
      op.phase = "rclone_wait"
      return "running"
    end

    -- A previous operation may have died between `add` and `trim`, leaving the
    -- working tree wider than the index. Resetting the sparse list is the defined
    -- trim discipline, not a repair -- but if even the reset fails, the checkout
    -- is corrupt by the only test that matters, and it is rebuilt instead.
    if not op.full then
      local ok = Registry.reset_working_tree(dir, run_now)
      if not ok then
        Host.core.log("cdin-x: rebuilding the registry clone: the working tree "
          .. "would not trim")
        if Host.fs.exists(dir) then Host.fs.rm(dir) end
        local argv, err = Git.sparse_clone_args(url, dir)
        if not argv then
          cleanup(op, paths)
          return fail(op, err)
        end
        local job
        job, err = Git.run(argv, config.cache_dir, { label = "registry-clone" })
        if not job then
          cleanup(op, paths)
          return fail(op, err)
        end
        op.job = job
        op.progress = "cloning the registry"
        op.phase = "rclone_wait"
        return "running"
      end
    end

    op.progress = "reading the registry"
    op.phase = (op.kind == "refresh" or op.update) and "rrefresh" or "radd"
    return "running"
  end

  -- ── rclone_wait: the fresh clone landing ─────────────────────────────
  if op.phase == "rclone_wait" then
    local state, why = Git.poll(op.job)
    if state == "running" then
      return "running"
    end
    if state ~= "ok" then
      -- An old git, or a server that answers a filtered clone with an error
      -- about the option, gets one retry as a plain shallow clone: slower,
      -- never broken. Anything else is a real failure and is reported as one --
      -- retrying a refused authentication or a missing repository would only
      -- spend the user's time twice.
      if not op.plain_retry and not op.full and looks_like_option_error(why) then
        Host.core.log("cdin-x: retrying the registry clone without filter/sparse")
        local Registry = require("cdinx.manager.registry")
        local dir = Registry.root(config)
        if Host.fs.exists(dir) then Host.fs.rm(dir) end
        local argv = Git.plain_clone_args(op.url, dir, nil)
        if argv then
          local job
          job = Git.run(argv, config.cache_dir, { label = "registry-clone" })
          if job then
            op.job = job
            op.full = true
            op.plain_retry = true
            return "running"
          end
        end
      end
      cleanup(op, paths)
      return fail(op, "could not clone the registry: " .. tostring(why))
    end
    -- Markers belong to the job, not the cache: transient clones take theirs
    -- with them when the directory goes, but the persistent path leaves the
    -- cache directory behind, so each successful poll cleans up after itself.
    if Host.fs.exists(op.job.done) then Host.fs.rm(op.job.done) end
    if Host.fs.exists(op.job.log) then Host.fs.rm(op.job.log) end
    op.job = nil
    if not op.full then
      -- A fresh sparse clone checks out only the top level; the index lives
      -- under `registry/`, so it is set before anything reads it.
      local Registry = require("cdinx.manager.registry")
      local ok = Registry.reset_working_tree(Registry.root(config), function(a)
        return Git.run_now(a)
      end)
      if not ok then
        cleanup(op, paths)
        return fail(op, "the fresh registry clone would not trim")
      end
    end
    op.progress = "reading the registry"
    op.phase = (op.kind == "refresh" or op.update) and "rrefresh" or "radd"
    return "running"
  end

  -- ── rrefresh: fetch the branch head and check it out ─────────────────
  --
  -- Updates read the newest registry, installs read the one the catalog was
  -- built from: refreshing on every install would spend a fetch to learn what
  -- the panel already lists, and the catalog and the tree would still disagree
  -- whenever the branch moved between the two.
  if op.phase == "rrefresh" then
    if op.refresh_step == nil then
      local Registry = require("cdinx.manager.registry")
      local dir = Registry.root(config)
      local branch = Registry.tracked_branch()
      local argv, err = Git.fetch_args(dir, branch)
      if not argv then
        cleanup(op, paths)
        return fail(op, err)
      end
      local job
      job, err = Git.run(argv, config.cache_dir, { label = "registry-fetch" })
      if not job then
        cleanup(op, paths)
        return fail(op, err)
      end
      op.job = job
      op.refresh_step = "fetch"
      op.progress = "refreshing the registry"
      return "running"
    end
    local state, why = Git.poll(op.job)
    if state == "running" then
      return "running"
    end
    if state ~= "ok" then
      cleanup(op, paths)
      return fail(op, "could not refresh the registry: " .. tostring(why))
    end
    if Host.fs.exists(op.job.done) then Host.fs.rm(op.job.done) end
    if Host.fs.exists(op.job.log) then Host.fs.rm(op.job.log) end
    op.job = nil
    if op.refresh_step == "fetch" then
      local Registry = require("cdinx.manager.registry")
      local argv = Git.checkout_args(Registry.root(config))
      local ok, out = Git.run_now(argv)
      if not ok then
        cleanup(op, paths)
        return fail(op, "could not check out the refreshed registry: " .. tostring(out))
      end
      -- The commit the refresh landed on: recorded in the result, shown in the
      -- panel, and compared by updates. Read here rather than trusted from the
      -- fetch output, because the checkout is what the working tree actually is.
      local rev = Git.head_rev(Registry.root(config))
      if not rev then
        cleanup(op, paths)
        return fail(op, "the refreshed registry has no commit")
      end
      op.rev = rev
      if not op.full then
        local trimmed = Registry.reset_working_tree(Registry.root(config), function(a)
          return Git.run_now(a)
        end)
        if not trimmed then
          cleanup(op, paths)
          return fail(op, "the refreshed registry would not trim")
        end
      end
      op.refresh_step = "done"
    end
    if op.kind == "refresh" then
      op.progress = "finishing"
      op.phase = "rtrim"
      return "running"
    end
    op.progress = "reading package.lua"
    op.phase = "radd"
    return "running"
  end

  -- ── radd: materialise the one subdir being installed ─────────────────
  if op.phase == "radd" then
    if not op.full and op.subdir ~= "" then
      local Registry = require("cdinx.manager.registry")
      local dir = Registry.root(config)
      local argv, err = Git.sparse_args(dir, { op.subdir }, "add")
      if not argv then
        cleanup(op, paths)
        return fail(op, err)
      end
      local ok, out = Git.run_now(argv)
      if not ok then
        cleanup(op, paths)
        return fail(op, "could not materialise " .. op.subdir .. ": " .. tostring(out))
      end
    end
    op.progress = "reading package.lua"
    op.phase = "rev"
    return "running"
  end

  -- ── clone: one detached job, then (for a commit) init/fetch/checkout ──
  --
  -- Third-party origins clone transiently into the cache; the registry origin
  -- borrows the persistent checkout instead (see `rensure` below) and never
  -- reaches this branch.
  if op.phase == "clone" then
    op.cache = cache_dir(config, op.name)
    op.clone = Util.join(op.cache, "repo")
    op.transient = true
    local origin = op.origin
    local url, ref, ref_kind, subdir

    if origin.kind == "registry" then
      cleanup(op, paths)
      return fail(op, "internal error: a registry origin uses the persistent checkout")
    elseif origin.kind == "git" then
      local spec = origin.spec
      url, ref, ref_kind, subdir = spec.url, spec.ref, spec.ref_kind, spec.subdir or ""
      -- Recorded here rather than at the end of the phase, because the sha path
      -- below leaves this phase early to wait for its fetch: assigning on the way
      -- out meant a commit-pinned clone reached `rev` with no url and no subdir,
      -- and reported "subdir nil is not in nil at this commit". Every 40-hex `rev`
      -- -- which is what a recipe is, and what a pinned source is -- took it.
      op.url, op.ref, op.ref_kind, op.subdir = url, ref, ref_kind, subdir
      if ref_kind == "sha" then
        -- init is local and instant, so it runs inline; the fetch is the job.
        local ok, out = Git.run_now(Git.init_args(op.clone))
        if not ok then
          cleanup(op, paths)
          return fail(op, "could not initialise a clone: " .. tostring(out))
        end
        local argv, err = Git.fetch_sha_args(op.clone, url, ref)
        if not argv then
          cleanup(op, paths)
          return fail(op, err)
        end
        local job
        job, err = Git.run(argv, op.cache, { label = "fetch-" .. op.name })
        if not job then
          cleanup(op, paths)
          return fail(op, err)
        end
        op.job = job
        op.phase = "clone_wait_sha"
        return "running"
      else
        local argv, err = Git.clone_args({ url = url, ref = ref, ref_kind = ref_kind }, op.clone)
        if not argv then
          cleanup(op, paths)
          return fail(op, err)
        end
        local job
        job, err = Git.run(argv, op.cache, { label = "clone-" .. op.name })
        if not job then
          cleanup(op, paths)
          return fail(op, err)
        end
        op.job = job
      end
    else
      cleanup(op, paths)
      return fail(op, "unknown origin kind: " .. tostring(origin.kind))
    end

    op.phase = "clone_wait"
    return "running"
  end

  if op.phase == "clone_wait" or op.phase == "clone_wait_sha" then
    local state, why = Git.poll(op.job)
    if state == "running" then
      return "running"
    end
    if state ~= "ok" then
      cleanup(op, paths)
      return fail(op, "could not clone " .. tostring(op.url) .. ": " .. tostring(why))
    end
    if Host.fs.exists(op.job.done) then Host.fs.rm(op.job.done) end
    if Host.fs.exists(op.job.log) then Host.fs.rm(op.job.log) end
    if op.phase == "clone_wait_sha" then
      -- checkout is local and instant: detached, so the tree is exactly the commit.
      local ok, out = Git.run_now(Git.checkout_fetch_head_args(op.clone))
      if not ok then
        cleanup(op, paths)
        return fail(op, "could not check out " .. tostring(op.ref) .. ": " .. tostring(out))
      end
    end
    op.job = nil
    op.progress = "reading package.lua"
    op.phase = "rev"
    return "running"
  end

  -- ── rev + manifest: what was cloned, and is it what was asked for ────
  if op.phase == "rev" then
    local rev, err = Git.head_rev(op.clone)
    if not rev then
      cleanup(op, paths)
      return fail(op, err)
    end
    op.rev = rev
    local root = (op.subdir ~= "" and Util.join(op.clone, op.subdir)) or op.clone
    if not Host.fs.is_dir(root) then
      cleanup(op, paths)
      if op.origin.kind == "registry" then
        return fail(op, string.format(
          "the registry has no %s at this commit; it moved, or this checkout is stale",
          op.subdir))
      end
      return fail(op, string.format(
        "subdir %q is not in %s at this commit", op.subdir, op.url))
    end
    op.root = root
    op.phase = "manifest"
    return "running"
  end

  if op.phase == "manifest" then
    local meta, err = Manifest.load(op.root)
    if not meta then
      cleanup(op, paths)
      return fail(op, "no readable package.lua in " .. tostring(op.url)
        .. (op.subdir ~= "" and (" at " .. op.subdir) or "") .. ": " .. tostring(err))
    end
    if meta._legacy then
      cleanup(op, paths)
      return fail(op, "no package.lua in " .. tostring(op.url)
        .. (op.subdir ~= "" and (" at " .. op.subdir) or ""))
    end
    -- The name has to be what was asked for. For a registry origin that is the
    -- catalog name; for a git origin with an explicit `name` it is that. Without
    -- either, the manifest's own name is adopted -- but only by the caller, which
    -- knows the difference between "asked" and "found".
    if op.origin.kind == "registry" and meta.name ~= op.name then
      cleanup(op, paths)
      return fail(op, string.format(
        "the registry's %s declares itself %q; refusing to install it under %q",
        op.subdir, meta.name, op.name))
    end
    if op.origin.kind == "git" and op.origin.spec.name
        and meta.name ~= op.origin.spec.name then
      cleanup(op, paths)
      return fail(op, string.format(
        "package.lua declares %q, but %q was asked for", meta.name, op.origin.spec.name))
    end
    op.manifest_name = meta.name
    op.version = meta.version or ""
    op.spec = meta.spec
    op.progress = "selecting files"
    op.phase = "enumerate"
    return "running"
  end

  -- ── enumerate + select: what lands, and does it fit ───────────────────
  if op.phase == "enumerate" then
    local candidates, err = enumerate(op.clone, op.subdir, op.root)
    if not candidates then
      cleanup(op, paths)
      return fail(op, err)
    end
    -- The clone itself is capped too: a repository that is mostly something else
    -- is not a package that happens to be large, it is a monorepo someone pointed
    -- at, and copying from it means walking all of it first.
    local total = 0
    for _, entry in ipairs(candidates) do total = total + (entry.size or 0) end
    if total > limits.max_clone_bytes then
      cleanup(op, paths)
      return fail(op, string.format(
        "the clone holds %s; the limit is %s", Transport.human(total),
        Transport.human(limits.max_clone_bytes)))
    end
    op.candidates = candidates
    op.phase = "select"
    return "running"
  end

  if op.phase == "select" then
    local files = op.spec and op.spec.files or nil
    local ignore = op.spec and op.spec.ignore or nil
    local chosen, _, err = Select.pick(op.candidates, files, ignore)
    if not chosen then
      cleanup(op, paths)
      return fail(op, tostring(err))
    end
    local count, bytes = Select.size(chosen)
    if count > limits.max_files then
      cleanup(op, paths)
      return fail(op, string.format(
        "%s selects %d files; the limit is %d per package",
        op.name, count, limits.max_files))
    end
    if bytes > limits.max_bytes then
      cleanup(op, paths)
      return fail(op, string.format(
        "%s selects %s; the limit is %s per package",
        op.name, Transport.human(bytes), Transport.human(limits.max_bytes)))
    end
    local reader = function(path)
      local fp = io.open(op.root .. "/" .. path, "rb")
      if not fp then return nil end
      local text = fp:read("*a")
      fp:close()
      return text
    end
    local problem = Select.validate(chosen, reader, op.manifest_name)
    if problem then
      cleanup(op, paths)
      return fail(op, problem)
    end
    op.chosen = chosen
    op.bytes = bytes
    op.count = count
    op.progress = string.format("copying %s", Transport.human(bytes))
    op.phase = "copy"
    return "running"
  end

  -- ── copy: chunked across polls, so no tick blocks the frame ───────────
  if op.phase == "copy" then
    local budget = Transport.COPY_BUDGET
    while budget > 0 and op.copy_index <= #op.chosen do
      local entry = op.chosen[op.copy_index]
      local src = op.root .. "/" .. entry.path
      local dst = op.staging .. "/" .. entry.path
      if not op.copy_fp then
        Host.fs.mkdir(Host.fs.dirname(dst))
        local inf = io.open(src, "rb")
        if not inf then
          cleanup(op, paths)
          return fail(op, "cannot read " .. src)
        end
        local outf = io.open(dst, "wb")
        if not outf then
          inf:close()
          cleanup(op, paths)
          return fail(op, "cannot write " .. dst)
        end
        op.copy_fp = { inf = inf, outf = outf }
        op.copy_offset = 0
      end
      local chunk = op.copy_fp.inf:read(math.min(65536, budget))
      if chunk and #chunk > 0 then
        op.copy_fp.outf:write(chunk)
        op.copy_offset = op.copy_offset + #chunk
        budget = budget - #chunk
      else
        op.copy_fp.inf:close()
        op.copy_fp.outf:close()
        op.copy_fp = nil
        op.copy_index = op.copy_index + 1
        op.progress = string.format("copying %d/%d files (%s)",
          math.min(op.copy_index, #op.chosen), #op.chosen, Transport.human(op.bytes))
      end
    end
    if op.copy_index <= #op.chosen then
      return "running"
    end
    op.progress = "installing"
    op.phase = "swap"
    return "running"
  end

  -- ── swap: the only moment anything becomes visible ────────────────────
  --
  -- Everything before this touched only the cache and the staging directory, so a
  -- failure anywhere above leaves the installed set exactly as it was. This phase
  -- is two renames in the same directory -- atomic on any filesystem this editor
  -- runs on -- which is what makes the install appear at once rather than grow.
  if op.phase == "swap" then
    if not op.update then
      if Host.fs.exists(paths.final) then
        cleanup(op, paths)
        return fail(op, op.name .. " is already installed; update it instead")
      end
      local ok, err = Host.fs.move(op.staging, paths.final)
      if not ok then
        cleanup(op, paths)
        return fail(op, "could not place " .. op.name .. ": " .. tostring(err))
      end
    else
      if not Host.fs.exists(paths.final) then
        cleanup(op, paths)
        return fail(op, op.name .. " is not installed; install it instead of updating")
      end
      if op.known_version ~= nil and op.version == op.known_version then
        -- Same version as what is on disk: remove the staging and finish without
        -- swapping. The result says so explicitly, because "done" alone would
        -- read as "updated" to a caller that only checks the status.
        Host.fs.rm(op.staging)
        if op.transient and op.cache and Host.fs.exists(op.cache) then
          Host.fs.rm(op.cache)
        end
        release_lock(paths)
        op.status = "done"
        op.progress = "done"
        op.result = {
          name = op.manifest_name or op.name,
          requested = op.name,
          rev = op.rev,
          version = op.version or "",
          files = op.count or 0,
          bytes = op.bytes or 0,
          source = op.origin.kind,
          url = op.url,
          ref = op.ref,
          ref_kind = op.ref_kind,
          subdir = op.subdir or "",
          update = op.update,
          updated = false,
        }
        return "done", op.result
      end
      -- A leftover `.old` means a previous update was never confirmed: the
      -- running tree already proved itself by loading since, so it is debris --
      -- but it is said out loud, because silently deleting a rollback is how a
      -- rollback goes missing the one time it is needed.
      if Host.fs.exists(paths.old) then
        Host.core.log("cdin-x: removing a stale .old for %s from an unconfirmed update",
          op.name)
        Host.fs.rm(paths.old)
      end
      local ok, err = Host.fs.move(paths.final, paths.old)
      if not ok then
        cleanup(op, paths)
        return fail(op, "could not stage the old " .. op.name .. ": " .. tostring(err))
      end
      ok, err = Host.fs.move(op.staging, paths.final)
      if not ok then
        -- The old tree is safe in `.old`, but the new one did not land: put it
        -- back rather than leaving the package missing. If even that fails the
        -- `.old` is still there and the message says exactly that.
        local back, back_err = Host.fs.move(paths.old, paths.final)
        cleanup(op, paths)
        if back then
          return fail(op, "could not place the new " .. op.name .. ": " .. tostring(err))
        end
        return fail(op, "could not place the new " .. op.name .. ": " .. tostring(err)
          .. " (and the old tree could not be restored: " .. tostring(back_err)
          .. "; it is at " .. paths.old .. ")")
      end
    end
    -- A registry origin borrowed the persistent checkout and added its subdir:
    -- trim it back before finishing, or the working tree grows with every
    -- install. Transient clones are deleted at `finish` instead; the two shapes
    -- never share a cleanup.
    if op.origin.kind == "registry" then
      op.progress = "trimming the registry"
      op.phase = "rtrim"
    else
      op.progress = "finishing"
      op.phase = "finish"
    end
    return "running"
  end

  -- ── rtrim: the working tree back to the index and nothing else ───────
  --
  -- Non-fatal by design: the install already swapped, so failing the whole
  -- operation here would report failure for work that succeeded. What fails
  -- instead is loud -- an error in the log naming the directory -- and the next
  -- operation resets the sparse list at `rensure` before it reads anything, so a
  -- missed trim never compounds.
  if op.phase == "rtrim" then
    if not op.full then
      local Registry = require("cdinx.manager.registry")
      local trimmed = Registry.reset_working_tree(Registry.root(config), function(a)
        return Git.run_now(a)
      end)
      if not trimmed then
        Host.core.error("cdin-x: the registry working tree would not trim; "
          .. "the next operation resets it before reading")
      end
    end
    op.progress = "finishing"
    op.phase = "finish"
    return "running"
  end

  if op.phase == "finish" then
    if op.transient and op.cache and Host.fs.exists(op.cache) then
      Host.fs.rm(op.cache)
    end
    -- The registry lock outlives the trim and the release of the per-package
    -- lock, and is released last: until here the shared working tree may still
    -- have been the thing the copy was reading.
    if op.registry_locked and op.registry_lock then
      if Host.fs.exists(op.registry_lock) then Host.fs.rm(op.registry_lock) end
      op.registry_locked = false
    end
    release_lock(paths)
    op.status = "done"
    op.progress = "done"
    op.result = {
      name = op.manifest_name or op.name,
      requested = op.name,
      rev = op.rev,
      version = op.version or "",
      files = op.count or 0,
      bytes = op.bytes or 0,
      source = op.origin.kind,
      url = op.url,
      ref = op.ref,
      ref_kind = op.ref_kind,
      subdir = op.subdir or "",
      update = op.update,
      updated = true,
    }
    return "done", op.result
  end

  cleanup(op, paths)
  return fail(op, "unknown phase: " .. tostring(op.phase))
end

--- Starts a registry refresh: ensure the clone, fetch the tracked branch, check
--- it out, trim. The op is named `.registry` so the panel shows the work and the
--- per-operation lock serialises two refreshes; its staging paths are never
--- created, only the lock directory is used.
--- @return table op
function Transport.start_refresh()
  local op = Transport.start(".registry", { kind = "registry", subdir = "" }, {})
  op.kind = "refresh"
  return op
end

--- Releases everything an operation was holding, for an operation that will not be
--- resumed.
---
--- The queue calls this when a phase *raises* rather than reporting a failure: the
--- state machine's own `fail` path cleans up as it goes, but an exception unwinds
--- past all of that, and a lock left behind is a lock the next operation refuses to
--- take for `LOCK_TIMEOUT` and the user has to delete by hand. Deliberately not
--- `rollback`: `.old` belongs to a swap that happened, and a phase that raised
--- cannot be assumed to have got that far.
--- @param config table
--- @param op table
function Transport.abandon(config, op)
  cleanup(op, store_paths(config, op.name))
  op.status = "failed"
end

--- Puts `.old` back over a failed update.
---
--- Only ever called when the new tree failed to load right after the swap, which
--- is the one case the swap cannot undo itself: the files are already in place
--- and something has to move them back. Anything else -- a failure before the
--- swap -- never touched `final` and has nothing to roll back.
--- @param config table
--- @param name string
--- @return boolean ok
--- @return string|nil err
function Transport.rollback(config, name)
  local paths = store_paths(config, name)
  if not Host.fs.exists(paths.old) then
    return false, "no previous version of " .. name .. " to restore"
  end
  if Host.fs.exists(paths.final) then Host.fs.rm(paths.final) end
  local ok, err = Host.fs.move(paths.old, paths.final)
  if not ok then return false, tostring(err) end
  return true
end

--- Removes `.old` after the new tree proved itself by loading.
---
--- Called after a successful init, never before: deleting the rollback is what
--- makes the update permanent, and permanence before proof is the whole failure
--- this layout exists to survive.
--- @param config table
--- @param name string
function Transport.confirm(config, name)
  local paths = store_paths(config, name)
  if Host.fs.exists(paths.old) then Host.fs.rm(paths.old) end
  return true
end

--- Whether `.old` is still waiting for its proof.
--- @param config table
--- @param name string
--- @return boolean
function Transport.pending(config, name)
  return Host.fs.exists(store_paths(config, name).old)
end

--- Removes `.partial`/`.new` leftovers without touching anything else.
--- @param config table
--- @param name string
function Transport.discard(config, name)
  local paths = store_paths(config, name)
  for _, debris in ipairs({ paths.partial, paths.new }) do
    if Host.fs.exists(debris) then Host.fs.rm(debris) end
  end
  return true
end

--- Where an installed package lives, or nil.
--- @param config table
--- @param name string
--- @return string|nil
function Transport.installed_path(config, name)
  local path = store_paths(config, name).final
  if Host.fs.is_dir(path) then return path end
  return nil
end

-- ── the update check ─────────────────────────────────────────────────────
--
-- `git ls-remote` without cloning: the commit a ref points to now, compared with
-- the locked rev. A tag whose commit changed is reported as "tag moved" and never
-- followed, because following it would move the user to a commit nobody pinned.

--- Starts an update check for a git-sourced package.
--- @param config table
--- @param name string
--- @param lock table  the lock entry: { url, ref, rev }
--- @return table|nil op
--- @return string|nil err
function Transport.start_check(config, name, lock)
  if type(lock) ~= "table" or not Source.valid_url(lock.url) then
    return nil, "no recorded source to check " .. name .. " against"
  end
  local argv, err = Git.ls_remote_args({ url = lock.url, ref = lock.ref })
  if not argv then return nil, err end
  local workdir = Util.join(config.cache_dir, "checks")
  Host.fs.mkdir(workdir)
  local job
  job, err = Git.run(argv, workdir, { label = "ls-remote-" .. name, timeout = 60 })
  if not job then return nil, err end
  return {
    name = name,
    kind = "check",
    status = "running",
    progress = "checking " .. name,
    phase = "wait",
    job = job,
    lock = lock,
  }
end

--- Polls an update check.
--- @param op table
--- @return string status
--- @return table|string|nil payload
function Transport.poll_check(op)
  if op.status ~= "running" then return op.status, op.result end
  if op.cancelled then
    op.status = "failed"
    return "failed", "cancelled"
  end
  local state, why = Git.poll(op.job)
  if state == "running" then return "running" end
  if state ~= "ok" then
    op.status = "failed"
    return "failed", "could not check " .. op.name .. ": " .. tostring(why)
  end
  local text = nil
  do
    local fp = io.open(op.job.log, "rb")
    if fp then text = fp:read("*a") fp:close() end
  end
  -- Best-effort cleanup of the check's own marker files; a failure here is not a
  -- failure of the check, which already has its answer.
  if Host.fs.exists(op.job.done) then Host.fs.rm(op.job.done) end
  if Host.fs.exists(op.job.log) then Host.fs.rm(op.job.log) end

  local lock = op.lock
  local refs = {}
  for sha, refname in (text or ""):gmatch("(%x+)%s+([^\r\n]+)") do
    refs[refname] = sha
  end

  local result = { name = op.name, update = false }
  if not lock.ref or lock.ref == "" then
    -- Pinned to the default branch: HEAD is what moves.
    local head = refs["HEAD"]
    if not head then
      op.status = "failed"
      return "failed", "the server did not answer for HEAD"
    end
    result.remote = head
    result.update = head ~= lock.rev
  else
    local tag = refs["refs/tags/" .. lock.ref]
    local head = refs["refs/heads/" .. lock.ref]
    if tag and tag ~= lock.rev then
      op.status = "failed"
      return "failed", string.format(
        "tag %s moved since the lock (was %s, is now %s); refusing to follow it "
        .. "silently -- pin the new commit explicitly to update",
        lock.ref, tostring(lock.rev), tag)
    end
    local now = tag or head
    if not now then
      op.status = "failed"
      return "failed", string.format(
        "ref %q is gone from %s", lock.ref, tostring(lock.url))
    end
    result.remote = now
    result.update = now ~= lock.rev
  end

  op.status = "done"
  op.result = result
  return "done", result
end

return Transport