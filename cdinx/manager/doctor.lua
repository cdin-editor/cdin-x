-- Is this installation sane? Asked the same way from three places.
--
-- The editor's `:cdin-x:doctor`, the command line's `cdin-x doctor`, and CI all
-- want the same answers and none of them can be answered differently: a check
-- that runs in the editor and says "everything is fine" while the command line
-- says the store is missing a package is worse than having no check at all, and
-- two copies of the questions is how that happens.
--
-- So the questions live here and each caller renders them. A check returns
--
--   { name = "registry clone", status = "ok" | "warn" | "bad",
--     detail = <one line>, fix = <what to do about it> }
--
-- and nothing else. A check never raises, never fetches and never writes: `doctor`
-- is the thing a person runs when something is already wrong, and a diagnostic
-- that changes the state it is diagnosing cannot be trusted to report on it.
-- That last rule is why "is the registry stale?" is a question here and not a
-- `fetch`: a stale clone is an answer, and the fix is the user's to run.
--
-- `warn` is not a softer `bad`. `bad` means this cannot work; `warn` means it
-- works but something about it deserves an opinion -- a lock entry for a package
-- that is not on disk, a retired legacy install still listed. Both are printed;
-- only `bad` decides the exit code of the command-line doctor.
local Host    = require "cdinx.host"
local Util    = require "cdinx.manager.util"
local Git     = require "cdinx.manager.git"
local Lock    = require "cdinx.manager.lock"
local Package = require "cdinx.packages"
local Spec    = require "cdinx.manager.spec"

local Doctor = {}

local OK, WARN, BAD = "ok", "warn", "bad"

local function check(name, status, detail, fix)
  return { name = name, status = status, detail = detail, fix = fix }
end

--- Every file under `dir`, by walking it.
---
--- The only walk in this system, and it is here on purpose: the answer is a byte
--- count, a wrong one is a wrong number in a diagnostic, and nothing is being
--- installed from the result. The install path uses `git ls-files` instead, where a
--- wrong answer would be a symlink shipped to a user.
local function all_files(dir)
  local out = {}
  for _, entry in ipairs(Host.fs.list(dir) or {}) do
    local path = Util.join(dir, entry.name)
    if entry.type == "dir" then
      for _, nested in ipairs(all_files(path)) do out[#out + 1] = nested end
    else
      out[#out + 1] = path
    end
  end
  return out
end

local function human(bytes)
  if bytes < 1024 then return string.format("%d B", bytes) end
  if bytes < 1024 * 1024 then
    return string.format("%.1f KiB", bytes / 1024)
  end
  return string.format("%.1f MiB", bytes / (1024 * 1024))
end

--- Whether a package's files are actually there.
---
--- `Host.fs.is_dir` on the store path is the whole test: a package whose directory
--- has been deleted behind the editor is the most common real damage, and nothing
--- else notices until something requires it.
--- @param config table
--- @param name string
--- @return boolean
local function files_present(config, name)
  return Host.fs.is_dir(Util.join(config.store_dir, name))
end

-- ── the checks ────────────────────────────────────────────────────────────

--- git: is it there, and does it understand what this system asks of it?
---
--- The second half matters more than the first. An install with no git works fine
--- until it tries to install anything, and a git older than 2.27 cannot do the
--- sparse clone the registry uses -- which it will fail differently, and much
--- later, than it fails here.
function Doctor.git()
  local exe, why = Git.find()
  if not exe then return check("git", BAD, tostring(why),
    "install Git for Windows, or put git on PATH") end
  local version = Git.version()
  local sparse = Git.supports_sparse()
  return check("git", OK, string.format("%s (%s%s)", tostring(exe), tostring(version),
    sparse and "" or "; sparse clones unsupported, installs will use a plain clone"))
end

--- The registry clone: is it a clone, does it speak to the right remote, is it
--- behind.
function Doctor.registry(config)
  local Registry = require "cdinx.manager.registry"
  local dir = Registry.root(config)
  if not Registry.is_clone(dir) then
    return check("registry clone", BAD, "there is no clone at " .. tostring(dir),
      "open the Extensions panel and press ctrl+r")
  end
  local url, url_err = Registry.remote_url(dir, function(argv)
    return Git.run_now(argv)
  end)
  if not url then
    return check("registry clone", BAD, "half-built: " .. tostring(url_err),
      "delete " .. dir .. " and press ctrl+r")
  end
  local want = tostring(config.registry_url or "")
  if url ~= want then
    return check("registry clone", BAD,
      string.format("it fetches from %s, not %s", url, want),
      "delete " .. dir .. " and press ctrl+r")
  end
  local rev = Registry.clone_rev(config)
  if not rev then
    return check("registry clone", BAD, "it has no commit", "delete " .. dir .. " and press ctrl+r")
  end
  return check("registry clone", OK, string.format("%s at %s", dir, rev:sub(1, 12)))
end

--- The catalog: is there a readable one, and how many names does it hold.
---
--- Zero entries is a warning rather than a failure, because an empty registry is
--- a legitimate state -- this repository's own index ships empty until something is
--- vetted -- and calling it broken would make every fresh install look alarming.
function Doctor.catalog(config)
  local Registry = require "cdinx.manager.registry"
  local path = Registry.catalog_path(config)
  if not path then
    return check("catalog", BAD, "no catalog at " .. tostring(Registry.root(config)),
      "press ctrl+r in the Extensions panel")
  end
  local Fetch = require "cdinx.manager.fetch"
  local data = Fetch.read_catalog(path)
  if type(data) ~= "table" or type(data.plugins) ~= "table" then
    return check("catalog", BAD, "the catalog at " .. path .. " is not readable",
      "press ctrl+r in the Extensions panel")
  end
  local count = 0
  for _ in pairs(data.plugins) do count = count + 1 end
  if count == 0 then
    return check("catalog", WARN, "the catalog lists nothing",
      "an empty registry is valid until a recipe is accepted")
  end
  return check("catalog", OK, string.format("%d package(s) in %s", count, path))
end

--- `packages.lua`: readable, and every source resolvable.
---
--- The problems come back as the check's detail rather than as separate checks,
--- because they are all one thing -- what the user wrote -- and a doctor that
--- reported each misspelled field as its own line would bury the one that matters
--- under four others.
function Doctor.user_file(config)
  local _, problems = Package.load(config)
  if #problems > 0 then
    return check("packages.lua", WARN,
      table.concat(problems, "; "), "fix the lines above in " .. tostring(config.packages_file))
  end
  local specs, source_problems = Spec.resolve(Package.sources(), {})
  if #source_problems > 0 then
    return check("packages.lua", BAD, table.concat(source_problems, "; "),
      "fix the sources block in " .. tostring(config.packages_file))
  end
  local names = {}
  for name in pairs(specs) do names[#names + 1] = name end
  table.sort(names)
  if #names == 0 then
    return check("packages.lua", OK, "no sources; the editor's own set only")
  end
  return check("packages.lua", OK, string.format("%d source(s): %s",
    #names, table.concat(names, ", ")))
end

--- The dev directories a source names: is each one there?
---
--- A separate check from the one above because it is the one a person actually has
--- to act on: a source whose directory moved will never install and never load, and
--- nothing else in this list mentions it.
--- @return table|nil
function Doctor.dev_dirs()
  local specs = Spec.resolve(Package.sources(), {}).specs or {}
  local missing = {}
  for name, spec in pairs(specs) do
    if spec.kind == "dir" and not Host.fs.is_dir(spec.dir) then
      missing[#missing + 1] = string.format("%s -> %s", name, spec.dir)
    end
  end
  if #missing == 0 then return nil end
  table.sort(missing)
  return check("dev directories", BAD, table.concat(missing, "; "),
    "move the directory, or drop the entry from packages.lua")
end

--- The lock: readable, and does it still agree with what is on disk.
---
--- Three ways this can be wrong, and they are not the same severity. A lock that
--- will not read is repaired by itself at the next start, so it is a warning. A
--- lock that names a package nothing has on disk is the interesting one: it is
--- what `restore` acts on, so a stale entry turns a restore into work that
--- restores nothing.
--- @param config table
--- @return table
function Doctor.lock(config)
  local data, problems = Lock.load(config)
  if not data then
    -- No `--rebuild` flag, and deliberately: a diagnostic that repairs is one
    -- whose next answer cannot be compared with its last. The remedy is already
    -- true without a flag -- the lock is a projection, and the state file it
    -- projects from is written by the editor on every change -- so the instruction
    -- is just to start cdin-x again, which rebuilds it at boot.
    return check("cdin-x.lock", WARN, table.concat(problems or {}, "; ")
      .. " -- it is rebuilt from the state file at the next start",
      "start cdin-x again, or run any cdin-x command; nothing else is lost")
  end
  local stale = {}
  for name, entry in pairs(data.packages) do
    if entry.source == "dir" then
      -- A dev directory is not in the lock at all in normal operation; one that is
      -- means something wrote it there, and it has nothing to restore from.
      stale[#stale + 1] = name .. " (a dev directory has no commit)"
    elseif not files_present(config, name) then
      stale[#stale + 1] = name
    end
  end
  if #stale > 0 then
    table.sort(stale)
    return check("cdin-x.lock", WARN,
      string.format("%d entr(y/ies) with nothing on disk: %s",
        #stale, table.concat(stale, ", ")),
      "`cdin-x restore` will put them back")
  end
  local count = 0
  for _ in pairs(data.packages) do count = count + 1 end
  return check("cdin-x.lock", OK, string.format("%d entr(y/ies) in %s",
    count, tostring(Lock.path(config))))
end

--- The store: what is recorded as installed, and what is actually there.
---
--- The recorded set and the files on disk are compared rather than trusted, because
--- they drift in both directions and each direction has a different fix: recorded
--- but missing is damage, missing but recorded nowhere is a directory nobody put
--- there.
function Doctor.store(config, state_lock)
  local bytes, missing, orphaned = 0, {}, {}
  local recorded = {}
  for name in pairs(state_lock or {}) do recorded[name] = true end

  for _, entry in ipairs(Host.fs.list(config.store_dir) or {}) do
    if entry.type == "dir" and not entry.name:match("%.lock$") then
      local name = entry.name
      if name:match("%.partial$") or name:match("%.new$") then
        -- Debris from an interrupted install. Reported, never deleted: the next
        -- operation for that package clears it, and a doctor that removed files
        -- would be doing the thing it was called to diagnose.
        missing[#missing + 1] = name:gsub("%.partial$", ""):gsub("%.new$", "")
      elseif recorded[name] then
        local total = 0
        for _, path in ipairs(all_files(Util.join(config.store_dir, name))) do
          local info = Host.fs.stat(path)
          total = total + (info and info.size or 0)
        end
        bytes = bytes + total
      else
        orphaned[#orphaned + 1] = name
      end
    end
  end
  table.sort(missing)
  table.sort(orphaned)

  if #missing > 0 then
    return check("store", WARN, string.format("interrupted install debris: %s",
      table.concat(missing, ", ")), "installing any of them again clears it")
  end
  if #orphaned > 0 then
    return check("store", WARN, string.format("%d package(s) on disk but not "
      .. "recorded: %s", #orphaned, table.concat(orphaned, ", ")),
      "`cdin-x:clean` removes what is not in the catalog")
  end
  return check("store", OK, human(bytes) .. " in " .. tostring(config.store_dir))
end

--- A superseded legacy install: still on disk, still listed, deliberately not running.
---
--- Reported because it is a real state a user reaches and has to be told about, and
--- because "why is this listed but not working" is the question it answers. Needs
--- the live catalog -- a retirement is a relation between two catalog entries, and
--- one of the two is the package that replaced the other.
--- @param ctx table
--- @return table|nil
function Doctor.retired(ctx)
  if type(ctx) ~= "table" or type(ctx.available) ~= "table" then return nil end
  local Legacy = require "cdinx.manager.legacy"
  local retired = Legacy.recompute(ctx)
  local names = {}
  for name in pairs(retired) do names[#names + 1] = name end
  if #names == 0 then return nil end
  table.sort(names)
  return check("retired packages", WARN,
    string.format("%d superseded install(s) still listed: %s",
      #names, table.concat(names, ", ")),
    "remove them from the Extensions panel; nothing was deleted")
end

-- ── the report ────────────────────────────────────────────────────────────

--- Runs every check and returns them in a fixed order.
---
--- `ctx` is the live manager context, when there is one. Without it the checks
--- that need a catalog fall back to reading the files themselves, so the command
--- line gets the same answers as the editor rather than a thinner set.
--- @param config table
--- @param ctx table|nil
--- @return table[] checks
function Doctor.run(config, ctx)
  local out = {}
  local function add(c) if c then out[#out + 1] = c end end

  add(Doctor.git())
  add(Doctor.registry(config))
  add(Doctor.catalog(config))
  add(Doctor.user_file(config))
  add(Doctor.dev_dirs())

  local state_lock = ctx and ctx.state and ctx.state.lock
  add(Doctor.lock(config))
  if state_lock then add(Doctor.store(config, state_lock)) end

  add(Doctor.retired(ctx))
  return out
end

--- Whether any check failed, which is what a command line's exit code is.
--- @param checks table[]
--- @return boolean
function Doctor.failed(checks)
  for _, c in ipairs(checks or {}) do
    if c.status == BAD then return true end
  end
  return false
end

--- One line per check, for a log or a terminal.
---
--- The three-letter status is deliberately not a colour: this is read in a log
--- window, in a terminal, and in CI, and the only one of those that can show colour
--- is the one that does not need it.
--- @param checks table[]
--- @return string[]
function Doctor.lines(checks)
  local out = {}
  for _, c in ipairs(checks or {}) do
    local mark = c.status == OK and "ok  " or (c.status == WARN and "warn" or "BAD ")
    out[#out + 1] = string.format("%s %-18s %s", mark, c.name, tostring(c.detail))
    if c.fix and c.status ~= OK then
      out[#out + 1] = string.format("     %-18s -> %s", "", tostring(c.fix))
    end
  end
  return out
end

return Doctor
