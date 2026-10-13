# git

Running git, and knowing what state the repository is in.

Install it and the status bar grows a branch. That is most of what this plugin
does on its own — **it registers no commands and binds no keys**, on purpose.
Anything you would want to *do* with git belongs to another package, and vim's
`with` entry on `git` is the one that ships. See
[what vim is wired to](vim-integrations.md).

## What you get on its own

The status bar, at the left of the document view:

```text
main  ↑2 ~3        branch, commits ahead, files changed
main  -            branch, no upstream
(main 1a2b3c)      detached HEAD
```

and nothing at all when you are not in a repository, or when the plugin is not
installed, or when nothing started the polling loop — see the last section. There
is no "git is missing" state, because the status bar asks a hook, and with no
hook it draws nothing.

| reading | means |
| --- | --- |
| `↑2` | two commits ahead of the upstream |
| `↓3` | three behind |
| `-` | no upstream tracking branch |
| `+1` | one file staged |
| `~4` | four files changed or untracked |
| `!2` | two files in conflict |

The counts come from `git status --porcelain`, not from parsing human output,
which is why an unusual filename does not confuse it. A name containing a
newline, a tab or a quote will: the parser strips git's quoting but does not
decode the escapes inside it.

## Using it from a menu

With `vim` and `menu` installed, <kbd>m</kbd> has a Git section, or run the commands:

| command | runs |
| --- | --- |
| `vim-git:status` | `git status` |
| `vim-git:log` | `git log --oneline -20` |
| `vim-git:diff` | `git diff` |
| `vim-git:add-all` | `git add .` |
| `vim-shell:git-status` / `git-log` / `git-diff` | the same three, under the shell's names |

All of them open the output in a scratch buffer, the same one `:!make` writes
to. Nothing is piped through a pager, and nothing is interactive — `git commit`
without `-m` would sit there waiting, which is why the menu's Commit entry asks
for the message first instead of running the bare command.

The menu also has Commit, Push, Pull and Branches, which are menu entries rather
than commands.

## Using it from your own plugin

```lua
local git = require "X.core.git.api"
```

| what | what it is |
| --- | --- |
| `git.exe()` | the path to the git executable, or `false` if it is not installed |
| `git.exe_cwd()` | the same, prefixed with `-C "<project dir>"` |
| `git.popen(cmd)` | run `cmd` and return its **captured output**, or `nil` |
| `git.normalize_path(p)` | a path the way git writes it |
| `git.IS_WIN` | the platform, so you don't have to ask `core` |
| `git.status` | the live status table (below) |
| `git.status.is_ignored(path)` | is this path in `.gitignore` |
| `git.status.refresh_ignored_now()` | re-read `.gitignore` |
| `git.recipes` | the shared shell command strings |

`exe()` and `exe_cwd()` take **no arguments** — they answer "where is git" and
"where is git, told about this project", not "run this". They are the two calls a
plugin needs before it can build a command line out of `git.recipes`.

`popen()` reads the whole stream and closes it, so it returns a string, not a
handle. It is not for something long-running.

`git.status` is a live table, not a function — it is polled on a coroutine
every `config.git_update_rate` seconds (2 by default) and the status bar reads
whatever is in it:

```lua
git.status.branch       -- "main", or "(" .. short_hash .. ")" when detached, or nil
git.status.has_remote   -- an upstream tracking branch exists
git.status.ahead        -- commits ahead
git.status.behind       -- commits behind
git.status.staged       -- files staged
git.status.unstaged     -- files changed or untracked
git.status.conflicts    -- files in conflict
git.status.repo_dirty   -- anything at all
git.status.root         -- the repository toplevel
git.status.state        -- "rebase" | "merge" | "cherry" | "bisect", or nil
```

A detached HEAD renders as `(1a2b3c)` — the short hash in parentheses. It is not
the literal word `detached`, and a comment in `status.lua` claiming otherwise is
wrong.

`git.status.state` is probed out of `.git/` directly: `rebase-merge`,
`rebase-apply`, `MERGE_HEAD`, `CHERRY_PICK_HEAD`, `BISECT_LOG`. It is nil in a
clean tree.

Also on the table, and used by integrations: `git.status.get_status(item)`,
`git.status.get_entry(item)`, `git.status.refresh()`, `git.status.thread()`, and
the raw per-file map `git.status.status`.

**Finding git is cached, including a failure.** On Windows the search is
`where.exe git`, then a preference for `…\cmd\git.exe`, then five hard-coded
paths. The result — or `false` — is cached for the life of the process, with no
invalidation. Installing git while the editor is open does not fix it.

## The recipes

`git.recipes` is a table of shell command strings, and it exists so the whole
repository spells each git invocation the same way:

```lua
status = "git status"
log    = "git log --oneline -20"
diff   = "git diff"
add_all= "git add ."
commit = "git commit"
push   = "git push"
pull   = "git pull"
branches = "git branch -a"
```

They are named `recipes` and not `commands` on purpose. In this codebase
`commands.lua` means a module with `register()`/`unregister()` that owns a set
of *cdin commands*, and a table of strings would be a lie under that name.

Adding to it is a one-line change, and every menu entry and command that runs
that git invocation follows — which is why the `with` entry on `git` has both its menu and its command
list driven by the one table.

## How it works

**`api.lua` is not `init.lua`, and that is deliberate.** The extension manager
reads a plugin's `init.lua` with `dofile()`, which produces a *different* table
from the one `require` hands out. A plugin whose `init.lua` is also its public
API therefore ends up with two half-initialised copies, and whichever one a
consumer got depends on how it was loaded. So `init.lua` holds the manifest and
nothing else, and the real surface is `api.lua`, which is only ever `require`d.

This is worth internalising because it applies to every plugin in the catalog
and it is the one structural rule that has no `validate` check behind it.

**The editor has no idea git exists.** `core` exposes a generic hook,
`core.register_vcs_provider`, and the status bar reads through it. With no
provider registered the status bar renders nothing there. This is the same
arrangement as vim mode and the menu: the runtime is not allowed to grow a
special case for a capability it does not own.

**The provider is a table of three functions** — `is_ignored`,
`refresh_ignored_now`, and `status` — registered once and never removed, because
`core` keeps no list to remove from. `unregister()` drops this plugin's own
flag so a later enable registers again. That is a smaller promise than the rest
of the catalog makes, and it is honest about it.

**This plugin starts no polling thread.** `core.add_thread(git.status.thread)`
appears in exactly one place in the catalog, and it is not here — it belonged to
`git-treeview`, and that package is gone. So installing
`git` on its own registers a provider and leaves `git.status.branch` nil until
the host's `register_vcs_provider` hook decides to start the loop for it. That
is the host's half of the contract, and the page should not have implied
otherwise.

**Registration is guarded, and the guard is silent.** `register()` only does
anything `if core.register_vcs_provider` exists. On a host without that hook it
is a no-op with no message — the plugin looks loaded and does nothing.

**The catalog is fetched with git.** `sync_registry`, which used to live here,
is gone, along with the HTTPS download it wrapped: `cdinx/manager/registry.lua`
keeps a **sparse shallow clone** of the cdin-x repository and reads the catalog
out of it, while `cdinx/manager/git.lua` and `transport.lua` clone and update
third-party packages the same way. Every git command runs as a detached job
polled from a coroutine, so a slow or stalled transfer cannot freeze the editor.
`Manager.set_registry_syncer` survives only as a deprecation shim that logs once
per process, and nothing registers one.

**Status polling is a coroutine.** It sleeps `config.git_update_rate` between
passes and never blocks the frame loop. `is_ignored` is synchronous because the
file tree has to decide whether to draw an entry *now*, and it answers from a
cache that `refresh_ignored_now` updates.

**Porcelain is parsed, not decoded.** The parser strips git's quotes but does not
unescape `\n`, `\t` or `\"` inside them, so a filename containing one of those is
stored wrong. `core.project_files` limits the damage — such a file will not be in
the list anyway — but the claim that "a path with a newline does not confuse it"
was too strong.

## Files

| file | holds |
| --- | --- |
| `api.lua` | the public surface, and the host's vcs hook |
| `exec.lua` | running processes, platform differences |
| `status.lua` | the status table, polling, `.gitignore` |
| `recipes.lua` | the shared command strings |
| `manager/ops.lua` | `exe`, `exe_cwd`, `popen` — and three dead helpers |
| `manager/find-git.lua` | finding the git executable, cached |
| `manager/utils.lua` | shared helpers |

`manager/ops.lua` still carries the banner comment for the deleted registry
fetcher, and three locals — `quote`, `succeeded`, `run` — that nothing calls.
`exec.exe_with_dir` exists and is not re-exported by `api.lua`, so it is
unreachable from the documented surface.
