#!/usr/bin/env python3
"""Produce the bundle a cdin build needs, from a named bundle.

    python3 scripts/bundle.py --out <DEST_DATA_DIR> [--bundle <name>]

A cdin checkout contains only its runtime. What a build gets from cdin-x is
decided by a bundle -- a named list of packages in bundles/<name>.lua -- and by
nothing else. No package is essential; `--bundle empty` is how a build says it
wants nothing from this repository, and the default is `standard` because
cdin's build calls this with --out and nothing else.

    <DEST>/cdinx/**               the kernel, verbatim
    <DEST>/plugins/cdin-x.lua     the kernel's entry point -- the only shim
    <DEST>/packages/<name>/**     every package in the closure, verbatim
    <DEST>/themes/<t>/**          every theme in the closure
    <DEST>/<support>/**           every `bundle_with` path a member declares
    <DEST>/fonts/**               copy of this repository's fonts/
    <DEST>/BUNDLE.lua             return { plugins = {...}, themes = {...} }

Why one shim and not one per package: the host's plugin loader looks in one
bundled directory and dofile()s every entry point it finds there, so anything in
<data>/plugins is loaded unconditionally and cannot be taken off. Putting a
package there therefore makes it permanent, which is exactly what this layout
exists to stop -- `vim` is in the default bundle and a user must be able to turn
it off. The build's packages go to <data>/packages instead, which the host never
looks at; the kernel reads it and loads each entry like any other package, so
turning one off is a row in the panel.

The kernel still needs a shim, because the host has to be told to load it, and
the module it shims is read out of plugins/cdin-x/init.lua rather than written
here, so the site install and a build cannot drift apart.

`bundle_with` is the same problem one level up. A package may have code that
does not live under `packages/`: declaring `bundle_with = { "some/dir" }` copies
those paths into the destination with their layout intact, so `require "some.dir"`
resolves from <DEST>/ exactly as it does from a checkout. The bundler does not
guess at this: an undeclared dependency is a build whose editor starts and then
does nothing, which is not a failure anyone should have to debug at runtime.

The closure is the bundle's `includes`, plus every `dependencies` entry any of
them declares, plus what they declare in `bundle_with`. Bundles may include other
bundles. An `includes` entry that is not in the tree stops the build; an
`optional` entry that is missing is a warning, because it is optional.

Every manifest and bundle file here is read as text, never executed. One can
call functions, read the clock, or raise; none of that is acceptable in a build
step that only needs to know which files to copy. Anything this reader does not
recognise stops the build rather than being guessed at.

Stdlib only, Python 3.8+, no network, no imports from cdin.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import sys
from pathlib import Path
from typing import Dict, List, NoReturn, Optional, Sequence, Tuple, TypedDict

# Repository layout, in one place: the kernel, the first-party catalog and the
# bundles that name a subset of it.
#
# CATALOG_ROOTS is a list because every caller walks it, and a collection whose
# shape changes when a second root is added is a collection every caller has to be
# re-read after. One root since Phase 9 removed `X/`.
# PACKAGES_DIR is where a package lands in a *build* -- flat, under its own name,
# because a build carries a named set rather than a tree and the kernel reads that
# root as an ordinary catalog source.
KERNEL_DIR = "cdinx"
CATALOG_ROOTS = ("packages",)
PACKAGES_DIR = "packages"
# Directories this script used to write into a build and no longer does. They are
# still cleared, and that is the point of the list: a build directory outlives the
# script version that made it, so a stale copy of a package under `X/` would be
# picked up by the catalog scanner of any editor opened on that build. Phase 9 made
# `X/` a root nobody scans, which is what turns "cleared" from tidiness into the
# thing that makes an old build safe to open.
RETIRED_DIRS = ("X",)
# Where a theme lands in a build. Not ours to choose: the host reads
# <data>/themes/<name>/theme.lua and cdin's extension contract says so.
THEME_DIR = "themes"
BUNDLE_DIR = "bundles"
FONT_DIR = "fonts"

# The entry the site install uses, and the flat shim a build gets instead. The
# module name is read out of the first, so the two cannot drift apart.
SITE_ENTRY = "plugins/cdin-x/init.lua"
KERNEL_SHIM = "plugins/cdin-x.lua"

# What a build gets when it names no bundle. cdin's assemble_data.py calls this
# script with --out and nothing else, so the default is not optional: it is the
# set an editor has to have to be usable.
DEFAULT_BUNDLE = "standard"

# What a package installs when it says nothing. `package.lua` first, because a
# selection without it is not a package; `LICENSE*` and `NOTICE*` because shipping
# someone's code without their licence text is not a style question. The Lua twin
# of both lists is cdinx/manager/select.lua, and validate.lua runs the two over
# every first-party package and fails if they disagree.
DEFAULT_FILES = ["package.lua", "**/*.lua", "LICENSE*", "NOTICE*", "README.md"]
DEFAULT_IGNORE = ["test/**", "tests/**", "spec/**", "**/*_spec.lua",
                  "**/*_test.lua", "examples/**", "docs/**", ".*/**"]

# `return require("X.core.manager")`, which is the whole of the site entry.
ENTRY_MODULE_RE = re.compile(r'return\s+require\s*\(?\s*"([^"]+)"')

QUOTED_RE = re.compile(r'"([^"]*)"|\'([^\']*)\'')

# Lua comments: --[[ ... ]] blocks, --[==[ ... ]==] blocks, and -- to EOL.
# A string containing "--" would be mangled by the second pass; no manifest or
# bundle file in this tree puts one before its fields, and the cost of a false
# negative is a loud error rather than a silent wrong bundle.
_BLOCK_COMMENT_RE = re.compile(r"--\[(=*)\[.*?\]\1\]", re.DOTALL)
_LINE_COMMENT_RE = re.compile(r"--[^\n]*")

# A manifest is a table inside a file that may also be code, so a field is only
# read where a line starts with it. A bundle file is pure data with no code in
# it, so the same fields are read anywhere: a one-line bundle is still a
# bundle. `anchored` is that difference and nothing else.
NAME_RE = r'name\s*=\s*"([^"]+)"'
# Unanchored, like the bundle fields: a package's manifest is data with code
# beside it, so this matches anywhere on a line. It only decides where the
# package's files land in the bundle, so a false positive costs a wrong
# directory, not a wrong copy -- and `check.lua` compares this against the same
# field read by Lua.
CATEGORY_RE = r'category\s*=\s*"([^"]+)"'
KIND_RE = r'kind\s*=\s*"bundle"'
# `fonts = false`: the only way a build says it wants no bundled fonts. Anything
# else, including the field being absent, means the fonts go in.
FONTS_RE = r'fonts\s*=\s*(false|true)'


class Package(TypedDict):
    """One catalog entry the bundler can copy."""

    name: str
    kind: str  # "plugin" or "theme"
    root: Path  # the directory to copy, or the one .lua file it is
    rel: str  # its path under its catalog root, forward slashes
    single_file: bool  # True when root is one .lua file rather than a directory
    category: str  # its declared category, else the directory it sits in
    dependencies: List[str]
    bundle_with: List[str]


class Bundle(TypedDict):
    """A named list of packages, as bundles/<name>.lua declares it."""

    name: str
    includes: List[str]
    optional: List[str]
    fonts: bool  # False only when the bundle says `fonts = false`


def is_link(path: Path) -> bool:
    """True for a symlink, a junction, or any other reparse point.

    os.path.islink is false for a Windows junction, and a junction is
    exactly as dangerous here: it redirects writes to another tree. Any
    reparse point is treated as a link — unlinked, never traversed. Erring
    that way is safe because only entries this script owns are ever tested.
    """
    if os.path.islink(path):
        return True
    if sys.platform == "win32":
        try:
            st = os.lstat(path)
        except OSError:
            return False
        return bool(getattr(st, "st_file_attributes", 0) & 0x400)
    return False


def _force_utf8_stdio() -> None:
    """Let the status lines print on a Windows console.

    Python defaults stdout to the ANSI code page, which is cp1252 on most
    Western installs and cannot encode the tick below. A build step that
    dies on its own success message is worse than one that prints a box.
    """
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass


def die(message: str) -> NoReturn:
    print("✗ " + message, file=sys.stderr)
    sys.exit(1)


def warn(message: str) -> None:
    print("⚠ " + message)


def ok(message: str) -> None:
    print("✓ " + message)


def read_text(path: Path) -> str:
    """The file as text, or a build that stops with the reason."""
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        die("cannot read {}: {}".format(path, exc))


def strip_lua_comments(src: str) -> str:
    return _LINE_COMMENT_RE.sub("", _BLOCK_COMMENT_RE.sub("", src))


def find(src: str, pattern: str, anchored: bool):
    """The first match of a `field = "value"` pattern, or None."""
    prefix = r"^\s*" if anchored else r"\b"
    return re.search(prefix + pattern, src, re.MULTILINE)


def string_list(src: str, field: str, anchored: bool = True) -> List[str]:
    """The quoted strings in `field = { ... }`, or [] when it is absent.

    Read as text for the same reason the manifest is: a build step that
    executes a package to learn what to copy has run the package.
    """
    match = find(src, field + r"\s*=\s*\{([^}]*)\}", anchored)
    if not match:
        return []
    out = []
    for dquoted, squoted in QUOTED_RE.findall(match.group(1)):
        item = (dquoted or squoted).strip()
        if item not in out:
            out.append(item)
    return out


def read_manifest(path: Path) -> Dict[str, object]:
    """name / category / dependencies / bundle_with, read from a manifest as text.

    `category` is read because it decides where a package lands in the bundle,
    and a package that declares one must land where it says: the panel groups it
    by that value, and a build that put it somewhere else would produce a data
    tree whose layout disagrees with what the editor says about the same package.
    """
    src = strip_lua_comments(read_text(path))
    match = find(src, NAME_RE, True)
    if not match:
        die("{}: no `name = \"...\"` at the start of a line. A build reads "
            "manifests as text, so that is the only place a name can come from."
            .format(path))
    category = find(src, CATEGORY_RE, False)
    return {
        "name": match.group(1),
        "category": category.group(1) if category else None,
        "dependencies": string_list(src, "dependencies"),
        "bundle_with": string_list(src, "bundle_with"),
    }


def manifest_file(root: Path) -> Optional[Path]:
    """The file carrying a directory package's manifest, or None.

    `package.lua` first: a package that ships one keeps its manifest out of
    `init.lua`, and a build that only looked for the other two would find
    nothing to read a name from.
    """
    for name in ("package.lua", "manifest.lua", "init.lua"):
        candidate = root / name
        if candidate.is_file():
            return candidate
    return None


def add_package(
    catalog: Dict[str, Package],
    root: Path,
    rel: str,
    kind: str,
    single_file: bool,
    manifest: Path,
    domain: str,
) -> None:
    meta = read_manifest(manifest)
    name = str(meta["name"])
    if name in catalog:
        die("two packages declare the name '{}': {} and {}"
            .format(name, catalog[name]["rel"], rel))
    catalog[name] = Package(
        name=name,
        kind=kind,
        root=root,
        rel=rel,
        single_file=single_file,
        # A declared category wins over the domain directory it sits in, because
        # that is where the panel says it belongs; the directory is only the
        # fallback, and only for a package that states none.
        category=meta["category"] or domain,  # type: ignore[index]
        dependencies=list(meta["dependencies"]),  # type: ignore[arg-type]
        bundle_with=list(meta["bundle_with"]),  # type: ignore[arg-type]
    )


def scan_dir(base: Path, rel: str, catalog: Dict[str, Package]) -> None:
    """One domain directory of a catalog root, descending through groupings.

    A directory that carries a manifest is a package and is not descended into;
    a directory that does not is a grouping directory. Same rule the runtime
    scanner uses, so the bundler and the editor agree on what a package is.
    """
    for item in sorted(base.iterdir(), key=lambda p: p.name):
        if is_link(item):
            continue
        sub_rel = "{}/{}".format(rel, item.name)
        if item.is_dir():
            theme = item / "theme.lua"
            manifest = manifest_file(item)
            if theme.is_file() and manifest is None:
                add_package(catalog, item, sub_rel, "theme", False, theme, rel)
            elif manifest is not None:
                add_package(catalog, item, sub_rel, "plugin", False, manifest, rel)
            else:
                scan_dir(item, sub_rel, catalog)
        elif item.suffix == ".lua":
            add_package(catalog, item, sub_rel, "plugin", True, item, rel)


def scan_catalog(root: Path) -> Dict[str, Package]:
    """Every package in this checkout, keyed by the name it declares."""
    if not any((root / r).is_dir() for r in CATALOG_ROOTS):
        die("none of {} under {} — is --cdinx-root pointing at a cdin-x checkout?"
            .format(" or ".join(CATALOG_ROOTS), root))
    catalog: Dict[str, Package] = {}
    for root_name in CATALOG_ROOTS:
        catalog_root = root / root_name
        if not catalog_root.is_dir():
            continue
        # `rel` is relative to the root, so a package found under either root has
        # the same identity. The destination no longer depends on it: a build is
        # flat, and a package's name is where it lands.
        for domain in sorted(catalog_root.iterdir(), key=lambda p: p.name):
            if domain.is_dir() and not is_link(domain):
                scan_dir(domain, domain.name, catalog)
    return catalog


# ── the file selection ────────────────────────────────────────────────────
#
# The Lua twin is cdinx/manager/select.lua. The grammar is duplicated here because
# the bundler cannot run Lua, and the two are kept in step by a rule in
# validate.lua that runs both over every first-party package and fails if they
# disagree. A divergence is a build that ships a file the editor would not have
# installed, or the reverse -- and neither is visible until a user reports it.
#
# The grammar is deliberately the smallest one that covers a package: literal
# names, `*` (no `/`), `**` (any depth, as a whole segment), `/` as the separator.
# `**/` compiles to two alternatives -- zero directories, or one or more -- because
# a regex has no "optional group" that a Lua pattern can express, and the two
# implementations have to agree on the same paths.

# What a regex gives a meaning to, so a literal glob character can be escaped.
#
# A plain string, not a compiled character class: a class written to contain `[` is
# parsed by Python 3.7+ as a *nested* set, which changes what it matches -- it
# stopped matching `.` entirely, so `**/*.lua` compiled to a pattern that matched
# `xluax` as well as `x.lua`. Membership in a string cannot be misparsed.
_REGEX_MAGIC = "\\^$.|?*+()[]{}"


def _literal(char):
    return "\\" + char if char in _REGEX_MAGIC else char


def expand_glob(glob):
    """One glob -> a list of regex patterns, or None plus a reason.

    A list, for the same reason the Lua version returns a list: `**/` means "zero
    or more directories", and the only way to say that in both languages is two
    patterns that are each obviously right.
    """
    if not isinstance(glob, str) or glob == "":
        return None, "a glob must be a non-empty string"
    if "\\" in glob:
        return None, "{} uses backslashes; a `files` glob always uses '/'".format(glob)
    if glob.startswith("/"):
        return None, "{} is not relative to the package root".format(glob)
    if glob.endswith("/"):
        return None, "{} ends with '/', which names no file".format(glob)
    if "//" in glob:
        return None, "{} has an empty path segment".format(glob)
    for segment in glob.split("/"):
        if segment == "..":
            return None, "{} climbs out of the package".format(glob)
    if any(ord(c) < 32 for c in glob):
        return None, "{} contains a control character".format(glob)

    alternatives = [""]
    i, n = 0, len(glob)
    while i < n:
        char = glob[i]
        if char == "*":
            if i + 1 < n and glob[i + 1] == "*":
                before_ok = (i == 0) or (glob[i - 1] == "/")
                after = glob[i + 2] if i + 2 < n else ""
                if not (before_ok and after in ("", "/")):
                    return None, "{} puts '**' inside a path segment".format(glob)
                if after == "/":
                    alternatives = alternatives + [p + ".*/" for p in alternatives]
                    i += 3
                else:
                    alternatives = [p + ".*" for p in alternatives]
                    i += 2
            else:
                alternatives = [p + "[^/]*" for p in alternatives]
                i += 1
        else:
            alternatives = [p + _literal(char) for p in alternatives]
            i += 1

    # Two values always, success or failure, so a caller can write
    # `patterns, err = expand_glob(g)` without a special case for the good path.
    # The Lua twin answers the same way.
    return ["^" + p + "$" for p in alternatives], None


def _compiled(globs):
    out = []
    for glob in globs:
        patterns, err = expand_glob(glob)
        if err:
            return None, err
        out.extend(patterns)
    return out, None


def _forbidden(relpath):
    """.git at any depth, whatever the globs say."""
    return ".git" in relpath.split("/")


def select_files(root, files=None, ignore=None):
    """The files of one package that would be installed, as relative paths.

    `root` is a directory on disk. Symlinks are never selected and never followed:
    copying one would either duplicate its target or pull in something from outside
    the repository, and the selection is of the repository.
    """
    files = list(files) if files is not None else list(DEFAULT_FILES)
    ignore = list(ignore) if ignore is not None else list(DEFAULT_IGNORE)

    file_pats, err = _compiled(files)
    if err:
        return None, "files: " + err
    ignore_pats, err = _compiled(ignore)
    if err:
        return None, "ignore: " + err

    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        # Pruned rather than skipped: descending into .git would walk a whole
        # repository's history to select nothing from it.
        dirnames[:] = sorted(d for d in dirnames
                             if d != ".git" and not is_link(os.path.join(dirpath, d)))
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            if is_link(full):
                continue
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            if _forbidden(rel):
                continue
            if any(re.search(p, rel) for p in ignore_pats):
                continue
            if any(re.search(p, rel) for p in file_pats):
                out.append(rel)
    return out, None


# ── bundles ─────────────────────────────────────────────────────────────


def scan_bundles(root: Path) -> Dict[str, Bundle]:
    """bundles/*.lua, keyed by the name --bundle selects them with."""
    directory = root / BUNDLE_DIR
    if not directory.is_dir():
        return {}
    found: Dict[str, Bundle] = {}
    for item in sorted(directory.iterdir(), key=lambda p: p.name):
        if not item.is_file() or item.suffix != ".lua":
            continue
        src = strip_lua_comments(read_text(item))
        match = find(src, NAME_RE, False)
        if not match:
            die("{}: a bundle file must declare `name = \"...\"`".format(item))
        name = match.group(1)
        if name != item.stem:
            die("{} declares name = \"{}\", but --bundle selects it as \"{}\""
                .format(item, name, item.stem))
        if not find(src, KIND_RE, False):
            die('{}: kind = "bundle" is missing; bundles/<name>.lua is where '
                "the build's package list lives".format(item))
        if name in found:
            die("two bundle files declare the name '{}'".format(name))
        fonts = find(src, FONTS_RE, False)
        found[name] = Bundle(
            name=name,
            includes=string_list(src, "includes", False),
            optional=string_list(src, "optional", False),
            # Absent means the fonts go in: `fonts = false` has to be said.
            fonts=fonts is None or fonts.group(1) != "false",
        )
    return found


class Closure:
    """The packages a bundle resolves to, and the paths they need beside them.

    Resolution is by name, so the same rule the kernel uses decides what a
    bundle contains: what is named, plus what the named packages depend on.
    A missing hard dependency and a cycle are both build errors; a missing
    optional one is not.
    """

    def __init__(self, catalog: Dict[str, Package], bundles: Dict[str, Bundle]) -> None:
        self.catalog = catalog
        self.bundles = bundles
        self.selected: Dict[str, Package] = {}
        self.support: List[str] = []
        self.warnings: List[str] = []

    def take(self, name: str, stack: Sequence[str]) -> bool:
        """Add `name` and everything it needs. False when it is not in the tree.

        `stack` is the bundle chain we arrived through, so a cycle is reported
        as the chain rather than as a name repeating with no explanation.
        """
        if name in self.selected:
            return True
        package = self.catalog.get(name)
        if package is not None:
            self._take_package(package, stack)
            return True
        bundle = self.bundles.get(name)
        if bundle is None:
            return False
        if name in stack:
            die("bundle cycle: " + " -> ".join(list(stack) + [name]))
        for member in bundle["includes"]:
            if not self.take(member, list(stack) + [name]):
                die("bundle '{}' includes '{}', which is not in the tree"
                    .format(name, member))
        for member in bundle["optional"]:
            if not self.take(member, list(stack) + [name]):
                self.warnings.append(
                    "bundle '{}': optional '{}' is not in the tree; skipped"
                    .format(name, member))
        return True

    def _take_package(self, package: Package, stack: Sequence[str]) -> None:
        self.selected[package["name"]] = package
        for rel in package["bundle_with"]:
            if rel in self.support:
                continue
            if not rel or rel.startswith("/") or ".." in rel.split("/"):
                die("{} declares bundle_with = {{ {} }}, which is not a path "
                    "inside the repository".format(package["name"], rel))
            self.support.append(rel)
        for dep in package["dependencies"]:
            if not self.take(dep, list(stack) + [package["name"]]):
                die("package '{}' depends on '{}', which is not in the tree"
                    .format(package["name"], dep))

    def plugins(self) -> List[Package]:
        return sorted(
            (p for p in self.selected.values() if p["kind"] == "plugin"),
            key=lambda p: p["name"])

    def themes(self) -> List[Package]:
        return sorted(
            (p for p in self.selected.values() if p["kind"] == "theme"),
            key=lambda p: p["name"])


def resolve(root: Path, bundle_name: str) -> Tuple[Closure, Bundle]:
    catalog = scan_catalog(root)
    bundles = scan_bundles(root)
    bundle = bundles.get(bundle_name)
    if bundle is None:
        have = ", ".join(sorted(bundles)) or "none"
        die("no bundle '{}' in {}/ (have: {})".format(bundle_name, BUNDLE_DIR, have))

    closure = Closure(catalog, bundles)
    for name in bundle["includes"]:
        if not closure.take(name, [bundle_name]):
            die("bundle '{}' includes '{}', which is not in the tree"
                .format(bundle_name, name))
    for name in bundle["optional"]:
        if not closure.take(name, [bundle_name]):
            closure.warnings.append(
                "bundle '{}': optional '{}' is not in the tree; skipped"
                .format(bundle_name, name))
    return closure, bundle


# ── writing ─────────────────────────────────────────────────────────────


def copy_file(src: Path, dst: Path) -> None:
    """A real copy, byte for byte, with no timestamps.

    shutil.copy2 would preserve mtime, which makes the bundle depend on when
    the source was checked out and defeats any comparison between two runs.
    """
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dst)


def copy_tree(src: Path, dst: Path) -> None:
    """Copy a directory tree verbatim: no symlinks, no metadata."""
    for item in sorted(src.iterdir(), key=lambda p: p.name):
        if item.is_dir() and not is_link(item):
            copy_tree(item, dst / item.name)
        elif item.is_file() and not is_link(item):
            copy_file(item, dst / item.name)
        # Anything else (a socket, a dangling symlink) is not bundle material.


def write_shim(dst: Path, module: str) -> None:
    """The one-line entry point the host's loader dofile()s."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text('return require("{}")\n'.format(module), encoding="utf-8",
                   newline="\n")


def kernel_module(root: Path) -> str:
    """The module the site entry hands over to, read from the site entry."""
    entry = root / SITE_ENTRY
    if not entry.is_file():
        die("no {} — the kernel has no entry point to write a shim for"
            .format(SITE_ENTRY))
    match = ENTRY_MODULE_RE.search(strip_lua_comments(read_text(entry)))
    if not match:
        die("{}: expected `return require(\"...\")`, which is what the shim "
            "in {} repeats".format(SITE_ENTRY, KERNEL_SHIM))
    return match.group(1)


def write_index(out: Path, plugins: Sequence[str], themes: Sequence[str]) -> None:
    def lua_list(names: Sequence[str]) -> str:
        return "{ " + ", ".join('"' + n + '"' for n in sorted(names)) + " }"

    body = (
        "-- Generated by cdin-x's scripts/bundle.py. Do not edit.\n"
        "--\n"
        "-- What this build bundles from cdin-x. Written so a build can be\n"
        "-- checked without diffing the whole tree, and so an installed copy\n"
        "-- can say which cdin-x revision it came from.\n"
        "return {\n"
        "  plugins = " + lua_list(plugins) + ",\n"
        "  themes = " + lua_list(themes) + ",\n"
        "}\n"
    )
    (out / "BUNDLE.lua").write_text(body, encoding="utf-8", newline="\n")


def reset(out: Path, support: Sequence[str] = ()) -> None:
    """Clear only what this script owns, then rebuild it.

    Idempotent by construction: a second run over a first run's output
    produces byte-identical files. The other entries in the destination are
    left strictly alone — in particular `core`, which is the host's own
    runtime and is not ours to touch.

    The kernel and `support` are ours too, and they are cleared here for the
    same reason `packages/` is: a directory this script copies into and does not
    clear is how a file deleted from a package survives in every build after it.
    """
    owned = [KERNEL_DIR, PACKAGES_DIR, "plugins", "themes", FONT_DIR]
    # What earlier versions of this script wrote here. `X/` held the build's
    # packages until the kernel took ownership of the shipped set, and held the
    # generated manifest until Phase 9; a build directory made before that is a
    # real thing on a user's disk, and leaving it behind would keep a whole dead
    # copy of every bundled package alive in every build directory that was ever
    # produced. Phase 9 removed `X/` as a catalog root, so that copy is no longer
    # loadable -- but it is still on the user's disk, and clearing it is the only
    # way it goes away. Nothing here is the user's: every file under it was written
    # by a previous version of this script.
    for name in RETIRED_DIRS:
        if name not in owned:
            owned.append(name)
    for path in support:
        top = path.replace("\\", "/").split("/")[0]
        if top and top not in owned:
            owned.append(top)

    for name in owned:
        target = out / name
        if is_link(target):
            # A link here would make rmtree delete through to whatever it
            # points at. Unlink it; never traverse.
            os.unlink(target)
        elif target.is_dir():
            shutil.rmtree(target)
        elif target.exists():
            target.unlink()

    index = out / "BUNDLE.lua"
    if is_link(index):
        os.unlink(index)
    elif index.exists():
        index.unlink()


def write_bundle(root: Path, out: Path, bundle_name: str) -> int:
    closure, bundle = resolve(root, bundle_name)
    for message in closure.warnings:
        warn(message)

    plugins, themes = closure.plugins(), closure.themes()

    # Support files are checked before anything is written, so a path that is
    # not there stops the build rather than half-assembling it.
    for rel in closure.support:
        if not (root / rel).exists():
            die("a package in bundle '{}' declares bundle_with = {{ {} }} but "
                "{} is not there".format(bundle_name, rel, root / rel))

    # The fonts are not optional and are not substituted. A cdin build with
    # no fonts does not start, and a build that silently shipped without
    # them would be discovered by the user, at startup, with no way to tell
    # why. A bundle that says `fonts = false` is asking for an editor with no
    # bundled fonts, and it had to say so, so it is honoured.
    fonts = root / FONT_DIR
    has_fonts = fonts.is_dir() and any(fonts.iterdir())
    if not bundle["fonts"]:
        # The bundle said so, so the check below does not apply and the fonts
        # simply are not part of this build.
        copy_fonts = False
    elif has_fonts:
        copy_fonts = True
    else:
        die("no fonts in {}. The bundled fonts are the ones this repository "
            "ships; a cdin build cannot start without them, and nothing here "
            "will substitute a different set.".format(fonts))

    out.mkdir(parents=True, exist_ok=True)
    reset(out, closure.support)

    # The kernel, and the entry point that reaches it. A bundle that cannot
    # boot cdin-x is a bundle nobody can open a panel in.
    copy_tree(root / KERNEL_DIR, out / KERNEL_DIR)
    write_shim(out / KERNEL_SHIM, kernel_module(root))

    # The closure, flat: one directory per package, named for the package.
    #
    # Flat rather than `<category>/<name>/`, because this root is not a copy of
    # the repository -- it is a named set, and the kernel reads it as an ordinary
    # catalog source. A build has no domain directories worth reproducing, and
    # keeping the build's shape identical to the store Phase 7 introduces means
    # one scanner rule instead of two.
    #
    # The category is *not* lost: it stays in package.lua, which is what the
    # panel groups by, so the shipped tree agrees with what the editor says
    # about the same package without the directory having to say it again.
    for package in plugins:
        leaf = package["name"] + (".lua" if package["single_file"] else "")
        dst = out / PACKAGES_DIR / leaf
        if package["root"].is_dir():
            copy_tree(package["root"], dst)
        else:
            copy_file(package["root"], dst)

    # A standalone theme entry is the exception: the host reads
    # <data>/themes/<name>/theme.lua, so it lands with the theme roots rather
    # than with the packages. By name rather than by where it sat here, because
    # the host's layout is fixed and this repository's is not.
    for package in themes:
        copy_tree(package["root"], out / THEME_DIR / package["name"])

    # A theme *package* is the harder case, and the reason is fixed rather than
    # ours: the host's theme root is <data>/themes, it is in cdin's extension
    # contract, and there is no way to ask the host to look anywhere else. So a
    # package that carries `themes/<name>/theme.lua` has those flattened up to
    # <data>/themes/<name>/theme.lua as well as being copied in place -- the copy
    # in place is what a *site install* needs, because there the package
    # registers its own root with themes.add_root and the host is free to be
    # pointed at it. A build has no such hook, so the files have to arrive where
    # the host already looks.
    for package in plugins:
        if not package["root"].is_dir():
            continue
        for theme_dir in sorted((package["root"] / "themes").iterdir()
                                if (package["root"] / "themes").is_dir() else []):
            if not theme_dir.is_dir() or is_link(theme_dir):
                continue
            manifest = theme_dir / "theme.lua"
            if manifest.is_file():
                dst = out / THEME_DIR / theme_dir.name
                dst.mkdir(parents=True, exist_ok=True)
                copy_file(manifest, dst / "theme.lua")

    # Deliberately no per-package shim. A shim in <data>/plugins is an entry the
    # host loads unconditionally and the user cannot remove, so writing one per
    # package would put `vim` back exactly where it was before the kernel owned
    # the shipped set. `KERNEL_SHIM` above is the only entry that directory gets.

    # <support>/** — verbatim, at the top level, so a package's own module
    # namespace is the same in a build as in a checkout.
    for rel in closure.support:
        src = root / rel
        if src.is_dir() and not is_link(src):
            copy_tree(src, out / rel)
        else:
            copy_file(src, out / rel)

    if copy_fonts:
        copy_tree(fonts, out / FONT_DIR)
        font_count = sum(1 for f in (out / FONT_DIR).rglob("*") if f.is_file())
    else:
        font_count = 0

    write_index(out, [p["name"] for p in plugins], [t["name"] for t in themes])

    ok("bundled '{}': {} plugin(s) [{}], theme(s) [{}], {} font file(s) → {}"
       .format(bundle_name, len(plugins), ", ".join(p["name"] for p in plugins),
               ", ".join(t["name"] for t in themes), font_count, out))
    if closure.support:
        print("  with support files: {}".format(", ".join(closure.support)))
    return 0


def run_selection(root: Path, files: Sequence[str], ignore: Sequence[str]) -> int:
    """Print the files `select_files` would install from `root`, one per line.

    Exists so validate.lua can run the Python twin of the selection over a package
    and compare it with the Lua one. Without it the two implementations could drift
    and the only place that would show is a user's install.
    """
    selected, err = select_files(root, files, ignore)
    if err:
        die(err)
    for rel in selected:
        print(rel)
    return 0


def main() -> int:
    default_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(
        description="Bundle a named set of cdin-x packages for a cdin build.")
    # Not required here, because --select is a second mode that writes stdout
    # instead of a directory. The check that one of the two is present is in main(),
    # where the reason can be given rather than argparse's generic "required".
    parser.add_argument("--out", type=Path,
                        help="destination data/ directory")
    parser.add_argument("--bundle", default=None,
                        help="bundle to take the packages from "
                             "(bundles/<name>.lua); default %s, and a build "
                             "that wants nothing names `empty`" % DEFAULT_BUNDLE)
    parser.add_argument("--cdinx-root", type=Path, default=default_root,
                        help="cdin-x checkout (default: this repository)")
    parser.add_argument("--select", type=Path, default=None, metavar="PKG_DIR",
                        help="print the files the selection would install from "
                             "PKG_DIR, one per line, and exit")
    parser.add_argument("--files", default=None,
                        help="the package's `files` list, comma-separated "
                             "(default: the built-in default)")
    parser.add_argument("--ignore", default=None,
                        help="the package's `ignore` list, comma-separated "
                             "(default: the built-in default)")
    args = parser.parse_args()

    if args.select is None and args.out is None:
        die("one of --out <dir> (write a bundle) or --select <pkg> (print a "
            "selection) is required")

    root = args.cdinx_root

    if args.select is not None:
        # A separate mode rather than a flag on the bundler, because the bundler
        # writes a directory and this writes stdout: a caller that asked for one
        # and got the other has a build to clean up.
        files = args.files.split(",") if args.files else None
        ignore = args.ignore.split(",") if args.ignore else None
        return run_selection(args.select, files, ignore)

    out = args.out

    # The destination has to be a real directory. A symlink or junction left
    # by an older build layout points at some other tree, and writing the
    # bundle through it would put build output inside that tree.
    if is_link(out):
        die("--out is a symlink or junction ({}); refusing to write through "
            "it. Point it at a real directory.".format(out))

    if args.bundle is None:
        # cdin's assemble_data.py calls this with --out and nothing else, so the
        # name has to have a default. `standard` is the set a build has always
        # carried; a build that wants something else passes --bundle, and a
        # build that wants nothing passes `--bundle empty`.
        args.bundle = DEFAULT_BUNDLE

    return write_bundle(root, out, args.bundle)


if __name__ == "__main__":
    _force_utf8_stdio()
    sys.exit(main())