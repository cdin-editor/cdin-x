-- The lua syntax definition. Data only: no require, no functions.
--
-- Moved here verbatim from `X/syntax/lua.lua`, which was a single-file plugin
-- carrying this table inside its `init`. It is a module of the package rather than
-- a body of `init.lua` for one reason: six language packages then have identical
-- `init.lua` files, and the part of this that can be wrong is data.
--
-- Read by `require "lua.syntax"` from init.lua. Nothing else may require it,
-- because a definition added twice is a definition that shadows the first one for
-- the rest of the session.
return {
  files = "%.lua$",
  headers = "^#!.*[ /]lua",
  comment = "--",
  patterns = {
    { pattern = { '"', '"', '\\' },       type = "string"   },
    { pattern = { "'", "'", '\\' },       type = "string"   },
    { pattern = { "%[%[", "%]%]" },       type = "string"   },
    { pattern = { "%-%-%[%[", "%]%]"},    type = "comment"  },
    { pattern = "%-%-.-\n",               type = "comment"  },
    { pattern = "-?0x%x+",                type = "number"   },
    { pattern = "-?%d+[%d%.eE]*",         type = "number"   },
    { pattern = "-?%.?%d+",               type = "number"   },
    { pattern = "<%a+>",                  type = "keyword2" },
    { pattern = "%.%.%.?",                type = "operator" },
    { pattern = "[<>~=]=",                type = "operator" },
    { pattern = "[%+%-=/%*%^%%#<>]",      type = "operator" },
    { pattern = "[%a_][%w_]*%s*%f[(\"{]", type = "function" },
    { pattern = "[%a_][%w_]*",            type = "symbol"   },
    { pattern = "::[%a_][%w_]*::",        type = "function" },
  },
  symbols = {
    ["if"]       = "keyword",
    ["then"]     = "keyword",
    ["else"]     = "keyword",
    ["elseif"]   = "keyword",
    ["end"]      = "keyword",
    ["do"]       = "keyword",
    ["function"] = "keyword",
    ["repeat"]   = "keyword",
    ["until"]    = "keyword",
    ["while"]    = "keyword",
    ["for"]      = "keyword",
    ["break"]    = "keyword",
    ["return"]   = "keyword",
    ["local"]    = "keyword",
    ["in"]       = "keyword",
    ["not"]      = "keyword",
    ["and"]      = "keyword",
    ["or"]       = "keyword",
    ["goto"]     = "keyword",
    ["self"]     = "keyword2",
    ["true"]     = "literal",
    ["false"]    = "literal",
    ["nil"]      = "literal",
  },
}
