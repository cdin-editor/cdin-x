# Building a with entry

A `with` entry connects two **packages** that must not know about each other. It
is the thinnest thing in the architecture — most are one file — and it is the one
place where the catalog's central rule actually applies. So this page is short on
mechanics and long on the two decisions: which relationships deserve an entry, and
what the manifest has to say.

## When you need one

> package A has something package B needs, and a direct dependency between them
> would be wrong.

That last clause is doing the work. Sometimes A genuinely cannot work without B,
and then the honest answer is that A and B are one package. Reach for a `with`
entry when the coupling is *about use*, not about existence.

**A real one.** `search` can find text. `vim` can run a normal-mode key. Neither
depends on the other — a search is useful without vim, and vim is useful without a
search package. But <kbd>/</kbd> and <kbd>n</kbd> are what a vim user expects, and
they only make sense if someone maps them onto search. `with/search.lua` is that
mapping, and it is one file.

**Not a real one.** `treeview` cannot show a file list without reading the
filesystem. That is a dependency on the *runtime*, not on a package, and it
belongs in `treeview`. An entry there would be a file that forwards to another
file, which is worse than no file.

**Also not a real one.** Two commands in your own package that both use a shared
helper. That is a third module inside your package, not a new directory.

## The shape

A `with` entry is a file, or a small directory, **inside the package that owns
it**. There is no separate integration root any more — that was
`X/integration/`, and it is gone.

```text
<package>/
  package.lua         declares `with`
  with/
    <name>.lua        one entry
    <name>/           an entry with enough wiring to be worth a directory
      *.lua
```

The payload lives in `<package>/with/<key>/` when there is more than one file; a
single file entry is `<package>/with/<name>.lua`.

## The manifest

```lua
-- packages/navigation/search/package.lua
with = {
  vim = "with/vim.lua",
},
```

**The key is always a package name, never a name for the seam.** That is not
stylistic. It is what lets the validator check what an entry is allowed to reach:
`scripts/validate.lua` builds a prefix map from the manifest and fails the build if
a file under `with/` requires something outside the one package its own key named.
A seam named `vim-search` could reach `vim` and `search` and the check could not
tell which was which.

**A partner may carry a list of paths**, because two seams can wait on one package:

```lua
-- packages/editing/vim/package.lua
with = {
  git       = "with/git.lua",
  menu      = { "with/menus.lua", "with/plugin-manager.lua" },
  workspace = { "with/tab.lua", "with/window.lua" },
},
```

This is what replaced the old dependency-on-an-integration trap: `vim-main-menu`
used to have to declare a dependency on `vim-menu` purely so that `vim.main`
would exist before it extended it. That trap cannot be fallen into now, because
`vim/init.lua` defines `vim.main` and init always runs first.

**There is no self-reference.** `with[<own name>]` is an error the checker
reports, not something that happens to work.

## A complete one

Here is a working entry, start to finish. It makes search reachable from vim mode —
the same shape as the real one, and small enough to hold in your head.

### 1. The manifest

```lua
return {
  name = "search",
  kind = "plugin",
  version = "0.1.0",
  description = "Find, replace, and search across the project",
  category = "core",
  min_cdin_version = "0.5.0",

  with = {
    vim = "with/vim.lua",
  },

  entry = "init.lua",
}
```

**Nothing else is declared.** In particular there is no `dependencies` and no
`optional_dependencies`. A `with` entry is by definition only ever run when its
partner is already up, so declaring that the partner is required would be asking
the loader to guarantee something it has already guaranteed — and declaring it
*optional* would say "load it if it happens to be installed", which is a different
claim, and one that would make a missing partner look like a missing feature.

### 2. The file

```lua
-- packages/navigation/search/with/vim.lua
local keymap = require "core.input.keymap"

local M = {}

-- Hoisted, because removal compares by identity: a table built fresh at removal
-- time matches nothing and the keys survive the partner being switched off.
local MAP = {
  ["/"] = function(view) require("search.api").prompt(view) end,
  ["n"] = function(view) require("search.api").repeat_last(view) end,
  ["N"] = function(view) require("search.api").repeat_last(view, true) end,
}

function M.enable()
  require("vim.registry").register_key(MAP)
end

function M.disable()
  require("vim.registry").unregister_key(MAP)
end

return M
```

### 3. What the kernel does with it

`cdinx/manager/with.lua` holds four pieces of state per entry:

| | |
| --- | --- |
| `declared(spec)` | reads the manifest; records which partners the package is waiting on |
| `apply(name)` | a partner arrived: run every entry this package declared against it |
| `partner_arrived` / `partner_left` | the same, from the other direction |
| `active` | the table of entries currently up, **keyed by path** |

The active table is keyed by **path**, not by seam name. That is deliberate: two
seams can share one partner, so `vim`'s `menu` key carrying two paths must be able
to say "`with/menus.lua` is up" and "`with/plugin-manager.lua` is up" independently.
Keyed by seam name, the second one to arrive would overwrite the first and one
would be silently lost.

Both `enable` and `disable` are required. `disable_all` and `partner_left` call
`disable` and have nothing else to fall back on — `scripts/check.lua` R8 fails a
package whose `with` files do not define both.

## The one rule that is not optional

**A `with` entry must not `require` its own partner.**

The real `with/menus.lua` opens `require("menu.impl").open("vim.main")` *at the
moment the entry runs*. If it did that at file scope it would need `menu` loaded
before the kernel had loaded it — turning a guaranteed ordering into a circular
one.

So the collaborator is passed **in as an argument**:

```lua
-- packages/editing/vim/with/menus/menu.lua
function M.extend(registry, vim)     -- not require("menu.impl")
  ...
end
```

This is the one place in the architecture where a module is handed its
collaborator instead of looking it up, and it is worth understanding rather than
copying. Everything else may `require` freely; this may not, because everything
else is inside one package and this is the join.

## The old failure mode, for reference

If you are reading a pre-`package.lua` guide or an old `init.lua` that says:

```lua
dependencies = { "vim", "menu", "vim-menu" }
```

that was the rule: if your integration extends a menu, declare the integration
that **defines** that menu, not just the capability. Declaring only `menu` gives

```
menu is not defined: vim.main
```

…on some runs and not others, because the catalog is scanned with `pairs()` and
load order is not stable.

**There is no version of that mistake any more.** A `with` entry extends a
*package's* surface and is only ever built after that package is up, and the
thing that gets extended (`vim.main`) is defined by that package's own `init.lua`
rather than by a sibling entry. The dependency dance existed to order two
extensions against each other; `with` does not have extensions that order against
each other.

## What a `with` entry may not declare

| | |
| --- | --- |
| its own package as a key | R8: "a with entry is between two packages" |
| `dependencies` | the partner is implied by being up |
| `optional_dependencies` | that means "load it if installed", which is a different mechanism |
| a `features` block | features are parts of *one* package; entries are between two |
| a `min_cdin_version` of its own | the package's own field covers the whole directory |

## See also

- [extending vim](../extending-vim.md) — the seven seams an entry registers through.
- [what vim is wired to](../plugins/vim-integrations.md) — the seven real entries.
- [building a feature](a-feature.md) — the other kind of optional part, and the
  difference.
- [writing a plugin](../writing-a-plugin.md) — the whole shape, before any of this.