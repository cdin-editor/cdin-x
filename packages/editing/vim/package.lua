-- The manifest for the vim package. Data only: no require, no functions.
--
-- Two kinds of optional part exist in the architecture, and vim uses only one:
--
--   features    part of a package you may switch off. Vim has none: everything
--               optional about vim needs another package, and that is what `with`
--               is for.
--
-- Nothing here declares a dependency on any of them. `optional_dependencies`
-- would say "load it if it happens to be installed", which is not the same thing:
-- vim does not need git, and a missing git must not appear anywhere in the load.
return {
  name = "vim",
  kind = "plugin",
  version = "0.3.3",
  description = "Vim-style modal editing and command-line integration",
  authors = { "cdin Team" },
  license = "MIT",
  tags = { "editor", "vim", "input" },

  category = "core",
  min_cdin_version = "0.5.0",

  -- Everything vim reaches outside itself. Each entry is one seam, and it runs only
  -- while both packages are loaded.
  --
  -- The key is always the *package*, never a name for the seam. That is what lets
  -- validate check what a seam is allowed to reach, and it is why `menu` appears
  -- once as a key carrying two paths rather than `menus` and `plugin-manager`
  -- appearing as keys of their own. Two seams waiting on one package is a list
  -- under that one key.
  --
  -- Nothing here declares a dependency on any of them. `optional_dependencies`
  -- would say "load it if it happens to be installed", which is a different thing:
  -- vim does not need git, and a missing git must not appear in the load at all.
  --
  -- `vim.main` is defined in init.lua rather than in `with/menus.lua`, so that it
  -- exists before any of these entries extends it -- see init.lua.
  with = {
    git = "with/git.lua",
    menu = { "with/menus.lua", "with/plugin-manager.lua" },
    search = "with/search.lua",
    treeview = "with/treeview.lua",
    workspace = { "with/tab.lua", "with/window.lua" },
  },

  entry = "init.lua",
}