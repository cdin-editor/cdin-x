-- Running git, and not letting it run anything else.
--
-- Everything here comes from three places: the user's `packages.lua`, a remote the
-- user pointed at, and this file. Only the first two are untrusted, and both are
-- validated by `source.lua` before they get here. This module's job is the third
-- kind of care: even a validated value has to reach git as one argument, and git
-- has to be unable to reach a shell.
--
-- So the shape is the same throughout:
--
--   1. An *argument builder* returns a list of strings. No quoting, no shell, no
--      string concatenation. Pure, and testable without git installed.
--   2. `Git.argv_to_command` turns that list into a command line, quoting every
--      element exactly once, in one place. There is no second path that produces
--      a command line, so there is nothing to keep in step.
--   3. `Git.run` hands the command to `system.exec` and returns a job the caller
--      polls from a thread. Nothing here blocks.
--
-- The four settings every command carries, and why each is here rather than in a
-- wrapper script somewhere:
--
--   GIT_TERMINAL_PROMPT=0   a credential prompt on a detached job is a job that
--                           never finishes. It is the difference between "the
--                           clone failed" and "the editor hangs forever".
--   GIT_ALLOW_PROTOCOL=https:ssh
--                           `ext::` and `file::` are git transports that *execute
--                           something*: `ext::sh -c '…'` runs a shell command during
--                           a clone. source.lua refuses those URLs, and this makes
--                           it true a second time at the point where it matters.
--   core.symlinks=false     a checkout on Windows must not materialise links to
--                           files outside the tree.
--   core.hooksPath=<empty>  a clone must not run a hook from the repository it
--                           just cloned.
--
-- No submodule is ever initialised, and every user-controlled argument goes after
-- `--`, so a ref that looked like an option cannot become one.
local Host = require "cdinx.host"
local Util = require "cdinx.manager.util"
local Source = require "cdinx.manager.source"

local Git = {}

--- How long a git job may run before it is called failed.
---
--- Bounded because an unbounded job is an editor that never comes back: a stalled
--- transfer with no `--low-speed` trigger, a server that accepts a connection and
--- then says nothing. Both of those are covered below; this is the backstop.
Git.TIMEOUT = 300

--- Refused past this, not truncated. A package over the cap is one whose author
--- should hear about it, not one that gets a mysterious half-install.
Git.LIMITS = Source.LIMITS

-- ── quoting ──────────────────────────────────────────────────────────────
--
-- One function, because one function is one thing to get right. `fetch.lua` has
-- its own, and the reason this is not shared is that fetch.lua's is wrapped around
-- a shell and this one is not.

--- Quotes one argument for a POSIX shell or for cmd.exe.
---
--- The rule is the conservative one: if the string contains nothing that a shell
--- could act on, it is used as it is; otherwise it is quoted, once, here. POSIX
--- gets single quotes with embedded quotes closed, escaped and reopened. Windows
--- gets double quotes, because cmd.exe does not treat `'` as special at all and a
--- single-quoted path with a space in it arrives as several arguments. An embedded
--- `"` on Windows is escaped as `\"`, which is what the C runtime's own parsing
--- turns back into one argument.
--- @param arg string
--- @return string
function Git.quote(arg)
  arg = tostring(arg)
  if arg ~= "" and not arg:find("[%s\"'&|<>^();$`\\!]") then
    return arg
  end
  if Host.is_windows then
    return '"' .. arg:gsub('"', '\\"') .. '"'
  end
  -- `'` is the only character that cannot appear inside a POSIX single-quoted
  -- string, so it is the only one that needs closing.
  return "'" .. arg:gsub("'", "'\\''") .. "'"
end

--- A command line from an argument list.
--- @param argv string[]
--- @param env table<string, string>|nil  extra environment assignments
--- @return string
function Git.argv_to_command(argv, env)
  local parts = {}
  -- Sorted, because a command line is observable in a log and in a test, and a
  -- `pairs` order makes the same operation read differently on two runs.
  if env then
    local keys = {}
    for key in pairs(env) do keys[#keys + 1] = key end
    table.sort(keys)
    if Host.is_windows then
      -- `set "VAR=value" && `, not `VAR=value `.
      --
      -- The POSIX spelling is not a Windows one, and the difference is not
      -- cosmetic: `cmd.exe` has no environment-prefix syntax at all, so
      -- `GIT_ALLOW_PROTOCOL=https:ssh git clone ...` is read as a command named
      -- `GIT_ALLOW_PROTOCOL=https:ssh` -- and every git command cdin-x runs on
      -- Windows fails with "'GIT_ALLOW_PROTOCOL' is not recognized", before git is
      -- ever reached. The whole-quoted assignment is the form Windows agrees on and
      -- the one that survives a value containing `=` or a space.
      for _, key in ipairs(keys) do
        parts[#parts + 1] = "set " .. Git.quote(key .. "=" .. tostring(env[key])) .. " &&"
      end
    else
      for _, key in ipairs(keys) do
        parts[#parts + 1] = key .. "=" .. Git.quote(env[key])
      end
    end
  end
  for _, arg in ipairs(argv) do
    parts[#parts + 1] = Git.quote(arg)
  end
  return table.concat(parts, " ")
end

--- The environment every git command runs with.
--- @return table<string, string>
function Git.env()
  return {
    -- A prompt on a detached job is a job that never ends.
    GIT_TERMINAL_PROMPT = "0",
    -- Blocks `ext::` and `file::`, which are not transports but command runners.
    GIT_ALLOW_PROTOCOL = "https:ssh",
  }
end

--- The `-c` flags every git command carries.
---
--- `http.lowSpeedLimit`/`http.lowSpeedTime` are what turn "the transfer has
--- stalled" into a failure git reports, instead of a job that sits forever under
--- the generic timeout.
--- @param git string|nil  the git executable, when it is known
--- @return string[]
function Git.base_flags()
  return {
    "-c", "core.symlinks=false",
    "-c", "core.hooksPath=",          -- empty: a freshly cloned hook never runs
    "-c", "protocol.version=2",
    "-c", "http.lowSpeedLimit=1000",
    "-c", "http.lowSpeedTime=30",
    -- `--no-recurse-submodules` used to be here, and it is a `git clone` option
    -- rather than a `git` global: git rejects the whole command line with "unknown
    -- option" before it looks at the subcommand, so every command cdin-x runs
    -- failed. It is with the clone now, which is where it means anything -- and
    -- selection refuses mode 160000 as well, so a submodule is never copied either
    -- way. Two defences because the first one is a flag git parses and the second is
    -- a rule this system enforces.
  }
end

-- ── the executable ───────────────────────────────────────────────────────

--- Where git is, or nil.
---
--- Probed once and cached, because a missing git is a fact about the machine and
--- asking again on every install would cost a process spawn to learn nothing new.
---
--- PATH is tried first because that is where a user who installed git put it; the
--- Git for Windows locations after, because that installer does not always add
--- itself to PATH for a process that is not an interactive shell.
---
--- The probe is `--version` rather than `rev-parse`: it starts no repository
--- discovery, touches no network, and says the one thing we want to know.
--- @return string|nil path
--- @return string|nil why
function Git.find()
  if Git._found ~= nil then
    return Git._found, Git._why
  end

  local function probe(exe)
    local cmd = Git.argv_to_command({ exe, "--version" })
    local pipe = io.popen(cmd .. " 2>nul")
    local out = pipe and pipe:read("*a") or ""
    if pipe then pipe:close() end
    if type(out) == "string" and out:find("git version", 1, true) then
      return exe, out:match("git version ([%d%.]+)")
    end
    return nil
  end

  for _, exe in ipairs({ "git", "git.exe" }) do
    local found, version = probe(exe)
    if found then
      Git._found, Git._why, Git._version = found, nil, version
      return found
    end
  end

  -- The usual install locations, tried in the order a user would expect: 64-bit
  -- first, then 32-bit.
  local suffix = Util.join("Programs", "Git", "cmd", "git.exe")
  for _, base in ipairs({ "C:/Program Files", "C:/Program Files (x86)" }) do
    local candidate = base .. "/" .. suffix
    local found, version = probe(candidate)
    if found then
      Git._found, Git._why, Git._version = found, nil, version
      return found
    end
  end

  Git._found, Git._why = false, [[git was not found on PATH or in the usual
    locations. Packages shipped with the editor need no git; installing or
    updating one does. Install Git for Windows, or put git on PATH, and try again.]]
  return false, Git._why
end

--- The probed git version ("2.50.0"), or nil when git is missing.
---
--- Recorded by the `--version` probe rather than re-asked, because the answer
--- cannot change while the editor runs and a second process spawn buys nothing.
--- Compared numerically where it matters: sparse clones need 2.27+, so an older
--- git gets a plain shallow clone instead of an error about an option it never
--- had.
--- @return string|nil
function Git.version()
  if Git._found == nil then Git.find() end
  return Git._version
end

--- Whether this git understands `clone --sparse`.
--- @return boolean
function Git.supports_sparse()
  local v = Git.version()
  if not v then return false end
  local major, minor = v:match("^(%d+)%.(%d+)")
  major, minor = tonumber(major), tonumber(minor)
  if not major then return false end
  return major > 2 or (major == 2 and (minor or 0) >= 27)
end

--- Forgets the probe, so a test can ask again.
function Git.reset_probe()
  Git._found, Git._why = nil, nil
end

-- ── argument builders ────────────────────────────────────────────────────
--
-- Each returns an argv list, or nil plus a sentence. Each re-checks the URL and
-- the ref rather than trusting `source.lua` to have done it: the check is two
-- comparisons and the alternative is a module that is only safe when called from
-- exactly one other module.

--- `git ls-remote -- <url> <ref>`, to see what a ref points at without cloning.
--- @param spec table  as Source.parse returned
--- @return string[]|nil argv
--- @return string|nil err
function Git.ls_remote_args(spec)
  if not Source.valid_url(spec and spec.url) then
    return nil, Source.url_problem(spec and spec.url)
  end
  local argv = { "git", "-c", "credential.interactive=never" }
  for _, flag in ipairs(Git.base_flags()) do argv[#argv + 1] = flag end
  argv[#argv + 1] = "ls-remote"
  -- Everything user-controlled goes after `--`. For `ls-remote` that means the
  -- repository; the ref is positional and cannot be an option because `git`
  -- treats everything after the repository as a pattern, but it is validated
  -- anyway rather than relied upon.
  argv[#argv + 1] = "--"
  argv[#argv + 1] = spec.url
  if spec.ref then
    if not Source.valid_ref(spec.ref) then
      return nil, Source.ref_problem(spec.ref)
    end
    argv[#argv + 1] = spec.ref
  end
  return argv
end

--- The shallow clone of a branch or a tag.
---
--- `--depth 1 --single-branch` because nothing downstream asks for history: the
--- store holds selected files, the lock holds one commit, and an update is a fresh
--- shallow clone rather than a fetch into the old tree.
--- `--filter=blob:none` because the checkout only needs the blobs of the files it
--- selects. A server that ignores it is slower and never wrong.
--- @param spec table
--- @param dest string
--- @return string[]|nil argv
--- @return string|nil err
function Git.clone_args(spec, dest)
  if not Source.valid_url(spec and spec.url) then
    return nil, Source.url_problem(spec and spec.url)
  end
  if spec.ref_kind == "sha" then
    return nil, "a commit is not cloned with --branch; use Git.fetch_sha_args"
  end
  if spec.ref and not Source.valid_ref(spec.ref) then
    return nil, Source.ref_problem(spec.ref)
  end

  local argv = { "git" }
  for _, flag in ipairs(Git.base_flags()) do argv[#argv + 1] = flag end
  argv[#argv + 1] = "clone"
  argv[#argv + 1] = "--depth"
  argv[#argv + 1] = "1"
  argv[#argv + 1] = "--single-branch"
  argv[#argv + 1] = "--no-tags"
  argv[#argv + 1] = "--filter=blob:none"
  -- A submodule is another repository, and a package is not one. Said to `clone`
  -- rather than to `git`, which is the only place git accepts it.
  argv[#argv + 1] = "--no-recurse-submodules"
  if spec.ref then
    argv[#argv + 1] = "--branch"
    argv[#argv + 1] = spec.ref
  end
  argv[#argv + 1] = "--"
  argv[#argv + 1] = spec.url
  argv[#argv + 1] = dest
  return argv
end

--- `init <dir>`, the first step of a commit install.
---
--- A directory, not a repository: `git init` makes it one. Local and instant, so
--- the caller runs it inline rather than as a job.
--- @param dir string
--- @return string[]
function Git.init_args(dir)
  local argv = { "git" }
  for _, flag in ipairs(Git.base_flags()) do argv[#argv + 1] = flag end
  argv[#argv + 1] = "init"
  argv[#argv + 1] = dir
  return argv
end

--- `fetch <url> <sha>` inside an initialised directory, for a commit.
---
--- A server will usually not serve a commit by name -- `--branch` wants a branch
--- or a tag -- so the only way to install a pinned commit is to initialise an
--- empty repository, ask for that one object, and check it out detached. The URL
--- goes on the command line rather than through a remote because there is no
--- remote: this repository was just initialised and has never spoken to anyone.
--- @param dir string
--- @param url string
--- @param ref string  the 40-hex commit
--- @return string[]|nil argv
--- @return string|nil err
function Git.fetch_sha_args(dir, url, ref)
  if not Source.valid_url(url) then
    return nil, Source.url_problem(url)
  end
  if not Source.valid_ref(ref) then
    return nil, Source.ref_problem(ref)
  end
  local argv = { "git", "-C", dir }
  for _, flag in ipairs(Git.base_flags()) do argv[#argv + 1] = flag end
  argv[#argv + 1] = "fetch"
  argv[#argv + 1] = "--depth"
  argv[#argv + 1] = "1"
  argv[#argv + 1] = "--no-tags"
  argv[#argv + 1] = "--"
  argv[#argv + 1] = url
  argv[#argv + 1] = ref
  return argv
end

--- `checkout --detach FETCH_HEAD`, the last step of a commit install.
--- @param dir string
--- @return string[]
function Git.checkout_fetch_head_args(dir)
  local argv = { "git", "-C", dir }
  for _, flag in ipairs(Git.base_flags()) do argv[#argv + 1] = flag end
  argv[#argv + 1] = "checkout"
  argv[#argv + 1] = "--detach"
  argv[#argv + 1] = "FETCH_HEAD"
  return argv
end

--- `ls-files -s -z`, which is how a clone is enumerated.
---
--- From git's index rather than the filesystem, for two reasons neither of which
--- the filesystem can give: symlinks are visible as mode 120000 and so can be
--- refused rather than followed, and untracked droppings are simply not listed.
--- The host's `stat` follows symlinks and exposes no lstat, so a directory walk
--- cannot tell a link from a file -- this can.
--- @param dir string
--- @param subdir string|nil  the package root inside the clone, or nil for all
--- @return string[]
function Git.ls_files_args(dir, subdir)
  local argv = { "git", "-C", dir }
  for _, flag in ipairs(Git.base_flags()) do argv[#argv + 1] = flag end
  argv[#argv + 1] = "ls-files"
  argv[#argv + 1] = "-s"
  argv[#argv + 1] = "-z"
  argv[#argv + 1] = "--"
  if subdir and subdir ~= "" then
    argv[#argv + 1] = subdir
  else
    argv[#argv + 1] = "."
  end
  return argv
end

--- `rev-parse HEAD`, which is how the commit of a checkout is read.
--- @param dir string
--- @return string[]
function Git.rev_parse_args(dir)
  return { "git", "-C", dir, "rev-parse", "HEAD" }
end

--- The registry's own clone: shallow, blobless, sparse.
---
--- Separate from `clone_args` because the *shape* is different and the reasons are
--- specific: `--sparse` so the working tree holds only `registry/` however large
--- this repository grows, and no `--single-branch` because a registry that can
--- only ever update one branch is not a registry.
--- @param url string
--- @param dest string
--- @return string[]|nil argv
--- @return string|nil err
function Git.sparse_clone_args(url, dest)
  if not Source.valid_url(url) then return nil, Source.url_problem(url) end
  local argv = { "git" }
  for _, flag in ipairs(Git.base_flags()) do argv[#argv + 1] = flag end
  argv[#argv + 1] = "clone"
  argv[#argv + 1] = "--depth"
  argv[#argv + 1] = "1"
  argv[#argv + 1] = "--filter=blob:none"
  argv[#argv + 1] = "--sparse"
  argv[#argv + 1] = "--"
  argv[#argv + 1] = url
  argv[#argv + 1] = dest
  return argv
end

--- `sparse-checkout set` or `add`, which is what keeps a registry clone small.
---
--- `set` first (it replaces the list), then `add` for the package being
--- installed. Between them the working tree never holds more than the index plus
--- one package, which is the whole point of the sparse clone.
--- @param dir string
--- @param paths string[]
--- @param mode string|nil  "add" for everything after the first call
--- @return string[]|nil argv
--- @return string|nil err
function Git.sparse_args(dir, paths, mode)
  local argv = { "git", "-C", dir }
  for _, flag in ipairs(Git.base_flags()) do argv[#argv + 1] = flag end
  argv[#argv + 1] = "sparse-checkout"
  argv[#argv + 1] = (mode == "add") and "add" or "set"
  for _, path in ipairs(paths or {}) do
    -- A sparse path comes from a manifest read through the sandbox, but it still
    -- goes through the same refusal: no leading dash, no climb out.
    if type(path) ~= "string" or path:sub(1, 1) == "-" then
      return nil, "a sparse-checkout path may not start with a dash"
    end
    for _, segment in tostring(path):gmatch("[^/]+") do
      if segment == ".." then return nil, "a sparse-checkout path may not contain '..'" end
    end
    argv[#argv + 1] = path
  end
  return argv
end

--- `fetch` in an existing repository, for a registry refresh.
--- @param dir string
--- @param branch string|nil
--- @return string[]|nil argv
--- @return string|nil err
function Git.fetch_args(dir, branch)
  local argv = { "git", "-C", dir }
  for _, flag in ipairs(Git.base_flags()) do argv[#argv + 1] = flag end
  argv[#argv + 1] = "fetch"
  argv[#argv + 1] = "--depth"
  argv[#argv + 1] = "1"
  argv[#argv + 1] = "--no-tags"
  argv[#argv + 1] = "origin"
  if branch then
    if not Source.valid_ref(branch) then return nil, Source.ref_problem(branch) end
    argv[#argv + 1] = branch
  end
  return argv
end

--- A plain shallow clone: no `--filter`, no `--sparse`.
---
--- The fallback when the git at hand predates sparse clones, or the server
--- answers a filtered clone with an error about an option. Slower, never broken:
--- the working tree holds the whole shallow tree, so the sparse steps are
--- skipped and the trim is a no-op rather than a failure.
--- @param url string
--- @param dest string
--- @param ref string|nil
--- @return string[]|nil argv
--- @return string|nil err
function Git.plain_clone_args(url, dest, ref)
  if not Source.valid_url(url) then
    return nil, Source.url_problem(url)
  end
  if ref ~= nil and not Source.valid_ref(ref) then
    return nil, Source.ref_problem(ref)
  end
  local argv = { "git" }
  for _, flag in ipairs(Git.base_flags()) do argv[#argv + 1] = flag end
  argv[#argv + 1] = "clone"
  argv[#argv + 1] = "--depth"
  argv[#argv + 1] = "1"
  argv[#argv + 1] = "--single-branch"
  argv[#argv + 1] = "--no-tags"
  if ref then
    argv[#argv + 1] = "--branch"
    argv[#argv + 1] = ref
  end
  argv[#argv + 1] = "--"
  argv[#argv + 1] = url
  argv[#argv + 1] = dest
  return argv
end

--- `remote get-url origin`: who a clone speaks to, without trusting a file.
---
--- Read through git rather than by parsing `.git/config`, because the config
--- file's shape (subsections, includes, a `.git` that is a file rather than a
--- directory) is git's business and reimplementing its reader here is how a
--- working tree gets misidentified.
--- @param dir string
--- @return string[]
function Git.remote_url_args(dir)
  return { "git", "-C", dir, "remote", "get-url", "origin" }
end

--- `checkout --detach FETCH_HEAD`, for a registry refresh.
--- @param dir string
--- @return string[]
function Git.checkout_args(dir)
  return { "git", "-C", dir, "checkout", "--detach", "FETCH_HEAD" }
end

--- `sparse-checkout reapply`, to trim a working tree after a checkout.
--- @param dir string
--- @return string[]
function Git.sparse_reapply_args(dir)
  return { "git", "-C", dir, "sparse-checkout", "reapply" }
end

-- ── running them ─────────────────────────────────────────────────────────

--- Runs one git command and waits for it.
---
--- Only for the *local* ones. Anything that touches the network goes through
--- `Git.run`, because this blocks the caller's thread and the caller's thread is
--- the editor's frame.
--- @param argv string[]
--- @param opts table|nil  { cwd = string|nil }
--- @return boolean ok
--- @return string output  stdout and stderr together, trimmed
--- @return string|nil why
function Git.run_now(argv, opts)
  local command = Git.argv_to_command(argv, Git.env())
  if opts and opts.cwd then
    command = "cd " .. Git.quote(opts.cwd) .. " && " .. command
  end
  -- `io.popen` gives no exit status on every platform, so success is read from a
  -- marker git's own output cannot contain: one line, appended only when the
  -- command itself succeeded, never part of a path.
  local pipe = io.popen(command .. " 2>&1 && echo __CDINX_GIT_OK__")
  if not pipe then return false, "", "could not start a shell" end
  local out = pipe:read("*a") or ""
  pipe:close()
  local ok = out:find("__CDINX_GIT_OK__", 1, true) ~= nil
  out = out:gsub("__CDINX_GIT_OK__[%s]*$", ""):gsub("[\r\n]+$", "")
  return ok, out, ok and nil or (out ~= "" and out or "git produced no output")
end

--- Starts one git command as a detached job.
---
--- Returns a handle the caller polls. Nothing here waits: the marker file is
--- written by the child when it finishes, and `Git.poll` looks at it. That is the
--- same shape `fetch.lua` uses, and the reason is rule 7 of the host's own rules --
--- an unbounded wait on the frame thread is not allowed, and a credential prompt
--- is unbounded.
--- @param argv string[]
--- @param workdir string  a directory this module owns, used for markers
--- @param opts table|nil  { cwd = string|nil, timeout = number|nil, label = string|nil }
--- @return table|nil job
--- @return string|nil why
function Git.run(argv, workdir, opts)
  opts = opts or {}
  local label = (opts.label or "git"):gsub("[^%w%-]", "_")
  local base = Util.join(workdir, "." .. label)
  local done = base .. ".done"
  local log = base .. ".log"

  Host.fs.mkdir(workdir)

  -- A stale marker from a previous run would read as this run's result, so both
  -- are cleared before the command is started. The window between them is why the
  -- base name carries the label: two jobs of the same kind cannot collide.
  Host.fs.rm(done)
  Host.fs.rm(log)

  local command = Git.argv_to_command(argv, Git.env())
  if opts.cwd then
    command = "cd " .. Git.quote(opts.cwd) .. " && " .. command
  end
  -- `> log 2>&1 && echo ok > done` in one shell command, because that is the only
  -- way to make the marker appear *after* the process has finished and its output
  -- has been flushed. On Windows the outer quotes are what let an inner quoted
  -- path survive cmd's own quote stripping; the `||` is there so a non-zero exit
  -- still writes something to the log.
  local full = command .. " > " .. Git.quote(log) .. " 2>&1"
  if Host.is_windows then
    full = 'cmd.exe /C "' .. full .. " && echo ok> " .. Git.quote(done) .. '"'
  else
    full = full .. " && echo ok > " .. Git.quote(done)
  end

  -- `system.exec` starts the process detached and returns nothing, so there is no
  -- handle to check: a launch that failed leaves no marker, and the timeout in
  -- `Git.poll` is what turns that into a failure rather than a hang. Raising here
  -- would be a lie about what is known -- nothing -- and the poll loop is the one
  -- place that can tell "never started" from "still running".
  Host.exec(full)

  return {
    argv = argv,
    label = label,
    done = done,
    log = log,
    workdir = workdir,
    started = Host.time(),
    timeout = opts.timeout or Git.TIMEOUT,
  }
end

--- Whether a job has finished, and how it went.
--- @param job table
--- @return string  "running" | "ok" | "failed"
--- @return string|nil why  the last line of the log, when it failed
function Git.poll(job)
  if type(job) ~= "table" then return "failed", "no job" end

  -- Read with io.open directly, the way fetch.lua does: the host's fs module has
  -- no read_file, and adding host surface for one marker would be a second way to
  -- read a file for no benefit.
  local marker = nil
  do
    local fp = io.open(job.done, "rb")
    if fp then marker = fp:read("*a") fp:close() end
  end
  if not marker then
    -- No marker: either still running, or already timed out. The timeout is what
    -- tells them apart, and it is checked here rather than by a timer so a job
    -- polled from a thread needs no timer at all.
    local elapsed = Host.time() - (job.started or 0)
    if job.timeout and elapsed > job.timeout then
      return "failed", string.format(
        "git %s took longer than %d seconds and was given up on",
        job.label, job.timeout)
    end
    return "running"
  end

  local text = marker:match("ok") and "ok" or "failed"
  if text == "ok" then return "ok" end

  local last = ""
  local fp = io.open(job.log, "rb")
  if fp then
    for line in fp:lines() do last = line end
    fp:close()
  end
  return "failed", (last ~= "" and last) or ("git " .. job.label .. " failed")
end

--- Reads the commit a checkout is at.
---
--- Local, instant, and one of the git calls that may block: it reads state that
--- is already on disk, needs no network and takes no working-tree lock, so a
--- caller may run it inline without risking the frame. `init`, `checkout` and
--- `ls-files` are the others, for the same reason.
--- @param dir string
--- @return string|nil rev
--- @return string|nil why
function Git.head_rev(dir)
  local ok, out = Git.run_now(Git.rev_parse_args(dir))
  if not ok then return nil, out end
  local rev = out:match("(%x%x%x%x%x%x%x+)%s*$")
  if not rev or #rev < 7 then
    return nil, "git rev-parse did not return a commit"
  end
  return rev
end

return Git