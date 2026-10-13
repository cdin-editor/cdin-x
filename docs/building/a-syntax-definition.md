# Adding a syntax definition

```text
packages/languages/lang-<language>/{package.lua, init.lua, syntax.lua}
```

One package per language, named `lang-<language>`. No commands, no keys, and no
dependency beyond the host - which is why it gets its own category instead of
being an ordinary plugin: there is nothing to load and nothing to unload.

A language package declares `kind = "lang"`, and the schema requires that name
prefix: a name in the catalog should say what kind of thing it is before it is
opened. `kind` marks the package for the panel and for `check.lua`'s R10; the
definition itself is **not** manifest data. It is real Lua in `syntax.lua`,
called through `core.syntax.add` from `init.lua`, because the reader must never
execute a package to inspect it and the bundler reads manifests with a literal
parser.

Six ship here: `lang-c`, `lang-javascript`, `lang-lua`, `lang-markdown`,
`lang-python`, `lang-typescript` - and they claim disjoint extensions, so a
`.ts` file is never picked up by the JavaScript definition. See the table below.

Three files per language is the shape:

- `package.lua` - pure data: name, kind, version, description, the file
  selection, and `entry`.
- `syntax.lua` - the definition, a table the host understands.
- `init.lua` - registers it once, and has nothing to undo.

## The fastest way

```lua
-- ~/.config/cdin/user/init.lua
require("core.syntax").add {
  files = "%.zig$",
  patterns = {
    { pattern = { '"', '"', '\\' }, type = "string" },
    { pattern = "%-%-.*",          type = "comment" },
    { pattern = "0x%x+",            type = "number" },
    { pattern = "[%a_][%w_]*",     type = "symbol" },
  },
  symbols = { ["fn"] = "keyword", ["const"] = "keyword" },
}
```

No manifest, no directory, no `make validate`. The host matches the active
document's filename against `files` and uses the first definition that claims
it, so order matters if you have several.

This is for a definition only *you* want, in one editor, on one machine. It is
not part of the catalog, cannot be installed by anyone else, and disappears when
`core.syntax.add`'s list is reset - which cannot happen at runtime. For anything
that should ship, use the package form above.

## To add it to the catalog

```sh
lua scripts/new-plugin.lua zig syntax
make index
make validate
```

That writes `packages/languages/lang-zig/` - three files, the definition copied
from `packages/languages/lang-lua/syntax.lua` - and it refuses to write anything
if the directory already exists. The refusal is the point: `new-plugin.lua lua
syntax` in this repository would otherwise overwrite the real
`packages/languages/lua/` without asking.

## The shape

`syntax.lua` is the definition, and it is the table the host understands:

```lua
return {
  files   = "%.zig$",              -- which files this claims
  headers = "^#!.*[ /]zig",        -- a shebang, for extensionless files
  comment = "--",                  -- for commenting out a line

  patterns = {
    -- order matters: first match wins
    { pattern = { '"', '"', '\\' }, type = "string" },
    { pattern = "%-%-.*",           type = "comment" },
    { pattern = "0x%x+",            type = "number" },
    { pattern = "[%a_][%w_]*",     type = "symbol" },
  },

  symbols = {                       -- a set keyed by word
    ["fn"]    = "keyword",
    ["const"] = "keyword",
    ["true"]  = "literal",
  },
}
```

`init.lua` registers it, and that is all it does:

```lua
function M.init()
  if M.registered then return end
  M.registered = true
  require("core.syntax").add(require("lang-zig.syntax"))
end

function M.unload()
  M.registered = false
end
```

**The module name carries the package name.** `require "lang-zig.syntax"` means
package `lang-zig`, module `syntax`; the searcher resolves the first component to
the package's own directory. A language package has no submodules, so this is the
only require it makes.

**`unload` cannot take the definition back.** The highlighter has no remove, so
there is nothing to undo - and the package is no longer the same thing as the
definition after the first `init`. Switching the package off stops it being
loaded; it does not stop a `.zig` file being highlighted by the definition it
already registered. An empty `unload` is a true statement about that; a missing
one is a hole the reader has to reason about.

### `files` and `headers`

`files` is a **Lua pattern, or a list of them**, matched anywhere in the
filename. Not a glob, not an extension.

```lua
files = "%.lua$"                              -- one pattern
files = { "%.ts$", "%.d.ts$", "%.tsx$" }     -- any of these
```

The dot has to be escaped and the end anchored, or `%.js` also matches
`foo.js.bak`. A list is not an alternation — it is several patterns tried in
order, first match winning, and it exists because most languages have more than
one extension and writing `%.ts$|%.tsx$` is a pattern nobody can read.

Six definitions ship, and they claim disjoint extensions:

| definition | claims |
| --- | --- |
| `lang-c` | `.c` `.h` `.inl` `.cpp` `.hpp` |
| `lang-javascript` | `.js` `.json` `.cson` |
| `lang-typescript` | `.ts` `.d.ts` `.tsx` |
| `lang-lua` | `.lua` |
| `lang-python` | `.py` |
| `lang-markdown` | `.md` `.markdown` |

**`headers` is the same idea for files with no useful extension** — a
shebang, matched against the first line, for a `#!/usr/bin/env python` script
that is a Python file whatever it is called.

**A file with no definition is plain text, and nothing warns you.** Which is why
"my language is not highlighted" is nearly always a `files` pattern that does
not match, rather than a missing definition.

### `patterns`

A list, tried in order, **first match wins**. That is why the string rules come
first in every definition in the catalog: a `"` inside a comment must be a
comment, and if the comment rule were below the string rule it would be a
string.

A pattern is either a string or a three-element table:

| form | means |
| --- | --- |
| `pattern = "…"` | a Lua pattern, from the start of the line |
| `pattern = { open, close }` | a delimited span |
| `pattern = { open, close, escape }` | a delimited span where `escape` escapes |

So `{ '"', '"', '\\' }` is a double-quoted string where `\` escapes the next
character, and `{ "%[%[", "%]%]" }` is a Lua long string — which is why the
brackets are escaped: inside a `char class`, `[` has to be `%[`.

`type` is one of `string`, `comment`, `number`, `keyword`, `keyword2`, `literal`,
`operator`, `function`, `symbol`, `normal`. **These are exactly the keys under
`syntax` in a theme**, which is the whole contract between a language definition
and a colour scheme. A `type` a theme has no key for falls back to `normal`, so
a typo is invisible rather than fatal.

Two patterns worth copying, because they are the ones you will want:

```lua
-- a function call: an identifier immediately followed by (
{ pattern = "[%a_][%w_]*%s*%f[(\"{]", type = "function" },

-- an operator: every character, one at a time
{ pattern = "[%+%-=/%*%^%%#<>]", type = "operator" },
```

The `%f[%a]`-style frontier in the first one is what makes it match the
*identifier* and stop before the paren, rather than swallowing the paren too.
Without it you get a function name that ends in a bracket.

### `symbols`

A set of words, keyed by the word, valued by its type. It is checked **after**
the patterns, which is why `symbols` cannot contain anything a pattern would
have claimed first — and why `"function"` in Lua's `symbols` colours as a
keyword even though `%a_[%w_]*` would have matched it as a symbol.

`symbols` is a set rather than a list because that is what a hand-written
definition reads like, and because duplicate keys in a Lua table constructor are
a silent last-wins rather than an error.

## How it works

**Definitions are a list, and the last one registered wins.** `syntax.add`
appends, and the lookup walks the list **backwards** and returns the first match
it finds. So a definition you add from your `init.lua` overrides a catalog
one — which is what you want, and also means a second `add` for the same
extension silently replaces the first.

**A definition is chosen by filename when the document loads, and cached with
it.** Changing a file's extension on disk is not something the editor notices;
reload the document and it re-reads.

**Only the visible lines are highlighted.** There is a `max_wanted_line` and a
`first_invalid_line`, and the highlighter works outward from what is on screen.
That is why opening a very large file is instant, and why scrolling into new
territory is where you notice a slow pattern — a pathological Lua pattern on a
long line is the one place highlighting can cost you a frame.

**The types a pattern emits are the theme's `syntax` keys, and nothing else in
the editor knows what they mean.** `source.lua` and `suggest.lua` decide which
type a span gets; a theme decides what colour that type is. A `type` a theme has
no key for falls back to `normal`, so a typo is invisible rather than fatal.

**There is no `syntax.remove`.** So `unload` is empty in all six definitions,
and that is not an oversight — there is nothing to call. A definition added from
your `init.lua` lasts for the session, which is exactly what you wanted when
you added it there.

## Writing patterns that do not lie

A pattern that matches too much is worse than no pattern, because the text it
claims is text you cannot read. Three habits:

**Anchor what must be anchored.** `"//.*"` is fine; `"//.*"` without a boundary
is the same thing here, but `".*//.*"` would match every line.

**Put longer alternatives first.** `{ "[%a_][%w_]*", type = "symbol" }` before
`{ "[%a_][%w_]*%s*(%b())", type = "function" }` gives you every identifier as a
symbol and no function names. The order is the pattern.

**Test on a real file, not on one line.** A definition that looks right on
`local x = 1` is not evidence about a file with a URL in a comment, and the URL
is where you will find out.

## Files

| file | holds |
| --- | --- |
| `packages/languages/lang-<language>/syntax.lua` | the definition |
| `../../data/core/doc/highlighter.lua` | the walker, in the cdin repository |
| `../../data/core/syntax.lua` | `syntax.add`, and the filename matching |
