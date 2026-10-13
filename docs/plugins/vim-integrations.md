# What vim is wired to

`vim` knows how to edit. It does not know what a tab is, or a file tree, or a
repository, or a menu. Seven **`with` entries** fill that gap, and each one is
part of `vim` rather than a separate installable — it exists only while both
packages are loaded, and disappears when either one goes.

```lua
-- packages/editing/vim/package.lua
with = {
  git       = "with/git.lua",
  menu      = { "with/menus.lua", "with/plugin-manager.lua" },
  search    = "with/search.lua",
  treeview  = "with/treeview.lua",
  workspace = { "with/tab.lua", "with/window.lua" },
},
```

Note what the keys are: **`git`, `menu`, `search`, `treeview`, `workspace`**. They
are package names, never names for the seam. `menu` appears once carrying two
paths, because two seams waiting on one package is a list under that one key —
not `menus` and `plugin-manager` as keys of their own.

## The table

| needs | you get |
| --- | --- |
| `menu` | <kbd>m</kbd> — the Files / Navigate / Build / Shell menu |
| `workspace` | <kbd>Ctrl</kbd>+<kbd>W</kbd> and <kbd>Tab</kbd>, `:split` and friends |
| `workspace` | <kbd>g</kbd><kbd>t</kbd>, <kbd>g</kbd><kbd>T</kbd>, `:tabnew` and friends |
| `search` | <kbd>/</kbd> <kbd>n</kbd> <kbd>N</kbd> <kbd>*</kbd> |
| `treeview` | `:tree`, `:trees` |
| `git` | git commands, and the Git section in the menu |
| `menu` | <kbd>M</kbd> — the extension manager |

`menu` is the only partner twice, because the menu is a *thing* that vim extends in
two different ways: the whole thing (`<kbd>m</kbd>`), and the manager inside it
(`<kbd>M</kbd>` plus the CDIN-X section).

## The important one: what happens when a partner is missing

**Nothing breaks.** This is the property the whole arrangement exists for, and it
is worth testing once, on a package you do not care about.

Uninstall `workspace`, or switch its `tab` feature off, and <kbd>g</kbd><kbd>t</kbd>
does nothing — because the `with/tab.lua` entry is what registered it, and that
entry was never built. The tab commands keep working: you still have
<kbd>Ctrl</kbd>+<kbd>T</kbd> and <kbd>Ctrl</kbd>+<kbd>Tab</kbd>. `:tabnew`
disappears from `:help`, because `:help` lists what is registered right now.

Contrast that with the alternative, which is what vim mode would look like if it
owned its own keys: remove `workspace` and `:tabnew` is still there, typed into
your muscle memory, silently doing nothing. You would spend an afternoon on that.

**A `with` entry can also be torn down while both packages stay loaded** — when a
*feature* goes. `workspace`'s `tab` and `window` are features; the entry watches
for the partner and comes down when the feature under it stops being there.

## Details

### on `menu`

<kbd>m</kbd>, and `vim-fmenu:open` / `vim-menu:open` if you want a different key.
Sections: **Files**, **Navigate**, **Build**, **Shell**. See [menu](menu.md).

The Git and CDIN-X sections come from the `git` and `menu`+`plugin-manager`
entries, not from this one. That is visible in a good way: with `git` not
installed, the menu opens and simply has fewer sections.

`with/menus.lua` takes the menu registry as an **argument** rather than requiring
it. That is the one thing a `with` file must not do — see below.

`with/plugin-manager.lua` exists because the manager is a *section of the menu*,
not a menu. It guards the menu registry with a `pcall` and checks
`registry.menus["vim.main"]` is actually there, because it can be raised while the
rest of this entry is still being built.

### on `workspace`

Two entries, differing only in which half of `workspace` they reach: `with/tab.lua`
for the `tab` feature, `with/window.lua` for the `window` feature.

**window**: <kbd>Ctrl</kbd>+<kbd>W</kbd> then a character, exactly as in vim —
<kbd>v</kbd>, <kbd>s</kbd>, <kbd>o</kbd>, <kbd>c</kbd>, <kbd>n</kbd>, <kbd>p</kbd>,
<kbd>h</kbd> <kbd>j</kbd> <kbd>k</kbd> <kbd>l</kbd>, <kbd>=</kbd>, <kbd>&gt;</kbd>,
<kbd>&lt;</kbd>. Also <kbd>Tab</kbd> for the next pane, and `:split` / `:vsplit` /
`:vnew` / `:close` / `:only` from the `:` line.

<kbd>Tab</kbd> is the one that is not vim — it is what <kbd>Tab</kbd> does in
every other editor. It is consulted only after vim's own keys decline, so it
cannot shadow one.

**tab**: <kbd>g</kbd><kbd>t</kbd> and <kbd>g</kbd><kbd>T</kbd>, with a count in
front (<kbd>3</kbd><kbd>g</kbd><kbd>t</kbd>). From the line: `:tabnew` `:tabe`
`:tabedit` `:tabclose` `:tabc` `:tabonly` `:tabo` `:tabnext` `:tabn`
`:tabprevious` `:tabp` `:tabfirst` `:tabr` `:tablast` `:tabmove` `:tabm`.

`:tabnew` and `:tabedit` take an optional path, and the `:` line offers path
completion for them.

### on `search`

<kbd>/</kbd> to search, <kbd>n</kbd> to repeat, <kbd>N</kbd> to repeat backwards,
<kbd>*</kbd> for the word under the cursor.

<kbd>*</kbd> with no word under the cursor deliberately does nothing rather than
opening an empty search — a key that opens a prompt you have to dismiss is worse
than a key that does nothing.

The menu section is **guarded rather than required**. The entry used to declare a
dependency on the `menu` package, which meant a user who installed the search
bindings without menus got nothing at all: the keys worked but the whole thing was
refused. Now the keys always go up and the menu section is a `pcall`.

### on `treeview`

`:tree` and `:trees`, and that is not the whole entry. It also subscribes to vim's
`cwd_changed` event so `:cd` refreshes the tree, contributes the menu's only
**context provider** (priority 200, which is why the menu title shows the tree's
state), and adds the **Tree** menu section — focus, refresh, toggle hidden, reveal
— at order 20, ahead of everything else.

It registers no vim keys at all. The arrows and <kbd>Enter</kbd> you use inside the
tree belong to [`treeview`](treeview.md), and they work in vim mode for a
structural reason: when the tree has focus, vim mode is not the thing handling your
keystrokes. Nothing here decides that; it falls out of which handler is live.

### on `git`

`vim-git:status`, `:log`, `:diff`, `:add-all`, and the `vim-shell:git-status` /
`git-log` / `git-diff` aliases. All output to the scratch buffer, the same one
`:!make` writes to.

It also adds the **Git** section to the menu — Status, Log, Diff, Add All, Commit,
Push, Pull, Branches — and Commit asks for a message first, because `git commit`
with no `-m` would sit in the buffer waiting for input that cannot reach it.

## The one rule that is not optional

**A `with` entry must not `require` its own partner.**

`with/menus.lua` opens `require("menu.impl").open("vim.main")` **at the moment the
entry runs**. If it did that at the top of the file it would need `menu` to be
already loaded — which it is, by construction, but only because the kernel runs
entries after both packages have initialised. Making that a `require` at file
scope would turn a guaranteed ordering into a circular one.

So the menu registry is passed **in as an argument**:

```lua
-- with/menus/menu.lua
function M.extend(registry, vim)     -- not require("menu.impl")
```

This is the one place in the architecture where a module is handed its
collaborator instead of looking it up. It is also why `vim.main` is defined in
`vim/init.lua` rather than inside `with/menus.lua` — `menu.extend` and
`set_context_provider` both **assert** the menu exists, so the menu has to be
defined before anything can extend it, and `init.lua` is the only place that
guarantees running first.

## Why these are entries and not packages

Because `vim` may not depend on another package, and all seven of these need two:
`vim`, and the capability they wire.

`with/search.lua` is the clearest illustration. It reaches `vim` and `search`, and
it is the only file in the repository that mentions both. Remove it and `search`
still works, `vim` still works, and neither has a hole where the entry was. Keep
it and `/` works.

If `/` were implemented inside vim's own `init.lua`, then the day you decided to
ship cdin without vim mode, search would either break or grow a second code path
that nobody tests.

**Nothing here declares a dependency on any of them.** `optional_dependencies`
would say "load it if it happens to be installed", which is a different thing: vim
does not need git, and a missing git must not appear anywhere in the load.

## How they register

Every entry goes through `vim.registry`, which has seven seams:

| seam | used by |
| --- | --- |
| `register_command(spec)` | on `workspace`, on `treeview`, on `git` |
| `register_key(map)` | on `menu`, on `search`, on `workspace`, on `menu` (the manager) |
| `register_gmap(map)` | on `workspace` (`gt`, `gT`) |
| `register_wmap(map)` | on `workspace` — the <kbd>Ctrl</kbd>+<kbd>W</kbd> characters, and `:wincmd` |
| `register_visual_key(map)` | nothing yet |
| `register_action(id, fn)` | nothing yet |
| `on(event, fn)` | one event exists: `cwd_changed`, emitted by `:cd` and used on `treeview` |

[docs/extending-vim.md](../extending-vim.md) has the details and a worked example.

Two seams have no user. That is fine and is recorded rather than removed: a seam
with no user yet is a promise the registry makes to its own future, and it costs
five lines. The one that would be a defect is a seam with no *shape* — an argument
list nothing calls with, or a return value nothing reads.

See [building a with entry](../building/a-with-entry.md) for the mechanism.