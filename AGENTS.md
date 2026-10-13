# AGENTS.md

Instructions for AI coding agents working in this repository. Read this file and `CODE_STYLE.md` completely before the first edit. If a task prompt conflicts with either, stop and ask.

## What this repository is

cdin-x is the extension ecosystem for [cdin](https://github.com/m-mdy-m/cdin), a C + Lua text editor (a fork of lite). The editor is Lua 5.4 loaded from `data/core/`; the C binary is only a host.

- `cdinx/` — the kernel: finds, resolves, installs, loads and unloads packages, and draws the manager panel. It is not a package.
- `packages/` — first-party packages (plugins, languages, themes).
- `bundles/` — named lists of packages. A build or a user picks a bundle.
- `registry/` — index of third-party packages that live in their own repositories.
- `scripts/` — tooling (Lua for in-toolchain work, Python 3 stdlib only for build and install).

cdin is a separate repository. It knows nothing about packages and must start, render, edit and answer `ctrl+n` with an empty site directory. **Never edit the cdin repository from here**, and nothing in this repository may make cdin depend on cdin-x.

## The host contract

The authority is cdin's `docs/architecture/extension-contract.md`. If something is not in it, it is not a contract and you may not rely on it. The parts that decide most of your design:

- **Plugin protocol.** An entry point is a directory with `init.lua` or a single `.lua` file returning a table with `init(core, config)` (two positional arguments) and an optional `unload()`. `init` must tolerate being called twice. `unload` is called only by `core:unload-plugin`, never on exit or failure.
- **Two host roots.** `EXEDIR/data/plugins` (bundled: every entry loads, always, whatever `config.plugins` or `--no-plugins` say, and a bundled entry beats a site entry of the same name) and `config.site_path()/plugins` (selected by `config.plugins`). Entries load in sorted name order with no dependency ordering. The host loader `dofile`s the entry point.
- **Third place.** The manager keeps its own store and loads what it installed itself. The host has no idea it exists and nothing in cdin may name it.
- **Module resolution.** The site directory is appended to `package.path`; the editor's own modules stay ahead. Custom searchers must sit after the standard Lua-file searcher so core cannot be shadowed.
- **Real seams:** `command.add/remove`, `keymap.add/remove` (list values are fallback chains; always hand back the same table on `remove`), `Doc._before_save/_after_save/_after_load` lists, `core.register_status_pill`, `core.register_vcs_provider` (not usable from `init`; defer with `core.add_thread`), `core.register_recent_provider`, `core.register_help_shortcuts`/`unregister_help_shortcuts`, `core.root_view:attach_side_view/detach_view/get_edge_node`, `core.command_view:enter`, `core.themes.add_root`, `core.syntax.add` (no `remove`), `style.set_fallback`, `core.reload_module`.
- **There is no general event/hook system, no major/minor modes and no async process API.** `system.popen` blocks until the process ends and returns all output; `system.exec` starts a detached process. Background work is a `core.add_thread` coroutine (`coroutine.yield(seconds)` sleeps). The existing downloader starts a detached job and polls it from a thread; follow that pattern.
- **Globals are an error.** `core.runtime.strict` raises on undeclared globals. Host-provided globals: `EXEDIR`, `EXEFILE`, `PATHSEP`, `PLATFORM`, `VERSION`, `ARGS`, `SCALE`, `system`, `renderer` (and `core` where the existing code uses it unqualified; verify). Never write to them.
- **Paths.** Use `config.site_path()` (a function; never cache it) and `core.fs` (`join` handles separators). Never compute the site directory yourself.
- **A theme** is `<root>/<name>/theme.lua`; roots are added with `themes.add_root(dir)`. `config.theme` is applied before plugins run and re-applied once after. The editor has built-in fallback colours and fonts, so a missing theme is not fatal.

## Cross-repo invariants (until the owner updates cdin)

cdin's test suite (`make test-plugins`, `test-workflows`, `test-site-dir`) uses a cdin-x checkout as its site directory. Keep these true unless a task says otherwise, and list every one you break, and why, in your report:

1. `scripts/install.py` keeps `SITE_DIRNAME = "..."`, honours `CDIN_SITE_DIRNAME`, and exposes `--site-name`.
2. `cdinx/config.lua` keeps the line `config.site_dir = config.site_path()` and never hardcodes the directory name.
3. `require "cdinx.manager"` keeps working and exposes what the tests call.
4. The panel keeps its commands (`pluginmanager:*`, `cdin-x:*`) and `ctrl+shift+m`; `ctrl+shift+l` stays the log.
5. `scripts/bundle.py --out <dir>` with no other argument still produces a working build (today's `standard` set). cdin's `assemble_data.py` calls exactly that.
6. The workflow plugins keep registering `core:find-command`, `core:find-file`, `core:open-file`, `core:open-folder`, `core:reload-module`, `core:open-user-module`, `core:open-project-module` on `ctrl+shift+p`, `ctrl+p`, `ctrl+o`, `ctrl+shift+o` (names of the owning plugins may change; the cdin test names them).

## Layout

```text
cdinx/       kernel
plugins/     site entry point (one file)
packages/    first-party packages, grouped by domain; identity is package.lua, not the path
bundles/     bundle definitions
glue/        third-party-only pair packages            (Phase 7)
registry/    generated/catalog.lua; index.lua is Phase 7
scripts/     tooling
docs/  examples/  fonts/
```

Marked "(Phase N)" is where the task prompt puts it, not a thing to build early.

## Commands

Confirm exact targets in the `Makefile` before relying on them.

```sh
make validate                  # the gate; must pass before you report any work as done
make link | install | uninstall
make bundle [BUNDLE=<name>]    # no argument builds `standard`
make list
make check PKG=<path>          # one package against the rules in 6.9
make index                     # writes registry/generated/catalog.lua
```

`make manifest` is gone with `X/`. It regenerated a second copy of the catalog at
`X/manifest.lua`; `registry/generated/catalog.lua` is the only generated index.

No test target exists here. Do not add one.

## Priorities, in order

1. **Correctness and stability.** The boring, proven approach wins.
2. **Runtime performance and memory.** The editor is interactive; startup and per-keystroke paths are sacred.
3. **Simplicity.** The least logic that is correct and robust.
4. **Modularity.** Small files, one responsibility, explicit seams.
5. **Brevity.**

The fastest solution is not automatically the best, and the longest is not automatically the safest. Decide from the context: how often the code runs, what fails if it is wrong, and who has to maintain it. When two options are both stable and the trade-off is real, ask (see "When to ask").

## What you write and what you do not

You write production code only.

- **No tests.** The owner writes them. Design code so it is testable (pure functions separated from IO, dependencies passed in), but do not create test files, fixtures or test targets.
- **No documentation.** Do not create or edit `docs/`, `README.md` files, `CONTRIBUTING.md` or `CHANGELOG.md`. The owner writes these after the code is stable. If a validate rule demands docs or a changelog, make that rule a warning instead of an error and report it.
- **No comments beyond the policy** in `CODE_STYLE.md`.
- Throwaway smoke scripts for your own verification go in the scratchpad or a temp directory outside the repository and are never committed.

## Decision rules

- Prefer the standard library and what the repository already does. Add no dependency without asking.
- No cleverness: no metatable magic, no dynamic `load` of strings (except the sandboxed manifest reader), no wrapping of host functions when a documented seam exists. If you must wrap, save the original, call it, and restore it in `unload`.
- Do not abstract before the third use. Duplicating three lines beats a wrong abstraction.
- Do not change behaviour while moving code. Moves and edits are separate steps (see "Git").
- Fail loudly at boundaries, stay quiet inside. Validate input where it enters (files, user config, process output, network); trust it afterwards.
- Treat every package other than your own as unavailable until proven loaded.
- Never block the frame loop.

## When to ask

Ask when the answer changes what you build and you cannot settle it from the code, the task prompt or these rules:

- an irreversible or destructive action (deleting files outside the task, rewriting history, overwriting user data);
- a public contract: manifest fields, command names, file formats, directory names that users or third parties will depend on;
- two stable options with a real trade-off (e.g. extra memory for speed, extra files for isolation);
- host behaviour you cannot read from the cdin source or its contract;
- a new dependency;
- any deviation from the architecture in the task prompt.

Do not ask about formatting, naming, or anything these documents already decide.

Every question must carry its context, in this form:

```text
CONTEXT   What I am doing, in which file or phase, and why this question came up.
DECISION  The single thing I need decided.
OPTIONS   2-3 options. For each: what changes, stability, performance/memory, complexity.
RECOMMEND My pick and the reason.
DEFAULT   What I will do if there is no answer.
```

If nobody is available to answer, take the recommended option, say so at the top of your report, and continue with anything that does not depend on it.

## Edge cases

Think about edge cases before writing the code and handle them in the code. The checklist is in `CODE_STYLE.md`. Do not write edge cases into comments or files. Put them in your final report: which ones you handled and how, and which ones you deliberately left unhandled and why.

## Architecture invariants

These hold after every change. `make validate` enforces what it can.

1. A package's identity is `name` in `package.lua`, never its path. Modules are required as `require "<package>.<module>"`.
2. `package.lua` is pure data: no `require`, no functions, no globals.
3. A package may use another package only if it is in `depends`, and only through that package's root module. Its submodules are private.
4. Optional cooperation between two packages lives in the owner's `with/` files (or a `glue` package for third parties), never in a hard `require` and never in `pcall(require, ...)`.
5. No package is mandatory. Nothing in `package.lua` marks a package as essential. "Shipped by default" is decided only by a bundle.
6. The kernel imports nothing from `packages/`. Packages import nothing from `cdinx/` except its documented public API.
7. Everything a package registers in `init` (commands, keys, providers, panels, menus, pills, help shortcuts, document hooks, threads) is released in `unload`, symmetrically, so an enable/disable cycle never doubles anything.
8. Requiring a module has no side effects. Registration happens in `init`.
9. A package that fails to load is disabled with a reason; the editor and every other package keep working.
10. Startup touches only enabled packages. Full catalog scans happen on demand, in a yielding coroutine, and are cached.
11. An installed package contains only its selected runtime files (`files`/`ignore` in `package.lua`): no `.git`, tests, docs, examples or CI files. Builds apply the same selection.
12. A package name must not collide with a module the host or Lua already provides (`core`, `cdinx`, `fs`, `path`, `system`, `renderer`, and the Lua standard library names).

## Git

- Do not commit, push or tag unless asked. When asked, use conventional commits: `feat(scope): ...`, `fix(scope): ...`, imperative, under 72 characters. One topic per commit. Branches: `fix/*` or `feature/*`.
- Rename and move files in their own step with no content change, so history follows them.
- Never run destructive commands (`reset --hard`, `clean -fd`, force push, deleting directories) without asking.
- Leave unrelated working-tree changes alone.

## Working method

1. Read the relevant code first. Do not infer behaviour from file names.
2. Make a short task list. Keep the last item as verification.
3. Change one concern at a time; keep `make validate` green between steps.
4. Verify with what exists: `make validate`, a syntax check of every Lua file you touched (`luac -p`), `luacheck`/LuaLS if installed, a before/after diff of bundle output where applicable.
5. Report using the format below.

## Final report

Keep it short and factual.

```text
DONE        What changed, by concern (not file by file).
DECISIONS   Choices you made and the stability/performance reason.
EDGE CASES  Handled: <case> -> <how>. Not handled: <case> -> <why>.
VERIFIED    Commands run and their result.
CDIN SIDE   Changes the cdin repository will need (owner applies them), or "none".
BROKEN      Cross-repo invariants you had to break, and why.
OPEN        Questions that still need an answer, in the ask format.
NEXT        The next step, if there is a natural one.
```