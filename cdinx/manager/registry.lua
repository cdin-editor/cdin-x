-- Locating the extension registry, keeping its clone, and reading its index.
--
-- The registry is a persistent sparse clone of this repository: `git clone
-- --depth 1 --filter=blob:none --sparse`, then `sparse-checkout set registry`.
-- It holds the tree of names and the index, never package contents -- those are
-- added per install (`sparse-checkout add <subdir>`) and trimmed back afterwards,
-- so the working tree never holds more than the index plus one package. That is
-- what makes the catalog grow without the download growing with it.
--
-- The async work -- cloning, refreshing, adding a subdir -- belongs to
-- manager/transport.lua, which owns the job chains. This module answers the
-- synchronous questions: where the clone lives, whether it is usable, what the
-- index says. A corrupt or half-built clone is never repaired in place: it is
-- deleted and cloned again, because a repair would have to prove what "whole"
-- means and a fresh clone simply is whole.
--
-- There is no way to fetch the registry from here. `Registry.refresh` and the
-- `set_syncer` seam that chose between a registered syncer and the HTTPS
-- downloader are gone: the catalog lives in the clone, so refreshing means
-- moving the clone, and a second mechanism for that is one more thing to keep
-- correct. `Manager.set_registry_syncer` survives only as a deprecation shim
-- that logs once.
local Host   = require "cdinx.host"
local Util   = require "cdinx.manager.util"
local Recipe = require "cdinx.manager.recipe"
local Schema = require "cdinx.schema"

local Registry = {}

-- Where the catalog file may be. One, since Phase 9 removed `X/` and the older of
-- the two generated indexes this preferred between.
local CATALOG_FILES = { "registry/generated/catalog.lua" }

-- Overridable through config.registry_dir, which the user config may set
-- from the environment via CDIN_X_REGISTRY.
--
-- The registry directory itself, not a subdirectory of it: it is a sparse
-- checkout of this repository, so it holds the catalog the tree uses.
function Registry.root(config)
  return config.registry_dir
end

--- The catalog file that is actually there, or nil.
--- @param config table
--- @return string|nil path
--- @return string|nil relative  what to ask the remote for
function Registry.catalog_path(config)
  local dir = Registry.root(config)
  for _, rel in ipairs(CATALOG_FILES) do
    local path = Util.join(dir, rel)
    if Host.fs.is_file(path) then return path, rel end
  end
  return nil
end

--- Whether a catalog is on disk, or why the user has to get one first.
---
--- Never fetches: "the catalog is not on disk yet" is exactly the case a refresh
--- exists to fix, and fixing it here would block the frame on a clone.
--- @param config table
--- @return boolean ok
--- @return string|nil err
function Registry.ensure(config)
  if Registry.catalog_path(config) then return true end
  return false, "no extension catalog yet at " .. tostring(config.registry_dir)
    .. " (open the Extensions panel and press ctrl+r to clone it)"
end

Registry.registry_root = Registry.root

-- ── the clone ────────────────────────────────────────────────────────────
--
-- Synchronous checks only. Cloning, fetching and sparse-checkout run as detached
-- jobs in the transport; what lives here is the part that can be answered from
-- the filesystem: is this directory a clone, does it speak to the right remote,
-- and which branch does the user follow.

--- Whether `dir` is a git working tree at all.
--- @param dir string|nil
--- @return boolean
function Registry.is_clone(dir)
  if type(dir) ~= "string" or dir == "" then return false end
  -- `.git` may be a directory (a clone) or a file (a worktree pointer); either
  -- way git is in charge here. Anything else is not a clone, including a
  -- directory that merely holds a downloaded catalog file.
  return Host.fs.exists(Util.join(dir, ".git"))
end

--- The URL the clone fetches from, or nil plus why not.
---
--- Asked through git rather than by reading `.git/config`: the config file's
--- shape is git's business, and a hand-rolled INI reader is how a working tree
--- gets misidentified the one time the format surprises it. Local and instant --
--- `remote get-url` touches no network -- so callers may ask inline.
--- @param dir string
--- @return string|nil url
--- @return string|nil err
function Registry.remote_url(dir, run_now)
  local Git = require("cdinx.manager.git")
  local ok, out, err = run_now(Git.remote_url_args(dir))
  if not ok then return nil, tostring(out ~= "" and out or err) end
  local url = out:match("^%s*(.-)%s*$")
  if not url or url == "" then return nil, "the clone has no origin URL" end
  return url
end

--- Whether the clone is usable for this registry: a working tree whose origin
--- is the configured URL.
---
--- The comparison is exact, after trimming: a clone of a fork is a different
--- registry, not this one with a different name, and using it as this one would
--- install packages reviewed by nobody the user trusts.
--- @param config table
--- @param run_now fun(argv: string[]): boolean, string, string|nil
--- @return boolean ok
--- @return string|nil why
function Registry.valid_clone(config, run_now)
  local dir = Registry.root(config)
  if not Registry.is_clone(dir) then
    return false, "no registry clone at " .. tostring(dir)
  end
  local rev_ok, rev_out = run_now(require("cdinx.manager.git").rev_parse_args(dir))
  if not rev_ok then
    return false, "the registry clone is half-built: "
      .. tostring(rev_out ~= "" and rev_out or "rev-parse failed")
  end
  local url, err = Registry.remote_url(dir, run_now)
  if not url then
    return false, "the registry clone is half-built: " .. tostring(err)
  end
  local want = tostring(config.registry_url or "")
  if url ~= want then
    return false, string.format(
      "the registry clone fetches from %s, not %s", url, want)
  end
  return true
end

--- The commit the clone is at, or nil.
---
--- Local and instant. Shown in the panel next to the catalog state, so "which
--- registry am I reading" has an answer more precise than a branch name -- and
--- answered from git rather than from a file, because HEAD is the only thing
--- that cannot be stale in a checkout.
--- @param config table
--- @return string|nil rev
function Registry.clone_rev(config)
  local dir = Registry.root(config)
  if not Registry.is_clone(dir) then return nil end
  local Git = require("cdinx.manager.git")
  return Git.head_rev(dir)
end

--- The branch the registry follows.
---
--- `config.registry_url` names the repository and never the branch, so the branch
--- comes from the environment with one default: `CDIN_X_BRANCH`, else `main`. One
--- place rather than two, because a refresh that followed a different branch from
--- the one the clone was made from would be reading a registry nobody reviewed.
--- @return string
function Registry.tracked_branch()
  local branch = os.getenv("CDIN_X_BRANCH")
  if type(branch) == "string" and branch ~= "" then return branch end
  return "main"
end

--- Trims the working tree back to the index: `sparse-checkout set registry`,
--- then `reapply`.
---
--- The defined end state after every use of the clone: the working tree holds
--- the index plus nothing else, so it cannot grow as packages are installed.
--- Returns false when git says no, and the caller treats that as corruption --
--- a checkout that will not trim is not a checkout to keep installing from.
--- @param dir string
--- @param run_now fun(argv: string[]): boolean, string, string|nil
--- @return boolean
function Registry.reset_working_tree(dir, run_now)
  local Git = require("cdinx.manager.git")
  local set_argv = Git.sparse_args(dir, { "registry" })
  if not set_argv then return false end
  local ok = run_now(set_argv)
  if not ok then return false end
  local reapply_ok = run_now(Git.sparse_reapply_args(dir))
  if not reapply_ok then return false end
  return true
end

-- ── the index ────────────────────────────────────────────────────────────
--
-- `registry/index.lua`: the third-party recipes. Read through the sandbox like
-- every other untrusted file -- it ships in this repository, but a user's
-- registry clone is a checkout that has been written to by the network, and the
-- reader must not care which one it is looking at.

--- The recipe kinds the index may name. Spelled here so callers that already
--- require the registry need not require a second module; the definition lives
--- in manager/recipe.lua, which is also what `scripts/validate.lua` reads.
Registry.INDEX_KINDS = Recipe.KINDS

--- Reads and validates the index, returning the good recipes.
---
--- One bad recipe does not spoil the file: it is skipped with a collected
--- problem, because an index with forty good entries and one typo is forty
--- packages the panel can still offer. What is refused per recipe is said per
--- recipe, naming the entry.
--- @param config table
--- @param taken table<string, boolean>|nil  first-party names no recipe may claim
--- @return table[] recipes  sorted by name
--- @return string[] problems
function Registry.read_index(config, taken)
  local file = Util.join(Registry.root(config), "registry", "index.lua")
  if not Host.fs.is_file(file) then return {}, {} end

  local data, err = Schema.read_data(file, "index.lua")
  if type(data) ~= "table" then
    return {}, { "registry/index.lua is not readable: " .. tostring(err) }
  end

  local recipes, problems, seen = {}, {}, {}
  local names = {}
  for _, entry in ipairs(data) do
    if type(entry) ~= "table" then
      problems[#problems + 1] = "registry/index.lua: an entry is not a table"
    else
      names[#names + 1] = entry
    end
  end
  -- Deterministic order: the file is hand-edited, and two reads of it must agree
  -- about which problem is reported first.
  table.sort(names, function(a, b)
    return tostring(a.name) < tostring(b.name)
  end)

  for _, entry in ipairs(names) do
    local problem = Recipe.check(entry, taken)
    if problem then
      problems[#problems + 1] = "registry/index.lua: " .. problem
    elseif seen[entry.name] then
      problems[#problems + 1] = string.format(
        "registry/index.lua: %q is listed twice", entry.name)
    else
      seen[entry.name] = true
      recipes[#recipes + 1] = entry
    end
  end
  return recipes, problems
end

return Registry