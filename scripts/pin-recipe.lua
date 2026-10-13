-- Resolves each recipe in `registry/index.lua` to the commit its tag names.
--
--     lua scripts/pin-recipe.lua            check every recipe
--     lua scripts/pin-recipe.lua <name>     print one resolution, for an author
--
-- A recipe carries a 40-hex commit, not a tag: CI resolved the tag when the recipe
-- was accepted, so what a user installs cannot move afterwards. This script is the
-- half of that which needs the network, and it answers two questions:
--
--   "what commit does this tag point at?"   for an author adding a recipe
--   "does the commit in this recipe still match its tag?"  for CI
--
-- The second question is why this is not `make validate`. `validate` runs with no
-- network and must stay that way -- it is the gate a build runs, and a gate that
-- needs the internet is a gate that fails when the internet does. This one is the
-- network check, and it runs in a workflow where a failure means "the index and
-- the world disagree", which is worth a red build.
--
-- Nothing is written. Printing is the whole interface: CI turns the exit code into a
-- job result and the owner turns the printed commit into an edit.
local Schema  = dofile("cdinx/schema.lua")
local Recipe  = dofile("cdinx/manager/recipe.lua")

local INDEX = "registry/index.lua"
local SHA_LEN = 40

local function read_index()
  local handle = io.open(INDEX, "rb")
  if not handle then return nil, INDEX .. " does not exist" end
  local text = handle:read("*a")
  handle:close()
  -- Through the sandbox, like every other untrusted read. `Schema.sandboxed` is the
  -- function that returns whatever the chunk produced; the data read path adds the
  -- shape check this does not need, because `validate` already does that one.
  local value, err = Schema.sandboxed(text, "index.lua")
  if type(value) ~= "table" then
    return nil, INDEX .. " is not readable: " .. tostring(err or "not a table")
  end
  return value
end

--- The commit a tag points at, or nil plus why not.
---
--- All tags are listed and matched here rather than by passing the tag to git as a
--- pattern, for two reasons. One is quoting: the URL must reach git exactly as
--- written, and rewriting its separators -- which a path-shaped helper does
--- automatically -- turns `https://host/o/r.git` into something git cannot read.
--- The other is that a pattern is a *prefix* match to git, so asking for `v0.1.0`
--- also answers with `v0.1.0-rc1`, and picking the wrong line silently pins the
--- wrong commit. Matching the full ref name in Lua is the only way to be sure.
---
--- The dereferenced `^{}` line is preferred over the plain one, and that is the
--- whole reason a tag name cannot be a lock: for an annotated tag the plain ref is
--- the *tag object*, which is not a commit and cannot be checked out.
local function commit_for(url, ref)
  local quoted = (package.config:sub(1, 1) == "\\")
    and string.format('"%s"', (url:gsub('"', ''))) or "'" .. url .. "'"
  local command = package.config:sub(1, 1) == "\\"
    and string.format("git ls-remote --tags -- %s 2>nul", quoted)
    or string.format("git ls-remote --tags -- %s 2>/dev/null", quoted)
  local pipe = io.popen(command)
  if not pipe then return nil, "could not start a shell" end
  local text = pipe:read("*a") or ""
  pipe:close()

  local plain_ref = "refs/tags/" .. ref
  local deref_ref = plain_ref .. "^{}"
  local dereferenced, plain
  for line in text:gmatch("[^\r\n]+") do
    local sha, name = line:match("^(%x+)%s+(.+)$")
    if sha then
      -- Compared whole, not as a prefix: `v0.1.0` must not match `v0.1.0-rc1`.
      if name == deref_ref then
        dereferenced = sha
      elseif name == plain_ref then
        plain = sha
      end
    end
  end
  local sha = dereferenced or plain
  if not sha then
    return nil, string.format("the tag %q is not in %s", ref, url)
  end
  if #sha ~= SHA_LEN then
    return nil, string.format("%s answered with %q, which is not a commit", url, sha)
  end
  return sha
end

local argv = {}
for i = 1, #(arg or {}) do argv[i] = arg[i] end
local only = argv[1]

local entries, err = read_index()
if not entries then
  io.stderr:write("pin-recipe: " .. err .. "\n")
  os.exit(1)
end

-- Sorted, so two runs of the same tree report the same first disagreement.
local names = {}
for _, entry in ipairs(entries) do names[#names + 1] = entry end
table.sort(names, function(a, b)
  return tostring(a.name) < tostring(b.name)
end)

local failed = false
for _, entry in ipairs(names) do
  if only == nil or entry.name == only then
    local problem = Recipe.check(entry, nil)
    if problem then
      -- A recipe that is not well formed is `make validate`'s business, not this
      -- script's; saying so is better than resolving a URL that is not there.
      io.stderr:write(string.format("pin-recipe: %s: %s\n",
        tostring(entry.name), tostring(problem)))
      failed = true
    else
      local sha, why = commit_for(entry.git, entry.ref or entry.rev)
      if not sha then
        io.stderr:write(string.format("pin-recipe: %s: %s\n", entry.name, why))
        failed = true
      else
        -- Printed whatever happens: for an author this is the line they paste into
        -- `rev`, and for CI it is the evidence for the verdict below.
        print(string.format("%-24s %s  %s", entry.name, sha, tostring(entry.ref or "(no tag)")))
        if entry.rev ~= sha then
          io.stderr:write(string.format(
            "pin-recipe: %s is pinned at %s but %s points at %s\n",
            entry.name, tostring(entry.rev), tostring(entry.ref or entry.rev), sha))
          failed = true
        end
      end
    end
  end
end

if only and not failed then
  -- One recipe asked about and nothing wrong with it: the printed line is the
  -- answer, and a non-zero exit would turn a successful lookup into a CI failure.
  os.exit(0)
end
os.exit(failed and 1 or 0)
