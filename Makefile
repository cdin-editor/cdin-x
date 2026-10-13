# CDIN-X development tasks.
#
# There is no build here: cdin-x is Lua and data. These targets install it,
# link it for development, and run the checks that guard the catalog.
#
#   make install    copy cdinx/, packages/ and plugins/cdin-x/ into the site dir
#   make link       the same three, symlinked, for development
#   make uninstall  remove them again
#   make bundle     produce one bundle for a cdin build (needs BUNDLE and DEST)
#   make validate   structural checks over the catalog
#   make check      one package against the rules (needs PKG)
#   make index      regenerate registry/generated/catalog.lua
#   make list       print the catalog
#   make doctor     say whether an installed cdin-x is sound
#   make recipe     resolve every third-party recipe to its tag's commit (network)
#
# SITE   overrides the site directory.
# DEST   is the data/ directory a cdin build should bundle into.
# BUNDLE is the bundle a build takes its packages from.
# PKG    is a package directory or name, for `make check`.
# LUA    overrides the interpreter (default: lua).

SITE ?=
# Mirrors cdin's config.site_dirname — the site directory's name, the one
# knob that decides what <data_home>/cdin/<name> is called. Set it here as
# well as in your cdin user init.lua if you rename the directory; cdin's
# `make test-site-dir` compares the two so they cannot drift apart silently.
SITE_NAME ?=

# ── the shell ─────────────────────────────────────────────────────────────
#
# There is no build to compile, so the only interpreter this file needs is Lua.
# Finding it is the first thing that has to be portable, and it was not: the old
# line was `$(shell command -v lua 2>/dev/null || echo lua)`, and `command` is a
# POSIX shell builtin. Under Windows make it is not a command at all, so the
# substitution printed an error and fell back to a bare `lua`, which is also not
# what a Windows install calls it.
#
# `where` is the Windows one and `command -v` is the POSIX one, so the platform
# decides which is asked. A Makefile that finds its interpreter with the other
# platform's command works on exactly one of them.
ifeq ($(OS),Windows_NT)
  LUA ?= $(firstword $(shell where lua 2>NUL) $(shell where lua54 2>NUL) lua)
else
  LUA ?= $(shell command -v lua 2>/dev/null || command -v lua5.4 2>/dev/null || echo lua)
endif

# `python3` is the POSIX name and on most Windows installs only `python` and
# `py` exist. Asking for one of them and failing is the whole defect: `make
# install` printed "CreateProcess failed" on Windows because of this line, and
# `PYTHON=python` from the command line was the only way around it.
#
# `firstword` is load-bearing here and was not obvious: `where python` prints one
# line per match, so this machine reports three interpreters, and a recipe that
# expands to all three becomes the command
#     C:\...\Python311\python.exe C:\...\Python313\python.exe C:\...\Python310\python.exe scripts/bundle.py
# which python then tries to parse as a source file and rejects as non-UTF-8. One
# path, the first, is what a recipe wants.
ifeq ($(OS),Windows_NT)
  PYTHON ?= $(firstword $(shell where python 2>NUL) $(shell where py 2>NUL) python)
else
  PYTHON ?= python3
endif

# `test -n` and `$(subst ,, ,)` in a recipe are POSIX shell. Under Windows make
# runs the recipe through cmd.exe, which has neither, so every target that used a
# guard died with "'test' is not recognized" before it did anything.
#
# The guards move into make's own language instead. `$(if ...)` and `$(error ...)`
# are evaluated by make on every platform, so a missing DEST is a clean one-line
# failure with no shell involved at all -- and the recipe below no longer needs a
# shell to run, which is the actual portability fix.

# --site is a full path and wins; --site-name is only passed when no full
# path was given, so the two can never disagree.
SITE_ARG = $(if $(SITE),--site "$(SITE)",$(if $(SITE_NAME),--site-name "$(SITE_NAME)",))

.PHONY: install link uninstall bundle validate check index list doctor recipe help

# Unquoted echo arguments, no quoting of any kind.
#
# `echo 'text'` and `echo "text"` both work in cmd.exe, but they make the quotes
# part of the output: `echo "hello"` prints `"hello"`. And the older
# `'"'"'` form -- how a single quote is written inside a POSIX single-quoted
# string -- is not quoting at all in cmd.exe, so `make help` printed a line
# containing literal quote characters and then failed with "The system cannot find
# the file specified". `make help` is the first command anyone runs and it exited
# 1 on Windows.
#
# So the constraint this satisfies is: no quoting, and none of these lines contains
# a character either shell would treat specially. That rules out the apostrophe in
# "host's" (hence "host site_dir"), `>` and `|`, and `&`. The em dash that was here
# also went, since a recipe's output is read in terminals that may not be UTF-8 and
# the text says the same thing without it.
help:
	@echo Targets: install, link, uninstall, bundle, validate, check, index, list, doctor, recipe
	@echo.
	@echo   install   copy into SITE (default: the host site_dir)
	@echo   link      symlink the same three, for development
	@echo   bundle    BUNDLE=standard DEST=dir  - one bundle for a cdin build
	@echo   validate  structural checks over the catalog
	@echo   check     one package against the rules: make check PKG=packages/system/themes
	@echo   index     regenerate registry/generated/catalog.lua
	@echo   list      print the catalog
	@echo   doctor    the installed cdin-x: git, registry, catalog, sources, lock, store
	@echo   recipe    resolve every third-party recipe to the commit its tag names

install:
	$(PYTHON) scripts/install.py $(SITE_ARG)

link:
	$(PYTHON) scripts/install.py $(SITE_ARG) --symlink

uninstall:
	$(PYTHON) scripts/install.py $(SITE_ARG) --uninstall

# What a cdin build consumes. `make` in cdin calls this through
# scripts/assemble_data.py; DEST is the build output's data/ directory.
# BUNDLE names the bundle to take the packages from (bundles/<name>.lua);
# a build that names none gets nothing from cdin-x.
bundle:
	$(if $(DEST),,$(error DEST is required: make bundle BUNDLE=standard DEST=/path/to/build/data))
	$(if $(BUNDLE),,$(error BUNDLE is required: make bundle BUNDLE=standard DEST=/path/to/build/data))
	$(PYTHON) scripts/bundle.py --out "$(DEST)" --bundle "$(BUNDLE)"

validate:
	$(LUA) scripts/validate.lua

# One package, against the same rules validate applies to the whole tree.
# PKG is a path or a package name; several may be given, comma-separated.
#
# The recipe used to be a POSIX `for` loop, which cmd.exe does not have, so
# `make check` did not run at all on Windows. check.lua takes several paths in one
# invocation and reports them together, so it is called once with all of them --
# which also fixes the count: a loop over three packages printed three reports and
# the last one said "1 package(s)".
#
# The split is comma-to-space, which is the whole job. `$(subst ,, ,$(PKG))` looks
# like it should do this and does not: it substitutes the comma for a comma and the
# space for a space, so `a,b,c` comes back as ` ,a,b,c` -- one word with a comma in
# it -- and check.lua reports `",a,b,c" is neither a directory nor a package name`,
# which is a confusing way to say "you gave me three packages".
comma := ,
PKG_NAMES = $(subst $(comma), ,$(strip $(PKG)))

check:
	$(if $(strip $(PKG)),,$(error PKG is required: make check PKG=packages/navigation/search))
	$(LUA) scripts/check.lua $(PKG_NAMES)

index:
	$(LUA) scripts/generate-index.lua

# Removed in Phase 9: `make manifest`, and scripts/generate-manifest.lua with it.
# `X/manifest.lua` was a 29-line generated index kept alongside the real catalog
# for cdin's own test suite; with `X/` gone and `registry/generated/catalog.lua`
# being the only index, keeping a second generated copy of the same data was a
# second file that can be stale and nothing that reads it.

list:
	$(LUA) scripts/plugin-list.lua

# The same report `cdin-x doctor` and `:cdin-x:doctor` print, for a machine that
# has no editor open. One implementation, three callers, which is what keeps the
# three from disagreeing about whether an installation is sound.
doctor:
	@$(LUA) scripts/bin/cdin-x doctor

# Resolves every recipe's tag to a commit. The only target here that needs the
# network, and it is not part of `validate` for exactly that reason: `validate` is
# what a build runs, and a build gate that needs the internet is a gate that fails
# when the internet does.
recipe:
	$(LUA) scripts/pin-recipe.lua
