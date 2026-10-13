# Writing a package

A package is a directory with a `package.lua` and an `init.lua` in it, or a
single `.lua` file. The editor hands the entry point two arguments and then gets
out of the way.

That's the whole contract. Everything below is either that contract, or a rule
this repository enforces on the packages it ships, with the reason it enforces
it.

## Where yours lives

Not here.

This repository is the catalog. Your package is yours, in your own directory,
anywhere on disk — and **Install Local** in the manager installs it from that
path into your package store. That's the whole workflow: edit in your checkout,
re-install, see the change.

You only add a package *here* if you want it in the catalog for other people,
which is a different job with a different bar (see
[CONTRIBUTING.md](../CONTRIBUTING.md)).

## The smallest one that does something

```text
hello/
  package.lua      the manifest. data only.
  init.lua         init() and unload(), and nothing else
  commands.lua
  keymap.lua
```

```lua
-- hello/package.lua
return {
  name        = "hello",
  kind        = "plugin",
  version     = "0.1.0",
  description = "Says hello, to show the shape of a package",
  authors     = { "you" },
  license     = "MIT",
  category    = "core",
  min_cdin_version = "0.5.0",
  entry       = "init.lua",
}
```

```lua
-- hello/init.lua
local M = {}

local loaded = false

function M.init(core, config)
  if loaded then return end
  loaded = true

  require("hello.commands").register()
  require("hello.keymap").register()
end

function M.unload()
  if not loaded then return end
  require("hello.keymap").unregister()
  require("hello.commands").unregister()
  loaded = false
end

return M
```

```lua
-- hello/commands.lua
local M = {}
local command = require "core.input.command"

function M.register()
  command.add(nil, {
    ["hello:say"] = function()
      require("core").log("hello")
    end,
  })
end

function M.unregister()
  command.remove(nil, { ["hello:say"] = true })
end

return M
```

```lua
-- hello/keymap.lua
local M = {}
local keymap = require "core.input.keymap"

-- Hoisted, because removal compares by identity.
local KEYS = { ["ctrl+alt+h"] = "hello:say" }

function M.register()
  keymap.add(KEYS)
end

function M.unregister()
  keymap.remove(KEYS)
end

return M
```

Save that, point **Install Local** at the directory, and
<kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>H</kbd> does the thing. No build, no restart.

## The manifest is `package.lua`, and it is data

`package.lua` returns a table and **nothing else** — no `require` at its top
level, no function, no logic. The fields are validated against a schema before
anything is loaded:

| field | required | |
| --- | --- | --- |
| `name` | yes | your directory name, spelled the same |
| `kind` | yes | `"plugin"`, `"theme"`, or `"lang"` |
| `version` | yes | `x.y.z` |
| `description` | yes | one line; the panel shows it |
| `authors`, `license`, `tags` | | list, string, list |
| `category` | | `"core"` or another label |
| `min_cdin_version` | | a host older than this refuses the package |
| `entry` | | defaults to `init.lua` |
| `options` | | declared, defaulting settings — read from `opts` |
| `features` | | switchable parts — see [a feature](building/a-feature.md) |
| `with` | | wiring to other packages — see [a with entry](building/a-with-entry.md) |
| `depends` | | packages that must be present, and are loaded first |
| `optional_dependencies` | | loaded if present, absent if not, with no complaint |

**A single `.lua` file is still a package.** It has no directory, so it has no
`package.lua`, and its manifest is the table the file returns. That path exists
for a one-file package and nothing else; a package with commands and keys wants a
directory, because that is what makes the removals have something to match.

## Nothing is required at the top of `init.lua`

This is the rule people hit first, so it is worth saying why.

The catalog has to know a package's name and dependencies *before* it decides
what order to load things in, and `package.lua` is a separate file precisely so
that it can read it without executing the package. A `require` at module scope of
the entry point would run the whole subtree — every registration, every side
effect — purely so the catalog could look up a name.

```lua
-- no
local command = require "core.input.command"
command.add(nil, { ["x"] = f })

-- yes
function M.init(core, config)
  require("x.commands").register()
end
```

## `init()` may be called twice

The guard is not decoration. A package `dofile`d as its entry point and then
`require`d by a `with` entry is **two module instances with two independent
guards** — the second one sees `loaded == false` and does all the work again. The
result is two copies of every command, and a key binding that fights itself.

```lua
local loaded = false

function M.init(core, config)
  if loaded then return end
  loaded = true
  -- ...
end
```

## `unload()` has to undo all of it

Every command removed, every key binding removed, every menu section removed. A
package that leaves a key behind will fight the next thing to bind that key, and
one that reloads accumulates one copy of its registrations per load.

**Removals compare by identity.** `command.remove`, `keymap.remove` and
`registry.unregister_key` match the table or function you hand them against what
was registered. So the table has to be *the same table* — hoisted to a local above
both functions, as in `keymap.lua` above.

Building it inside each function is a removal that matches nothing, and it is
silently the most common bug there is: nothing errors, and the key simply never
goes away.

For help entries, keep the handle and hand it back:

```lua
function M.init(core, config)
  M.help = core.register_help_shortcuts { { key = "ctrl+alt+h", desc = "Say hello" } }
end

function M.unload()
  core.unregister_help_shortcuts(M.help)
  M.help = nil
end
```

## Where things live, and what may depend on what

If your package is going into this repository, it goes under one of these roots,
and each is a rule rather than a label:

| directory | holds |
| --- | --- |
| `packages/<domain>/<name>/` | everything, including the packages a bundle names |
| `packages/languages/lang-<language>/` | language definitions, one package each |
| `packages/system/themes/themes/<name>/theme.lua` | themes, beside the package that ships them |

There is no `X/` any more, and with it no `X/integration/` and no `X/optional/`.
Wiring between two packages is a `with` entry *inside one of them*; everything
else is in `packages/`, and a package's `category` field is the label.

The rule that makes the catalog checkable: **a package may not depend on another
package.** Not may not *prefer* to — may not, at all.

The alternative is a package that works right up until somebody uninstalls the
other one, and a catalog you can't reason about. If two packages genuinely need
to know about each other, that knowledge goes in a **`with` entry**, which is the
only thing allowed to reach across. `make validate` enforces all of it.

## What ships is a bundle, not a flag

Nothing in a manifest says "ship me by default". A **bundle** does, and it is a
list:

```lua
-- bundles/standard.lua
return { "vim", "themes" }
```

There are three: `standard` (vim and themes), `minimal`, and `empty` — which also
brings no fonts. A cdin build asks for one by name, and the closure is computed
for it: the listed packages, their `depends`, and nothing more.

There used to be a per-package `essential = true` flag, and it is gone. It was
three answers to one question, and the three disagreed — the flag said what
*bundles* ship, `category` said what was *core*, and the bundler counted the
flags and complained if the count was not what it expected.

**A package is not required to be self-contained.** That rule existed only
because an essential package was copied *alone*; a bundle is a closure, so
`manager` can live in `cdinx/` and ship beside vim without declaring anything.

## Themes

```text
<package>/themes/<name>/theme.lua
```

One file, a table of colors, and that's the layout cdin's theme registry reads —
so a theme directory can be handed to `core.themes.add_root()` as-is. The manager
installs themes but never loads them; the host's registry does.

A `theme` **package** is one `<name>/theme.lua` whose own name starts with
`theme-`. A *container* of themes is a `plugin`, which is what
[`themes`](plugins/themes.md) is — and pretending otherwise would make the
schema demand a prefix that says nothing true.

## Commands and keys, in one place each

Commands are registered by name with an optional predicate:

```lua
command.add(nil, { ["hello:say"] = run })                  -- always
command.add("core.views.docview", { ["hello:word"] = run }) -- only in a doc
```

`nil` for the predicate means always. The string form is the command's own
context, so `core.views.docview` is how you say *in a document view*.

Keys map keystrokes to command names, and never to functions:

```lua
keymap.add { ["ctrl+alt+h"] = "hello:say" }
```

Binding a name rather than a function is what lets
<kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>P</kbd> find and run your command without
knowing that it exists.

**A stroke is spelled, not described.** The editor builds the string it looks up
— every modifier held, in the order `ctrl`, `alt`, `altgr`, `shift`, then the
key's own name — and matches that string for equality, with no normalisation,
aliases or case folding. So the modifiers have to be written in that order:
`ctrl+alt+shift+n`, not `ctrl+shift+alt+n`, and a key is one name, lowercase,
with no `+` inside it. A stroke spelled any other way is not a near miss, it is a
string no key press produces — a binding that can never fire and says nothing when
it does not. `["ctrl+shift+alt+n"]` shipped in treeview that way. The host now
reports every such stroke in the log at boot, and `make validate` fails on one
before it ships.

**Commands and keys are never renamed.** Two packages changed their names when
they gained a `package.lua` — `autocomplete` → `complete`, `autoupdate` →
`update` — and their commands are still `autocomplete:complete` and
`autoupdate:check`. A command name is a string in somebody's `init.lua` and in
their keymap; renaming it breaks working configuration for no benefit. Package
identity is yours to change. Commands are not.

## What `make validate` will tell you

It's the gate, and every rule it enforces is a failure mode that's invisible
until much later:

- a required file missing, or a manifest field missing or misspelled
- `name` not matching the directory, or a `theme` package not named `theme-*`
- a bundle naming a package that does not exist, or reaching outside its closure
- `fonts/` missing or empty, for any bundle but `empty`
- a `require` that crosses a package boundary without a `with` entry behind it
- a `with` entry that reaches a package its own manifest key did not name
- a feature or `with` file with no `enable`/`disable`, or a `features` key with
  no file at `features/<key>.lua`
- a `register` without a matching `unregister`
- an `EXEDIR` reference, or the old `core.x` namespace, anywhere in `cdinx/` or
  `packages/`
- a keystroke no key press can produce - wrong modifier order, an uppercase key, a
  `+` inside the key, or a modifier the input layer does not report
- a language package whose `kind` is not `lang`, or whose name is not `lang-*`
- a workflow file whose `needs:`, `uses:` or `with:` names something that is not
  there, or a job the `required` gate does not list
- and finally it **runs the real bundler for every bundle** and
  compares, so the thing a cdin build consumes is checked rather than assumed

```sh
make validate
```

## Working on one without installing it

`make link` (or `make link SITE=/path`) symlinks this checkout into your site
directory, so a change to a package here is a restart away rather than an
install. That's the reason `make link` exists as a separate target from
`make install`, and the reason to use it while you're still moving things around.

## Working examples

Three, in [`examples/`](../examples), each small enough to read in one sitting:

| example | shows |
| --- | --- |
| [`01-hello`](../examples/01-hello) | the minimum: one command, one key, a clean unload |
| [`02-word-count`](../examples/02-word-count) | reading a document, a view that owns the status line |
| [`03-vim-word-count`](../examples/03-vim-word-count) | extending vim mode through its registry, from a `with` entry |

## What cdin guarantees

The loader, the command and key registries, the theme registry, and
`core.command_view` are cdin's half of this, and they have their own document:
[the extension contract](https://github.com/m-mdy-m/cdin/blob/main/docs/architecture/extension-contract.md).
Read it before you rely on anything not listed there — in particular, there is
no hook or event system, so extending something means wrapping the function
and calling the original.