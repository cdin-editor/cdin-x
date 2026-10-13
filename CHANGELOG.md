# cdin-x Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Versioning follows [Semantic Versioning](https://semver.org/).

---

## [Unreleased]

### Added

- **Packages, and everything optional inside one.** What a build ships is decided by
  a bundle in `bundles/` rather than by an `essential` flag in a manifest. `essential`
  is gone and nothing replaces it: `standard` is `{ vim, themes }`, `minimal` is the
  kernel alone, `empty` is the kernel with no fonts, and
  `scripts/bundle.py --bundle <name>` picks which. The catalog is 18 packages, down
  from 26.
- **A package's identity is its `name`, not its path.** `package.lua` is pure data,
  read and validated in a sandbox and never executed, so `require "git.api"` works
  wherever the files live. `entry` may name any file, so a single-file package and a
  directory of modules are the same kind of thing.
- **Features: parts of a package you can switch off.** A package declares
  `features = { tab = { default = true } }` and each is a `features/<key>.lua` with an
  `enable()` and a `disable()`. One that nobody enabled is never required, so its
  commands, its keymap and its module state are never built.
- **`with` entries: two packages that need each other without depending on each
  other.** One file, named in `package.lua` against the other package, run only while
  both are loaded and torn down when either leaves. `themes` pushes the chosen theme
  into the session's saved state this way, as do vim's git, search, tab, treeview and
  window bindings and git's status badges.
- **`<user_root>/packages.lua`** — the user's own choices, readable and editable, read
  in a sandbox. It names packages to switch off and features to switch off, and what
  it writes is checked against the catalog at boot: a name that matches nothing is
  reported by name, with a near-miss offered where one is close.
- **The panel can switch a feature.** Feature rows appear indented under their package
  showing whether each is on, whether that is the user's choice or the package's
  default, and whether it is actually running. `f` toggles the one under the cursor,
  and the change is written before the row is redrawn so it is true this frame rather
  than a promise about the next start.
- **Host version compatibility is checked.** All twelve packages declared
  `min_cdin_version` and nothing compared it. Install now refuses a package the running
  host cannot satisfy, saying what is needed and what this is.
- **`scripts/check.lua`** — per-package rules, run by `make check`.
- **Six language packages, and a third kind of bundle.** The syntax definitions are
  packages now: `lang-c`, `lang-javascript`, `lang-lua`, `lang-markdown`,
  `lang-python` and `lang-typescript`, each a `package.lua`, an `init.lua` and a
  `syntax.lua`, declaring `kind = "lang"`. The `lang-` prefix is the schema's rule
  (`cdinx/schema.lua` already required it and no package had ever tripped it), so a
  name in the catalog now says what kind of thing it is. The definition is still
  real Lua called through `core.syntax.add` - not manifest data - because a package
  must never be executed to be inspected. Three **domain bundles** group packages for
  a kind of work: `web-frontend`, `backend-python` and `devops-linux`, each carrying
  `themes` because a theme is editor infrastructure rather than a capability of one
  field of work. CSS, HTML, SQL, Bash, YAML, Rust and Go have **no** package; they are
  listed under each bundle's `optional` so `make validate` reports them missing,
  which records the gap rather than pretending to fill it.
- **`make validate` checks the GitHub workflow files.** A job that `needs:` a job the
  file does not define, a step reading `needs.X` for a job that was removed, a
  reusable-workflow call that does not exist, a `with:` key the callee does not
  declare, or a job the `required` gate does not list. Phase 9 deleted the `manifest`
  job and left four references to it, which made the whole workflow fail to load
  before a single check ran; nothing in the repository could see that.
- **`make` works on Windows.** Interpreter discovery asks `where` there and
  `command -v` on POSIX, `firstword` keeps `where python`'s three matches from
  becoming one unrunnable command, the POSIX-shell guards moved into make's own
  `$(error)`, and `make help` no longer prints a line of literal quote marks.
  `make check` calls `check.lua` once with every package, so three packages report
  three instead of three reports ending in "1 package(s)".
- **`scripts/generate-index.lua` refuses to write an empty catalog.** A scanner that
  finds nothing used to replace a real index with a stub that still parses. It now
  fails with a message and leaves the committed file untouched.
- **The language packages were renamed, and `lang-` is now required.** `c`,
  `javascript`, `lua`, `markdown`, `python` and `typescript` are now `lang-c`,
  `lang-javascript`, `lang-lua`, `lang-markdown`, `lang-python` and
  `lang-typescript`, and each declares `kind = "lang"`. `cdinx/schema.lua` has
  required the prefix since the schema landed; no package tripped it until now, so
  the rule was never exercised. Two consequences: `require "lang-python.syntax"`
  rather than `require "python.syntax"`, which is the only require any of them made,
  and the panels that group by `category = "syntax"` still do, because `category`
  is unchanged. **A user whose `packages.lua` or `disable` list names one of the old
  names will find it retired** - `cdinx/manager/moved.lua` maps each old name to the
  package it became and the panel says so by name.

### Changed

- **`X/integration/` is gone.** Its eight packages existed only to wire two other
  packages together, which is what a `with` entry is for. No command name, keystroke or
  config key changed: `vim-git:status`, `vim-menu:open` and `core:find-command` are
  spelled exactly as before, and only the module names and directories moved.
- **One place reads the host.** `cdinx/host.lua` is the single reader of host globals
  and modules, which took the tree from three undefined globals to none.
- **`packages/` is a required install root again.** It was optional while the move out
  of `X/` was in progress and themes still lived there. They have moved, so a site
  install is four roots or it is a broken one.

### Fixed

- **The panel's feature switches did nothing.** The runtime read
  `ctx.state.features`; `State.load` populated only `disabled` and `lock` and
  `State.save` wrote only those, so the table was always nil, every declared default
  won, and turning a feature off changed nothing — silently, with no warning.
- **`min_cdin_version` meant nothing**, for the reason above: declared by every
  package, shape-checked by the schema, compared by nothing.
- **Four places still read `essential`**, a field the schema now refuses.
  `get_essential_names` therefore returned an empty list to every caller; the orphan
  guard in `Lifecycle.clean` protected nothing; and `disable`/`uninstall` had a dead
  disjunct beside `_source == "builtin"`.
- **`Packages.load` silently ignored any path not ending in `packages.lua`** — a guard
  against a mis-set config key that turned a valid Windows temp path into a no-op
  reporting no problems.
- **The panel's `unregister` listed command names by hand** and the list had drifted:
  it contained a name registered nowhere and omitted one that was.
- **A misspelt package name in `packages.lua` was inert forever**, read and never
  compared against anything.

### Removed

- **`essential`**, as a manifest field. Schema, `validate.lua` and `check.lua` all
  refuse it.
- **`X/themes/`** — themes are a package, and `bundle.py` flattens them to
  `<data>/themes/<name>/` where the host reads them.
- **`vim-menu`, `vim-git`, `vim-search`, `vim-tab`, `vim-window`, `vim-treeview`,
  `vim-plugin-manager`, `git-treeview`** — now `with` entries or features.
- **The manager package.** What it bootstrapped is `cdinx/`, which every bundle now
  writes into the build along with its entry shim, so the panel is reachable without
  a package being responsible for it.
- **`X/`** - the last of it. The directory held everything before `packages/`
  existed, then vim, then only the generated manifest and the syntax definitions; the
  language definitions are `lang-*` packages and the generated manifest is
  `registry/generated/catalog.lua`. With it went `scripts/generate-manifest.lua`, the
  `make manifest` target, and the CI job that existed only to check
  `X/manifest.lua` was not stale. A build directory produced before this still has an
  `X/` full of packages; `bundle.py` clears it, because a directory this script
  copied into and does not clear is how a deleted file survives in every build after
  it. Nothing scans `X/` any more, so that copy is inert either way.
- **`Manager.set_registry_syncer`** as a working seam. It survives as a shim that
  logs one deprecation per process, per the extension contract.

### Fixed (earlier, still unreleased)

- **vim 0.3.3 - `:!` doubled every `"` before cmd saw it, on Windows.**
  `shell.capture` wrapped the command as `cmd /c "<cmd>"` and, to be safe,
  escaped each `"` inside it as `""`. That is the escape for CSV and PowerShell,
  not for cmd: cmd strips the outer pair and passes the rest through verbatim,
  so `git commit -m "chore(docs): add README.md"` reached git as
  `-m ""chore(docs): add` — an empty string followed by a bare word. `-m` took
  `chore(docs):`, and `add` and `README.md` were read as pathspecs:
  `error: pathspec 'add' did not match any file(s) known to git`. The only way
  to get a commit through was to type `\"`, which then landed in the message
  with the quotes included.

  The command goes through untouched now, so `:!git commit -m "a b"` behaves the
  way it does in a terminal and the message is committed without quotes. The
  vim-git **Commit** menu, which escapes quotes as `\"` itself, was hitting the
  same bug and is fixed by the same change. The PowerShell capture path
  (`config.shell_capture_win = "powershell"`) is unchanged.

## [0.2.0] — 2026-10-03

`manager` is now a plugin in the catalog and `essential = true`, so every cdin
build carries an extension panel. The catalog is downloaded over plain HTTPS —
one file to search, one file per install — and cdin-x is never cloned and git is
never invoked.

And `vimode/motions.lua` became a *rule* rather than a command name, which is
what lets `dw`, `de` and `dj` be one definition instead of three that can
disagree.

### ⚠️ BREAKING CHANGES

#### The essential set is two plugins, not one

`X/core/manager` is marked `essential = true` alongside `vim`, with the `default`
theme. `scripts/bundle.py` now produces:

```
X/core/vim/**            verbatim copy of the vim plugin, whole subtree
X/core/manager/**        verbatim copy of the manager plugin
cdinx/**                  the manager's own modules, via bundle_with
plugins/vim.lua          return require("X.core.vim")
plugins/manager.lua      return require("X.core.manager")
themes/default/theme.lua the essential theme
fonts/**                 5 fonts + 2 licences
BUNDLE.lua               { plugins = { "manager", "vim" }, themes = { "default" } }
```

Everything the manager *offers* stays optional. What is not optional is the
ability to ask what is installed and change it.

#### Nothing is fetched with git any more

0.1.0 shipped a syncer hook: `cdinx` refused to know git existed, the git
plugin injected `M.sync_registry`, and **Refresh Catalog** reported the syncer
unavailable when `git` was not installed. That whole path is gone.

- `cdinx/manager/fetch.lua` (418 lines) is the only network code. It downloads
  `X/manifest.lua` — one file, ~16 KiB — and then, for an install, exactly the
  files that extension's manifest entry lists. `curl`, else `wget`, else
  PowerShell on Windows. 120-second timeout, staging directory, and files are
  only moved into place once the whole download succeeded.
- `Manager.set_registry_syncer` still exists and still has **no callers**.
  `registry.refresh` prefers an injected syncer and falls through to
  `Fetch.sync`, so the HTTPS path is what runs.
- `X/core/git/manager/ops.lua` lost `sync_registry` and kept the banner comment
  and three dead locals (`quote`, `succeeded`, `run`).
- **git is not required to install cdin-x extensions.** It is not used at all.

New config: `config.registry_raw_url`, derived from `registry_url` by pattern,
overridable directly; `CDIN_X_BRANCH` picks the branch.

#### `config.extension_dir` gained an `X`

`<data_home>/cdin/extensions` → `<data_home>/cdin/extensions/X`, because the
store keeps each extension's category directory. The old path is preserved as
`config.legacy_extension_dir`.

#### `r` is vim's replace, and redo is <kbd>Ctrl</kbd>+<kbd>Y</kbd>

`r` used to be redo here — a documented departure from vim, where `r` replaces
the character under the caret. It now does what vim's does, and redo moved to
<kbd>Ctrl</kbd>+<kbd>Y</kbd>.

That is the editor's own redo stroke, so nothing was taken away from it — but if
you have been pressing <kbd>r</kbd> to redo, use <kbd>Ctrl</kbd>+<kbd>Y</kbd>.
Nothing else changed meaning.

#### <kbd>Ctrl</kbd>+<kbd>D</kbd> is half a screen, not select-word

Inside vim mode. Outside it, and on the panel and the finders, it is unchanged.
<kbd>iw</kbd> is what the old binding did anyway.

### Added

- **`X/core/manager` — the extension panel, bundled into every build.**
  `Ctrl+Shift+M` anywhere opens it. It groups by status first — *In the editor*,
  *Installed*, *Available* — with categories inside the last two, which answers
  "what is here, and what is mine" in that order. `Space`/`Enter`/`X` toggle,
  `I` installs, `U` removes, `D` opens details, `R` rescans, `?` says where the
  catalog came from, `Ctrl+R` re-downloads it, `[`/`]` resize, `/` or `Ctrl+F`
  searches. The title bar carries the counts: `12 in editor  4 installed  29
  available`.

  `Shift+M` is deliberately **not** bound globally. It belongs to
  `vim-plugin-manager` through vim's registry, so it is vim-normal-mode-only and
  only when that integration is installed — a global `Shift+M` is also how you
  type a capital `M`.

- **`cdinx/manager/loader.lua` — the extension store is requireable.** Every
  extension's own code names its modules by their place in the repository
  (`require "X.core.treeview.treeview_impl"`), but the manager stores an
  installed extension *without* the `X/` prefix, at
  `<extension_dir>/core/treeview/init.lua`. Nothing told Lua about the mapping,
  so the manager could download, place and `dofile` an extension and its first
  `require` failed — for every installed extension with more than one file. This
  is a `package.searchers` entry rather than a `package.path` line, because the
  mapping is not a path template. It sits **after** the standard Lua searcher,
  so the build's own copies still win.

- **`bundle_with` in the bundler.** An essential plugin can declare paths that
  have to travel with it:

  ```lua
  bundle_with = { "cdinx" },
  ```

  `manager` needs it — its code lives at the checkout root rather than under
  `X/`, and a bundle that needs files the bundler did not know about is a build
  whose editor starts and then does nothing. `bundle.py` reads it as text rather
  than executing the manifest, clears the top-level directories it owns so a
  deleted file does not survive in every later build, and **dies** on a path that
  does not exist or that escapes the repository (`/…`, or a `..` segment).

- **CI, which 0.1.0 did not have.** Six workflows under `.github/workflows/`:
  `bundle.yml` (validate + bundle, twice into separate trees, compared whole),
  `ci.yml` (manifest-is-current, install on Linux/macOS/Windows, and the required
  -checks aggregator), `contract.yml` (checks out cdin and runs
  `make test-workflows` against this checkout — the only check that can fail
  because *another* repository changed, and the only failure a user hits),
  `test-install.yml`, `release.yml`, `tag.yml`. Push, PR, weekly, manual.

- **Panel search.** Substring over name, description and category first, fuzzy
  over the name second, best match ranked to the top with the cursor on it. Never
  the other way round — a fuzzy match that quietly returns things you did not ask
  for is worse than a miss.

- **`treeview:toggle-key`.** A command whose only job is to give one keystroke a
  predicate, so <kbd>F2</kbd> can be a fallback chain entry instead of a
  replacement.

- **vim 0.3.0 — the editing grammar.** `di"`, `ci"`, `yi"`, `dw`, `db`, `de`,
  `d$`, `di(`, `diw`, `dat`, and the rest of what makes a modal editor usable,
  now work. They did not before, and the reason was structural rather than a
  missing key.

  `vimode/motions.lua` was a table of key → cdin command name. That can answer
  "which command does this key run" and nothing else — and an operator needs to
  know where a motion *ended*. `dw` is not `d` then `w`; it is one range from the
  caret to wherever `w` would have gone, and whether the character it lands on
  belongs to that range is exactly what separates `de` from `dw`. A command name
  cannot carry that, so `d` set a half-typed flag, the next key discarded it, and
  `dw` was `w`.

  Motions are now rules that answer an endpoint plus the two facts an operator
  needs about it — inclusive (does the landing character belong to the range:
  `$` and `e` do, `w` and `h` do not) and linewise (is the range whole lines:
  `j` and `G` are). Normal mode, a pending operator and `.` all read the same
  rule, so they cannot disagree about where `w` goes.

- **Text objects.** Two keys that name a *region* rather than a place, which no
  motion can express: `iw aw iW aW`, `i" a"`, `i' a'`, `i( a(` and `ib ab`,
  `i[ a[`, `i{ a{`, `i< a<`, `it at` across lines, `ip ap`, `is as`. They follow
  an operator (`ci"`), a motion, or stand alone in visual mode to re-aim a
  selection (`vi"`). A name that covers nothing — `di(` outside a bracket —
  does nothing, which is what vim does.

- **Counts everywhere.** `3x` cuts three characters, `3w` moves three words,
  `2dd` takes two lines. A count on either side of an operator multiplies, so
  `2d3w` deletes six words. Before, the count was parsed and then read by exactly
  one key, `gt`.

- **Shifted punctuation reaches vim as the character it produces.** The host
  reports the *unshifted* key and a separate shift flag — `"` arrives as `'`
  with shift held, `$` as `4`. `vimode/keys.lua` maps both spellings. Without
  it, `yi"` matched nothing and the key was silently swallowed, which is the
  report this release answers.

- **`V` for visual line**, and `o` to swap which end of a selection the caret is
  on. Visual mode now counts, and takes text objects.

- **`.` to repeat the last change**, at the caret's new position rather than the
  old coordinates — which is what makes it useful on the next line.

- **`gu` / `gU` / `g~`**, over a motion or a text object, and `u` / `U` in visual
  mode.

- **`r<char>` to replace**, with a count for more than one character.

- **`0`, `^`, `gg`, `G`, `w W b B e E`, `f F t T ; ,`, `%`, `{ }`, `( )`,
  `+ -`, `|`, and `H M L` for the window.** `G` tells <kbd>1</kbd><kbd>G</kbd>
  from <kbd>G</kbd>, which takes a count that means "no count" when absent.

- **Paging.** <kbd>Ctrl</kbd>+<kbd>F</kbd> and <kbd>Ctrl</kbd>+<kbd>B</kbd> for a
  screen, <kbd>Ctrl</kbd>+<kbd>U</kbd> and <kbd>Ctrl</kbd>+<kbd>D</kbd> for half of
  one. The docs claimed there was no page movement and that it would need a
  command that does not exist; the host has had `doc:move-to-next-page` and
  `doc:move-to-previous-page` all along.

- **Capsular keys are no longer eaten by lowercase ones.** Shift and `d` arrives
  as the character `d`, so `D` reached the operator table as a pending delete,
  `C` as a pending change, and `J` was answered by the motion table as `6j`. A
  shifted letter now skips both tables. Within the capitals the registry is asked
  first, because `N` and `M` are the one spelling both vocabularies can claim.

### Changed

- **`cdinx/panel.lua` is now `cdinx/panel/`.** One file had grown to hold the
  view, the row model, the search, the commands and the keys.

  | file | holds |
  | --- | --- |
  | `panel/init.lua` | builds the view, splits the pane |
  | `panel/view.lua` | the view: rows, cursor, scrolling, drawing |
  | `panel/rows.lua` | catalog → rows. Pure |
  | `panel/search.lua` | what a query matches. Pure |
  | `panel/commands.lua` | every command, with the predicate that gates it |
  | `panel/keymap.lua` | the keys, in three maps |

- **Plugins no longer replace key bindings to join them.** `keymap.add(MAP, true)`
  on strokes the runtime also owns — `Up`, `Down`, `Return`, `Ctrl+R` — meant
  the document's arrows and the log view's reload died the moment treeview
  registered. `keymap.add` **prepends**, so a chain with predicates does the
  same job and keeps the fallback. Applied across `search`, `tab`, `window`,
  `session`, `autocomplete`, `autoupdate`, `treeview` and the optional plugins.
  `X/core/search/keymap.lua` carries the reasoning next to the binding, because
  it is the kind of thing that gets "tidied up" once.

- **`plugins/cdin-x/init.lua` is one line.** `return require("X.core.manager")`.
  An installed cdin-x and a bundled cdin-x are the same manager; only how the
  host finds it differs. Two copies of a bootstrap would be two things to keep in
  step, and the day they disagree the panel is the thing that is wrong.

- **The catalog reports what is in the editor.** Plugins the host loaded were
  dropped from the listing, so a fresh build opened an empty panel while vim was
  running. They are listed now, as *in editor*: present, visible, and not the
  manager's to remove.

- **`vim-treeview` does more than `:tree`.** It subscribes to vim's `cwd_changed`
  so `:cd` refreshes the tree, contributes the menu's only context provider
  (priority 200), and adds the **Tree** menu section at order 20.

- **`vim-search` adds a menu section** (order 40). Four integrations now extend
  `vim.main` — Tree 20, Git 30, Search 40, CDIN-X 80 — not two.

- **`session` became the quit-wrapping plugin it says it is**, and
  `tab-session` lost the dependency it did not have: it has its own writer, its
  own path, and takes only the `on_quit` seam.

- **`X/core/vim/vimode/` is split by concern**, and the split is the point:

  | file | holds |
  | --- | --- |
  | `text.lua` | position and range arithmetic over a document |
  | `motions.lua` | where a key sends the caret, and what that means to an operator |
  | `textobjects.lua` | the `i`/`a` objects |
  | `operators.lua` | applying an operator to a span, and the clipboard |
  | `keys.lua` | the key reader and the half-typed states |
  | `mode.lua` | which mode you are in |

  Every entry in the middle three is a function of (document, line, column,
  count) and touches no view, no mode and no clipboard. That is what lets normal
  mode, a pending operator and `.` share one definition rather than three that
  agree until one of them changes — and it is what made this fix checkable
  without an editor.

- **A capital letter asks the plugin registry before vim's own tables.** The one
  place the documented lookup order flips, because a shifted letter is the only
  spelling both vocabularies claim.

- **`X/core/vim/README.md` and `docs/plugins/vim.md`** carry the new key tables,
  and the page no longer claims there is no page movement or no `.`.

### Fixed

- **`Ctrl+Shift+Alt+N` — new directory in the tree — did nothing.** A stroke is
  not looked up by meaning: the host *builds* the string it will look up
  (`ctrl+`, `alt+`, `altgr+`, `shift+`, then the key's own name) and matches
  that string for equality, with no normalisation. `ctrl+shift+alt+n` is
  therefore not a variant of `ctrl+alt+shift+n`, it is a string no key press
  produces, and the binding was dead in the same silent way a binding naming an
  unregistered command is: `on_key_pressed` misses, returns false, nothing is
  written anywhere. It is `ctrl+alt+shift+n` now, and the docs that repeated the
  wrong order are corrected.
- **<kbd>F2</kbd> no longer opens the tree instead of switching the log.** The
  log view advertises <kbd>F2</kbd> in its own header for switching between its
  two streams, and `log:switch-source` is view-scoped, so it declines everywhere
  else and wins the stroke — provided something on the tree's side declines too,
  because a stroke is a fallback chain and `keymap.add` prepends. Hence
  `treeview:toggle-key`: a command whose only job is to give that one keystroke a
  predicate, the same shape as `rename-key` and `delete-key`. `treeview:toggle`
  itself is untouched, so the palette and every integration can still toggle the
  tree from the log view.
- **`make validate` no longer rejects a correct bundle.** `cdinx/` is a
  `bundle_with` support tree and has been inside the bundle since the manager
  moved there, but the validator's allow-list still predated it, so every
  `cdinx/*.lua` was reported as "a non-essential entry" and `make validate` —
  which CI runs — was red. `cdinx` is now a recognised top-level entry, README and
  all.
- **A keystroke nothing could press now fails the build instead of the user.**
  `make validate` walks every `.lua` file under `cdinx/` and `X/`, and rejects a
  binding whose stroke the input layer cannot build, naming the reason and the
  spelling that would have worked. The rule is restated there rather than
  required from the host, because cdin-x must not depend on cdin's modules;
  cdin's own `make test-plugins` covers its half, and the host reports every
  unreachable stroke in the log at boot.
- **A bundled extension was loaded twice.** cdin-x bootstraps from inside the
  host's own plugin loop, so `core.plugins.loaded` is missing every entry after
  it in the alphabet — and cdin-x would load vim out of the bundle with `dofile`
  while the host loaded it with `require`. Two instances, and the second collided
  with the first one's commands. The manager now reads the host's plugin
  directory as well as its loaded set.
- **A command whose `perform` was a string.** `command.add` stores what it is
  handed, so a table of names resolved nowhere is a keystroke that raises into
  `core.try`, logs, and does nothing. The panel's tables are resolved at
  registration.
- **A filter that found rows nothing could be selected on.** The cursor was
  re-seated from the *previous* row list, which put it on a section header or
  past the end after any filter. It is re-seated from the new one.

- **`*` in vim-search could never fire.** It is registered as `"*"`, and the host
  sends shift and the 8 key — so the token it was looked up under was `shift+8`.
  The same normalisation that makes `di"` work makes it reachable.

- **`x` did not put anything on the clipboard.** It ran `doc:delete`, which
  removes a character and never touches the clipboard, so `x` then `p` pasted
  whatever was copied last. It goes through `doc:cut` now.

- **The arrow keys did nothing in normal and visual mode.** The host names them
  `up` / `down` / `left` / `right` and vim has no arrow keys, so they reached the
  motion table as the word "up", matched nothing, and fell through. Insert mode
  hid it, because insert mode does not read keys and the host moves the caret
  there. They are `hjkl` now — character-wise, so a count and an operator both
  work — and only while the document is the focused view, which is what leaves
  the tree, project search and the autocomplete popup their own arrows.

- **vim 0.3.1 — <kbd>Home</kbd>, <kbd>End</kbd>, <kbd>Space</kbd>,
  <kbd>PageUp</kbd> and every other key the host reports by name.** Four names
  were translated and the rest were not, so `home` reached the motion table as
  the word "home" — and then the command table answered "handled" for every key
  it did not match, so the editor never saw it either. A dead key, with no error
  and nothing on screen: they worked in insert mode and did nothing in normal
  mode, which is backwards, because insert mode does not read keys at all.
  <kbd>Home</kbd> is <kbd>0</kbd>, <kbd>End</kbd> is <kbd>$</kbd>,
  <kbd>Space</kbd> is <kbd>l</kbd> and <kbd>Enter</kbd> is <kbd>+</kbd>, under
  the same focus gate as the arrows; everything else — <kbd>PageUp</kbd>,
  <kbd>PageDown</kbd>, <kbd>Delete</kbd>, the function keys — is handed back to
  the editor instead of being swallowed. A shifted arrow or
  <kbd>Shift</kbd>+<kbd>Home</kbd> no longer arrives as <kbd>H</kbd>,
  <kbd>M</kbd>, <kbd>L</kbd> or <kbd>)</kbd>, either.

- **A single normal-mode key registered by a plugin could not fire.** The registry
  lookup sat below that same `return true`, so it was unreachable: `/` and
  <kbd>n</kbd> from `vim-search`, <kbd>Tab</kbd> from `vim-window`,
  <kbd>m</kbd> from `vim-menu` and <kbd>M</kbd> from the manager were all dead.

- **`$` landed one column past the last character, and was not inclusive.** It
  resolved to the newline rather than to the character before it — `text.eol`
  where the header of `vimode/motions.lua` says `text.last_col` belongs, and
  where `last_col`'s own docstring already said it belonged — and it was not
  marked inclusive, which is why `d$` left the last character of the line behind.
  `|` clamped to the same off-by-one column.

- **`Ctrl`+`Shift`+`;` did not open a terminal on Windows.** `open_terminal()`
  called `system.exec("start cmd")`, and `start` is a cmd *builtin*:
  `system.exec` starts a process rather than a shell, so the loader looked for an
  executable named "start", found none, and failed without a word. Every other
  Windows call site here wraps in `cmd.exe /C`; this one now does too.

### Documentation

Every plugin in the catalog was read against its documentation, page by page,
and the pages were corrected against the code rather than the other way round.
The significant corrections, because a reader would have acted on them:

- **`autoupdate` did not use a status pill.** The page said the badge goes in
  through `core.register_status_pill` and "disappears by returning nil". It
  wraps `StatusView.get_items` and splices three cells onto the front of the
  right-hand group; it is removed by putting the original back. And dismissal is
  **one boolean, for this session** — not per-version and not persisted — so
  `autoupdate:skip-version` is a name the behaviour does not earn.
- **`modules` reported nothing on failure.** The page said a module that fails
  to require "is reported in the log next to the prompt". The error is caught,
  returned, and never read; there is a log line on the success path and none on
  the failure path.
- **`menu` short-circuits on the *first* character, not a single-character
  input.** Typing `git` runs the `g` entry and discards the rest, and the live
  filter collapses the list to that one entry and stops narrowing. The page
  stated the opposite. Four integrations extend `vim.main`, not two, and the
  `vim-menu` sections were listed wrong — there is no save, no close, no recent
  files, no terminal.
- **`search` never overwrote a binding.** The page described
  `keymap.add(MAP, true)` and a list-valued `ctrl+d`. Neither exists: `ctrl+d`
  is a plain string, and the chain is formed by `keymap.add` prepending. The
  page was describing the design as originally intended — the very failure mode
  the rest of the documentation is written to prevent. Also: the replace
  commands rewrite the **whole document**, there is no handoff from a search to a
  replace, and `find-replace:clear-highlight` silently kills `repeat-find` and
  `previous-find`.
- **`treeview` invents a read-only refusal and a per-item refresh.**
  `readonly.lua` is a badge cache — no command consults it, so rename and delete
  are not refused on a read-only checkout, and `os.remove`'s result is not even
  checked. `treeview:refresh-key` performs `treeview:refresh`, which is a **full**
  project rescan; there is no per-item refresh. `toggle-hidden` is a dotfile
  regex on a **host-wide** scanner setting, not git's answer, and hidden files
  are shown by default.
- **`git`'s API table described three functions that do not exist as documented.**
  `exe()` takes no arguments and returns the executable path; `exe_cwd()` takes
  no arguments and returns it prefixed with `-C`; `popen()` returns a captured
  string, not a handle. Detached HEAD renders as `(1a2b3c)`, not
  `(detached)`. And this plugin starts no polling thread — the only
  `core.add_thread(git.status.thread)` in the catalog is in `git-treeview`.
- **`session` documents none of its five config keys**, including
  `session_restore`, which is `false` by default — so nothing comes back on
  launch until you turn it on. And `session:show-info` prints `nil` for the path
  (see known issues).
- **`tab` has no tab bar** — it patches the status bar with a `[n/total]`
  counter. `tab:pin` only blocks `tab:close`, because `close-others` and
  `close-all` pass `force` and the guard tests `pinned and not force`.
  `tab:close` never inspects documents, so `tab:close-force` is not "close the
  dirty one anyway".
- **`window`: `close-force` does not prompt and `close-all-views` discards
  unsaved changes without asking.** Focus is geometric and does **not** wrap —
  only `focus-next`/`focus-prev` do. `maximize-*` leaves the other pane at a
  tenth of the axis, not collapsed.
- **`vim`'s `:ls` lists a directory's contents in a scratch buffer**, not open
  buffers, and `ex/tokenize.lua` has **no range support** — `:5`, `:%d` and
  `:''a,''b` are not parsed.
- **The "exactly one essential plugin" claim was in eleven places** and was
  wrong in all of them: `manager` is essential too. Corrected in
  `X/core/README.md`, `docs/writing-a-plugin.md`, `CONTRIBUTING.md`,
  `docs/getting-started.md`, `docs/extending-vim.md`, `docs/plugins/vim.md`,
  `docs/plugins/optional.md`, `X/optional/README.md`, `X/core/vim/README.md`, and
  the `tab`, `window` and `treeview` plugin READMEs.
- **The "ten `vim-*` integrations" claim was wrong** — there are seven
  `vim-*` plugins plus three that are not about vim mode. Corrected in
  `X/integration/README.md`, `docs/plugins/vim-integrations.md` and
  `docs/plugins/manager.md`.
- **`manager.md` claimed every panel key is behind a view predicate.** It is not:
  all three `keymap.add` calls are bare, and gating lives on the commands. The
  visible consequence is that **`Esc` closes the panel from anywhere in the
  editor**, because `pluginmanager:close` is one of the three persistent commands
  with no predicate. The page also referenced `make test-panel` and
  `make test-panel-view`, which do not exist.
- **`X/core/manager/README.md` said "No network".** There are 418 lines of HTTPS
  downloader in `fetch.lua` and no registered syncer. It also listed
  `cdinx/panel.lua`, a file that has not existed since the panel was split.
- **`docs/getting-started.md` sent a fresh install to the wrong keys.** It said
  <kbd>Shift</kbd>+<kbd>M</kbd> (vim-only, and only with an optional integration
  installed), that <kbd>Enter</kbd> "opens the plugin" (it is the same command as
  <kbd>Space</kbd>), and that <kbd>R</kbd> opens a plugin's README (it rescans;
  opening the README has no key).
- **`docs/installing-plugins.md`, `cdinx/README.md`, `CODEOWNERS`** all still
  described the pre-0.1.0 layout: a cloned registry, `cdinx/panel.lua`, and a
  `core/` directory that was renamed at 0.1.0.
- **`docs/plugins/optional.md`** claimed both RTL settings are applied with
  `~= false`. Only `shaping_enabled` is; `config.direction` is assigned
  unconditionally on every toggle, so the first press overwrites your setting.
- **`autocomplete`'s `api.set` takes one argument.** The page's
  `ac.set("my-language", …)` example implies a two-argument call that does not
  exist; the second argument is silently discarded and the provider registers
  empty and matching everything.

### Known issues and limitations

- **`X/manifest.lua` is stale.** `core_files` lists 20 files under `cdinx/`; the
  tree has 21. `cdinx/manager/loader.lua` — the package searcher every installed
  extension with more than one file depends on — is missing from the index,
  because `X/manifest.lua` has not been regenerated since it landed. `make
  manifest` fixes it. CI's `manifest` job would catch it; it cannot pass until
  it is regenerated.
- **The panel and the file tree still fight over the layout.** Both split
  `core.root_view:get_active_node()` — whichever pane happens to be focused — so
  whichever extension loaded second takes the layout and the result depends on
  where you last clicked. The fix (`RootView:attach_side_view`,
  `config.treeview_side`, an idempotent claim on an edge) was written and then
  **reverted** in `9828808`, because the host API it needs is not there yet.
- **`session:show-info` prints `nil` for the path.** `api.info()` returns
  `Sys.path`; `manager/sys.lua` defines `path` as a *function* and never
  assigns the field.
- **`tab:close-all` cannot close the last tab.** The last-tab check runs before
  `force` is consulted, so it always leaves exactly one and logs
  `tab: cannot close the last tab`.
- **Nothing refuses a write to a read-only project.** `readonly.lua` caches which
  paths could be opened for writing and one function reads it, to draw `"RO"`.
  `os.remove`'s return value is not checked, so a file that could not be deleted
  disappears from the tree and the UI with no message.
- **`trimwhitespace` leaves its command registered.** `unload` is empty: both the
  `Doc._before_save` hook and the `trim-whitespace:trim-trailing-whitespace`
  command survive a disable.
- **`autocomplete`'s unload does not stop its scanner.** `source.stop()` exists
  and nothing calls it, so the background thread and the `open-docs` provider
  survive.
- **`git-treeview`'s unload does not stop git's status thread.** It removes its
  badge and refresh providers and leaves `core.add_thread(git.status.thread)`
  running.
- **`X/core/autoreload/` and `X/core/trimwhitespace/` are README-only
  directories** sitting next to the single-file plugins that are the actual
  entries. No scanner sees them, they are in no manifest `files` list, and so they
  are **not downloaded** when the plugin is installed from the panel — a user
  gets the `.lua` file and no README.
- **`Manager.set_registry_syncer` is public, documented, and has no callers.**
  Nothing validates that an injected function honours the `(root, url)` contract.
- **`make list` prints 35 of the 45 catalog entries.** `plugin_entries()` never
  yields themes, so all ten themes are missing from a command four documents
  describe as "print the catalog".
- **`validate.lua` does not bound the number of essential plugins.** It fails at
  zero and fails unless there is exactly one essential *theme*; a third essential
  plugin would pass silently.
- **`psx.yml` describes a repository that no longer exists** — roughly twenty
  dead paths (`core/`, `examples/terraform/`, `docs/architecture/`,
  `docs/api/`, `docs/guides/`, `.github/workflows/build.yml`,
  `docs/INSTALLATION.md`, …). `.psx-project.yml` still says `version: "0.1.0"`
  and points `quality_command` at `make quality`, which does not exist.
- **`make fmt`, `make fmt-test` and `make check` do not exist**, though
  `.github/PULL_REQUEST_TEMPLATE.md` still offers them as checklist items. The
  real quality gate is `make validate`.
- **`scripts/load_check.lua` is referenced by a comment in `scripts/validate.lua`
  and does not exist.**
- **`syntax.add` has no `remove`,** so `unload` is empty in all six language
  definitions. Two TypeScript types (`comment2`, `special`) are emitted by
  `X/syntax/typescript.lua` and defined by **no** theme, so both render as
  `normal`.
- **`X/integration/session/theme-switcher` is versioned `0.1.0`** while every
  sibling is `0.2.0`, so `cdin-x:update` treats it as stale for no reason.

### Stability

- Every structural rule the release depends on has a static check behind it.
  The keystroke check is new and is the reason
  `ctrl+shift+alt+n` could not have shipped again.
- The bundler's output was verified against the file set cdin's
  `docs/architecture/extension-contract.md` documents, and CI compares two clean
  runs of the whole tree rather than one file.
- `contract.yml` defaults to cdin's `resplit` branch rather than `main`, because
  a `main` probe would report success by not running at all — and says so loudly
  in the step summary when it skips.

### Provenance

The `[Unreleased]` section this entry was built from described four fixes, all
of them about keystrokes and the validator. Everything under **Added** and
**Changed** above comes from the 11 commits between `v0.1.0` and this tag; the
**Documentation** section is a full read of all 16 core plugins, 10 integrations,
3 optional plugins, 6 syntax definitions and 10 themes against the pages that
describe them.

An earlier draft of this entry described `X/optional/cursor_fx/` and three
`make test*` targets. None of them exists — in the tree or in any branch's
history — so they are not carried forward.

---

## [0.1.0] — 2026-09-30

First tagged release. 13 commits, 134 files changed, +7,354 / −735.

cdin-x at this release is the **extension ecosystem** and nothing else: a plugin
catalog, an installer, a bundler that a cdin build calls, the mandatory set a
cdin build cannot start without, and the optional workflow plugins. It installs
into the editor's **site directory** and touches nothing in a cdin checkout, so
the two repositories are independent — cdin can be built and run with no
cdin-x present, and cdin-x can be installed, updated or removed without going
near the editor.

The contract cdin provides and cdin-x may rely on is written down in cdin's
[`docs/architecture/extension-contract.md`](https://github.com/m-mdy-m/cdin/blob/main/docs/architecture/extension-contract.md).
Paired release: **cdin `0.2.0-alpha.2`**, which is what bundles this.

### What a 0.1.0 install contains

| Path | What it is |
|------|------------|
| `plugins/cdin-x/` | the entry point — one site plugin whose `init()` starts the manager |
| `cdinx/` | the manager: catalog, deps, registry, lifecycle, runtime, state |
| `X/core/` | 15 capability plugins |
| `X/integration/` | 4 integrations — `vim` (the ten `vim-*` capabilities), `session`, `tab-session`, `git-treeview` |
| `X/optional/` | 3 plugins the user installs deliberately: `rtl_toggle`, `theme_switcher`, `unicode_inspect` |
| `X/syntax/` | 6 language definitions: `c`, `javascript`, `lua`, `markdown`, `python`, `typescript` |
| `X/themes/` | 10 themes, one directory each: `<name>/theme.lua` |
| `fonts/` | 5 fonts + 2 licences — 7 files, and a cdin build without them cannot start |
| `scripts/` | `bundle.py`, `install.py`, and `validate.lua`, `generate-manifest.lua`, `new-plugin.lua`, `plugin-list.lua`, `_scan.lua` |
| `docs/`, `examples/` | documentation, and three complete plugins to copy |

### ⚠️ BREAKING CHANGES

#### cdin-x is installed into a site directory, and its manager is `cdinx`

cdin-x no longer installs *into* a cdin tree. It installs into the editor's
**site directory** — `config.site_path()`, default
`<data_home>/cdin/site` — and nothing in a cdin checkout is touched. That makes the
two repositories independent: cdin can be built and run with no cdin-x present, and
cdin-x can be installed, updated and removed without going near the editor.

- **`core/` is now `cdinx/`.** `require "core.x.<m>"` becomes
  `require "cdinx.<m>"`. The field the bootstrap publishes on the host's
  `core` table is now `core.cdinx`, not `core.x`.
- **`plugins/cdin-x/` is the entry point.** It is installed as a site plugin,
  so the host's own loader finds it, and its `init()` is the single call that
  starts the manager. It does not touch `package.path`: the host has already
  appended the site roots by the time a plugin's `init()` runs.
- **Install with `make install` / `make link`** (or `scripts/install.py`),
  which copy or link exactly three directories — `cdinx/`, `X/`,
  `plugins/cdin-x/` — and write nothing else. `make uninstall` removes them.
  `scripts/install.sh` is replaced by `scripts/install.py` (stdlib, so it runs
  on Windows without a POSIX shell).
- **No `EXEDIR`, no sibling lookup, no assumptions about cdin's tree.**
  `builtin_root()` is `config.site_path()/X`; the registry root is
  `config.registry_dir/X`, overridable with `config.registry_dir` or
  `CDIN_X_REGISTRY`; the site root can be overridden with `CDIN_SITE_DIR`.
- **Host-provided plugins.** A cdin build ships vim, and the host loads it
  before any site plugin runs. The manager collects the host's
  `core.plugins.loaded` at bootstrap and treats those names as *provided*: they
  satisfy a declared dependency but are never loaded a second time. A plugin's
  load guard is per module instance, and the host `dofile`s the entry point
  while a `require`d integration `dofile`s it again, so a second load would
  re-run every registration and collide with itself.
- **Themes are directories again**: `X/themes/<name>/theme.lua`, the layout the
  host's theme registry reads. The catalog recognises the `themes` category
  explicitly, because the generic rules would misread a theme directory
  several different ways.
- **`X/core/cdin_x_bundle.lua` is deleted.** Its only job was to mark the
  built-in bundle as present, and the manifest it marked is generated.
- **`cdinx/preboot.lua` is deleted.** It duplicated the host's pre-boot state
  reader; the session plugin already uses the host's.
- **The essential set is what a cdin build bundles, and nothing else**: the
  `vim` plugin, the `default` theme, and the fonts. An essential plugin must be
  self-contained, because the bundle contains that plugin alone — `make
  validate` checks this.
- **All ten `X/themes/*.lua` files became directories** (`<name>/theme.lua`),
  which is the layout `core.themes` reads and the layout
  `themes.add_root()` can be pointed at.

### Added

#### `scripts/bundle.py` — what a cdin build consumes

Reads a checkout and writes **real copies**. No network, no fetch, no
substitute. Idempotent: a second run over the first run's output is
byte-identical. It refuses to write *through* a symlink or junction, and it
refuses to substitute anything for the fonts — a build with no fonts cannot
start, and silently shipping a substitute would be worse than not shipping.

Verified output of `python3 scripts/bundle.py --out <dir>` on this release:

```
X/core/vim/**            verbatim copy of the vim plugin, whole subtree
plugins/vim.lua          one line: return require("X.core.vim")
themes/default/theme.lua the essential theme
fonts/**                 5 fonts + 2 licences
BUNDLE.lua               { plugins = { "vim" }, themes = { "default" } }
```

The `plugins/<name>.lua` shim is what the host's loader finds, since it walks
`data/plugins` for entry points and the plugin itself lives under `X/`. The
`X.*` namespace is preserved so `require "X.core.vim"` resolves the same way in
a bundle and in a site install.

#### Optional workflow plugins

Three of cdin's commands were runtime commands and are now ordinary, non-essential
plugins under `X/core/`. None is in the bundle, and a vim-only build stays usable
through vim's Ex commands — `:e`, `:w`, `:q`, `:new`, `:cd` — with none of them
installed.

| Plugin | Provides | Keys |
|--------|----------|------|
| `palette` | `core:find-command` | `ctrl+shift+p` |
| `finder` | `core:find-file`, `core:open-file`, `core:open-folder` | `ctrl+p`, `ctrl+o`, `ctrl+shift+o` |
| `modules` | `core:reload-module`, `core:open-user-module`, `core:open-project-module` | none; use the palette |

The host invokes these by name in one place — the empty view — through
`command.perform`, which returns false and does nothing for a name nothing
registered. That is deliberate: a missing optional command is a silent no-op, not
an error.

#### The registry syncer is a hook, and the git plugin provides it

`cdinx/manager/registry.lua` will pull or clone the catalog, and it refuses to
know that git exists. It asks for a syncer instead, and the git plugin injects
one: `M.sync_registry` in `X/core/git/manager/ops.lua`, registered through
`manager.set_registry_syncer` in the plugin's `register()`.

Fetching a repository is a git operation, so it lives with the git code rather
than in a manager that would otherwise have to `require` a capability the editor
itself is unaware of. `sync_registry(root, url)` derives the checkout with a
separator-safe parent join — a bare `..` after a trailing separator is a no-op on
some platforms — probes for an existing checkout with `rev-parse --git-dir`, and
then either `pull --ff-only` or `clone --depth 1`. It returns `true`, or `false`
plus a reason.

**With the git plugin absent, "Refresh Catalog" reports that the syncer is
unavailable** rather than quietly doing nothing and leaving the reader to wonder
whether the catalog is stale.

#### The Makefile

There was no build here — cdin-x is Lua and data — and no Makefile at all. There
is one now, and its targets install, link and check rather than compile:

| Target | What it does |
|--------|--------------|
| `make install` | copy `cdinx/`, `X/` and `plugins/cdin-x/` into the site directory |
| `make link` | the same three, symlinked, for development |
| `make uninstall` | remove them again |
| `make bundle DEST=…` | the mandatory set, for a cdin build to consume |
| `make validate` | structural checks over the catalog |
| `make manifest` | regenerate `X/manifest.lua` |
| `make list` | print the catalog |

`SITE=` overrides the site directory by full path, `SITE_NAME=` overrides only its
*name*, and `PYTHON=` / `LUA=` pick the interpreters. Only one of the two is passed
to `install.py`, so a full path and a name can never disagree.

#### `make validate` grew the checks that matter

Beyond the required files, the theme layout and the dependency rules, validation
now covers the things that are cheap to get wrong and expensive to debug at
runtime — and two of them fail silently rather than loudly, which is the whole
reason to check statically:

- **No `EXEDIR`, and no `core.x` namespace**, anywhere under `cdinx/` or `X/`.
  `EXEDIR` is a global the host defines as the directory the binary lives in;
  depending on it assumes a cdin install layout, which is exactly what cdin-x
  must not assume. A leftover `require "core.x.…"` resolves to nothing on a host
  that has no such module and fails at load time rather than build time. Only
  code is checked, and `--` comments and string literals are stripped first, so a
  line that merely *mentions* either word is not a failure.
- **Every essential plugin is self-contained.** The bundler copies one essential
  plugin and its own files with no other plugin alongside it, so an essential
  plugin that requires another `X` plugin bundles into something that cannot
  load. This is not a style rule — it is the property that makes the bundle
  valid, and it cannot be checked any other way, because the failure only appears
  in a built cdin.
- **The `register` / `unregister` seam.** A plugin that calls
  `require("…").register()` on a module that defines no such function loads, does
  nothing, and reports nothing: the manager's `pcall` around `init()` only
  catches a *raise*, and the resulting `attempt to call a nil value` is one line
  among forty in a log nobody opens. Both shapes are checked — the call must name
  a function, on the entry point or on a sibling it requires — and the pair must
  be symmetric. It is static, not a load: it cannot see a nil field two levels
  deep in someone's own module.
- **The bundle itself.** The one check that exercises the real code path.
  `scripts/bundle.py` is run and its output compared against the exact file set a
  cdin build is entitled to find — run twice, so the artifact is *checked* rather
  than assumed. Everything else above is a statement about the source; this one
  is a statement about the thing that ships.

Resolving the `register` seam reads the table an `init.lua`'s `register()` call
resolves to **without running it**: `dofile` would execute the body, and a
top-level `require` in a manifest-carrying file is a catalog hazard that
validation must not itself trigger.

#### `examples/` — three complete, installable plugins

`01-hello` (a command and a key), `02-word-count` (a document reader with a
status-bar pill) and `03-vim-word-count` (a vim integration). Each is a plugin
that actually installs, meant to be copied rather than read.

### Changed

- **`X/manifest.lua` is regenerated from `cdinx/` and the new theme layout.** It is
  written with explicit CRLF, as it always was, but *deterministically* — in text
  mode the same checkout produced two different files depending on the platform.
- **`scripts/new-plugin.lua` scaffolds the inline-manifest form** every current
  plugin uses, rather than a separate `manifest.lua`.
- **Documentation is split by what you are trying to do.** `docs/` now holds
  four documents that were previously scattered across the root README and the
  per-directory ones: [getting-started](docs/getting-started.md),
  [installing-plugins](docs/installing-plugins.md),
  [writing-a-plugin](docs/writing-a-plugin.md) and
  [extending-vim](docs/extending-vim.md).
- **Directory READMEs are introductions again.** `X/README.md`,
  `X/integration/README.md` and the plugin READMEs are now two or three
  paragraphs: what this directory is, and where the detail lives. The long
  analyses they carried — the `fs.list` trap, the `menu.extend` load-order trap,
  the `register()` asymmetry — are either in the new documents or, where they were
  a warning about a specific line of code, in that line's comment, which is where
  somebody hitting it at two in the morning will actually look.
- **`README.md` rewritten** to lead with the three commands that matter —
  `make install`, `make validate`, `make bundle` — instead of the repository's
  history.

### Fixed

Two from the split itself:

- **`config.site_dir` is no longer read as a path.** cdin now exposes
  `config.site_path()`, a resolver, and the name of the directory is a single
  knob — `config.site_dirname`, default `"site"`. cdin-x reads the host's
  resolver instead of computing a path of its own, so renaming the site
  directory in a user's `init.lua` renames it for both halves at once. Before
  this, the literal `"site"` was hardcoded in three independent places and
  changing one did nothing to the other two.
- **`make install` gained `SITE_NAME`.** `make link SITE_NAME=extensions`
  mirrors `config.site_dirname`; a full `SITE=` path still wins. cdin's
  `make test-site-dir` compares the two constants so they cannot drift apart
  silently.

Eight found while verifying the split — not introduced by it, and the last three
were listed as known issues in `X/integration/README.md`:

- **`tab-session` never loaded.** Its `init()` called `register()` on
  `X/integration/tab-session/session.lua`, which returned a table with only
  `save`/`restore` on it — the subscription, the command and the restore
  thread were wired up as *require-time side effects* and there was no
  `register` to call. The manager's `pcall` swallowed the resulting
  `attempt to call a nil value` and the integration simply never appeared.
  `session.lua` now has the `register`/`unregister` seam every other
  integration uses, which also means `unload()` can actually undo the
  subscription instead of leaving a second one behind.
- **`autocomplete` never loaded.** `api.lua` called
  `suggest.refresh_providers(providers)`, which did not exist on `suggest`.
  Added, and implemented by calling `update()` rather than duplicating the
  matching rules.
- **The autocomplete suggestion list only ever held one entry.**
  `suggest.update` filled `suggestions[i]` for `i = 1…max` while its inner
  dedup loop advanced only the *input* cursor `j`, so the same output slot was
  written `max_suggestions` times. Rewritten as a `while` that advances both
  counters, so a run of equal items collapses onto one entry and the next
  item lands in the next slot.
- **`vim-plugin-manager` could load before the menu it extends.** It called
  `menu.extend("vim.main", …)`, which asserts the menu exists, and `vim-menu`
  is what defines it — but the manifest declared only `{ "vim", "menu" }`, so
  nothing ordered them. The catalog is walked with `pairs()`, so the failure
  was intermittent: some runs raised `menu is not defined: vim.main`. It now
  declares `vim-menu`, and the manager's topological sort guarantees the
  order. Verified both ways: with the dependency `vim-menu` sorts first,
  without it `vim-plugin-manager` lands four plugins ahead.
- **`core:open-folder` offered no directories at all.** `suggest_dirs` read
  `entry.type` and `entry.name` off the result of `system.list_dir`, which
  returns an array of *names* — so every entry looked like a file and the
  prompt opened empty, with nothing logged. It now goes through
  `core.fs.list`, which stats each entry and does return the type. This was
  introduced by the move, not inherited: the pre-split runtime had no
  `core:open-folder` definition at all, only the empty view's call to it.
- **`X/core/modules` called `core.reload_module` on a global `core`, and
  `core` is not a global** — the runtime raises on undeclared globals
  (`core.runtime.strict`), so reloading a module that failed to require
  produced `cannot get undefined variable: core` instead of the reason it
  failed. The helper now takes the `core` table `register()` already requires.
- **`:ls` (and `:help`, `:!cmd`, `:net`) left their output behind as "unsaved
  changes", so quitting afterwards asked to discard work that was never
  done.** Each of them built a scratch document, filled it with generated
  text, and then only *renamed* it:

  ```lua
  function doc:get_name() return "ls " .. path end
  ```

  `text_input()` had already moved the undo index, so the document stayed
  dirty forever, had no filename to save to, and the next `:q` counted it —
  and named it. All four now call `doc:clean()` after filling the buffer,
  which is the runtime's own way of saying "this document is not modified". A
  genuine edit is still protected: the fix is not "never ask".
- **vim mode was silently off, and looked like "vim is not loaded".**
  `X/core/vim/init.lua` declared its default (`M.config = { vim_mode_enabled =
  true }`) but never applied it, and nothing in the runtime copies `M.config`
  onto `config`. Every gate in vim mode tests `if not config.vim_mode_enabled
  then return false end`, so with the value left nil the key handler bailed on
  the very first keystroke. The only way to turn it on was
  `vim:toggle-mode` — i.e. `ctrl+alt+v` — which read exactly like "this plugin
  needs activating by hand". The default is now applied in `init()`, guarded
  with `== nil` so a user who set it in their `~/.config/cdin/user/init.lua`
  still wins. `ctrl+alt+v` remains as the manual toggle.
- **`X/core/treeview` overwrote the user's config.** `config.treeview_size` and
  `config.show_hidden_files` were assigned unconditionally at load, so a
  setting the user could see working in their own file was silently replaced
  with the default. Both are guarded with `== nil` now, matching how
  autocomplete and tab-session already did it.

### Documentation

- **One page per plugin**, in [docs/plugins/](docs/plugins) — 18 files. Each says
  what the plugin does, what you press, and how it works; the third half being the
  reason a rule exists rather than a restatement of it. Sixteen capability pages,
  one covering the three optional plugins, and one for the ten `vim-*`
  integrations.
- **Three "how to make one" guides**, in [docs/building/](docs/building):
  [an integration](docs/building/an-integration.md) with a complete worked
  example, [a theme](docs/building/a-theme.md) listing every colour the editor
  has and what each one is for, and
  [a syntax definition](docs/building/a-syntax-definition.md) for highlighting
  a language.
- **`CONTRIBUTING.md` rewritten** (176 lines) around what a plugin author
  actually needs to know before their first pull request.
- **The directory READMEs stay introductions** and gained one line each,
  pointing at the page about that plugin. The line is the only reason a reader
  who lands in `X/core/search/` can find the documentation at all.

Five claims the first drafts made were wrong, and the code is what they are
being corrected against:

- Search has **no prefix syntax** — no `/`, `c/` or `r/`. There is no
  case-sensitive mode; `no_case = true` is set on both search commands and
  nothing reads it back. "Pattern" is a separate *command*, not a prefix.
- The menu filter is a **plain substring**, matched against an entry's label
  and its hint text. The palette is the fuzzy one. A single letter is checked
  as a key *before* it is treated as filter text, so a shortcut does win.
- Menu **context providers do not combine**. The highest-priority provider that
  returns something wins and the rest are not called; `menu.spec.context` is
  the fallback. A provider that never returns `nil` has taken the context away
  from everybody.
- The palette **hides** commands whose predicate does not hold
  (`get_all_valid()` filters), and it is fuzzy — it does not grey them out.
- vim mode has **no page-scrolling movement** and **no `.` to repeat** the last
  change. Its motion set is eight keys, declared as data in
  `vimode/motions.lua`; `r` is redo, not replace. A number typed before a
  command is buffered, and only `gt` / `gT` consume it, so `3gt` is the third
  tab and `3x` is one character.

Two more that only bite someone rebinding a key:

- Arrow strokes are **named, not drawn**: `alt+left`, not `alt+←`. The two
  splits are `ctrl+\` and `ctrl+shift+\`, with a literal backslash.
- `syntax.add` **appends, and the lookup walks backwards**, so the last
  definition registered wins. A second `add` for the same extension silently
  replaces the first. There is no `syntax.remove`, which is why `unload` is
  empty in all six language definitions.

**Three documentation bugs fixed, not carried forward.**
`X/core/search/README.md` described a `manifest.lua` inside the plugin, which
stopped existing when manifests moved inline into `init.lua`. `X/core/tab`,
`treeview` and `window` claimed to be part of the built-in set and
un-uninstallable — only `vim` and the `default` theme are `essential`, and
all three are ordinary optional plugins. The three `X/optional/` READMEs said
in the same breath that their plugin "is loaded only when installed" and that
"essential extensions cannot be removed".

**A dangling reference resolved.** `X/integration/README.md` pointed at
`X/core/vim/README.md` for "the full table of extension points and a worked
example". That file was five lines and had no table. It is
[docs/extending-vim.md](docs/extending-vim.md) now.

### Known issues and limitations

- **Bundled vim and site-installed integrations can come from different cdin-x
  versions**, and there is no version negotiation — cdin's `make bundle` reads
  whatever `CDINX_DIR` points at, and the installed site set is whatever the user
  installed. The compatibility surface between them is `X.core.vim.registry`: an
  integration that uses its documented extension points works across the gap, one
  that reaches into a vim module's internals does not. This is the one known
  limitation, and it is written down on both sides.
- **"Refresh Catalog" needs the git plugin.** The manager asks for a syncer and
  this release only ships one in `X/core/git`. With it absent, refresh reports
  that the syncer is unavailable rather than pretending to succeed. A syncer for
  any other transport is a drop-in: implement `sync_registry(root, url)` and pass
  it to `manager.set_registry_syncer`.
- **There is no CI.** `.github/workflows/` is empty, so `make validate` runs
  nowhere automatically. Nothing in this repository is checked on push.
- **`make fmt`, `make fmt-test` and `make check` do not exist**, though
  `.github/PULL_REQUEST_TEMPLATE.md` still offers them as checklist items. The
  Makefile's real quality gate is `make validate`.
- **`scripts/load_check.lua` is referenced by a comment in `scripts/validate.lua`
  and does not exist.** The static seam check says so itself — it cannot see a
  nil field two levels deep in someone's own module — and the load check it points
  at was never written.
- **`syntax.add` has no `remove`,** so `unload` is empty in all six language
  definitions. Redefining an extension replaces the previous definition (the
  lookup walks backwards); removing one is not possible.

### Stability

- Every rule the split depends on has a static check behind it, and each was
  verified by reintroducing the original defect and confirming the failure.
- The bundler's output was verified against the file set cdin's
  `docs/architecture/extension-contract.md` documents, and is byte-identical on a
  second run.
- cdin `0.2.0-alpha.2`'s `make test-workflows` boots the real loader against a
  cdin-x checkout and asserts that `palette`, `finder` and `modules` register
  their commands, that `ctrl+p` / `ctrl+shift+p` / `ctrl+o` / `ctrl+shift+o` each
  have **exactly one** command bound to them, and that unloading the three through
  the manager detaches both the commands and the strokes. Run it before tagging a
  paired release.

### Provenance

The `Added (initial)`, `Structure` and `Technical` lists that used to sit at the
end of `[Unreleased]` described the repository **before** this split, and several
of their claims no longer hold: `core/` is `cdinx/`, `scripts/install.sh` is
`scripts/install.py`, manifests moved inline into `init.lua`, and the
`X/lsp/`, `X/formatters/`, `X/git/`, `X/debug/`, `X/ui/` and `X/utils/` category
directories are not in the tree. They have been replaced by the layout table at
the top of this entry rather than carried forward.
