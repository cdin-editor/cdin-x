-- Which files of a package land on disk.
--
-- git moves the code; this decides what of it the user gets. It is the MELPA idea
-- taken from the second group of ecosystems rather than the first: Vim and Neovim
-- managers leave the whole repository in the plugin directory, README and tests
-- and examples included, and Emacs' MELPA builds each package from a `:files`
-- spec so what a user installs is the package and not its history. cdin-x takes
-- the transport from the first and the selection from the second, because a user
-- who installs `treeview` wants treeview's runtime, not treeview's repository.
--
-- Pure: no filesystem and no process. It is handed a list of candidate paths with
-- their sizes and hands back the subset. That is what makes the Python twin in
-- scripts/bundle.py a short function rather than a second implementation of a
-- directory walk, and it is what lets `validate.lua` run both over every
-- first-party package and fail if they disagree.
--
-- -- the grammar, in full -----------------------------------------------
--
--   literal    matched exactly, case-sensitively
--   `*`        any run of characters except `/`
--   `**`       any run of characters including `/`, used as a whole segment
--   `/`        the separator, on every platform
--
-- There is nothing else. No character classes, no braces, no `?`, no negation, no
-- `**` in the middle of a segment. That is not a limitation to apologise for: it
-- is the reason two implementations of this can agree, and a glob dialect nobody
-- has to look up is a glob dialect that cannot be misread in a `files` field.
--
-- Two rules that are not the glob at all, and are enforced before it:
--
--   `.git` is never selected. Not by a pattern -- by the selector, so no glob can
--   opt into shipping a repository's internals.
--   A symlink is never selected. Copying one would either duplicate its target or,
--   on a system that resolves them, pull in something from outside the repository.
--
-- `ignore` beats `files`. A pattern in both means out, because a package author
-- who writes `**/*.lua` and also writes `ignore = { "with/generated.lua" }` has
-- said what they meant twice and the second statement is the specific one.
local Select = {}

-- The interpreter this module's one impure function found, and why it is here
-- rather than in the function: a probe that re-runs on every call is a process
-- spawn per package, and this module is otherwise pure.
local cached_python = nil

--- The interpreter to shell out to, or `python` when none can be found.
---
--- `python3` is preferred and `python` is the fallback, because they are not the
--- same name everywhere and the failure is quiet in a way that matters: a
--- cross-check that shells out to an interpreter that is not there reads the error
--- message as its *output*, and reports that two selections disagree -- which
--- names the wrong thing entirely and sends a person looking at glob patterns
--- instead of at their PATH.
---
--- The one impure function in this file, and it is here rather than in
--- `validate.lua` so that every caller gets the same answer; two callers each
--- writing `or "python3"` is how the two drift apart. Never raised from: the
--- fallback is right often enough to be useful, and a caller that needs certainty
--- has the command it would have run.
--- @return string
function Select.python_command()
  if cached_python then return cached_python end
  local is_win = package.config:sub(1, 1) == "\\"
  for _, candidate in ipairs({ "python3", "python" }) do
    -- `--version` rather than `-V`, because the latter's output goes to stderr on
    -- some builds and stderr is not what this reads.
    local command = is_win
      and (candidate .. " --version 2>nul")
      or (candidate .. " --version 2>/dev/null")
    local pipe = io.popen(command)
    if pipe then
      local out = pipe:read("*a") or ""
      pipe:close()
      if out:match("Python") then
        cached_python = candidate
        return candidate
      end
    end
  end
  cached_python = "python"
  return cached_python
end

--- What is installed when a package says nothing.
---
--- `package.lua` first, because a selection without it is not a package and
--- `Select.validate` refuses the whole thing -- so an author who overrode `files`
--- and forgot it gets one clear error rather than an install that cannot be
--- described in the panel.
---
--- `LICENSE*` and `NOTICE*` are not optional. Shipping someone's code without
--- their licence text is not a style question.
Select.DEFAULT_FILES = {
  "package.lua",
  "**/*.lua",
  "LICENSE*",
  "NOTICE*",
  "README.md",
}

--- What is never installed unless a package asks for it by name.
---
--- Tests, specs, examples and docs are the four that a package author always
--- forgets are in there. `.*/**` catches CI configuration and editor droppings,
--- and is separate from the `.git` rule so that the rule reads as a rule.
Select.DEFAULT_IGNORE = {
  "test/**",
  "tests/**",
  "spec/**",
  "**/*_spec.lua",
  "**/*_test.lua",
  "examples/**",
  "docs/**",
  ".*/**",
}

--- The characters a Lua pattern gives a meaning to.
---
--- Every literal character of a glob has to be escaped before it goes into a
--- pattern, and `%q` does not do that: `("%q"):format(".")` is `"."`, which in a
--- pattern is *any character*. So `.*/**` -- the default that hides CI
--- configuration and editor droppings -- would have compiled to something that
--- also matched `x/github/x`, and `LICENSE*` would have matched `LICENSEx`.
--- Escaping is spelled out here rather than delegated to a formatter.
local PATTERN_MAGIC = "^$()%.[]*+-?"

--- One literal glob character as a literal pattern character.
--- @param c string
--- @return string
local function literal(c)
  if PATTERN_MAGIC:find(c, 1, true) then return "%" .. c end
  return c
end

--- Compiles one glob into the set of Lua patterns that mean it.
---
--- Returns nil plus a reason for a malformed glob, because the caller has a
--- package name and a field name and can say something useful, and a pattern that
--- silently matched nothing would install an empty package instead.
---
--- The result is a *list* rather than one pattern, because of `**/`. That segment
--- means "zero or more directories", and Lua patterns have no optional group:
--- `(.*/)?` compiles without complaint and then matches nothing at all, which is
--- the worst possible failure for a default that every package relies on. So `**/`
--- is compiled to two alternatives -- one where it contributes nothing and one
--- where it contributes `.*/` -- and a path matches the glob if it matches either.
--- Two patterns that are each obviously right beat one pattern that is subtly wrong.
--- @param glob string
--- @return string[]|nil patterns
--- @return string|nil err
function Select.expand(glob)
  if type(glob) ~= "string" or glob == "" then
    return nil, "a glob must be a non-empty string"
  end
  if glob:find("\\", 1, true) then
    return nil, string.format(
      "%q uses backslashes; a `files` glob always uses '/', whatever platform the "
      .. "package was authored on", glob)
  end
  if glob:sub(1, 1) == "/" then
    return nil, string.format("%q is not relative to the package root", glob)
  end
  if glob:sub(-1) == "/" then
    return nil, string.format("%q ends with '/', which names no file", glob)
  end
  if glob:find("//", 1, true) then
    return nil, string.format("%q has an empty path segment", glob)
  end
  for segment in glob:gmatch("[^/]+") do
    if segment == ".." then
      return nil, string.format("%q climbs out of the package", glob)
    end
  end
  -- A control character is escaped by neither %q nor `literal` and would end the
  -- pattern early. Refused rather than half-compiled.
  if glob:find("%c") then
    return nil, string.format("%q contains a control character", glob)
  end

  -- One alternative per way `**/` can be read. Starts as a single empty prefix.
  local alternatives = { "" }
  local i, n = 1, #glob
  while i <= n do
    local c = glob:sub(i, i)
    if c == "*" then
      if glob:sub(i + 1, i + 1) == "*" then
        -- `**` is only a wildcard as a whole segment. `a**b` is not in the
        -- grammar, and compiling it as "a, then anything, then b" would quietly
        -- accept a glob the author did not write.
        local before_ok = (i == 1) or (glob:sub(i - 1, i - 1) == "/")
        local after = glob:sub(i + 2, i + 2)
        local after_ok = (after == "") or (after == "/")
        if not (before_ok and after_ok) then
          return nil, string.format(
            "%q puts '**' inside a path segment; '**' is only a whole segment", glob)
        end
        if after == "/" then
          -- Zero directories, or one or more. Both, as separate alternatives.
          local with_dir = {}
          for _, prefix in ipairs(alternatives) do
            with_dir[#with_dir + 1] = prefix .. ".*/"
          end
          for _, prefix in ipairs(with_dir) do
            alternatives[#alternatives + 1] = prefix
          end
          i = i + 3
        else
          -- `**` as the last segment: any depth below here.
          for k = 1, #alternatives do
            alternatives[k] = alternatives[k] .. ".*"
          end
          i = i + 2
        end
      else
        for k = 1, #alternatives do
          alternatives[k] = alternatives[k] .. "[^/]*"
        end
        i = i + 1
      end
    else
      for k = 1, #alternatives do
        alternatives[k] = alternatives[k] .. literal(c)
      end
      i = i + 1
    end
  end

  local out = {}
  for _, prefix in ipairs(alternatives) do
    out[#out + 1] = "^" .. prefix .. "$"
  end
  return out
end

--- Whether one path matches one glob.
--- @param glob string
--- @param relpath string  forward slashes, relative to the package root
--- @return boolean
function Select.matches(glob, relpath)
  local patterns = Select.expand(glob)
  if not patterns then return false end
  for _, pattern in ipairs(patterns) do
    if relpath:match(pattern) ~= nil then return true end
  end
  return false
end

--- Compiles a list of globs once.
---
--- Flattened across the whole list, so a caller holds one array of patterns and
--- tests each path against it. The glob-to-pattern mapping is not needed after
--- this point, and keeping it would be a second thing to keep in step.
--- @param globs string[]|nil
--- @return string[]|nil patterns
--- @return string|nil err
function Select.compiled(globs)
  local out = {}
  for _, glob in ipairs(globs or {}) do
    local patterns, err = Select.expand(glob)
    if not patterns then return nil, err end
    for _, pattern in ipairs(patterns) do
      out[#out + 1] = pattern
    end
  end
  return out
end

--- Whether a path is one this selector will never take, whatever the globs say.
--- @param relpath string
--- @return boolean
function Select.forbidden(relpath)
  -- `.git` anywhere: the repository's own directory, at any depth. A package that
  -- vendors a dependency which happens to be a git checkout must not smuggle it.
  for segment in relpath:gmatch("[^/]+") do
    if segment == ".git" then return true end
  end
  return false
end

--- Picks the files to install from a list of candidates.
---
--- `candidates` is `{ { path = "init.lua", size = 1234 }, ... }` with forward
--- slashes. Order is the caller's: nothing here sorts, because the installer walks
--- in whatever order it walks and re-sorting would be a second, different answer
--- to "what order do we copy in".
---
--- Returns the chosen entries plus the reason for each exclusion, because a
--- package author whose data file did not land needs to know which pattern
--- dropped it rather than a list of everything that did not match.
--- @param candidates table[]  { path = string, size = integer|nil }
--- @param files string[]|nil
--- @param ignore string[]|nil
--- @return table[]|nil chosen
--- @return table<string, string>|nil skipped  path -> why
--- @return string|nil err
function Select.pick(candidates, files, ignore)
  local files_globs = (files ~= nil) and files or Select.DEFAULT_FILES
  local ignore_globs = (ignore ~= nil) and ignore or Select.DEFAULT_IGNORE

  local file_pats, err = Select.compiled(files_globs)
  if not file_pats then return nil, nil, "files: " .. err end
  local ignore_pats
  ignore_pats, err = Select.compiled(ignore_globs)
  if not ignore_pats then return nil, nil, "ignore: " .. err end

  local chosen, skipped = {}, {}
  for _, entry in ipairs(candidates) do
    local rel = entry.path
    if Select.forbidden(rel) then
      skipped[rel] = "it is inside a .git directory"
    else
      local ignored = false
      for _, pattern in ipairs(ignore_pats) do
        if rel:match(pattern) then ignored = true break end
      end
      if ignored then
        skipped[rel] = "an `ignore` pattern matched it"
      else
        local wanted = false
        for _, pattern in ipairs(file_pats) do
          if rel:match(pattern) then wanted = true break end
        end
        if wanted then
          chosen[#chosen + 1] = entry
        else
          skipped[rel] = "no `files` pattern matched it"
        end
      end
    end
  end

  return chosen, skipped, nil
end

--- How large a selection is.
--- @param chosen table[]
--- @return integer count
--- @return integer bytes
function Select.size(chosen)
  local count, bytes = 0, 0
  for _, entry in ipairs(chosen) do
    count = count + 1
    bytes = bytes + (tonumber(entry.size) or 0)
  end
  return count, bytes
end

--- The requires a selected Lua file names, as module paths.
---
--- Reads the file through `reader`, so this stays pure and the caller decides how
--- text is obtained. Deliberately shallow: `require "vim.ex"` is `vim.ex` and
--- anything after the first segment is that package's own business. A require with
--- no dot -- `require "core"` -- belongs to the host and is not this package's to
--- ship.
---
--- Both quote styles are recognised. A third-party package is not held to this
--- repository's StyLua settings, and a require written with single quotes is still
--- a require -- missing it would leave a module out of the selection.
---
--- The pattern is a long bracket so the quotes and the parens do not have to be
--- escaped twice, and it deliberately does not try to match a closing paren: the
--- name is the thing being captured, and a paren that is or is not there does not
--- change which module was asked for.
--- @param text string
--- @return string[]
function Select.requires_in(text)
  local out, seen = {}, {}
  for name in text:gmatch([==[require%s*%(?%s*["']([^"']+)["']%s*%)?]==]) do
    if not seen[name] then
      seen[name] = true
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

--- Whether a selection can work: non-empty, has `package.lua`, and contains every
--- module it requires.
---
--- The third clause is section 6.5.1's "a selection that leaves a `require`d
--- module outside it is an error that names the missing file", and it is the one
--- that matters. Every other check can pass and the package still break at load
--- time with "module 'treeview.api' not found", which is a far worse place to find
--- that out.
---
--- `reader(path) -> text|nil` is given each selected path. `root_prefix` is the
--- module prefix the package claims -- its own name -- and the question is whether
--- `require "<prefix>.<something>"` resolves to something selected.
--- @param chosen table[]  the selection, as `pick` returned it
--- @param reader fun(path: string): string|nil
--- @param root_prefix string|nil
--- @return string|nil err
function Select.validate(chosen, reader, root_prefix)
  if #chosen == 0 then
    return "nothing was selected: the `files` patterns matched none of the files "
      .. "in the repository"
  end

  local have = {}
  for _, entry in ipairs(chosen) do have[entry.path] = true end

  if not have["package.lua"] then
    return "package.lua was not selected, so this is not a package. Add it to "
      .. "`files`, or drop the `files` field and take the default."
  end

  if type(root_prefix) ~= "string" or root_prefix == "" then return nil end

  -- Sorted, so two runs of the same tree report the same missing module first.
  local sources = {}
  for _, entry in ipairs(chosen) do
    if entry.path:sub(-4) == ".lua" then sources[#sources + 1] = entry.path end
  end
  table.sort(sources)

  local missing = {}
  for _, path in ipairs(sources) do
    local text = reader(path)
    if type(text) == "string" then
      for _, name in ipairs(Select.requires_in(text)) do
        local package = name:match("^([%a][%w%-]*)%.")
        if package == root_prefix then
          -- The package's own modules are relative to the package root, so the
          -- prefix comes off before the dots become slashes. Leaving it on turns
          -- `require "treeview.api"` into `treeview/api.lua`, which is never a path
          -- in the selection and so reports every package as broken.
          local rel = (name:sub(#root_prefix + 2):gsub("%.", "/"))
          if not have[rel .. ".lua"] and not have[rel .. "/init.lua"] then
            missing[rel .. ".lua"] = true
          end
        end
      end
    end
  end

  if next(missing) == nil then return nil end

  local names = {}
  for rel in pairs(missing) do names[#names + 1] = rel end
  table.sort(names)
  return string.format(
    "the selection leaves %d required module(s) out of it: %s. Add them to "
    .. "`files`, or list them in `ignore` if they are meant to be optional.",
    #names, table.concat(names, ", "))
end

return Select