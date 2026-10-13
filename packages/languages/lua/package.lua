-- The manifest for the Lua syntax package. Data only: no require, no functions.
--
-- A language package is a manifest and a definition, and nothing else. There
-- is no command, no key and no panel of its own: what it offers is that a
-- file of this language is highlighted once this package is loaded.
--
-- `kind = "lang"` and the `lang-` name are the schema's rule, not a preference:
-- cdinx/schema.lua requires a lang package to be named `lang-*`, so a name in the
-- catalog says what kind of thing it is before it is opened.
--
-- What `kind = "lang"` does *not* do here: the definition is not in this manifest.
-- It is real Lua in syntax.lua, called through core.syntax.add from init.lua,
-- because 8.3 forbids executing anything to inspect a package and the bundler
-- reads manifests with a literal parser. `kind` marks the package for the panel
-- and for validate's R10; it is not a promise that the tokens are data.
--
-- `unload` cannot take the definition back, because the host's
-- `core.syntax.add` has no `remove` and the contract says so. That is recorded
-- where it belongs, in init.lua, rather than worked around here.
return {
  name = "lang-lua",
  kind = "lang",
  version = "0.1.0",
  description = "Lua syntax support",
  authors = { "cdin Team" },
  license = "MIT",
  tags = { "language", "lua" },

  category = "syntax",
  min_cdin_version = "0.5.0",

  -- Named so R10 checks something. The default selection already installs all
  -- three of these, and listing them means check.lua verifies each is present
  -- rather than passing over an empty list.
  files = { "package.lua", "init.lua", "syntax.lua" },

  entry = "init.lua",
}
