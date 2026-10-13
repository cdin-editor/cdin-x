# Extending vim mode

Vim mode is one of the two packages a cdin build cannot start without, so it is
in every bundle rather than installed beside everything else. That has a
consequence worth stating plainly: **vim core cannot know what tabs are.**

It cannot know about the file tree, or search, or git, or the manager, or any of
the other capabilities cdin has. If vim mode grew a `:tabnew` of its own, then
removing the tab package would leave a `:tabnew` that quietly did nothing — which
is the exact failure this arrangement exists to make impossible.

So vim mode offers seams, and what fills them is **seven `with` entries** inside
`vim` itself. Everything below goes through one module: `vim.registry`.

## The seven seams

| call | what it claims | resolved by |
| --- | --- | --- |
| `register_command(spec)` | an ex-command: `:tabnew`, `:split`, … | the `:` line and its completion |
| `register_key(map)` | one normal-mode key | the normal-mode key reader |
| `register_visual_key(map)` | one visual-mode key | the visual-mode key reader |
| `register_gmap(map)` | a `g`-prefixed sequence: `gt`, `gT` | the normal-mode key reader |
| `register_wmap(map)` | a character after <kbd>Ctrl</kbd>+<kbd>W</kbd>, or after `:wincmd` | both readers, which is why one seam covers two |
| `register_action(id, fn)` | a named function another package can call | nothing, until someone calls it |
| `on(event, fn)` | a notification | whoever emits it |

Each has a matching `unregister_*`, and an entry that registers is expected to
unregister — see [writing-a-plugin.md](writing-a-plugin.md) for why that is not
optional.

### ex-commands

The one with a spec, because an ex-command has more to it than a function:

```lua
local registry = require "vim.registry"

local specs = {}

function M.register()
  specs = {
    {
      names     = { "tabnew", "tabe", "tabedit" },
      arg_paths = true,                       -- the : line offers path completion
      help      = "--    :tabnew [path]  open a new tab, optionally with a file",
      run       = function(arg)
        require("core.input.command").perform("tab:new")
        if arg then open_file(arg) end
      end,
    },
  }
  for _, spec in ipairs(specs) do registry.register_command(spec) end
end

function M.unregister()
  for _, spec in ipairs(specs) do registry.unregister_command(spec) end
  specs = {}
end
```

`names` is a list rather than a string because `:tabe` and `:tabedit` are the
same command and should stay the same command — aliases registered against one
spec, so `:help` lists them together and unregistering removes all of them at
once.

`help` is what `:help` prints, and it is why these entries don't each patch the
help text: the registry collects every distinct `help` string and prints them in
registration order.

### keys and sequences

The three key seams take a map, and a map is a table, which means you keep the
reference you registered so you can hand it back:

```lua
local registry = require "vim.registry"

local keys = { ["H"] = function(view) vim_go_top(view) end }
local gmap = { ["gt"] = function(n) tabs().next(n) end }

function M.register()
  registry.register_key(keys)
  registry.register_gmap(gmap)
end

function M.disable()
  registry.unregister_key(keys)   -- the same table, not a copy
  registry.unregister_gmap(gmap)
end
```

Unregistering is by identity: the registry removes an entry only if the value is
still the one you registered. That's what lets two entries both answer to `H` and
lets the later one win without the earlier one's `disable` deleting it out from
under it.

**Register a key the host reports by name under that name.** `register_key` is
asked about the key as the host spells it, before vim mode rewrites it: `tab`,
`home`, `space`, `pageup`, `f3`, and the shifted spellings `shift+n` for a capital
and `*` for the character itself. So `["tab"]` works, which is how the entry on
`workspace` moves panes — and a key vim mode *does* implement, spelled as a motion
(`home` is `0`, `end` is `$`, `space` is `l`), never reaches the registry while a
document has focus, because vim is asked first.

Anything the registry declines goes on to the editor's own keymap, unless it is a
single printable character — those are swallowed, because vim beeps at a letter it
does not know and swallowing is what the beep is made of.

### actions

A named function, for capabilities that want to be callable rather than reachable
by a key:

```lua
local vim = require "vim.api"   -- an alias for the registry
vim.register("my.capability", function(arg) ... end)
vim.call("my.capability", arg)
```

`vim.api` is the older spelling of the same three calls. New code should use the
registry; the alias is there so an existing entry keeps working.

### events

`on(event, fn)` / `off(event, fn)` / `emit(event, ...)`, and there is exactly one
event today: `cwd_changed`. It fires when the working directory changes, and the
entry on `treeview` uses it to refresh the tree.

This seam is thin on purpose. The editor has no general event system — see
[the extension contract](https://github.com/m-mdy-m/cdin/blob/main/docs/architecture/extension-contract.md)
— so extending behaviour means wrapping the function and calling the original. An
event is worth adding when the alternative is polling.

## A whole entry

`packages/editing/vim/with/tab.lua` is about twenty lines and shows the shape:

```lua
-- packages/editing/vim/with/tab.lua
local M = {}

local commands = nil
local keymap = nil
local enabled = false

function M.enable()
  if enabled then return end
  enabled = true
  commands = require "vim.with.tab.commands"
  keymap = require "vim.with.tab.keymap"
  commands.register()
  keymap.register()
end

function M.disable()
  if not enabled then return end
  enabled = false
  if keymap then keymap.unregister(); keymap = nil end
  if commands then commands.unregister(); commands = nil end
end

return M
```

Three things to notice.

**`enable` / `disable`, not `init` / `unload`.** The kernel calls these when a
*partner* arrives and leaves, which may be several times in a session, and both
are guarded. A feature's `enable`/`disable` are the same contract for the same
reason.

**The requires are inside `enable`, not at the top.** A `with` entry is not built
at all unless its partner is up, so hoisting them out of `enable` would buy
nothing and would make the file look loadable on its own. It is not.

**It is the only file under `X/` that mentions `workspace.tab`.** That is the
entire point of the arrangement: one place where the two meet, so either one can
be removed without leaving the other half-wired.

**Nothing here declares a dependency on `workspace`.** The manifest does, as
`with = { workspace = "with/tab.lua" }` — a package name, which is what lets
`make validate` check that this file reaches `workspace` and nothing else.

## Which entry to copy

| you want | read |
| --- | --- |
| ex-commands and `gt`/`gT` | `packages/editing/vim/with/tab.lua` |
| <kbd>Ctrl</kbd>+<kbd>W</kbd> splits | `packages/editing/vim/with/window.lua` |
| `/ n N *` over the search package | `packages/editing/vim/with/search.lua` |
| the <kbd>m</kbd> menu | `packages/editing/vim/with/menus.lua` |
| git commands, and a menu for them | `packages/editing/vim/with/git.lua` |
| `:tree`, and the tree in vim | `packages/editing/vim/with/treeview.lua` |
| the manager, from vim | `packages/editing/vim/with/plugin-manager.lua` |

If you are adding a section to a menu another entry defines, read
[building a with entry](building/a-with-entry.md) first. `menu.extend`
**asserts**, so the thing being extended has to exist before anything extends it —
and that is why `vim.main` is defined in `vim/init.lua` rather than inside
`with/menus.lua`.

For what each of the seven actually does, and what happens when its partner is
missing, see [what vim is wired to](plugins/vim-integrations.md).