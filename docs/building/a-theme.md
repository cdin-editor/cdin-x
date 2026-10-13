# Adding a theme

```text
<themes>/<name>/theme.lua
```

One directory, one file, a table of colours. That is the whole format, and it
is the layout cdin's theme registry reads — so a theme directory can be handed
to `core.themes.add_root()` as-is.

## The fastest way

Point the registry at a directory. No install, no manifest, no `make validate`:

```lua
-- ~/.config/cdin/user/init.lua
require("core.themes").add_root(os.getenv("HOME") .. "/my-themes")
```

Each subdirectory of that root that holds a `theme.lua` becomes a theme. This is
the right way to try one out, and the right way to keep your own themes, since
a directory you own can be version-controlled and symlinked independently of
the editor.

## To add it to the catalog

```sh
lua scripts/new-plugin.lua my-theme themes
make index
make validate
```

That writes `packages/system/themes/themes/my-theme/theme.lua` and a README, and
it copies the template from `nord/theme.lua` rather than inventing one. That
matters more than it looks: **the key names are the host's, and a wrong one is
invisible.** The runtime falls back to the default for a key nobody supplied, so
a misspelled colour key is a theme that quietly looks like another one rather
than an error.

Ten ship here: `catppuccin-mocha`, `default`, `dracula`, `github-light`,
`gruvbox-dark`, `monokai`, `nord`, `solarized-dark`, `solarized-light`,
`tokyo-night`.

**Nothing in a theme file says whether it ships.** A theme reaches a build only
when a bundle in `bundles/` names it, and `standard` names `themes` - the
*container*, not the themes inside it. The domain bundles (`web-frontend`,
`backend-python`, `devops-linux`) all name it too, because a theme is editor
infrastructure rather than a capability of one kind of work.

## Every key

Copy an existing theme and change the colours; that is easier than starting
from this list. The list is here so you know what *exists*.

| key | what it colours |
| --- | --- |
| `background` | the editor's own backdrop |
| `background2` | the one behind it — the tab bar, the status bar |
| `background3` | one step further forward — menus, the popup |
| `text` | ordinary text |
| `caret` | the cursor |
| `accent` | the one saturated colour in the scheme; used sparingly |
| `dim` | secondary text — hints, inactive entries |
| `divider` | the lines between things |
| `selection` | the selected region |
| `line_number` | the gutter |
| `line_number2` | the current line's number |
| `line_highlight` | the current line's background |
| `scrollbar` / `scrollbar2` | the scrollbar, and its handle |
| `search_highlight` | `{ r, g, b, a }` — matches, and it is **not** a hex string |
| `titlebar_text` | the window title, unfocused |
| `titlebar_text_focus` | …focused |
| `titlebar_button_hover` | a titlebar button under the mouse |
| `titlebar_close_hover` | the close button, hovered |

### Vim mode

| key | what it colours |
| --- | --- |
| `vim_pill_fg` | the text in the mode pill |
| `vim_normal_bg` | normal mode |
| `vim_insert_bg` | insert mode |
| `vim_visual_bg` | visual mode |
| `vim_replace_bg` | replace mode |
| `vim_command_bg` | the `:` command line |

**The mode pill has to be legible at a glance.** That is what these four are
for, and it is the part of a theme people get wrong: a scheme can be beautiful
and still leave normal and visual mode indistinguishable at a glance, which is
the one job the pill has.

### Git

Only used when the `git` plugin is installed. With no git plugin, these keys do
nothing and you can leave them out.

| key | what it colours |
| --- | --- |
| `git_modified` | a tracked file with changes |
| `git_added` | staged |
| `git_deleted` | deleted |
| `git_conflict` | in conflict |
| `git_untracked` | untracked |
| `git_renamed` | renamed |

### Syntax

The tokens the highlighter emits. `source.lua` and `suggest.lua` decide which
type a span gets; these decide what colour that type is.

| key | what it colours |
| --- | --- |
| `normal` | the base for anything not otherwise classified |
| `symbol` | identifiers |
| `comment` | comments |
| `keyword` | the language's own reserved words |
| `keyword2` | a second class of them — types, builtins, second-level keywords |
| `number` | numeric literals |
| `literal` | `true`, `false`, `nil` — things that are values rather than words |
| `string` | strings |
| `operator` | operators |
| `function` | function names |

`keyword` and `keyword2` are two classes on purpose. A language with one big
reserved-word list renders as a wall of identical colour; splitting it lets
`self` and `true` stand out from `if` and `end` without a theme having to know
any particular language.

## A worked example

Start from a theme you already like. This is `nord`, changed to be darker and
to have a warmer accent, and it is about eight lines of difference:

```lua
local base = dofile(<path to the original>/nord/theme.lua)

local M = {}
for k, v in pairs(base) do
  if type(v) == "table" then
    M[k] = {}
    for k2, v2 in pairs(v) do M[k][k2] = v2 end
  else
    M[k] = v
  end
end

M.name = "nord-warm"
M.background = "#1c1f26"
M.background2 = "#191c22"
M.accent      = "#d08770"
M.syntax.keyword  = "#b48ead"
M.syntax.comment  = "#5c6773"

return M
```

Two things about that shape.

**Copying is a deep copy.** Assigning `M = base` and then changing one colour
would change the original, and the original is on disk and shared. Walking the
nested `syntax` table by hand is the price of not doing that.

**A copied theme is a new theme, and it is not in any build.** There is no
`essential` field to set and no inherited flag to override. The only question was
ever "is this in a build", and it is answered by `bundles/standard.lua` naming
the `themes` package — never by anything in a theme file. A theme you add is
available to the switcher and to `core.themes.add_root()`, and that is all.

**Every key in the base is a key you now own.** Copy `nord` and you have copied
`["function"]` and all of the `vim_*` pills, and if `nord` later gains one your
copy will not. Deep-copying a theme is copying a snapshot; the thing to copy
instead is the *list* in this page.

## How it works

**A theme is a table of colours, and the runtime does the rest.** There is no
theme format, no inheritance, no theme engine. `core.themes` reads the table,
resolves any colour the plugin did not supply from the default, and hands the
result to the style object everything draws with.

**Colours are hex strings, except `search_highlight`, which is
`{ r, g, b, a }`.** That one is an RGBA table because it has to be composited
over whatever is behind it, and a hex string with an alpha channel would be a
second colour format for one key.

**Missing keys fall back rather than erroring.** A theme that sets six colours
works. That is deliberate: a theme should be able to be a *variation*, not a
complete specification, and an error would make the six-colour theme impossible.

**The manager installs themes; the runtime loads them.** So installing a theme
does not add a running plugin — it adds an entry to the theme switcher, and
nothing appears to happen until you select it. That is a confusing first
experience and it is worth knowing about before you conclude the install failed.

**The switcher sets the theme; a `with` entry is what remembers it.** They are
two different questions — *change it now* and *remember that I did* — and some
people want the first without the second. The switcher is the `switcher` feature
of the [`themes`](../plugins/themes.md) package; the remembering is
`with/themes.lua`, which exists only while both `themes` and `workspace` (through
its `session` feature) are active.

`config.theme = "nord"` in your own `init.lua` does neither of those, and does
not need either: the host reads it at startup. That is the answer for someone who
does not want a list.
## Files

| file | holds |
| --- | --- |
| `theme.lua` | the colours, and nothing else |
| `../../scripts/new-plugin.lua` | the template, copied from `nord` |
| `../../scripts/generate-index.lua` | what puts it in the catalog index |
