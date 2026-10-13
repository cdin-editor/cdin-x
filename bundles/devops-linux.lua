-- Systems work: the two languages a systems programmer reads most, and the
-- editing tools that go with them.
--
-- `themes` is here because a theme is editor infrastructure, not a capability of
-- one field of work: a bundle that shipped no theme would boot into whatever the
-- host falls back to, and the host tolerates that silently. Every domain bundle
-- therefore carries it, the same way `standard` does.
--
-- This is the largest of the three because it is the only kind of work here that
-- wants a text editor to be a text editor: `vim` for modal editing, `launcher`
-- for the command palette, `workspace` for tabs and splits, `text-tools` for
-- right-to-left text and codepoint inspection.
--
-- The shell languages are NOT in this bundle. A shell is the first thing anyone
-- working on a Linux box reads, and cdin has no definition for one, so `lang-bash`
-- is named under `optional` to record the gap rather than to ship it. That is the
-- single largest hole in a bundle called `devops-linux`, and it is deliberate.
--
-- No per-platform gating here either: a bundle is a list, and `os` filtering per
-- package is what 6.2 describes. Nothing in this list is Linux-only, so nothing in
-- it needs a gate today.
return {
  name = "devops-linux",
  kind = "bundle",
  version = "1",
  description = "Shell and systems languages with modal editing and navigation.",

  includes = {
    "lang-lua",
    "lang-c",
    "vim",
    "themes",
    "launcher",
    "workspace",
    "text-tools",
    "git",
    "treeview",
    "search",
  },

  -- Named, not present. See the note above.
  optional = { "lang-bash", "lang-yaml", "lang-rust", "lang-go" },
}
