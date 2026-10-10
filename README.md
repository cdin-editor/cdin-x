# cdin-x

The package ecosystem for [cdin](https://github.com/m-mdy-m/cdin).

cdin is the editor — window, renderer, text pipeline, document, command and
key registries — and it knows nothing about packages. This repository is
everything the editor isn't.

[![License](https://img.shields.io/badge/license-MPL--2.0-blue.svg)](LICENSE)

## Why it's a separate repository

So that both halves can be wrong independently.

A cdin checkout builds and runs with nothing from here present: `make bin`
needs no cdin-x, and the editor starts, renders, edits, and answers
<kbd>Ctrl</kbd>+<kbd>N</kbd> with an empty site directory. Conversely, this
repository installs, updates and removes itself without going near an editor
installation. Neither one reads a path into the other except at build time, and
there that path is one variable, `CDINX_DIR`.

The cost is a line in a build script. What it buys is that "the editor is
broken" and "a package misbehaves" stop being the same investigation.

## Two kinds of thing live here

**What a build ships** is a **bundle**, and a bundle is a list:

```lua
-- bundles/standard.lua
return { "vim", "themes" }
```

There are three: `standard` (vim and themes), `minimal`, and `empty` — which
also brings no fonts. A cdin build asks for one by name, and the closure is
computed for it: the listed packages, their `depends`, and nothing more.

There is deliberately **no per-package "ship me" flag.** There used to be
`essential = true`, and it was three answers to one question that disagreed with
each other — the flag said what bundles ship, the manifest's `category` said what
was core, and the bundler counted the flags and complained if the count was not
what it expected. One list, asked for by name, has none of those.

Two things are in every bundle. The `manager`, because an editor whose only
answer to "what is installed, and how do I change that" is a script in another
directory is a half-finished editor, and the person who finds out is always the
one who just installed something. And `vim`, for the same reason a build that
cannot be configured after the fact is not a build. Everything the manager
*offers* stays optional; what is not optional is the ability to ask.

**Everything else**: the command palette, the file finders, the project tree,
tabs, search, git, completion. A user installs these from inside the editor, and
the manager handles them from there.

## Install

```sh
git clone https://github.com/m-mdy-m/cdin-x.git
cd cdin-x

make link      # symlink into the site directory — for development
make install   # copy into the site directory
make uninstall
```

That writes four directories into cdin's **site directory** and nothing else:

```text
<site>/cdinx/            the manager
<site>/X/                what has not moved into packages/ yet (vim, syntax)
<site>/packages/         the first-party packages, and the themes
<site>/plugins/cdin-x/   the entry point cdin's loader finds
```

The site directory is `<data_home>/cdin/site` — `data_home` being
`$XDG_DATA_HOME` or `~/.local/share` on POSIX, and `%LOCALAPPDATA%`, then
`%APPDATA%`, then `%USERPROFILE%\AppData\Local` on Windows. It is the editor's
to name, so if you renamed it:

```sh
make link SITE_NAME=extensions        # just the name
make link SITE=/somewhere/else         # or a full path, which wins
```

`site` is the word vim and neovim use for exactly this directory
(`:h site-dir`) — third-party content, as opposed to the editor's own.

## Then, from inside cdin

<kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>M</kbd> opens the manager
(<kbd>Shift</kbd>+<kbd>M</kbd> in vim normal mode, with `vim` and `menu`
installed). Pick something, press <kbd>Space</kbd>, and it's installed and
loaded. No restart, and after this one-time install you don't come back to a
terminal for it.

**[Start here](docs/getting-started.md)** if you just want to use it.

## For a cdin build

A cdin build consumes this repository through one variable:

```sh
make CDINX_DIR=/path/to/cdin-x      # in the cdin checkout
```

which runs `scripts/bundle.py`, writing the bundle's packages, the fonts, a
one-line shim per package, and a `BUNDLE.lua` index into the build's `data/`
directory. Real copies, no network.

It fails rather than working around a problem — a bundle naming a package that
does not exist, a package reaching outside the closure, a missing or empty
`fonts/` for any bundle but `empty`, or an output directory that is a symlink or
junction, which it will not write through.

It is also idempotent: a second run over the first run's output is
byte-identical, and no timestamps are preserved. A bundle that differs between
builds of the same commit is a bug, and this is what makes that checkable
rather than a matter of trust.

Run it by hand with:

```sh
make bundle BUNDLE=standard DEST=/path/to/cdin/build/<platform>/data
```

## Developing

```sh
make validate        # the gate
make manifest        # regenerate X/manifest.lua
make list            # print the catalog
```

`make validate` is the one that matters. It checks the required files, the
manifest schema, that `name` matches the directory, the bundle closures, that a
`with` file reaches only the package its own manifest key named, that a feature
or `with` file defines both `enable` and `disable`, the
`register`/`unregister` symmetry, and that nothing under `cdinx/`, `X/` or
`packages/` refers to a cdin install layout or to the old `core.x` namespace.
Then it **runs the real bundler for each of the three bundles and compares**, so
the thing a cdin build actually consumes gets checked instead of assumed.

Every rule it enforces is a failure that is invisible until much later — a
`module not found` at startup in a built editor, or a package that works until
somebody uninstalls the other one. The reasons are in
[CONTRIBUTING.md](CONTRIBUTING.md).

## The layout

Every one of these has a README that says what the directory is and stops
there.

| directory | holds | the rule that shapes it |
| --- | --- | --- |
| [`packages/<domain>/`](packages) | one capability each, plus themes | may not depend on another package |
| [`X/core/`](X/core) | `vim` — the last entry that had not moved | may not depend on another package |
| [`X/syntax/`](X/syntax) | language definitions, one file each | the host only |
| [`cdinx/`](cdinx) | the manager | reads `config.site_path()` and nothing else about paths |
| [`plugins/`](plugins) | the entry point cdin's loader finds | one file |
| [`bundles/`](bundles) | what a build ships, as a list of package names | the closure, not a flag |
| [`scripts/`](scripts) | bundler, installer, and the tools validate runs | stdlib and plain `lua`, no dependencies |
| [`examples/`](examples) | three complete packages to copy | not part of the catalog |

**There is no `X/integration/`.** It held eight packages whose only content was
wiring between two other packages, and those are now `with` entries — files
inside one of the two packages, run only while both are loaded. See
[docs/building/a-with-entry.md](docs/building/a-with-entry.md).

## Documentation

| you want | read |
| --- | --- |
| to use it | [docs/getting-started.md](docs/getting-started.md) |
| to install packages | [docs/installing-plugins.md](docs/installing-plugins.md) |
| to use one package | [docs/plugins/](docs/plugins/) — one page each, with what you press and how it works |
| to write a package | [docs/writing-a-plugin.md](docs/writing-a-plugin.md) — and [examples/](examples/) |
| to make a switchable feature | [docs/building/a-feature.md](docs/building/a-feature.md) |
| to wire two packages together | [docs/building/a-with-entry.md](docs/building/a-with-entry.md) |
| to make a theme | [docs/building/a-theme.md](docs/building/a-theme.md) |
| to highlight a language | [docs/building/a-syntax-definition.md](docs/building/a-syntax-definition.md) |
| to extend vim mode | [docs/extending-vim.md](docs/extending-vim.md) |
| to work on this repo | [CONTRIBUTING.md](CONTRIBUTING.md), [scripts/README.md](scripts/README.md) |
| to know what cdin guarantees | [the extension contract](https://github.com/m-mdy-m/cdin/blob/main/docs/architecture/extension-contract.md) |

Start at [docs/README.md](docs/README.md) if you would rather pick one.

## Requirements

A cdin that implements the extension contract: a site directory, a package
loader, `core.command_view`, and the command and key registries. Nothing here
assumes where that cdin is installed, and nothing is fetched at runtime except
the package catalog.

Python 3.8+ standard library for the three scripts, and `lua` for the four tools.
No dependencies beyond that.

## License

Mozilla Public License 2.0 — see [LICENSE](LICENSE). Third-party components retain their respective licenses; see [NOTICE](NOTICE).