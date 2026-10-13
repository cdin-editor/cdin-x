-- Front-end work: the two languages a browser project is written in, the version
-- control and navigation tools that go with it, and search.
--
-- `themes` is here because a theme is editor infrastructure, not a capability of
-- one field of work: a bundle that shipped no theme would boot into whatever the
-- host falls back to, and the host tolerates that silently. Every domain bundle
-- therefore carries it, the same way `standard` does.
--
-- Nothing here implies a language the repository does not have. CSS and HTML have
-- no package yet, and there is no way to write one today beyond copying a
-- definition: they are listed under `optional`, which bundle.py reports as
-- missing and which the build does not stop for. That is a record of what a
-- front-end bundle would want, not a claim that it is here.
--
-- What would actually be needed for CSS and HTML is a `lang-css` and a
-- `lang-html` package, each a manifest and a syntax.lua, exactly as the six
-- languages here are. That is future work and it is deliberately not faked.
return {
  name = "web-frontend",
  kind = "bundle",
  version = "1",
  description = "Front-end languages with version control, navigation and search.",

  includes = {
    "lang-javascript",
    "lang-typescript",
    "lang-markdown",
    "themes",
    "git",
    "treeview",
    "search",
  },

  -- Named, not present. See the note above.
  optional = { "lang-css", "lang-html" },
}
