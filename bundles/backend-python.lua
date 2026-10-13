-- Python work: the language, with the version control, navigation, search and
-- completion tools a Python project is edited with.
--
-- `themes` is here because a theme is editor infrastructure, not a capability of
-- one field of work: a bundle that shipped no theme would boot into whatever the
-- host falls back to, and the host tolerates that silently. Every domain bundle
-- therefore carries it, the same way `standard` does.
--
-- `complete` is here because completion over open documents is the one provider
-- cdin has today that needs no language server. A real Python completion engine
-- would be an LSP integration, and cdin has no LSP surface at all: 8.4 records
-- that as unavailable and this bundle does not pretend otherwise.
--
-- `lang-sql` is listed under `optional` and does not exist. A backend bundle that
-- only speaks Python is a real gap rather than a hypothetical one, and this is
-- where it is written down.
return {
  name = "backend-python",
  kind = "bundle",
  version = "1",
  description = "Python with version control, navigation, search and completion.",

  includes = {
    "lang-python",
    "themes",
    "git",
    "treeview",
    "search",
    "complete",
  },

  -- Named, not present. See the note above.
  optional = { "lang-sql" },
}
