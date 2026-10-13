-- The markdown syntax definition. Data only: no require, no functions.
--
-- Moved here verbatim from `X/syntax/markdown.lua`, which was a single-file plugin
-- carrying this table inside its `init`. It is a module of the package rather than
-- a body of `init.lua` for one reason: six language packages then have identical
-- `init.lua` files, and the part of this that can be wrong is data.
--
-- Read by `require "markdown.syntax"` from init.lua. Nothing else may require it,
-- because a definition added twice is a definition that shadows the first one for
-- the rest of the session.
return {
  files = { "%.md$", "%.markdown$" },
  patterns = {
    { pattern = "\\.",                    type = "normal"   },
    { pattern = { "<!%-%-", "%-%->" },    type = "comment"  },
    { pattern = { "```", "```" },         type = "string"   },
    { pattern = { "``", "``", "\\" },     type = "string"   },
    { pattern = { "`", "`", "\\" },       type = "string"   },
    { pattern = { "~~", "~~", "\\" },     type = "keyword2" },
    { pattern = "%-%-%-+",                type = "comment" },
    { pattern = "%*%s+",                  type = "operator" },
    { pattern = { "%*", "[%*\n]", "\\" }, type = "operator" },
    { pattern = { "%_", "[%_\n]", "\\" }, type = "keyword2" },
    { pattern = "#.-\n",                  type = "keyword"  },
    { pattern = "!?%[.-%]%(.-%)",         type = "function" },
    { pattern = "https?://%S+",           type = "function" },
  },
  symbols = { },
}
