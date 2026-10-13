-- Structural validation of the catalog.
--
-- Runs with plain lua, from the repository root: `make validate`. It checks
-- the things that are cheap to get wrong and expensive to debug at runtime:
-- the required files, the bundles a cdin build is composed from, the theme
-- layout, the dependency rules, self-containment of every bundle, and the two
-- rules that keep cdin-x independent of cdin — no EXEDIR, and no `core.x`
-- module namespace left over from the rename.
local scan = dofile("scripts/_scan.lua")

-- scan.exists handles files *and* directories; a read-based check would
-- report every category directory as missing.
local exists = scan.exists

local errors = {}
local warnings = {}
local Schema  = dofile("cdinx/schema.lua")

-- The one interpreter every shell-out in this file goes through, decided before
-- either place that uses it: a local declared further down is a *global* to
-- everything above it, and a nil global here put the literal text "nil" into a
-- command line once already.
local Select  = dofile("cdinx/manager/select.lua")
local PYTHON  = os.getenv("CDIN_PYTHON") or Select.python_command()
local root_files = {
  "README.md",
  "cdinx/init.lua",
  "cdinx/config.lua",
  "cdinx/manifest.lua",
  "cdinx/command.lua",
  "plugins/cdin-x/init.lua",
  "scripts/new-plugin.lua",
  "scripts/install.py",
  "scripts/bundle.py",
  "scripts/validate.lua",
}
for _, path in ipairs(root_files) do
  if not exists(path) then errors[#errors+1] = path .. " not found" end
end

-- ── the workflow files ───────────────────────────────────────────────────
--
-- A workflow is only ever read by GitHub, so a mistake in one is invisible until
-- a push -- at which point it costs a run, and the failure is a YAML load error
-- that says nothing about which reference is wrong. Phase 9 deleted a job and
-- left four references to it in ci.yml's `required` gate, which made the workflow
-- fail to load before a single check ran. That is the shape of bug this rule is
-- for: a workflow that cannot parse, or that refers to something not there.
--
-- It lives in validate rather than in ci.yml because `make validate` runs on a
-- contributor's machine and in every build, and the mistake is one nobody
-- catches by reading.
--
-- Deliberately not a YAML parser. These files are hand-written in one shape, and
-- the facts that matter -- a job's `needs`, what a step reads out of `needs`, a
-- job's `uses`, what it passes in `with:` -- are all recognisable line by line. A
-- parser would be a dependency to answer a question patterns answer, and a
-- dependency in `make validate` is a way for the gate itself to stop running.
--
-- What it does NOT check: indentation, quoting, matrices, action versions, or
-- whether a `run:` block's shell is right. Those fail loudly and specifically in
-- GitHub's parser. This asks only what a reader cannot answer by looking.

-- Each line with its comments stripped, so a `# needs:` in a comment cannot
-- register as a reference. Quoted `#` is not a comment in YAML; this
-- repository writes none, and a wrong guess here only costs a pattern match.
local function code_lines(text)
  local out = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = line:gsub("#.*$", "")
  end
  return out
end

-- The job names under `jobs:` in one file, and each job's own block.
--
-- A job name is a line indented by exactly two spaces whose value is empty --
-- `  build:`. Anything deeper is a step or a key inside a job, and anything at
-- zero indentation after `jobs:` has left the section. Depth is not tracked,
-- because a job block in these files is either a reusable `uses:` or a `steps:`
-- list, and both are indented past the name; the pattern for the name is what
-- excludes them, not a brace count that would have to understand YAML to be
-- right.
local function jobs_of(text)
  local jobs, order = {}, {}
  local in_jobs = false
  for _, bare in ipairs(code_lines(text)) do
    if not in_jobs then
      if bare:match("^jobs:%s*$") then in_jobs = true end
    elseif bare:match("^%S") then
      in_jobs = false                       -- a new top-level key ends the section
    else
      local name = bare:match("^  ([%w_%-]+):%s*$")
      if name then
        if not jobs[name] then order[#order + 1] = name end
        jobs[name] = {}
      else
        local owner = order[#order]
        if owner then
          local body = jobs[owner]
          body[#body + 1] = bare
        end
      end
    end
  end
  return jobs, order
end

-- `needs: [a, b]` and `needs: a` both, because both spellings are in use here.
-- Takes the job's block as the array of lines jobs_of built, not as text: the
-- caller should not have to re-join it, and a joined copy would be a second
-- representation to keep in agreement with the first.
local function needs_list(block)
  local list = {}
  for _, line in ipairs(block) do
    local rest = line:match("^%s*needs:%s*(.+)$")
    if rest then
      local inner = rest:match("^%[([^%]]*)%]")
      if inner then
        for name in inner:gmatch("[%w_%-]+") do list[#list + 1] = name end
      else
        local one = rest:match("^([%w_%-]+)%s*$")
        if one then list[#list + 1] = one end
      end
      return list                        -- first `needs:` wins; there is only one
    end
  end
  return list
end

-- Every workflow under .github/workflows, read into
-- { name, text, lines, jobs, order } and keyed by its *name* -- "ci.yml", not a
-- path.
--
-- Keyed by name on purpose. scan.list_files_recursive returns whatever prefix the
-- platform's shell produced: absolute on Windows, relative in a POSIX tree, and
-- spelled differently again under an emulation layer. Keying on that path meant
-- every lookup of a file by its repo-relative name missed on Windows, so the rules
-- that compare one workflow against another -- whether the callee exists, whether
-- the callee declares an input -- silently did nothing there. The rules that report
-- on the file they are currently reading passed regardless, which is what made this
-- look like a working check.
local function load_workflows()
  local out = {}
  if not exists(".github/workflows") then return out end
  for _, path in ipairs(scan.list_files_recursive(".github/workflows")) do
    local fh = io.open(path, "rb")
    if fh then
      local text = fh:read("*a")
      fh:close()
      -- The trailing path component, with either separator: the one thing that is
      -- the same on every platform.
      local name = path:gsub("\\", "/"):match("([^/]+)/*$")
      local jobs, order = jobs_of(text)
      out[name] = { name = name, text = text, lines = code_lines(text),
                    jobs = jobs, order = order }
    end
  end
  return out
end

do
  local docs = load_workflows()

  if not next(docs) then
    errors[#errors+1] = ".github/workflows holds no workflow; a plugin repository " ..
      "without CI cannot tell a user that cdin changed underneath it"
  end

  for _, name in ipairs((function()
    local p = {}
    for k in pairs(docs) do p[#p + 1] = k end
    table.sort(p)
    return p
  end)()) do
    local doc = docs[name]

    -- A job that `needs:` one this file does not define. GitHub rejects the whole
    -- workflow for this, not the one job: nothing in the file runs.
    for _, job in ipairs(doc.order) do
      for _, dep in ipairs(needs_list(doc.jobs[job])) do
        if not doc.jobs[dep] then
          errors[#errors+1] = string.format(
            "%s: job %q needs %q, which is not a job in this file. GitHub rejects "
            .. "the workflow outright rather than skipping the job, so nothing here "
            .. "runs.", name, job, dep)
        end
      end
    end

    -- `needs.X.result` and `needs.X.outputs` read inside a step. Same
    -- consequence, and the easiest reference in the file to leave behind: it
    -- reads correctly right up until the job it names is renamed.
    for _, bare in ipairs(doc.lines) do
      for dep in bare:gmatch("needs%.([%w_%-]+)") do
        if not doc.jobs[dep] then
          errors[#errors+1] = string.format(
            "%s: a step reads needs.%s, which is not a job in this file", name, dep)
        end
      end
    end

    -- A job that calls another workflow: the target must exist, and everything it
    -- is passed must be an input the callee declares.
    for _, job in ipairs(doc.order) do
      local callee
      for _, line in ipairs(doc.jobs[job]) do
        callee = line:match("%./%.github/workflows/([%w_%-%.]+)")
        if callee then break end
      end
      if callee then
        local other = docs[callee]
        if not other then
          errors[#errors+1] = string.format(
            "%s: job %q uses .github/workflows/%s, which does not exist",
            name, job, callee)
        else
          -- The keys the caller passes. `with:` opens a block whose children are
          -- the keys, and the flag is declared outside the loop -- inside it, the
          -- flag is false on every line that could set it true, and the block is
          -- never read at all.
          local passed = {}
          local in_with, with_indent = false, 0
          for _, line in ipairs(doc.jobs[job]) do
            if in_with then
              -- A line at zero indentation, or at less than `with:`'s own, has
              -- left the block.
              if line:match("^%S") or #line:match("^%s*") <= with_indent then
                in_with = false
              else
                local key = line:match("^%s+([%w_%-]+):")
                if key then passed[key] = true end
              end
            elseif line:match("^%s*with:%s*$") then
              in_with = true
              with_indent = #line:match("^%s*")
            end
          end

          -- The keys the callee declares, under `on: workflow_call: inputs:`.
          -- Collected by indentation relative to the `inputs:` line rather than
          -- scanned, because a scan of the whole file picks up every key in it and
          -- then declares everything legal.
          local declared = {}
          local in_inputs, inputs_indent = false, nil
          for _, line in ipairs(other.lines) do
            if in_inputs then
              local indent = #line:match("^%s*")
              if line:match("^%S") or indent <= inputs_indent then
                break
              end
              local key = line:match("^%s+([%w_%-]+):%s*$")
              if key and indent == inputs_indent + 2 then declared[key] = true end
            elseif line:match("^%s*inputs:%s*$") then
              in_inputs, inputs_indent = true, #line:match("^%s*")
            end
          end

          for key in pairs(passed) do
            if not declared[key] then
              errors[#errors+1] = string.format(
                "%s: job %q passes with.%s to %s, which does not declare it as an "
                .. "input", name, job, key, callee)
            end
          end
        end
      end
    end
  end

  -- ci.yml's `required` job is the gate a tag passes through. A job added above
  -- and not listed there runs but cannot fail a release; a job listed there and
  -- removed above is the load error checked already. The two lists have to agree,
  -- and nothing else in the file notices when they do not.
  local ci = docs["ci.yml"]
  if ci and ci.jobs["required"] then
    local gated = {}
    for _, dep in ipairs(needs_list(ci.jobs["required"])) do gated[dep] = true end
    for _, job in ipairs(ci.order) do
      if job ~= "required" and not gated[job] then
        errors[#errors+1] = string.format(
          "ci.yml: job %q is not in the `required` gate's needs, so it cannot "
          .. "fail a release. Add it there or say why it should not gate.", job)
      end
    end
    -- And the reverse direction, which is the Phase 9 shape: the gate refers to a
    -- job that is gone. Reported again, with the gate named, because "which list
    -- is wrong" is the useful half of that message.
    for _, dep in ipairs(needs_list(ci.jobs["required"])) do
      if not ci.jobs[dep] then
        errors[#errors+1] = "ci.yml: the `required` gate needs '" .. dep ..
          "', which is not a job in this file"
      end
    end
  end
end

-- ── CI path filters ──────────────────────────────────────────────────────
--
-- A `paths:` entry in a workflow, or a `files:` entry in psx.yml, decides
-- whether a change runs any check at all. An entry naming a file that does not
-- exist cannot fail: it never matches, the workflow is already green for that
-- path, and nothing says so.
--
-- This is the failure that survives every rule above. The workflow section
-- proves a workflow's *internal* references resolve -- its jobs, its needs, its
-- callees. A path filter is not an internal reference; it points at the working
-- tree. Deleting the file it names removes the check that would have noticed
-- the deletion, and the gate can no longer report on its own subject.
--
-- A glob is a pattern, not a path. `registry/**` is not a filename, and
-- asserting on it as one reports a false failure on every run, so an entry
-- carrying a wildcard is skipped rather than checked.
--
-- Deliberately not a YAML parser, for the reason at the top of the workflow
-- section: a dependency in `make validate` is a way for the gate itself to stop
-- running.
do
  -- Every file that carries path filters. psx.yml lists them under `files:`;
  -- each workflow under .github/workflows lists them under `paths:`.
  local filter_files = {}
  if exists("psx.yml") then
    filter_files[#filter_files + 1] = { name = "psx.yml", key = "files" }
  end
  for _, path in ipairs(scan.list_files_recursive(".github/workflows") or {}) do
    -- The trailing component, not the path as the shell spelled it: that is
    -- absolute on Windows and relative elsewhere, and the workflow section
    -- above already records that depending on it made a lookup silently miss.
    local name = path:gsub("\\", "/"):match("([^/]+)/*$")
    filter_files[#filter_files + 1] = {
      name = ".github/workflows/" .. name,
      key = "paths",
    }
  end

  for _, src in ipairs(filter_files) do
    local fh = io.open(src.name, "rb")
    if fh then
      local text = fh:read("*a")
      fh:close()
      local checking = false
      for _, line in ipairs(code_lines(text)) do
        if line:match("^%s*" .. src.key .. ":%s*$") then
          checking = true
        elseif line:match("^%S") then
          checking = false
        end
        if checking then
          local p = line:match('^%s*%-%s*path:%s*"([^"]+)"')
            or line:match("^%s*%-%s*path:%s*'([^']+)'")
            or line:match('^%s*%-%s*"([^"]+)"')
            or line:match("^%s*%-%s*'([^']+)'")
          if p and not p:find("*", 1, true) and not p:find("?", 1, true) then
            -- psx.yml writes a repository-absolute path and a workflow writes one
            -- relative to the root. Both name the same file.
            if not exists((p:gsub("^/", ""))) then
              errors[#errors + 1] = string.format(
                "%s: a CI path filter names %s, which does not exist. The filter "
                  .. "can never match, so a change to that file runs nothing, and "
                  .. "the check that would have noticed is the one that stopped "
                  .. "running.",
                src.name,
                p
              )
            end
          end
        end
      end
    end
  end
end

-- ── fonts ────────────────────────────────────────────────────────────────
-- The bundled fonts are the ones this repository ships, and a cdin build
-- cannot start without them. scripts/bundle.py refuses to substitute
-- anything, so the absence has to be a hard error here too rather than
-- something a build discovers later.
local REQUIRED_FONTS = { "font.ttf", "monospace.ttf", "icons.ttf" }
if not exists("fonts") then
  errors[#errors+1] = "fonts/ not found — a cdin build cannot start without them"
else
  for _, f in ipairs(REQUIRED_FONTS) do
    if not exists("fonts/" .. f) then
      errors[#errors+1] = "fonts/" .. f .. " not found (fonts/ exists but is incomplete)"
    end
  end
end


-- ── the catalog index ──────────────────────────────────────────────────
local function is_theme(entry)
  return entry.meta.type == "theme" or entry.category == "themes"
end

-- Two maps, because two questions are asked of the catalog: `known` is the set
-- of things that have a require prefix, `catalog` is every name a bundle may
-- name — a theme has no require prefix, but a bundle still carries it.
local known, catalog = {}, {}
-- Where each name was first claimed, so a second claimer can be named. Two
-- directories declaring one name is never a precedence question inside one
-- repository: it is a copy left behind by a move, or a manifest that lies about
-- what it is called, and both are mistakes rather than choices.
local claimed_at = {}
for _, entry in ipairs(scan.plugin_entries()) do
  if entry.meta.name then
    local held = known[entry.meta.name]
    if held then
      errors[#errors+1] = string.format(
        "%s is declared by two directories: %s and %s",
        entry.meta.name, tostring(held.base), tostring(entry.base))
    else
      known[entry.meta.name] = entry
      catalog[entry.meta.name] = entry
      claimed_at[entry.meta.name] = entry.base
    end
  end
end
local themes = scan.theme_entries()
for _, theme in ipairs(themes) do
  if catalog[theme.name] == nil then
    catalog[theme.name] = { base = theme.base, meta = theme.data, theme = true }
  end
end

-- -- ── every removed package says where it went ────────────────────────────────
--
-- `cdinx/manager/moved.lua` is the only record of what twenty-odd packages
-- became, and a record nobody checks is a record that drifts. The merge that
-- moved them keeps its history; this table does not, and an entry pointing at a
-- package that has since been renamed is advice worse than none.
--
-- So each owner must be a package this tree has, and each named feature must be
-- one that owner declares. `entry.meta` is already the sandboxed manifest, read
-- by the scan above, so this check reads no more code than that did.
do
  local Moved = dofile("cdinx/manager/moved.lua")

  for _, old in ipairs(Moved.names()) do
    local entry = Moved.lookup(old)
    if not entry.owner or entry.owner == "" then
      errors[#errors+1] = string.format("moved.lua: %s names no package it went to", old)
    elseif not known[entry.owner] then
      errors[#errors+1] = string.format(
        "moved.lua: %s points at %q, which is not a package in this tree",
        old, entry.owner)
    elseif entry.feature then
      local meta = known[entry.owner].meta
      if not (meta.features and meta.features[entry.feature]) then
        errors[#errors+1] = string.format(
          "moved.lua: %s points at the %q feature of %q, which declares no such feature",
          old, entry.feature, entry.owner)
      end
    end

    if known[old] then
      warnings[#warnings+1] = string.format(
        "moved.lua still lists %q as removed, and it is a package in this tree", old)
    end
  end
end

-- ── the third-party index ────────────────────────────────────────────────
--
-- `registry/index.lua` is the file strangers install from, so every entry is
-- checked the way the reader checks it at runtime: a valid name that no
-- first-party package claims, a usable git URL, a 40-hex commit (never a tag --
-- CI resolves the tag before the recipe lands), a subdir that stays inside the
-- repository, a known kind. An empty index is valid: no vetted package is not
-- an error, and the reader treats a missing file the same way.
do
  local path = "registry/index.lua"
  local f = io.open(path, "rb")
  if not f then
    errors[#errors+1] = "registry/index.lua is missing; the file may be empty, but it must exist"
  else
    f:close()
    -- The reader itself needs the host, so the gate reads through the sandbox
    -- and checks with the same pure module the reader uses -- one implementation
    -- of "what a recipe is", called from both sides rather than written twice.
    local Recipe = dofile("cdinx/manager/recipe.lua")
    local data, err = Schema.read_data(path, "index.lua")
    local recipes, problems = {}, {}
    if type(data) ~= "table" then
      problems[#problems + 1] = "registry/index.lua is not readable: " .. tostring(err)
    else
      local taken = {}
      for name in pairs(known) do taken[name] = true end
      -- Themes are catalog names too: a recipe may not claim one either.
      for _, theme in ipairs(scan.theme_entries()) do taken[theme.name] = true end
      local seen = {}
      local names = {}
      for _, entry in ipairs(data) do names[#names + 1] = entry end
      table.sort(names, function(a, b)
        return tostring(a.name) < tostring(b.name)
      end)
      for _, entry in ipairs(names) do
        if type(entry) ~= "table" then
          problems[#problems + 1] = "registry/index.lua: an entry is not a table"
        else
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
      end
    end
    for _, problem in ipairs(problems) do
      errors[#errors+1] = problem
    end
    -- The reader sorts; the file should already be sorted, so two checkouts
    -- agree about more than the set.
    local names = {}
    for _, recipe in ipairs(recipes) do names[#names + 1] = recipe.name end
    for i = 2, #names do
      if names[i - 1] > names[i] then
        errors[#errors+1] = "registry/index.lua is not sorted by name: "
          .. tostring(names[i - 1]) .. " comes before " .. tostring(names[i])
        break
      end
    end
  end
end

-- At least one theme root has to exist, and it has to hold at least one theme:
-- a build whose theme root is missing ships an editor with no `default`, which
-- the host tolerates by falling back -- so the failure is silent and the only
-- place it can be caught is here.
do
  local found_roots = {}
  for _, root in ipairs(scan.THEME_ROOTS) do
    if exists(root) then found_roots[#found_roots + 1] = root end
  end
  if #found_roots == 0 then
    errors[#errors+1] = "no theme root exists; looked for " ..
      table.concat(scan.THEME_ROOTS, " and ")
  elseif #scan.theme_entries() == 0 then
    errors[#errors+1] = "no theme found in " .. table.concat(found_roots, " and ") ..
      " - a theme is <root>/<name>/theme.lua and the host reads exactly that"
  end
end

local function namespace_of(entry)
  return entry.meta.category or entry.category
end

-- The prefix a package's own modules are required under. A package with a
-- package.lua is named by that file, and its modules are `require`d as
-- `<name>.<module>`; everything else is still required by its place in the
-- tree, and keeps being checked that way.
local function module_prefix(entry)
  if entry.package_file then return entry.meta.name end
  local p = entry.path:gsub("\\", "/")
  if entry.single_file then
    p = p:gsub("%.lua$", "")
  else
    p = p:gsub("/[^/]+%.lua$", "")
  end
  return (p:gsub("/", "."))
end

-- The plugin owning a required module: the longest matching prefix wins,
-- so vim.ex resolves to vim rather than to a shorter prefix.
local function owner_of(module_name)
  local best_name, best_len
  for name, entry in pairs(known) do
    local prefix = module_prefix(entry)
    if module_name == prefix or module_name:sub(1, #prefix + 1) == (prefix .. ".") then
      if not best_len or #prefix > best_len then
        best_name, best_len = name, #prefix
      end
    end
  end
  return best_name
end

--- A file's path relative to the package it is in, in forward slashes.
---
--- The key a manifest's `with` table is written in is a path like `with/themes.lua`,
--- and a rule about "the file the manifest named" has to compare it against
--- something. Normalising both to forward slashes is what makes the comparison
--- work on Windows, where `files_under` hands back backslashes and the manifest
--- does not.
--- @param entry table  a catalog entry, carrying `base`
--- @param path string  an absolute path from `files_under`
--- @return string|nil
local function relpath_of(entry, path)
  local base = tostring(entry.base or ""):gsub("\\", "/")
  if base:sub(-1) == "/" then base = base:sub(1, -2) end
  local p = path:gsub("\\", "/")
  if base ~= "" and p:sub(1, #base + 1) == base .. "/" then
    return p:sub(#base + 2)
  end
  return nil
end

local function x_requires(path)
  local f = io.open(path, "rb")
  if not f then return {} end
  local src = f:read("*a")
  f:close()
  local out, seen = {}, {}
  local function add(mod)
    if not seen[mod] then seen[mod] = true; out[#out + 1] = mod end
  end
  for mod in src:gmatch('require%s*%(?%s*"([Xx]%.[%w_%.%-]+)"') do add(mod) end
  for mod in src:gmatch("require%s*%(?%s*'([Xx]%.[%w_%.%-]+)'") do add(mod) end
  return out
end

--- Every `require "a.b"` in a file, whatever it names.
local function requires_of(path)
  local f = io.open(path, "rb")
  if not f then return {} end
  local src = f:read("*a")
  f:close()
  local out, seen = {}, {}
  local function add(mod)
    if not seen[mod] then seen[mod] = true; out[#out + 1] = mod end
  end
  for mod in src:gmatch('require%s*%(?%s*"([%w_][%w_%.%-]*)"') do add(mod) end
  for mod in src:gmatch("require%s*%(?%s*'([%w_][%w_%.%-]*)'") do add(mod) end
  return out
end

-- directories once per plugin and made validation take minutes.
local listing_cache = {}
local function files_under(dir)
  local hit = listing_cache[dir]
  if not hit then
    hit = scan.list_files_recursive(dir)
    listing_cache[dir] = hit
  end
  return hit
end
-- ── the two selections agree ──────────────────────────────────────────────
--
-- cdinx/manager/select.lua and select_files in scripts/bundle.py are two
-- implementations of one grammar, because the bundler cannot run Lua. Two
-- implementations of anything drift, and this one drifts into a build that ships
-- a file the editor would not have installed, or the reverse -- and neither is
-- visible until a user reports a missing module.
--
-- So both run over every first-party package and the results are compared. The
-- Python side is asked through `bundle.py --select`, which prints one relative
-- path per line, so the comparison is on the same shape the Lua side produces.
--
do
  -- Sizes are not compared: the Lua side is handed no sizes, because a selection is
  -- about which files, not how big they are, and inventing a size here would be a
  -- second source for a number the filesystem already has.
  --
  -- `PYTHON` is the file-scope local declared at the top: `python3` first and
  -- `python` as the fallback, because a Windows Python installs itself as
  -- `python.exe` and only sometimes also provides `python3`. A machine that has
  -- Python and no `python3` on PATH otherwise made every package's cross-check fail
  -- with a count mismatch -- the error says the *selections* disagree, when what
  -- actually happened is that one side of the comparison was an
  -- interpreter-not-found message counted as two filenames.
  for _, entry in ipairs(scan.plugin_entries()) do
    if entry.meta.name and not is_theme(entry) and not entry.single_file then
      local base = entry.base

      -- list_files_recursive strips the current directory, not the package, so the
      -- package's own directory comes off before the paths mean anything to the
      -- selector.
      local prefix = base:gsub("\\", "/") .. "/"
      local candidates = {}
      for _, path in ipairs(files_under(base)) do
        local rel = path:gsub("\\", "/")
        if rel:sub(1, #prefix) == prefix then rel = rel:sub(#prefix + 1) end
        candidates[#candidates + 1] = { path = rel, size = 0 }
      end

      local chosen, _, err = Select.pick(candidates)
      if not chosen then
        errors[#errors+1] = string.format(
          "%s: the Lua selection refuses this package: %s", base, tostring(err))
      else
        local lua_names = {}
        for _, item in ipairs(chosen) do lua_names[#lua_names + 1] = item.path end
        table.sort(lua_names)

        local pipe = io.popen(string.format(
          '%s scripts/bundle.py --select "%s" 2>&1', PYTHON, base))
        local out = pipe and pipe:read("*a") or ""
        if pipe then pipe:close() end

        local py = {}
        for line in out:gmatch("[^\n]+") do
          if line ~= "" then py[#py + 1] = line end
        end
        table.sort(py)

        if #lua_names ~= #py then
          errors[#errors+1] = string.format(
            "%s: the Lua and Python selections disagree on how many files (%d vs %d)",
            base, #lua_names, #py)
        else
          for i = 1, #lua_names do
            if lua_names[i] ~= py[i] then
              errors[#errors+1] = string.format(
                "%s: the Lua and Python selections disagree: lua has %s where python "
                .. "has %s", base, lua_names[i], py[i])
              break
            end
          end
        end
      end
    end
  end
end

for name, entry in pairs(known) do
  if not is_theme(entry) then
    local declared = {}
    for _, d in ipairs(entry.meta.dependencies or {}) do declared[d] = true end
    local files = entry.single_file and { entry.path } or files_under(entry.base)
    for _, f in ipairs(files) do
      for _, mod in ipairs(x_requires(f)) do
        local owner = owner_of(mod)
        if owner and owner ~= name then
          if not declared[owner] then
            errors[#errors+1] = string.format(
              "%s requires %s (owned by %q) without declaring it: %s", name, mod, owner, f)
          elseif namespace_of(entry) ~= "integration" then
            errors[#errors+1] = string.format(
              "%s is in %s/ and requires %s — cross-package wiring belongs in a `with` entry: %s",
              name, namespace_of(entry), mod, f)
          end
        end
      end
    end
  end
end

-- ── a package with a package.lua ─────────────────────────────────────────
--
-- Two rules that only exist because the package declares its name and may
-- therefore require modules by that name:
--
--   no reach into another package   `require "<other>.<sub>"` takes a
--                                  submodule of a package it did not declare,
--                                  which is the other half of architecture
--                                  invariant 3: a dependency's submodules are
--                                  private.
--   no cross-package require at all unless declared, same as above.
--
-- A `with` entry is the one exemption, and it is a narrow one. The files that
-- belong to a `with` entry -- the entry itself and the directory named after it --
-- are allowed to reach into the package that entry names. That is what a `with`
-- entry is for: it exists to wire two packages together that cannot know about
-- each other. Nothing else in the package may reach, and a `with` file may reach
-- only the one package its own entry named, so the exemption cannot become a
-- general permission to reach in.
--
-- The two forms live in one tree during the move, so this is checked only for
-- packages that ship a package.lua; the rest keep the path-shaped rules above.
for name, entry in pairs(known) do
  if entry.package_file and not is_theme(entry) then
    local prefix = module_prefix(entry)
    local declared = {}
    for _, d in ipairs(entry.meta.dependencies or {}) do declared[d] = true end
    -- rel -> the partner that file (or that file's with-entry) may reach into
    local with_partner = {}
    for partner, value in pairs(entry.meta.with or {}) do
      -- A partner may carry a list of paths: two seams can wait on one package.
      local paths = type(value) == "table" and value or { value }
      for _, rel in ipairs(paths) do
        local norm = (tostring(rel):gsub("\\", "/"))
        with_partner[norm] = partner
        -- The entry's own payload, in a directory named after it. `with/git.lua`
        -- owns `with/git/`, and those files are part of the same seam.
        if norm:sub(-4) == ".lua" then
          local dir = norm:gsub("%.lua$", "")
          with_partner[dir .. "/"] = partner
          with_partner[dir .. "/init.lua"] = partner
        end
      end
    end
    local files = entry.single_file and { entry.path } or files_under(entry.base)
    for _, f in ipairs(files) do
      local rel = relpath_of(entry, f)
      local partner = nil
      if rel then
        local norm = rel:gsub("\\", "/")
        partner = with_partner[norm]
        -- Longest directory prefix wins, so `with/git/commands.lua` resolves to
        -- whichever entry owns `with/git/`.
        if not partner then
          for path, p in pairs(with_partner) do
            if path:sub(-1) == "/" and norm:sub(1, #path) == path then partner = p break end
          end
        end
      end
      for _, mod in ipairs(requires_of(f)) do
        local owner = owner_of(mod)
        if owner and owner ~= name then
          if partner and owner == partner then
            -- the one reach a with entry exists to make
          elseif mod == prefix then
            -- the owner's own root module, required from outside itself
          elseif not declared[owner] then
            errors[#errors+1] = string.format(
              "%s requires %s, owned by %q, without declaring it: %s", name, mod, owner, f)
          elseif mod:sub(1, #owner + 1) ~= owner .. "." then
            -- nothing: mod is the owner's root module
          elseif partner then
            errors[#errors+1] = string.format(
              "%s belongs to the with %q entry but reaches %s, owned by %q — a with entry may only reach the package it named: %s",
              name, partner, mod, owner, f)
          else
            errors[#errors+1] = string.format(
              "%s requires %s, a submodule of %q — a dependency is used through its root module only: %s",
              name, mod, owner, f)
          end
        end
      end
    end
  end
end

-- Every declared dependency has to exist, or install order is undefined.
for name, entry in pairs(known) do
  for _, d in ipairs(entry.meta.dependencies or {}) do
    if not catalog[d] then
      errors[#errors+1] = string.format("%s declares dependency %q which is not in the tree", name, d)
    end
  end
end

-- A field the schema does not name. A warning, not an error: a package written
-- against a newer schema must still load, or adopting one becomes a two-step
-- edit. It is reported because a typo'd field is otherwise invisible — the
-- kernel reads what it knows and ignores the rest, and its author sees a
-- package that quietly does not do what they wrote.
for name, entry in pairs(known) do
  -- The spec as the file declared it, not the normalised record beside it.
  if entry.spec then
    for _, field in ipairs(Schema.unknown_fields(entry.spec)) do
      warnings[#warnings+1] = string.format(
        "%s sets %q, which the schema does not define (ignored): %s",
        name, field, entry.package_file)
    end
  end
end

-- ── independence from cdin ───────────────────────────────────────────────
--
-- Two rules, and both exist because the alternative fails silently rather
-- than loudly:
--
--   no EXEDIR     EXEDIR is a global the host defines as the directory the
--                  binary lives in. Depending on it assumes a cdin install
--                  layout, which is exactly what cdin-x must not assume.
--   no core.x     the old module namespace. A leftover `require "core.x…"`
--                  resolves to nothing on a host that has no such module, and
--                  fails at load time rather than at build time.
--
-- Only code is checked, and `--` comments and string literals are stripped
-- first so a line that merely *mentions* either word is not a failure.
-- Where code lives. Read from the catalog's own roots rather than hard-coded,
-- so the set follows the move out of X/ instead of needing an edit per package.
local CODE_DIRS = { "cdinx" }
for _, root in ipairs(scan.CATALOG_ROOTS) do CODE_DIRS[#CODE_DIRS + 1] = root end

local function code_files(dir)
  local out = {}
  for _, path in ipairs(scan.list_files_recursive(dir) or {}) do
    if path:match("%.lua$") then out[#out + 1] = path end
  end
  return out
end

local function strip_comments(src)
  src = src:gsub("%-%-%[%[.*%]%]", " ")          -- --[[ block ]]
  src = src:gsub("%-%-%[=*%[.*%]=*%]", " ")        -- --[==[ block ]==]
  return (src:gsub("%-%-[^\n]*", " "))             -- -- line
end

for _, dir in ipairs(CODE_DIRS) do
  for _, file in ipairs(code_files(dir)) do
    local handle = io.open(file, "rb")
    if handle then
      local code = strip_comments(handle:read("*a") or "")
      handle:close()

      for line in code:gmatch("[^\n]+") do
        if line:find("EXEDIR", 1, true) then
          errors[#errors+1] = string.format(
            "%s references EXEDIR — cdin-x must not assume a cdin install layout", file)
        end
        if line:find('core.x', 1, true) then
          errors[#errors+1] = string.format(
            "%s references core.x — the module namespace is now cdinx.*", file)
        end
      end
    end
  end
end

-- ── every bundle closure is complete and self-contained ──────────────────
--
-- scripts/bundle.py copies the packages a bundle names and nothing else, so a
-- bundle whose closure reaches outside itself builds into something that
-- cannot load: the require resolves to a module the build does not have. This
-- is not a style rule — it is the property that makes the bundle valid, and it
-- cannot be checked any other way, because the failure only appears in a built
-- cdin.
--
-- The closure is what scripts/bundle.py resolves: the bundle's includes, plus
-- the `dependencies` of everything in it. Bundles may include other bundles,
-- so the walk is recursive; `optional` is allowed to name something that is
-- not there, which is a warning rather than a broken bundle.
local function load_bundle(path)
  local chunk, cerr = loadfile(path)
  if not chunk then
    errors[#errors+1] = string.format("%s: %s", path, tostring(cerr))
    return nil
  end
  local ok, data = pcall(chunk)
  if not ok or type(data) ~= "table" then
    errors[#errors+1] = string.format("%s: a bundle file must return a table", path)
    return nil
  end
  return data
end

local bundles = {}
local bundle_paths = scan.list_files_recursive("bundles") or {}
if #bundle_paths == 0 then
  errors[#errors+1] = "bundles/ not found or empty — a build names one of these, " ..
    "and there is none to name"
end
table.sort(bundle_paths)
for _, path in ipairs(bundle_paths) do
  local bundle = load_bundle(path)
  if bundle then
    local file_name = path:match("([^/\\]+)%.lua$")
    if type(bundle.name) ~= "string" or bundle.name == "" then
      errors[#errors+1] = path .. ": a bundle file must declare a name"
    elseif bundle.name ~= file_name then
      errors[#errors+1] = string.format(
        "%s declares name %q, but --bundle selects it as %q", path, bundle.name, file_name)
    elseif bundles[bundle.name] then
      errors[#errors+1] = string.format("two bundle files declare the name %q", bundle.name)
    else
      bundles[bundle.name] = bundle
    end
  end
end

-- `empty` and `minimal` have to stay package-free. `empty` is what a build names
-- when it wants nothing from this repository, and `minimal` is the kernel alone;
-- a package quietly added to either is one that ships where the owner said it
-- would not.
for _, name in ipairs({ "empty", "minimal" }) do
  local bundle = bundles[name]
  if bundle and #(bundle.includes or {}) > 0 then
    errors[#errors+1] = string.format("bundles/%s.lua names %s — that bundle carries nothing",
      name, table.concat(bundle.includes or {}, ", "))
  end
end

-- Adds `name` and everything it pulls in to `closure`: a package brings the
-- packages it declares as dependencies, and a bundle brings its members. That
-- is the closure scripts/bundle.py resolves.
-- `seen` is the set of bundles being expanded on the current path, so a cycle
-- is reported as the path rather than as a name repeating with no explanation.
-- `path` is that path, used only to say who wanted a name that is not there.
-- Returns false plus a reason; an `optional` name that is not in the tree is
-- not a failure, because it is optional.
local function take_member(name, required, closure, seen, path)
  if closure[name] then return true end

  local entry = catalog[name]
  if entry then
    closure[name] = true
    if not (entry.meta.dependencies or {})[1] then return true end
    local deeper = {}
    for i = 1, #path do deeper[i] = path[i] end
    deeper[#deeper + 1] = name
    for _, dep in ipairs(entry.meta.dependencies) do
      local ok, reason = take_member(dep, true, closure, seen, deeper)
      if not ok then return false, reason end
    end
    return true
  end

  local bundle = bundles[name]
  if not bundle then
    if required then
      local referrer = path[#path]
      if #path > 1 then
        return false, string.format("%q needs %q, which is not in the tree",
          referrer, name)
      end
      return false, string.format("bundle %q names %q, which is not in the tree",
        referrer, name)
    end
    return true
  end
  if seen[name] then
    return false, "bundle cycle: " .. table.concat(path, " -> ") .. " -> " .. name
  end

  seen[name] = true
  for _, field in ipairs({ "includes", "optional" }) do
    for _, member in ipairs(bundle[field] or {}) do
      local ok, reason = take_member(member, field == "includes", closure, seen, { name })
      if not ok then return false, reason end
    end
  end
  seen[name] = nil
  return true
end

-- The closure of each bundle that resolves, kept for the bundle check below:
-- it is the exact file set scripts/bundle.py is expected to write.
local closures = {}

local bundle_names = {}
for bundle_name in pairs(bundles) do bundle_names[#bundle_names+1] = bundle_name end
table.sort(bundle_names)

for _, name in ipairs(bundle_names) do
  local closure, reason = {}, nil
  for _, member in ipairs(bundles[name].includes or {}) do
    local ok, why = take_member(member, true, closure, { [name] = true }, { name })
    if not ok then reason = why; break end
  end

  if not reason then
    for _, member in ipairs(bundles[name].optional or {}) do
      if not catalog[member] and not bundles[member] then
        warnings[#warnings+1] = string.format(
          "bundle %q: optional %q is not in the tree", name, member)
      end
      local ok, why = take_member(member, false, closure, { [name] = true }, { name })
      if not ok then reason = why; break end
    end
  end

  if reason then
    errors[#errors+1] = string.format("bundle %q does not resolve: %s", name, reason)
  else
    -- Everything in the closure has to resolve inside it.
    local members = {}
    for member in pairs(closure) do members[#members+1] = member end
    table.sort(members)

    for _, member in ipairs(members) do
      local entry = known[member]
      if entry then
        local files = entry.single_file and { entry.path } or files_under(entry.base)
        for _, f in ipairs(files) do
          for _, mod in ipairs(x_requires(f)) do
            local owner = owner_of(mod)
            if owner and not closure[owner] then
              errors[#errors+1] = string.format(
                "bundle %q: %s requires %s (owned by %q), which the bundle does not contain: %s",
                name, member, mod, owner, f)
            end
          end
        end
        -- A `bundle_with` path that is not in the repository is a build that
        -- copies nothing where the package's own modules should be.
        for _, rel in ipairs(entry.meta.bundle_with or {}) do
          if not exists(rel) then
            errors[#errors+1] = string.format(
              "bundle %q: %s declares bundle_with = { %q }, which is not in the tree",
              name, member, rel)
          end
        end
      end
    end

    closures[name] = members
  end
end

-- ── a register/unregister seam ───────────────────────────────────────────
--
-- Every plugin has to answer to the same two calls, because the manager and
-- each integration's own init() assume they exist. A plugin that exposes
-- neither loads, does nothing, and reports nothing: the manager's pcall
-- around init() only catches a *raise*, and a missing function is a raise the
-- reader then has to decode from one line among forty in the log.
--
-- `M.register` on the entry point is not the only way in. A plugin may delegate
-- to siblings (tab does: `require("X.core.tab.impl").register()`), in which
-- case the seam is a call to a name that has to resolve. Both shapes are
-- checked: the call must name a function, on the entry point or on a sibling
-- it requires, and the pair must be symmetric.
--
-- This is a static check, not a load. It cannot see a nil field two levels
-- deep in someone's own module, which is what scripts/load_check.lua is for.
local function has_function(tbl_or_false, name)
  if not tbl_or_false then return false end
  return type(rawget(tbl_or_false, name)) == "function"
    or type((getmetatable(tbl_or_false) or {}).__index == "function"
      and (tbl_or_false[name])) == "function"
end

-- The table an init.lua's register() call resolves to, without running it.
-- dofile would execute the body, which is the thing being avoided: a
-- top-level require in a manifest-carrying file is a catalog hazard, and
-- validation must not trigger one.
local function seam_target(entry)
  -- the entry point itself, if it defines the seam
  local init_file = entry.single_file and entry.path or (entry.base .. "/init.lua")
  local src = io.open(init_file, "rb")
  if not src then return nil end
  local body = strip_comments(src:read("*a") or "")
  src:close()

  -- entry-point form: `function M.register()`
  if body:find("function%s+M%.register%s*%(") then return { entry.base, "entry point" } end

  -- delegated form: require("<sibling>").register()
  local mod = body:match('require%s*%(?%s*"([^"]+)"%s*%)%.register%s*%(')
  if not mod then return nil end

  -- Resolve the module name to a file, the way the runtime would. For a
  -- package with a package.lua the name starts with the package's own name and
  -- the rest is a path inside it; for everything else the name is already a
  -- repo-relative path with dots turned into separators, because that is how
  -- package.path is searched — `core.tab.impl` IS `core/tab/impl`, and
  -- prefixing a root would make it `packages/X/core/…`.
  local rel
  if entry.package_file then
    local rest = mod:match("^" .. entry.meta.name .. "%.(.+)$")
    rel = rest and (entry.base .. "/" .. rest:gsub("%.", "/")) or nil
  else
    rel = mod:gsub("%.", "/")
  end
  if not rel then return { "?" .. mod, mod } end

  for _, cand in ipairs({ rel .. ".lua", rel .. "/init.lua" }) do
    if scan.exists(cand) then return { cand, mod } end
  end
  return { "?" .. mod, mod }
end

for name, entry in pairs(known) do
  if not is_theme(entry) then
    local init_file = entry.single_file and entry.path or (entry.base .. "/init.lua")
    local handle = io.open(init_file, "rb")
    local body = handle and strip_comments(handle:read("*a") or "") or ""
    if handle then handle:close() end

    -- A plugin that calls register()/unregister() at all must call both.
    local calls_register   = body:find("%.register%s*%(") ~= nil
    local calls_unregister = body:find("%.unregister%s*%(") ~= nil
    if calls_register ~= calls_unregister then
      errors[#errors+1] = string.format(
        "%s calls %s but not %s — init() and unload() must be symmetric: %s",
        name, calls_register and "register()" or "unregister()",
        calls_register and "unregister()" or "register()", init_file)
    end

    -- And the name it calls has to exist on the module it calls it on.
    if calls_register then
      local target = seam_target(entry)
      if target then
        local file = io.open(target[1], "rb")
        local tbody = file and strip_comments(file:read("*a") or "") or ""
        if file then file:close() end
        local defines = tbody:find("function%s+M%.register%s*%(")
                         or tbody:find("function%s+S%.register%s*%(")
                         or tbody:find("function%s+[A-Za-z_]+%.register%s*%(")
        if target[1]:sub(1, 1) == "?" then
          errors[#errors+1] = string.format(
            "%s calls %s.register() but no module %q resolves in the tree", name, target[2], target[2])
        elseif not defines then
          errors[#errors+1] = string.format(
            "%s calls %s.register() but %s defines no register()", name, target[2], target[1])
        end
      end
    end
  end
end

-- ── keystrokes have one spelling ─────────────────────────────────────────
--
-- The host does not look a keystroke up by meaning. It *builds* the string it
-- will look up — `ctrl+`, then `alt+`, then `altgr+`, then `shift+`, then the
-- key's own name — and compares that string for equality, with no
-- normalisation. So a stroke that differs in modifier order, in case, or in
-- where its `+` signs are is not a near miss: it is a string no key press can
-- produce, and the binding carrying it is dead — silently, because a miss in
-- `keymap.on_key_pressed` returns false and says nothing.
--
-- `["ctrl+shift+alt+n"]` sat in treeview's keymap for months being exactly
-- that. So this is checked here, where a typo costs a lint run instead of an
-- afternoon of pressing keys.
--
-- The rule is the host's (core.input.keymap) and cdin-x cannot require host
-- code — see the independence rule above — so it is restated here. The two
-- copies have to agree; cdin's own tests cover its side.
local MODIFIER_ORDER = { "ctrl", "alt", "altgr", "shift" }
local MODIFIER_RANK, MODIFIER_SET = {}, {}
for idx, mk in ipairs(MODIFIER_ORDER) do
  MODIFIER_RANK[mk] = idx
  MODIFIER_SET[mk] = true
end

-- Modifier names the input layer has never heard of. `keymap.modkeys` is fed
-- only by "left ctrl", "right ctrl", "left shift", "right shift", "left alt"
-- and "right alt", so a stroke spelled with one of these is as dead as one
-- spelled out of order — and "cmd"/"super" is what a keymap written for
-- another editor reaches for by reflex.
local FOREIGN_MODIFIERS = {
  cmd = true, command = true, meta = true, super = true, win = true,
  windows = true, control = true, option = true, opt = true, hyper = true,
}

-- Returns the stroke as the input layer would build it, or nil plus the reason
-- it never can and — where only the spelling is wrong — the form that works.
local function canonical_stroke(stroke)
  if type(stroke) ~= "string" or stroke == "" then return nil, "not a keystroke" end

  local parts, pos = {}, 1
  while true do
    local at = stroke:find("+", pos, true)
    parts[#parts + 1] = at and stroke:sub(pos, at - 1) or stroke:sub(pos)
    if not at then break end
    pos = at + 1
  end
  for _, part in ipairs(parts) do
    if part == "" then
      return nil, "'+' joins modifiers and nothing else, so this stroke has an empty part"
    end
  end

  -- What was meant, said back the only way the runtime can look it up: the
  -- modifiers it recognised, in the order the runtime builds them, then the
  -- key, lowercased.
  local mods, key_parts = {}, {}
  for _, part in ipairs(parts) do
    if MODIFIER_SET[part] then mods[part] = true else key_parts[#key_parts + 1] = part end
  end
  local canonical = {}
  for _, mk in ipairs(MODIFIER_ORDER) do
    if mods[mk] then canonical[#canonical + 1] = mk end
  end
  for _, part in ipairs(key_parts) do canonical[#canonical + 1] = part:lower() end
  local suggestion = table.concat(canonical, "+")

  local seen = 0
  for _, part in ipairs(parts) do
    if MODIFIER_SET[part] then
      if MODIFIER_RANK[part] <= seen then
        return nil, ("%q is repeated or out of order — modifiers are built ctrl, alt, altgr, shift")
          :format(part), suggestion
      end
      seen = MODIFIER_RANK[part]
    end
  end

  -- Only when something follows it: a bare "super" is a JavaScript keyword in
  -- a syntax table, not a modifier with a key missing.
  if #parts > 1 and FOREIGN_MODIFIERS[parts[1]] then
    return nil, ("%q is not a modifier this input layer reports; it knows ctrl, alt, altgr and shift")
      :format(parts[1]), suggestion
  end

  if #key_parts == 0 then return nil, "modifiers but no key", suggestion end
  if #key_parts > 1 then
    return nil, "the key is one key name; '+' joins modifiers and is not part of it", suggestion
  end
  local key = key_parts[1]
  if key:find("%u") then
    return nil, "key names arrive lowercased from the input layer", suggestion
  end

  return suggestion
end

-- Only a token that names a modifier *and* a key is even a candidate. Every
-- other `["…"] =` in the tree is a syntax keyword (`["super"]` is one in
-- javascript.lua), a theme colour or a manifest field, and this check must
-- not be the thing that fails on one of those.
-- (Spelled as a prefix test rather than a pattern: Lua patterns have no
-- alternation.)
local function names_a_modifier(token)
  if not token:find("+", 1, true) then return false end
  for _, mk in ipairs(MODIFIER_ORDER) do
    if token:sub(1, #mk + 1) == mk .. "+" then return true end
  end
  local first = token:match("^[^%+]+")
  return first ~= nil and FOREIGN_MODIFIERS[first] == true
end

for _, dir in ipairs(CODE_DIRS) do
  for _, file in ipairs(code_files(dir)) do
    local handle = io.open(file, "rb")
    if handle then
      local code = strip_comments(handle:read("*a") or "")
      handle:close()

      for token in code:gmatch('%["([^"]*)"%]%s*=') do
        if names_a_modifier(token) then
          local canonical, reason, suggestion = canonical_stroke(token)
          if not canonical then
            errors[#errors+1] = string.format(
              "%s binds %q, which no key press can produce: %s.%s",
              file, token, reason,
              suggestion and suggestion ~= token
                and (" Write it as " .. string.format("%q", suggestion) .. ".")
                or "")
          end
        end
      end
    end
  end
end

-- ── the bundle itself ───────────────────────────────────────────────────
--
-- The one check that exercises the real code path. Everything above is a
-- statement about the source; this runs scripts/bundle.py and compares what
-- came out against the exact file set the bundle's closure implies. A bundler
-- that copies one file too many ships a build whose contents nobody chose, and
-- one that copies one too few ships a build that loads and then does nothing.
-- The bundler's own invocation goes through the same interpreter the cross-check
-- used, rather than looking one up again: two lookups of the same thing are two
-- answers waiting to disagree, and this file already paid for the first one.
local TMPDIR = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "."

local function run_bundler(bundle, out)
  local args = bundle and ('--bundle "' .. bundle .. '" ') or ""
  local command = string.format('%s scripts/bundle.py --out "%s" %s2>&1',
    PYTHON, out, args)
  local pipe = io.popen(command)
  local output = pipe and pipe:read("*a") or ""
  if pipe then pipe:close() end
  return output
end

-- The file set a bundle's closure implies, in destination layout.
local function expected_files(bundle_name, with_fonts)
  local expected = {}
  local function add(rel) expected[rel] = true end

  add("BUNDLE.lua")
  add("plugins/cdin-x.lua")

  for _, member in ipairs(closures[bundle_name] or {}) do
    local entry = catalog[member]
    if entry then
      -- Where the package's files land. A package goes under the bundle's own
      -- catalog dir at its domain-relative path, whatever root it sits under
      -- here; a single-file package is one file. A standalone theme entry goes to
      -- themes/<name>, because that is where the host's theme registry looks.
      local leaf = entry.base:match("([^/\\]+)$") or ""
      local from = entry.base
      -- A single-file package's leaf already carries the extension, because its
      -- "directory name" *is* the filename. Dropping it here and re-adding it
      -- below would produce `packages/c.lua.lua`.
      if entry.single_file then leaf = leaf:gsub("%.lua$", "") end
      -- Where a package's files land in a build. Flat, under its own name, so a
      -- build carries a named set rather than a copy of the repository's tree --
      -- which is also the shape Phase 7's installed store uses, so the kernel has
      -- one rule for both. A standalone theme entry goes to themes/<name>, because
      -- that is where the host's theme registry looks.
      local to = (entry.theme
        and ("themes/" .. leaf)
        or ("packages/" .. leaf .. (entry.single_file and ".lua" or "")))

      if entry.single_file then
        add(to)
      else
        local prefix = from:gsub("(%W)", "%%%1")
        for _, f in ipairs(files_under(from)) do
          add(to .. f:gsub("^" .. prefix, ""))
        end
      end

      -- A theme *package* carries `themes/<name>/theme.lua` inside it. A build
      -- also has to put each of those at `<data>/themes/<name>/theme.lua`,
      -- because the host's theme root is that fixed path and a build has no hook
      -- for pointing it anywhere else -- the package's own add_root only helps a
      -- site install, where the host is still the one asking. bundle.py flattens
      -- them; this expects them, so the two cannot drift without the gate failing.
      if not entry.theme and not entry.single_file then
        local inner = from .. "/themes"
        if scan.is_dir(inner) then
          for _, theme_dir in ipairs(scan.list_dir(inner) or {}) do
            if theme_dir.type == "dir"
            and exists(inner .. "/" .. theme_dir.name .. "/theme.lua") then
              add("themes/" .. theme_dir.name .. "/theme.lua")
            end
          end
        end
      end

      if not entry.theme then
        -- No `plugins/<name>.lua` shim is expected here, and that is deliberate:
        -- an entry in the host's bundled root loads unconditionally and cannot
        -- be taken off, so one shim per package would make every bundled package
        -- permanent. The absence is asserted in check_bundle's `absent` list
        -- instead, so "there is no shim" is a gate rather than an oversight.
        for _, rel in ipairs(entry.meta.bundle_with or {}) do
          for _, f in ipairs(files_under(rel)) do add(f) end
        end
      end
    end
  end

  if with_fonts ~= false then
    for _, f in ipairs(files_under("fonts")) do add(f) end
  end
  for _, f in ipairs(files_under("cdinx")) do add(f) end
  return expected
end

-- The listing comes back with whatever prefix the platform produced — a relative
-- path for a tree inside the repo, an absolute one for a temp directory, and a
-- differently-spelled absolute one again under a POSIX emulation layer.
--
-- The relative part is recovered by cutting the known output directory, not by
-- looking for the last top-level entry: a package may be *called* `themes`, and a
-- path like `packages/system/themes/themes/nord/theme.lua` ends in four segments
-- that all look like a top-level name. Guessing which one is real is a way to
-- report a bundle as wrong when it is right.
--- @param out string  the directory this check built the bundle in
--- @param path string
--- @return string
local function bundle_rel(out, path)
  local p = path:gsub("\\", "/")
  local base = out:gsub("\\", "/")
  if base:sub(-1) == "/" then base = base:sub(1, -2) end

  -- The listing may or may not carry the directory at all, so try the longest
  -- spelling of it first and fall back to the last segment of the base.
  local candidates = { base, base:gsub("^.*/", ""), base:gsub("^.*/", "") }
  for _, prefix in ipairs(candidates) do
    if prefix ~= "" and p:sub(1, #prefix + 1) == prefix .. "/" then
      return p:sub(#prefix + 2)
    end
  end

  local cut = p:find("/[^/]+$")
  return cut and p:sub(cut + 1) or p
end

--- Whether a bundle ships the fonts, read from the bundle file itself.
---
--- Read as text for the same reason bundle.py reads a manifest as text: a gate
--- that executes a file to find out what it says has already done the thing it
--- was written to check. The rule is bundle.py's rule exactly -- absent means the
--- fonts go in, so only a stated `fonts = false` turns them off -- because two
--- readers of one field with two rules is a build that is right in one tool and
--- wrong in the other.
---
--- The previous signature took this as a fourth argument, defaulted from "did the
--- caller pass an `absent` list", which made an unrelated argument decide whether
--- fonts were expected. Passing `absent = { "packages/vim" }` silently turned the
--- fonts off in the expectation while the bundler still copied them.
--- @param bundle_name string
--- @return boolean
local function bundle_has_fonts(bundle_name)
  local path = "bundles/" .. bundle_name .. ".lua"
  if not exists(path) then return true end
  local f = io.open(path, "rb")
  if not f then return true end
  local src = f:read("*a") or ""
  f:close()
  -- Comments are stripped first, so a bundle that explains `fonts = false` in a
  -- comment is not read as having said it.
  src = src:gsub("%-%-%[%[.-%]%]", " "):gsub("%-%-%[=*%[.-%]=*%]", " ")
  src = src:gsub("%-%-[^\n]*", " ")
  return src:match("fonts%s*=%s*false") == nil
end

--- @param bundle_name string
--- @param required string[]  files that must be in the output
--- @param absent string[]|nil  files that must not be
local function check_bundle(bundle_name, required, absent)
  local with_fonts = bundle_has_fonts(bundle_name)
  local out = TMPDIR .. "/cdin-x-validate-bundle-" .. bundle_name
  local output = run_bundler(bundle_name, out)
  if not output:find("bundled") and not output:find("✓") then
    errors[#errors+1] = string.format("scripts/bundle.py --bundle %s did not run: %s",
      bundle_name, (output:gsub("\n", " ")))
    return
  end

  for _, path in ipairs(required) do
    if not exists(out .. "/" .. path) then
      errors[#errors+1] = string.format("bundle %q is missing %s", bundle_name, path)
    end
  end
  for _, path in ipairs(absent or {}) do
    if exists(out .. "/" .. path) then
      errors[#errors+1] = string.format(
        "bundle %q has %s, which it is not supposed to carry", bundle_name, path)
    end
  end

  local expected = expected_files(bundle_name, with_fonts)
  local found = {}
  for _, path in ipairs(scan.list_files_recursive(out) or {}) do
    local rel = bundle_rel(out, path)
    found[rel] = true
    if not expected[rel] then
      errors[#errors+1] = string.format(
        "bundle %q contains %s, which the bundle does not name", bundle_name, rel)
    end
  end
  for rel in pairs(expected) do
    if not found[rel] then
      errors[#errors+1] = string.format(
        "bundle %q is missing %s, which its closure names", bundle_name, rel)
    end
  end

  -- Idempotence: a second run must produce the same tree, or a build is not
  -- reproducible and a diff of two builds tells you nothing.
  local handle = io.open(out .. "/BUNDLE.lua", "rb")
  local before = handle and handle:read("*a") or ""
  if handle then handle:close() end

  run_bundler(bundle_name, out)

  local again = io.open(out .. "/BUNDLE.lua", "rb")
  local after = again and again:read("*a") or ""
  if again then again:close() end

  if before ~= after or before == "" then
    errors[#errors+1] = string.format("bundle.py is not idempotent for %q: two runs differ",
      bundle_name)
  end
end

-- `standard` is vim mode and the default theme.
--
-- There is no `plugins/vim.lua` any more, and that absence is the point of the
-- layout rather than an omission: an entry in the host's bundled root loads
-- unconditionally and cannot be taken off, so a shim per package would make
-- every bundled package permanent. `vim` is a package under `packages/` and the
-- kernel loads it, which is what lets a user turn it off. So the list below
-- asserts `packages/vim/init.lua` *and* that `plugins/` holds nothing but the
-- kernel shim.
check_bundle("standard", {
  "BUNDLE.lua",
  "plugins/cdin-x.lua",
  "themes/default/theme.lua",
  "packages/vim/init.lua",
  "packages/vim/registry.lua",
  "packages/vim/ex/init.lua",
  "cdinx/init.lua",
  "fonts/font.ttf",
  "fonts/monospace.ttf",
  "fonts/icons.ttf",
  -- "X" rather than a path inside it: Phase 9 removed the directory, and the whole
  -- of it is what must never come back. A filename under it would pass on a tree
  -- that had quietly grown a different X/.
}, { "plugins/manager.lua", "plugins/vim.lua", "plugins/themes.lua", "X" }, true)

-- `minimal` still has to produce a bootable kernel, and nothing else. It carries
-- the fonts, because it does not say `fonts = false`.
check_bundle("minimal", { "BUNDLE.lua", "plugins/cdin-x.lua", "cdinx/init.lua" },
  { "packages/vim" })

-- `empty` is the same, without the fonts: it is what a build names when it
-- wants nothing from this repository, so it has to be an honest answer rather
-- than a default that quietly ships vim. The fonts are expected to be *absent*
-- here because `bundles/empty.lua` says `fonts = false`, which is now read from
-- that file rather than asserted by the caller.
check_bundle("empty", { "BUNDLE.lua", "plugins/cdin-x.lua", "cdinx/init.lua" },
  { "fonts/font.ttf", "packages/vim" })

-- cdin's assemble_data.py calls the bundler with --out and nothing else, so
-- that call has to keep producing a usable editor. This is the check that
-- notices if the default ever stops being `standard`.
do
  local out = TMPDIR .. "/cdin-x-validate-default"
  if exists(out) then os.remove(out) end
  local output = run_bundler(nil, out)
  if not output:find("bundled 'standard'") then
    errors[#errors+1] = "scripts/bundle.py with no --bundle must default to the " ..
      "standard bundle, because cdin's build calls it that way: " ..
      output:gsub("\n", " ")
  elseif not exists(out .. "/packages/vim/init.lua") then
    -- `packages/`, not `plugins/`: a build ships vim as an ordinary package the
    -- kernel loads, so "did the default keep vim" is answered by asking whether
    -- the package is there, not whether a shim was written for it.
    errors[#errors+1] = "scripts/bundle.py with no --bundle produced a bundle " ..
      "without vim; cdin's build would ship an editor with no vim mode"
  end
end

if #errors > 0 then
  print("cdin-x validation failed:")
  for _, err in ipairs(errors) do print("  - " .. err) end
  os.exit(1)
end

for _, warn_msg in ipairs(warnings) do print("cdin-x warning: " .. warn_msg) end

local plugin_count = 0
for _ in pairs(known) do plugin_count = plugin_count + 1 end

print(string.format("cdin-x structure valid (%d package(s), %d theme(s), %d bundle(s))",
  plugin_count, #themes, #bundle_names))
