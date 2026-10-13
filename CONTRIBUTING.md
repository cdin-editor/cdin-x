# Contributing to cdin-x

## Start here

```sh
make validate
```

On a clean checkout, before anything else. It is the gate CI runs, and it is
fast enough to run on every save.

When it fails, read the failure as a rule rather than a typo. Nearly every rule
below exists because of a specific failure that was hard enough to find twice.

## Adding a package

```sh
lua scripts/new-plugin.lua <name> [editing|navigation|system|vcs]
lua scripts/new-plugin.lua <name> themes      # a theme
lua scripts/new-plugin.lua <name> syntax      # a language definition
```

It refuses to write anything if the files already exist, which matters more than
it sounds: `new-plugin.lua lua syntax` would otherwise overwrite the real
`packages/languages/lua/`.

The domain you pick is a decision, not a formality. `editing`, `navigation`,
`system` and `vcs` are the four there are, and a package's `category` field is
the domain - it is not a free-form label and it is not the package's own name.
The README of the domain directory you picked into is where that is written down
for that domain.

Then read [docs/writing-a-plugin.md](docs/writing-a-plugin.md), and copy
whichever of the [examples/](examples/) is closest to what you want. The parts
that are not obvious:

**The manifest is `package.lua`, and it is data.** No `require` at its top level,
no function, no logic. The catalog has to read your name and dependencies
*before* it decides load order, and a separate file is the only way to do that
without executing you.

**Nothing is required at the top of `init.lua`.** A top-level `require` would run
your whole subtree's side effects just to load the package. Requires go inside
`init()`.

**`init(core, config)` takes two arguments, positionally.** The runtime calls
`mod.init(core, config)`, so `function M.init()` works and
`function M.init(config)` compiles and then reads the core table as your config.
This one is worth checking by eye rather than by testing.

**`init()` must tolerate being called twice.** A package `dofile`d once as its
entry point and `require`d once by a `with` entry is two module instances with
two independent guards, and without a guard both of them do the work.

**`unload()` undoes everything `init()` did.** Commands, key bindings, menu
sections, status pills, help entries. Keep the handle
`core.register_help_shortcuts` returns and hand it back.

**Removals compare by identity.** `command.remove`, `keymap.remove` and
`registry.unregister_key` match the table you hand them against what was
registered, so the table has to be hoisted to a local above both the `add` and
the `remove`. One built fresh at removal time matches nothing, and it is silent.

## The rules, and what each one is for

1. **A package may not require another package.** Not may not *prefer* to — may
   not, at all. The one thing allowed to reach across is a **`with` entry**
   inside one of the two, and `validate` checks that a `with` file reaches only
   the package its own manifest key named. That is why the key is a package name
   and never a name for the seam: a key called `vim-search` could reach `vim`
   and `search`, and the check could not tell which was which.

2. **Every declared dependency exists in the tree.** A typo in a dependency
   name is otherwise a silent no-op: the sort is given a name nothing provides,
   and nothing complains.

3. **A bundle names packages, and the closure is checked.** `bundles/standard.lua`
   lists `vim` and `themes`; the closure adds their `depends` and stops. A
   bundle that reaches a package it did not name is a build carrying something
   nobody asked for, and `validate` runs the real bundler for all three so that
   is a failure rather than a surprise.

4. **Nothing under `cdinx/` or `packages/` mentions `EXEDIR` or
   `core.x`.** cdin-x does not know where the editor is installed, and there is
   no sibling checkout. `config.site_path()` is the whole of what it knows about
   paths, and it is the host's own resolver rather than one computed here.

5. **`init()` and `unload()` are symmetric**, and a `register()` a package calls
   exists on the module it calls it on.

   Rule 5 is here because a missing `register()` is the one failure that looks
   like success. The manager's `pcall` catches the raise, but by then the
   package has already been reported as loading, and the
   `attempt to call a nil value` is one line among forty in a log nobody opens.
   Three packages sat broken that way for long enough to be written down as
   known issues.

6. **A feature or a `with` file defines both `enable` and `disable`.** Not a
   preference: `disable_all` and `partner_left` call `disable` and have nothing
   else to fall back on. And `scripts/check.lua` R8 requires both *and* requires
   a `features` key to have a file at exactly `features/<key>.lua`.

## Do not depend on load order

**A `with` entry is the mechanism now**, and it removes most of this problem
rather than documenting it: an entry is only ever built *after* its partner is
already up, so there is no ordering to get right.

What is left is the case that `with` does not cover, which is a genuine
ordering inside one package: features are enabled in the order the manifest
lists them, and a feature may need another of its own package. `workspace`'s
`tab-session` needs `session`, so `session` is listed first. That is the whole
rule, and it is a fact about *one* package rather than a coin flip across two.

There is also `menu.extend(name, …)`, which *asserts* the menu exists — and
that assert is now safe, because the thing it extends (`vim.main`) is defined by
`vim/init.lua`, which is guaranteed to run before any `with` entry is built.
There is no `menu is not defined: vim.main` on some runs and not others any more.

## What not to do
**Do not add a package to a build to make it required.** "Ships by default" is
decided by `bundles/*.lua` and by nothing else. There used to be a per-package
`essential = true` flag, and it carried a second constraint — *the package is
copied alone, so it must be self-contained* — which was a real rule with a real
failure mode, and it is gone with the flag. A bundle is a closure now, so
`manager` can live in `cdinx/` and ship beside vim without declaring anything.
If a package is generally useful, the user installs it.

**Do not reach into the editor's tree.** `config.site_path()` is the whole of
what cdin-x knows about where things are. No `EXEDIR`, no sibling checkout, no
guessing where cdin was installed from. Validate will fail, and rightly.

**Transport is git, and it never blocks a frame.** The registry is a persistent
sparse clone of this repository (`cdinx/manager/registry.lua`), and installing a
third-party package clones its own repository (`cdinx/manager/git.lua`,
`transport.lua`). Every git command is a detached job polled from a
`core.add_thread` coroutine, so a slow network cannot freeze the editor. What
git *cannot* do must still work: packages a build ships need no git at all, and
`doctor` reports a missing one with one line on how to fix it.
`Manager.set_registry_syncer` survives only as a deprecation shim that logs once;
the HTTPS-download path it selected between is gone.

**Do not reformat files you are not changing.** The tree is LF, with five
deliberate exceptions: `cdinx/manager/init.lua`, `cdinx/command.lua` and
`scripts/validate.lua`, which are CRLF because of how they were written and
re-wrapping them would churn every line; and `AGENTS.md` and `CODE_STYLE.md`,
which have been CRLF since long before this file said anything about line
endings. The fonts are binary, and binary is not text and is not a line ending
at all.

Nothing enforces this, which is worth knowing: the pre-commit hook runs
`make validate` and nothing else, and `validate.lua` has no line-ending check.
So a mass reformat is caught by review, or not at all. A reformat turns a
three-line diff into a review nobody can do, which is the real cost — and it is
also why a reviewer who spots one should say so rather than approving it.

If you want the tree to stop depending on that, a `mixed-line-ending` check in
`validate.lua` is a small addition and would belong there rather than in a hook.

## Style

`snake_case` throughout.

Comments explain *why*, and say what breaks if the line changes. A comment
restating the line above it is noise. When a comment is long enough to need its
own paragraph, it has usually discovered that the code needed a different shape.

A file opens with a comment saying what it is and **what it refuses to do**. The
conventions here are worth matching, and not only in the code: the next person
deciding whether `packages/editing/vim` may require something else should find the answer
at the top of the file.

Keep functions short. A four-hundred-line function is a sign the file is doing
two things.

## Adding a theme

```sh
lua scripts/new-plugin.lua <name> themes
```

`packages/system/themes/themes/<name>/theme.lua`, copied from `nord`'s key set.
Nothing in a theme file decides whether it ships — a bundle names the `themes`
package, not the themes inside it. Run `make index` afterwards; the catalog is
generated.

## Before you open the pull request

1. `make validate`
2. `make index`, and commit `registry/generated/catalog.lua` if it changed
3. `lua scripts/plugin-list.lua` — check the entry reads the way you meant
4. A `README.md` for the package: what it is, what keys it takes, what it needs
   from the host. Two or three sentences is plenty; a directory README is an
   introduction, not a manual.
5. `CHANGELOG.md` under `[Unreleased]`, if it is a change a user would notice.

## Reporting a bug

`validate`'s output first, then `make list` so we are looking at the same
catalog you are. If the problem is a package failing at load, the reason is in
cdin's log — `core:open-log`, or <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>L</kbd> —
and that is usually the whole answer.