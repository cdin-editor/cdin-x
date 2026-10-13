#!/usr/bin/env python3
"""Install cdin-x into a cdin user's site directory.

    python3 scripts/install.py                 # copy
    python3 scripts/install.py --symlink       # link (development)
    python3 scripts/install.py --uninstall

Three directories go into the site directory, and that is the whole install:

    <site>/cdinx/             the kernel
    <site>/packages/          first-party packages: vim, the themes, the
                               language definitions
    <site>/plugins/cdin-x/    the entry plugin the host loads

There was a fourth, `<site>/X/`, and there is not any more. `X/` held every
package before `packages/` existed, then only vim, then only the generated
catalog manifest and the six language definitions; Phase 9 removed it, and with it
the second catalog root that made every reader in this repository ask "which of
the two did you mean".

The site directory is the host's `config.site_dir`:
<data_home>/cdin/site, where data_home is $XDG_DATA_HOME or ~/.local/share
on POSIX and %LOCALAPPDATA%, then %APPDATA%, then %USERPROFILE%\\AppData\\Local
on Windows. Override it with --site or the CDIN_SITE_DIR environment
variable.

What this deliberately does NOT do:

  * write anything into a cdin checkout. Installing cdin-x never touches the
    editor's tree, its build output, or its source. A cdin that has never
    heard of cdin-x keeps working; one that has, loads it.
  * filter by bundle. What a cdin BUILD carries is a bundle's list, and
    that is scripts/bundle.py's job. A user install is the opposite: it
    is the full catalog, managed at runtime.
  * install fonts. They ship with a cdin build.

No network, no registry, no package manager. Copying files is the install.
"""

from __future__ import annotations

import argparse
import os
import shutil
import sys
from pathlib import Path

# (source, destination relative to the site directory).
#
# Three entries, and there were four. `X/` was one of them for as long as anything
# lived there -- it held everything before `packages/` existed, then vim, then the
# generated manifest and the language definitions. Phase 9 removed the directory.
# It was never optional: a root the kernel scans cannot be missing, or the install
# is half a catalog.
#
# What a build carries is a *bundle's* list and is scripts/bundle.py's job. A user
# install is the whole catalog.
PAYLOAD = [
    ("cdinx", "cdinx"),
    ("packages", "packages"),
    ("plugins/cdin-x", "plugins/cdin-x"),
]

# Nothing. Kept as an empty list so the loop below has one code path: a root that
# becomes optional later is a line moved out of PAYLOAD, not a second mechanism.
#
# `X/` was in PAYLOAD until Phase 9 and is the reason this list exists at all -- it
# never became optional, it was deleted. A `--site` that still has an `X/` in it
# from an older install is left alone rather than deleted: this script removes only
# what it put there, and everything under that path was put there by an older
# version of this script.
OPTIONAL_PAYLOAD = []


def is_link(path: Path) -> bool:
    """True for a symlink, a junction, or any other reparse point.

    os.path.islink is false for a Windows junction, and a junction that
    looked like a directory would make rmtree delete through to its target.
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
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass


def die(message: str) -> "NoReturn":  # type: ignore[valid-type]
    print("✗ " + message, file=sys.stderr)
    sys.exit(1)


def ok(message: str) -> None:
    print("✓ " + message)


def warn(message: str) -> None:
    print("⚠ " + message)


# The directory name cdin uses, under <data_home>/cdin/.
#
# This is a COPY of `config.site_dirname` in cdin's data/core/config.lua, and
# it is the only value duplicated between the two repositories — the editor
# owns the name, but this script runs before any editor exists and cannot ask
# Lua for it. `make validate` compares the two, so they cannot drift apart
# silently.
#
# Renaming the directory takes two edits, both one-liners:
#   cdin   data/core/config.lua   config.site_dirname = "site"
#   here   scripts/install.py     SITE_DIRNAME = "site"
# ...or none at all, if you leave the default alone and pass --site-name or
# set CDIN_SITE_DIRNAME, or point at a full path with --site / CDIN_SITE_DIR.
SITE_DIRNAME = "site"


def env(name: str):
    value = os.environ.get(name)
    return value if value else None


def default_site() -> Path:
    """The host's site directory, computed the same way the host computes it.

    Duplicated rather than imported: this script runs before cdin exists on
    the machine, and cdin-x must not import from cdin. The per-platform
    fallbacks are the host's, character for character.
    """
    override = env("CDIN_SITE_DIR")
    if override:
        return Path(override)

    name = env("CDIN_SITE_DIRNAME") or SITE_DIRNAME

    is_win = os.name == "nt"

    def get(var: str):
        value = os.environ.get(var)
        return value if value else None

    if is_win:
        home = get("USERPROFILE") or get("HOME") or "."
        data_home = get("LOCALAPPDATA") or get("APPDATA") or str(Path(home) / "AppData" / "Local")
    else:
        home = get("HOME") or "."
        data_home = get("XDG_DATA_HOME") or str(Path(home) / ".local" / "share")

    return Path(data_home) / "cdin" / name


def remove(path: Path) -> None:
    """Remove a path, unlinking links rather than following them."""
    if not os.path.lexists(path):
        return
    if is_link(path):
        os.unlink(path)
    elif path.is_dir():
        shutil.rmtree(path)
    else:
        path.unlink()


def copy_tree(src: Path, dst: Path) -> None:
    """A real copy, byte for byte, with no symlinks and no timestamps."""
    for item in sorted(src.iterdir(), key=lambda p: p.name):
        target = dst / item.name
        if item.is_dir() and not item.is_symlink():
            target.mkdir(parents=True, exist_ok=True)
            copy_tree(item, target)
        elif item.is_file():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(item, target)


def link_tree(src: Path, dst: Path) -> None:
    """A link, falling back to a copy where links are not available.

    Windows without developer mode cannot create a symlink without admin
    rights, and a hard failure would make the development install unusable
    on a stock machine. A copy is not as convenient — it does not track
    edits — so it is a warning, not a silent downgrade.
    """
    try:
        os.symlink(src, dst, target_is_directory=True)
        return
    except (OSError, NotImplementedError, AttributeError):
        pass
    copy_tree(src, dst)
    warn("symlinks unavailable here; copied {} instead — edits to the "
         "checkout will not appear until you re-run this".format(src))


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def place(src: Path, site: Path, rel_dst: str, use_symlinks: bool) -> None:
    dst = site / rel_dst
    # Clean replace: a half-updated install is worse than a missing one,
    # because the loader would find a mixture of two versions.
    remove(dst)
    dst.parent.mkdir(parents=True, exist_ok=True)
    if use_symlinks:
        link_tree(src.resolve(), dst)
    else:
        copy_tree(src, dst)
    print("  {} -> {}".format(src, dst))


def install(site: Path, root: Path, use_symlinks: bool) -> None:
    for rel_src, rel_dst in PAYLOAD:
        src = root / rel_src
        if not src.is_dir():
            die("missing {} — is this a cdin-x checkout?".format(src))
        place(src, site, rel_dst, use_symlinks)

    for rel_src, rel_dst in OPTIONAL_PAYLOAD:
        src = root / rel_src
        if src.is_dir():
            place(src, site, rel_dst, use_symlinks)

    ok("cdin-x installed into {}".format(site))
    if not use_symlinks:
        print("  the editor's site directory now has cdinx/, X/ and packages/ "
              "on the catalog roots; restart cdin to load it")


def uninstall(site: Path) -> None:
    for rel_src, rel_dst in PAYLOAD + OPTIONAL_PAYLOAD:
        dst = site / rel_dst
        if not os.path.lexists(dst):
            continue
        remove(dst)
        print("  removed {}".format(dst))
    # plugins/ belongs to the host; only clean it up if we emptied it.
    plugins = site / "plugins"
    if plugins.is_dir() and not any(plugins.iterdir()):
        plugins.rmdir()
    ok("cdin-x removed from {}".format(site))


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Install cdin-x into a cdin user's site directory.")
    parser.add_argument("--site", type=Path, default=None,
                        help="full path to the site directory, overriding "
                             "everything else")
    parser.add_argument("--site-name", default=None,
                        help="the directory's name under <data_home>/cdin/ "
                             "(default: %s, the same value as cdin's "
                             "config.site_dirname)" % SITE_DIRNAME)
    parser.add_argument("--symlink", action="store_true",
                        help="link the three directories instead of copying "
                             "(for development)")
    parser.add_argument("--uninstall", action="store_true",
                        help="remove cdin-x from the site directory")
    args = parser.parse_args()

    if args.site_name and not args.site and not env("CDIN_SITE_DIR"):
        # The flag is this script's only handle on the name, so it has to work
        # without also requiring a full path.
        os.environ["CDIN_SITE_DIRNAME"] = args.site_name

    site = (args.site or default_site()).expanduser()
    root = repo_root()

    # "Is this a cdin-x checkout?" answered by the one directory that cannot be
    # anything else. It was `X/` for as long as there were two catalog roots, which
    # made the check cheap but tied to the layout; Phase 9 removed `X/`, and
    # `packages/` is the directory whose absence really does mean this is not a
    # cdin-x tree. `cdinx/` alone would not: a partial checkout of the kernel is a
    # thing a broken clone produces, and installing from it gives an editor with no
    # packages and no error.
    if not args.uninstall and not (root / "packages").is_dir():
        die("no packages/ under {} — is this a cdin-x checkout?".format(root))

    print("cdin-x {}".format(
        "uninstall" if args.uninstall
        else ("link" if args.symlink else "install")))
    print("  source : {}".format(root))
    print("  site   : {}".format(site))
    print("")

    if args.uninstall:
        uninstall(site)
    else:
        site.mkdir(parents=True, exist_ok=True)
        install(site, root, args.symlink)
    return 0


if __name__ == "__main__":
    _force_utf8_stdio()
    sys.exit(main())
