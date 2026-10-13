-- The manifest for the treeview package. Data only: no require, no functions.
return {
  name = "treeview",
  kind = "plugin",
  version = "0.2.0",
  description = "File tree sidebar with navigation and filesystem actions",
  authors = { "cdin Team" },
  license = "MIT",
  tags = { "navigation", "filesystem", "sidebar" },

  category = "core",
  min_cdin_version = "0.5.0",

  -- Git status badges on the rows. Owned here rather than by `git` because this is
  -- the package whose behaviour changes: with the entry up a row carries a git
  -- letter, and with it down it does not.
  with = {
    git = "with/git.lua",
  },

  entry = "init.lua",
}