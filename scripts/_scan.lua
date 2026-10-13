-- Shared filesystem helper for cdin-x development scripts.
--
-- These scripts run with plain lua and no editor, so they cannot reach the
-- kernel's host adapter. The one thing they share with the kernel is
-- cdinx/schema.lua, which depends on nothing but the standard library: a
-- package.lua is read and validated through exactly the same code here and in
-- the editor.
local Schema = dofile("cdinx/schema.lua")

local M = {}

local SEP = package.config:sub(1, 1)

--- The roots a first-party package may live under. One since Phase 9 removed `X/`.
--- Kept as a list rather than a string because every caller walks it, and a
--- collection that changes shape when a second root is added is a collection every
--- caller has to be re-read after.
M.CATALOG_ROOTS = { "packages" }

--- Where themes live. A theme is `<root>/<name>/theme.lua`, which is the host's
--- fixed layout, so the only thing that varies is the parent. One parent since
--- Phase 9: `X/themes/` went with the rest of `X/`. The themes package itself is
--- one catalog entry and is not descended into, so its themes are found here.
M.THEME_ROOTS = { "packages/system/themes/themes" }

local function shell_quote(path)
  if SEP == "\\" then
    return '"' .. path:gsub('"', '""') .. '"'
  end
  return "'" .. path:gsub("'", "'\\''") .. "'"
end

--- The file that carries a directory package's manifest, or nil.
--- `package.lua` first: a package that has one is never executed to be listed,
--- so the manifest may live somewhere other than its init.lua.
function M.manifest_path_of(dir)
  for _, name in ipairs({ "package.lua", "manifest.lua", "init.lua" }) do
    local candidate = dir .. "/" .. name
    local handle = io.open(candidate, "rb")
    if handle then
      handle:close()
      return candidate
    end
  end
  return nil
end

--- Reads a manifest through whichever reader its file needs.
---
--- For a package.lua the validated spec is returned as it was read, untouched.
--- The caller normalises it; mutating it here would make the spec disagree with
--- the file it came from, and the validator that checks for fields the schema
--- does not define would then report the ones this function added.
function M.read_manifest_at(path)
  if path:match("[/\\]package%.lua$") then
    local spec = Schema.read(path)
    if not spec then return nil end
    return spec, path
  end
  return M.read_manifest(path), nil
end

--- The shape every validator reads: `type` rather than `kind`, `dependencies` as
--- a sorted list rather than a range map, whatever the manifest actually said.
--- A fresh table either way — the old form is a `dofile` result that is also
--- fresh, but the package.lua form is a validated spec that must stay as read.
local function normalise(meta, is_package_file)
  if not is_package_file then return meta end
  local out = {}
  for k, v in pairs(meta) do out[k] = v end
  out.type = out.kind or out.type
  out.dependencies = out.dependencies or Schema.dependency_names(meta)
  return out
end

function M.plugin_entries()
  local entries = {}
  local seen_dirs = {}

  -- A package with a package.lua is data, and its identity is its name.
  local function scan_for_packages(dir, category_name)
    for _, entry in ipairs(M.list_dir(dir) or {}) do
      if entry.type == "dir" and entry.name ~= ".git" then
        local sub_dir = dir .. "/" .. entry.name
        if not seen_dirs[sub_dir] then
          local manifest_path = M.manifest_path_of(sub_dir)
          if manifest_path then
            local read, is_package_file = M.read_manifest_at(manifest_path)
            local meta = read and normalise(read, is_package_file)
            if meta then
              entries[#entries + 1] = {
                path = manifest_path, meta = meta,
                -- The validated spec, as the file declared it. Kept beside the
                -- normalised meta so a check that asks "what did the author
                -- write?" is not answered by the fields normalisation added.
                spec = is_package_file and read or nil,
                -- A declared category wins, and the domain directory is only the
                -- fallback. This is the same rule cdinx/manager/catalog.lua
                -- applies, and the two must agree: if they did not, the generated
                -- catalog would group a package one way and the running editor
                -- another, and the panel's grouping would depend on which of them
                -- had read it.
                category = meta.category or category_name,
                single_file = false, base = sub_dir,
                package_file = is_package_file,
              }
              seen_dirs[sub_dir] = true
            end
          else
            scan_for_packages(sub_dir, category_name)
          end
        end
      end
    end
  end

  -- Two roots, the same shape under each: <root>/<domain>/<package>/. A
  -- single-file package is <root>/<domain>/<name>.lua. Reading the roots from
  -- a table is what lets the move out of X/ finish one directory at a time.
  for _, root in ipairs(M.CATALOG_ROOTS) do
    for _, domain_entry in ipairs(M.list_dir(root) or {}) do
      if domain_entry.type == "dir" and domain_entry.name ~= ".git" then
        scan_for_packages(root .. "/" .. domain_entry.name, domain_entry.name)
      end
    end
  end

  -- Single-file packages, which live directly under a domain.
  for _, root in ipairs(M.CATALOG_ROOTS) do
    for _, domain_entry in ipairs(M.list_dir(root) or {}) do
      if domain_entry.type == "dir" and domain_entry.name ~= ".git" then
        local domain_dir = root .. "/" .. domain_entry.name
        for _, entry in ipairs(M.list_dir(domain_dir) or {}) do
          if entry.type == "file" and entry.name ~= "manifest.lua" then
            local name = entry.name:match("^(.+)%.lua$")
            if name then
              local file_path = domain_dir .. "/" .. entry.name
              local ok, meta = pcall(dofile, file_path)
              if ok and type(meta) == "table" then
                entries[#entries + 1] = {
                  path = file_path, meta = meta,
                  category = meta.category or domain_entry.name,
                  single_file = true, base = domain_dir,
                }
              end
            end
          end
        end
      end
    end
  end

  table.sort(entries, function(a, b) return a.path < b.path end)
  return entries
end

function M.read_manifest(path)
  local ok, meta = pcall(dofile, path)
  if ok and type(meta) == "table" then return meta end
  return nil
end

function M.dirname(path)
  return path:match("^(.*)[/\\][^/\\]+$")
end

function M.basename(path)
  return path:match("([^/\\]+)[/\\]?$" )
end

-- The domain a package sits under, read from its path rather than assumed, so
-- it is right under either root.
function M.category_from_manifest(path)
  for _, root in ipairs(M.CATALOG_ROOTS) do
    local domain = path:match("^" .. (root:gsub("(%W)", "%%%1")) .. "[/\\]([^/\\]+)")
    if domain then return domain end
  end
  return "unknown"
end

-- Is this path a directory?
function M.is_dir(path)
  if SEP == "\\" then
    local p = path:gsub("'", "''")
    local handle = io.popen('powershell -NoProfile -Command "if (Test-Path -LiteralPath \''
      .. p .. '\' -PathType Container) { \'yes\' }"')
    local out = handle and handle:read("*a") or ""
    if handle then handle:close() end
    return out:find("yes") ~= nil
  end
  local handle = io.popen('test -d "' .. path .. '" && echo yes')
  local out = handle and handle:read("*a") or ""
  if handle then handle:close() end
  return out:find("yes") ~= nil
end

-- Does this path exist at all, file or directory?
function M.exists(path)
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return M.is_dir(path)
end

-- List one directory as { name, type = "dir"|"file" }.
function M.list_dir(path)
  local results = {}
  local command
  if SEP == "\\" then
    local p = path:gsub("'", "''")
    command = 'powershell -NoProfile -Command "Get-ChildItem -LiteralPath \'' .. p ..
      '\' -Force | ForEach-Object { if ($_.PSIsContainer) { \'DIR \' + $_.Name } else { \'FILE \' + $_.Name } }"'
  else
    -- The parser below reads a "KIND name" pair, and only the PowerShell
    -- branch used to emit one. `ls -A` prints bare names, so every line failed
    -- the pattern and list_dir returned {} -- on every POSIX system. Nothing
    -- looked broken: the generators reported "0 extensions" and wrote a stub
    -- index over a real one, and CONTRIBUTING.md tells contributors to run
    -- exactly that and commit the result. `make index` is the one that
    -- survived; `make manifest` and `X/manifest.lua` went in Phase 9, and this
    -- bug is why the surviving one now writes the file only after it knows how
    -- many entries it found.
    --
    -- Two `find` passes, one per kind, each prefixed, because `find -printf` is
    -- GNU-only and this has to work on macOS too. `-mindepth`/`-maxdepth` are
    -- in BSD find, and `basename` and `sed` are in both.
    local q = shell_quote(path)
    command = "{ find " .. q .. " -mindepth 1 -maxdepth 1 -type d -exec basename {} \\; "
           .. "| sed 's|^|DIR |' ; "
           .. "find " .. q .. " -mindepth 1 -maxdepth 1 -type f -exec basename {} \\; "
           .. "| sed 's|^|FILE |' ; } 2>/dev/null"
  end

  local handle = io.popen(command)
  if not handle then return results end
  for line in handle:lines() do
    local kind, name = line:match("^(%u+)%s+(.+)$")
    if name then
      results[#results + 1] = { name = name, type = (kind == "DIR") and "dir" or "file" }
    end
  end
  handle:close()
  return results
end

function M.list_files_recursive(dir)
  local command, strip_prefix
  if SEP == "\\" then
    local cwd = (io.popen("cd"):read("*a") or ""):gsub("[\r\n]", "")
    strip_prefix = cwd:gsub("\\", "/"):gsub("/+$", "") .. "/"
    command = 'powershell -NoProfile -Command "Get-ChildItem -LiteralPath \''
      .. dir:gsub("'", "''") .. '\' -Recurse -File | ForEach-Object { $_.FullName }"'
  else
    command = "find " .. shell_quote(dir) .. " -type f -print"
  end

  local pipe = io.popen(command)
  if not pipe then return {} end
  local results = {}
  for line in pipe:lines() do
    if line ~= "" then
      local path = line:gsub("\\", "/")
      if strip_prefix and path:sub(1, #strip_prefix) == strip_prefix then
        path = path:sub(#strip_prefix + 1)
      end
      results[#results + 1] = path
    end
  end
  pipe:close()
  table.sort(results)
  return results
end

-- A theme is a directory holding theme.lua — the same layout the host's
-- theme registry uses (<root>/<name>/theme.lua), so a theme can be handed
-- straight to core.themes.add_root() without being copied or renamed.
--
-- THEME_ROOTS is a list because the *host's* theme layout is fixed but this
-- repository's is not, and a rule that hard-coded one path would break the moment
-- a second home appeared. There was a second: `X/themes/`, before the themes
-- package existed. Phase 9 removed it with the rest of `X/`, so the list has one
-- entry again -- and it stays a list, because the alternative is a string that has
-- to change again the next time.
--
-- The themes package itself is not descended into by the catalog scan -- it has a
-- package.lua, so it is one package -- which is why its themes are found here
-- rather than there.
function M.theme_entries()
  local entries = {}
  for _, themes_dir in ipairs(M.THEME_ROOTS) do
    if M.exists(themes_dir) then
      for _, entry in ipairs(M.list_dir(themes_dir) or {}) do
        if entry.type == "dir" and entry.name ~= ".git" then
          local path = themes_dir .. "/" .. entry.name .. "/theme.lua"
          if M.exists(path) then
            local ok, data = pcall(dofile, path)
            if ok and type(data) == "table" then
              entries[#entries + 1] = {
                name = data.name or entry.name,
                path = path,
                base = themes_dir .. "/" .. entry.name,
                data = data,
              }
            end
          end
        end
      end
    end
  end
  table.sort(entries, function(a, b) return a.name < b.name end)
  return entries
end

return M
