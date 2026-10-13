-- Regenerates registry/generated/catalog.lua, the index of this checkout.
--
--     lua scripts/generate-index.lua
--
-- One file, one fact per package: what it is called, what it is, which version,
-- what it needs, and exactly which files it is made of. A reader gets the whole
-- catalog from it without walking the tree — which is the point, because the
-- panel and a third-party installer both want the list, not the packages.
--
-- Every package is named by its own manifest. `package.lua` is read through the
-- sandbox in cdinx/schema.lua, the older inline manifest is dofile()d, and both
-- end up in the same shape here so a consumer never has to know which form a
-- package uses.
--
-- Output order is sorted at every level. A generated file whose order depends on
-- `pairs` is a file that differs between two machines with the same tree.
local scan = dofile("scripts/_scan.lua")

local OUT = "registry/generated/catalog.lua"

local function q(s)
  return string.format("%q", tostring(s or ""))
end

local function list(t)
  local out = {}
  for _, v in ipairs(t or {}) do out[#out + 1] = q(v) end
  return "{ " .. table.concat(out, ", ") .. " }"
end

local packages = {}

local function add(entry, meta, base, kind)
  local name = meta.name
  if not name then return end
  local files = entry.single_file and { entry.path } or scan.list_files_recursive(base)

  packages[name] = {
    kind = kind,
    version = meta.version or "0.0.0",
    description = meta.description or "",
    path = entry.single_file and entry.path or base,
    depends = meta.dependencies or {},
    files = files,
  }
end

for _, entry in ipairs(scan.plugin_entries()) do
  add(entry, entry.meta, entry.base, entry.meta.kind or "plugin")
end

for _, theme in ipairs(scan.theme_entries()) do
  local as_plugin = {
    path = theme.path,
    meta = theme.data,
    single_file = false,
  }
  add(as_plugin, theme.data, theme.base, "theme")
end

local names = {}
for name in pairs(packages) do names[#names + 1] = name end
table.sort(names)

local lines = {
  "-- Generated catalog index - do not edit by hand; run",
  "-- `lua scripts/generate-index.lua` instead.",
  "--",
  "-- Every package in this checkout, by name. `depends` is a sorted array of",
  "-- names; version ranges live in each package's own manifest.",
  "--",
  "-- `files` lists that package's files relative to the repository root, so a",
  "-- consumer can fetch them without cloning.",
  "return {",
  "  packages = {",
}

for _, name in ipairs(names) do
  local meta = packages[name]
  lines[#lines + 1] = "    [" .. q(name) .. "] = {"
  lines[#lines + 1] = "      kind = " .. q(meta.kind) .. ","
  lines[#lines + 1] = "      version = " .. q(meta.version) .. ","
  lines[#lines + 1] = "      description = " .. q(meta.description) .. ","
  lines[#lines + 1] = "      path = " .. q(meta.path) .. ","
  lines[#lines + 1] = "      depends = " .. list(meta.depends) .. ","
  lines[#lines + 1] = "      files = {"
  for _, f in ipairs(meta.files) do
    lines[#lines + 1] = "        " .. q(f) .. ","
  end
  lines[#lines + 1] = "      },"
  lines[#lines + 1] = "    },"
end

lines[#lines + 1] = "  },"
lines[#lines + 1] = "}"

-- An empty index is never what was meant, and writing one destroys the file that
-- was. This has happened: a scanner that found nothing on a POSIX box replaced a
-- real catalog with a stub, and nothing complained because the stub parses.
--
-- Refused rather than written, and the committed file is left exactly as it was,
-- because the recovery for a generator that has just done that is `git checkout`,
-- and the recovery for a generator that refuses is this message.
if #names == 0 then
  error(string.format(
    "%s: found no packages under any catalog root, so nothing was written. "
    .. "An empty index would replace a good one. Check that packages/ exists "
    .. "and that scripts/_scan.lua can list it.", OUT))
end

local fp, ferr = io.open(OUT, "wb")
if not fp then error(ferr) end
fp:write(table.concat(lines, "\n"), "\n")
fp:close()

print(string.format("generated %s with %d packages", OUT, #names))
