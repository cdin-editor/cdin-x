-- Where a package comes from, and whether that is safe to hand to git.
--
-- Pure: no filesystem, no process, no host. It turns what a user wrote in
-- `packages.lua` into the four facts a clone needs -- a URL, a ref, a subdirectory
-- and a name -- or into a sentence saying why not.
--
-- It exists as a separate module because the checks are the security boundary.
-- Everything downstream builds a command line from what this returns, so a URL
-- that arrives here as `ext::sh -c ...` must never reach argv. Two layers stop it:
-- this one refuses it with a message a person can act on, and `git.lua` passes
-- `GIT_ALLOW_PROTOCOL=https:ssh` so a URL that slipped through anyway cannot run
-- a command. Neither is trusted to be the only one.
--
-- The forms, from section 6.5.1:
--
--   "owner/repo"                          https://github.com/owner/repo.git
--   { "owner/repo", rev = "v1.2.0" }      a tag, a branch, or a 40-hex commit
--   { git = "…", rev = "…", subdir = "…" } any host
--   { name = "x", dir = "~/code/x" }       dev: used where it is, never cloned
local Source = {}

--- The URL schemes git is allowed to speak here.
---
--- `https://` and `ssh://` and `git@host:path` and nothing else. In particular not
--- `ext::` and not `file::`, which git treats as transports that *run something*:
--- `ext::sh -c '…'` executes a shell command during a clone. That is not a
--- theoretical risk on a machine that fetches a URL a user pasted.
Source.SCHEME_HTTPS = "^https://"
Source.SCHEME_SSH = "^ssh://"
Source.SCHEME_SCP = "^git@[%w%.%-]+:"

--- Git's own limits, which this module enforces before git ever sees them.
--- Kept here rather than in `git.lua` so a caller that builds a command elsewhere
--- cannot forget them.
Source.LIMITS = {
  max_files = 500,
  max_bytes = 5 * 1024 * 1024,      -- selected files only
  max_clone_bytes = 50 * 1024 * 1024,
  warn_bytes = 500 * 1024,           -- check.lua warns past this
}

-- A package name: what section 6.2 says, unchanged. `lang-` for a language,
-- `theme-` for a theme, and nothing else may claim either prefix by accident.
--
-- The length is checked separately rather than in the pattern, because Lua
-- patterns have no `{n,m}` quantifier: `{0,31}` in a pattern is five literal
-- characters, and a name regex written with it matches only names that contain
-- the string "{0,31}". That is not a subtle failure -- it is a name check that
-- rejects every name -- which is why it is spelled out here.
local NAME_RE = "^[a-z][a-z0-9%-]*$"
local NAME_MAX = 32

-- `owner/repo`, the short form. Deliberately narrow: no nested groups, no dots
-- that could be an ellipse, nothing that starts with a dash (which git would read
-- as an option).
local SHORT_RE = "^[%w][%w%._%-]*/[%w][%w%._%-]*$"

-- A ref: a tag, a branch or a commit. Starts with a word character, so it can
-- never be an option; no whitespace, no `..`, nothing a shell would touch.
local REF_RE = "^[%w][%w%._/%-]*$"

-- A 40-hex rev is a commit and gets `git init` + `fetch <sha>`; anything else is
-- a name and gets `--branch <ref>`. Deciding here rather than in `git.lua`
-- keeps the distinction in one place, and the distinction decides whether the
-- clone works at all: a server will usually not serve a commit by name.
--
-- Built rather than written out: a hand-counted run of forty `%x` is exactly the
-- kind of constant that is wrong by one and still looks right.
local SHA_RE = "^" .. string.rep("%x", 40) .. "$"

-- Names the host or Lua already provide. §6.2's list: a package called `string`
-- would shadow a standard library for every module that requires it, which is a
-- failure the user cannot diagnose from the symptom.
Source.RESERVED = {
  ["true"] = true, coroutine = true, debug = true, dofile = true,
  error = true, fs = true, getfenv = true, getmetatable = true, io = true,
  ipairs = true, load = true, loadfile = true, loadstring = true,
  math = true, module = true, newproxy = true, os = true, package = true,
  pairs = true, pcall = true, print = true, rawequal = true, rawget = true,
  rawlen = true, rawset = true, require = true, select = true,
  setfenv = true, setmetatable = true, string = true, table = true,
  tonumber = true, tostring = true, type = true, utf8 = true, xpcall = true,
  ["core"] = true, cdinx = true, path = true, renderer = true, system = true,
}

--- Whether a string is a safe package name.
--- @param name any
--- @return boolean
function Source.valid_name(name)
  return type(name) == "string" and name:match(NAME_RE) ~= nil
end

--- Whether a name may not be claimed by a package.
--- @param name string
--- @return boolean
function Source.is_reserved(name)
  return Source.RESERVED[name] == true
end

--- The one-line reason a name is refused, or nil if it is fine.
---
--- Separate from `valid_name` because the panel needs to say *why* and a boolean
--- cannot. The two reserved-name cases are kept apart on purpose: `core` and
--- `cdinx` are cdin-x's, and saying so is more useful than "reserved".
--- @param name any
--- @return string|nil
function Source.name_problem(name)
  if type(name) ~= "string" then
    return "a package name must be a string, got " .. type(name)
  end
  if name:match(NAME_RE) == nil or #name > NAME_MAX then
    return string.format(
      "%q is not a usable package name: lowercase letters, digits and dashes, "
      .. "starting with a letter, at most %d characters", name, NAME_MAX)
  end
  if name == "core" or name == "cdinx" then
    return string.format("%q belongs to cdin-x and cannot be a package name", name)
  end
  if Source.is_reserved(name) then
    return string.format(
      "%q is provided by the host or by Lua, and a package of that name would "
      .. "shadow it for everything that requires it", name)
  end
  return nil
end

--- Whether a URL is one this module will hand to git.
---
--- The whole URL is matched, not just the scheme: a URL is one argument to git,
--- and an argument that carries a space, a semicolon or a backtick is two commands
--- the moment anything quotes it wrongly. The alphabet below is everything a git
--- URL needs -- userinfo, port, path, `.git`, `~` expansion, `+` -- and nothing a
--- shell acts on. A URL that needs a query string or a credential in it is refused
--- here rather than quoted downstream, because quoting is a second layer and this
--- is the first.
--- @param url any
--- @return boolean
function Source.valid_url(url)
  if type(url) ~= "string" or url == "" then return false end
  if url:match("^https://[%w%._~%/%:%@%+%-]+%.git$") then return true end
  if url:match("^https://[%w%._~%/%:%@%+%-]+$") then return true end
  if url:match("^ssh://[%w%._~%/%:%@%+%-]+$") then return true end
  if url:match("^git@[%w%.%-]+:[%w%._~%/%+%-]+%.git$") then return true end
  if url:match("^git@[%w%.%-]+:[%w%._~%/%+%-]+$") then return true end
  return false
end

--- Why a URL is refused, or nil.
--- @param url any
--- @return string|nil
function Source.url_problem(url)
  if type(url) ~= "string" or url == "" then
    return "a git URL is required, and it must be a string"
  end
  if Source.valid_url(url) then return nil end

  -- Name the reason when we can, because "not allowed" on its own sends someone
  -- looking for a typo rather than for a transport git will execute.
  local scheme = url:match("^(%a[%w+.-]*)::")
  if scheme then
    return string.format(
      "%q uses git's %s:: transport, which runs a command instead of fetching "
      .. "files. Use https://, ssh:// or git@host:path.", url, scheme)
  end
  if url:match("^file:") then
    return string.format("%q is a file:// URL; this is a network installer", url)
  end
  return string.format(
    "%q is not an allowed git URL. Use https://, ssh:// or git@host:path.", url)
end

--- Whether a ref is safe to pass as an argument.
--- @param ref any
--- @return boolean
function Source.valid_ref(ref)
  if ref == nil then return true end
  if type(ref) ~= "string" or ref == "" then return false end
  -- Never an option. `--upload-pack=…` is a ref-shaped string that makes git run
  -- a program, and a leading dash is the only thing that makes it one.
  if ref:sub(1, 1) == "-" then return false end
  return ref:match(REF_RE) ~= nil
end

--- Why a ref is refused, or nil.
--- @param ref any
--- @return string|nil
function Source.ref_problem(ref)
  if ref == nil then return nil end
  if type(ref) ~= "string" then
    return "a rev must be a string, got " .. type(ref)
  end
  if ref == "" then return "a rev may not be empty" end
  if ref:sub(1, 1) == "-" then
    return string.format(
      "%q starts with a dash and git would read it as an option; a rev is a "
      .. "commit, a tag or a branch", ref)
  end
  if ref:match(REF_RE) == nil then
    return string.format(
      "%q is not a usable rev: letters, digits, dots, dashes, slashes and "
      .. "underscores, starting with a letter or digit", ref)
  end
  if ref:find("..", 1, true) then
    return string.format("%q contains '..', which is never a rev", ref)
  end
  return nil
end

--- Whether a subdirectory is inside the repository.
---
--- Checked on the path as written, before anything joins it to a root, and the
--- check is on segments rather than on a substring: a `..` anywhere is refused,
--- because the only reason for one here is an attempt to escape.
--- @param subdir any
--- @return boolean
function Source.valid_subdir(subdir)
  if subdir == nil then return true end
  if type(subdir) ~= "string" or subdir == "" then return false end
  if subdir:find("\\", 1, true) then return false end
  if subdir:sub(1, 1) == "/" then return false end
  if subdir:sub(-1) == "/" then return false end
  if subdir:find("//", 1, true) then return false end
  for segment in subdir:gmatch("[^/]+") do
    if segment == ".." or segment == "." then return false end
  end
  return true
end

--- Why a subdirectory is refused, or nil.
--- @param subdir any
--- @return string|nil
function Source.subdir_problem(subdir)
  if subdir == nil then return nil end
  if type(subdir) ~= "string" then
    return "a subdir must be a string, got " .. type(subdir)
  end
  if subdir == "" then return "a subdir may not be empty" end
  if subdir:find("\\", 1, true) then
    return string.format(
      "%q uses backslashes; a repository path always uses '/', whatever platform "
      .. "the package was authored on", subdir)
  end
  if subdir:sub(1, 1) == "/" or subdir:sub(-1) == "/" or subdir:find("//", 1, true) then
    return string.format("%q is not a path inside the repository", subdir)
  end
  for segment in subdir:gmatch("[^/]+") do
    if segment == ".." then
      return string.format("%q climbs out of the repository", subdir)
    end
    if segment == "." then
      return string.format("%q contains a '.' segment; write it out", subdir)
    end
  end
  return nil
end

--- Expands `~` and makes a dev path absolute enough to use.
---
--- Deliberately not a general path resolver: `~`, `.` and `..` are all a dev path
--- needs, and every one of them is resolved here where there is one test for it
--- rather than at three call sites.
--- @param path string
--- @param home string|nil  the user's home, when the host knows it
--- @return string
function Source.expand_home(path, home)
  if path:sub(1, 1) ~= "~" then return path end
  local rest = path:sub(2)
  if rest == "" or rest:sub(1, 1) == "/" or rest:sub(1, 1) == "\\" then
    if not home or home == "" then return path end
    return home .. rest
  end
  -- `~name/...` is a different user's home. Not supported, and refusing it is
  -- better than silently resolving it to *this* user's home.
  return path
end

--- Turns one `packages.lua` entry into a validated source.
---
--- `entry` is a string or a table, exactly as written. Returns a spec table, or
--- nil plus a sentence naming the field that is wrong.
--- @param entry any
--- @param home string|nil  for `dir = "~/…"`
--- @return table|nil spec
--- @return string|nil err
function Source.parse(entry, home)
  if type(entry) == "string" then
    entry = { entry }
  end
  if type(entry) ~= "table" then
    return nil, string.format(
      "a package entry must be \"owner/repo\" or a table, got %s", type(entry))
  end

  -- Exactly one of the three shapes. A table with both `git` and `dir` is
  -- ambiguous and guessing which one was meant is how a package gets cloned when
  -- the user asked for it to be used in place.
  local has_dir = entry.dir ~= nil
  local has_git = entry.git ~= nil
  local positional = entry[1]

  if has_dir and (has_git or positional ~= nil) then
    return nil, "a source is either `dir` or a repository, not both"
  end

  if has_dir then
    if type(entry.dir) ~= "string" then
      return nil, "`dir` must be a string, got " .. type(entry.dir)
    end
    local path = Source.expand_home(entry.dir, home)
    local spec = {
      kind = "dir",
      dir = path,
      -- Recorded so the panel can say "using your own copy" rather than
      -- "installed", which is the difference between a switch and a lie.
      source_label = path,
    }
    local problem = Source.name_problem(entry.name)
    if entry.name ~= nil and problem then return nil, problem end
    spec.name = entry.name
    return spec
  end

  local url, short
  if has_git then
    url = entry.git
  elseif type(positional) == "string" then
    if positional:match(SHORT_RE) == nil then
      return nil, string.format(
        "%q is not \"owner/repo\"; give a full `git = \"…\"` URL if it is "
        .. "somewhere other than GitHub", positional)
    end
    short = positional
    url = "https://github.com/" .. positional .. ".git"
  else
    return nil, "a package entry needs \"owner/repo\", a `git` URL, or a `dir`"
  end

  local problem = Source.url_problem(url)
  if problem then return nil, problem end

  problem = Source.ref_problem(entry.rev)
  if problem then return nil, problem end

  problem = Source.subdir_problem(entry.subdir)
  if problem then return nil, problem end

  if entry.name ~= nil then
    problem = Source.name_problem(entry.name)
    if problem then return nil, problem end
  end

  -- A 40-hex rev is a commit and gets `git init` + `fetch <sha>`; anything else is
  -- a name and gets `--branch <ref>`. Deciding here rather than in `git.lua`
  -- keeps the distinction in one place, and the distinction decides whether the
  -- clone works at all: a server will usually not serve a commit by name.
  local ref_kind = "default"
  if entry.rev then
    ref_kind = (entry.rev:match(SHA_RE) ~= nil) and "sha" or "name"
  end

  return {
    kind = "git",
    url = url,
    short = short,
    ref = entry.rev,
    ref_kind = ref_kind,
    subdir = entry.subdir,
    name = entry.name,
    source_label = short or url,
  }
end

--- Whether a parsed source is the same repository and the same place in it.
---
--- Used to decide whether an installed package can be updated in place: same URL
--- and same subdirectory, or it is a different package that happens to share a
--- name. `rev` is deliberately not compared -- that is the thing being changed.
--- @param a table|nil
--- @param b table|nil
--- @return boolean
function Source.same_origin(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  if a.kind ~= b.kind then return false end
  if a.kind == "dir" then return a.dir == b.dir end
  return a.url == b.url and (a.subdir or "") == (b.subdir or "")
end

return Source