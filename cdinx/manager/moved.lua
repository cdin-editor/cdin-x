-- Where each removed package went.
--
-- Twenty-three packages stopped being packages: the seven `vim-*` integrations,
-- the ten merged into `basics`/`launcher`/`workspace`/`text-tools`/`themes`, and
-- the two renamed. None of them lost code -- all of it is a `feature` file or a
-- `with` file inside the package whose behaviour changes -- but a user has names
-- for them. A `config.plugins` whitelist, a keymap, an `init.lua` line, or a
-- state file from before the merge all still say `finder`, and answering "no such
-- package" to that is a dead end the user cannot act on.
--
-- So the names are recorded here rather than guessed at. Two kinds of entry, and
-- the difference is the difference between advice and a refusal:
--
--   owner   the name whose package absorbed it. "install `menu` instead" is
--           actionable, so a request for the old name is answered with the new one
--           and nothing is installed on the user's behalf.
--   feature the feature of that package it became, when it became one of several
--           and the user has to know which switch to look at.
--
-- Nothing here migrates. Phase 6 rewrites the state file; this only answers the
-- question honestly at the moment it is asked. `scripts/validate.lua` checks every
-- owner and feature against what this tree actually declares, so an entry cannot
-- drift into naming a package that no longer exists.
--
-- Requires nothing, deliberately: `lifecycle.lua` and `runtime.lua` both consult
-- this while resolving, and a table of facts that can answer during a load should
-- not be able to fail during one.
local Moved = {}

--- The entries, keyed by the old name. Sorted nowhere: it is a lookup table, and
--- `pairs` order is not observable because every lookup is by key.
--- @type table<string, {owner: string, feature: string|nil, why: string|nil}>
Moved.MOVED = {
  -- The vim integrations. Each became a `with` entry on the package whose
  -- behaviour it changes, so it loads with that package and goes with it.
  ["vim-menu"] = {
    owner = "menu",
    why = "vim's file, shell and build menus are now a `with` entry on `menu`",
  },
  ["vim-plugin-manager"] = {
    owner = "menu",
    why = "the panel reached from vim is now the `menu` package",
  },
  ["vim-window"] = {
    owner = "workspace",
    feature = "window",
    why = "vim's window commands are now a `with` entry on `workspace`",
  },
  ["vim-tab"] = {
    owner = "workspace",
    feature = "tab",
    why = "vim's tab commands are now a `with` entry on `workspace`",
  },
  ["vim-search"] = {
    owner = "search",
    why = "the `/`, `n`, `N` and `*` bindings are now a `with` entry on `search`",
  },
  ["vim-treeview"] = {
    owner = "treeview",
    why = "`:tree` is now a `with` entry on `treeview`",
  },
  ["vim-git"] = {
    owner = "git",
    why = "vim's git commands and menu section are now a `with` entry on `git`",
  },
  ["git-treeview"] = {
    owner = "treeview",
    why = "the tree badges are now `treeview`'s `with` entry on `git`",
  },
  ["session-theme-switcher"] = {
    owner = "themes",
    why = "remembering the theme across a session is now `themes`' `with` entry on `workspace`",
  },

  -- Merges. The name *is* the noun, so there is nothing to explain beyond which
  -- switch to look at -- hence no `why` on these five.
  ["tab"] = { owner = "workspace", feature = "tab" },
  ["window"] = { owner = "workspace", feature = "window" },
  ["session"] = { owner = "workspace", feature = "session" },
  ["tab-session"] = { owner = "workspace", feature = "tab-session" },
  ["theme_switcher"] = { owner = "themes", feature = "switcher" },

  ["palette"] = { owner = "launcher", feature = "palette" },
  ["finder"] = { owner = "launcher", feature = "finder" },
  ["modules"] = { owner = "launcher", feature = "modules" },
  ["autoreload"] = { owner = "basics", feature = "autoreload" },
  ["trimwhitespace"] = { owner = "basics", feature = "trimwhitespace" },
  ["rtl_toggle"] = { owner = "text-tools", feature = "rtl" },
  ["unicode_inspect"] = { owner = "text-tools", feature = "unicode" },

  -- Renames: same package, new name. No feature, nothing to switch.
  ["autocomplete"] = { owner = "complete", why = "it was renamed to `complete`" },
  ["autoupdate"] = { owner = "update", why = "it was renamed to `update`" },

  -- The six language definitions. A rename the schema forced rather than one we
  -- chose: `kind = "lang"` requires a `lang-` name, and no package had declared
  -- that kind until Phase 8, so the rule had never run. Same code, same files,
  -- same directory -- only the identity and the module prefix changed.
  --
  -- Recorded because a user may already say the old name. `packages.lua`, a
  -- `disable` list and a state file written before Phase 8 all still say
  -- `python`, and "no such package" for that is a dead end with nothing to act
  -- on, which is exactly what this table exists to prevent.
  ["c"] = { owner = "lang-c", why = "it is a `lang` package now: `lang-c`" },
  ["javascript"] = {
    owner = "lang-javascript",
    why = "it is a `lang` package now: `lang-javascript`",
  },
  ["lua"] = { owner = "lang-lua", why = "it is a `lang` package now: `lang-lua`" },
  ["markdown"] = {
    owner = "lang-markdown",
    why = "it is a `lang` package now: `lang-markdown`",
  },
  ["python"] = { owner = "lang-python", why = "it is a `lang` package now: `lang-python`" },
  ["typescript"] = {
    owner = "lang-typescript",
    why = "it is a `lang` package now: `lang-typescript`",
  },
}

local NAMES = {}
for name in pairs(Moved.MOVED) do NAMES[#NAMES + 1] = name end
table.sort(NAMES)

--- What happened to `name`, or nil if it is still a package.
--- @param name string
--- @return {owner: string, feature: string|nil, why: string|nil}|nil
function Moved.lookup(name)
  if type(name) ~= "string" then return nil end
  return Moved.MOVED[name]
end

--- One line a caller can show or log in place of "no such package".
---
--- Built here rather than written out per entry, for the same reason the table
--- exists: one sentence said twice in two places is two sentences to keep in step.
--- A `why` is used *alone*, because appending the owner clause to it repeats the
--- same fact in a second sentence -- which is how the first version of this read
--- "the file finders are the `finder` feature of `launcher`. It is now the
--- `finder` feature of `launcher`."
--- @param name string
--- @return string|nil
function Moved.advice(name)
  local entry = Moved.lookup(name)
  if not entry then return nil end

  if entry.why then
    return string.format("%s is no longer a package: %s", name, entry.why)
  end

  if entry.feature then
    return string.format("%s is no longer a package: it is now the `%s` feature of `%s`.",
      name, entry.feature, entry.owner)
  end
  return string.format("%s is no longer a package: it is now part of `%s`.",
    name, entry.owner)
end

--- Every removed name, sorted. Used by the validator and, later, by `doctor`.
--- @return string[]
function Moved.names()
  local out = {}
  for i = 1, #NAMES do out[i] = NAMES[i] end
  return out
end

--- Whether `owner` is a package the catalog knows.
---
--- `available` is the catalog map rather than a require of the catalog, so the
--- answer is the catalog's and not this table's: a name that exists only in
--- `moved.lua` is exactly the drift `validate` is there to catch.
--- @param available table<string, table>|nil
--- @param name string
--- @return boolean
function Moved.owner_exists(available, name)
  local entry = Moved.lookup(name)
  if not entry or type(available) ~= "table" then return false end
  return available[entry.owner] ~= nil
end

return Moved