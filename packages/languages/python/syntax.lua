-- The python syntax definition. Data only: no require, no functions.
--
-- Moved here verbatim from `X/syntax/python.lua`, which was a single-file plugin
-- carrying this table inside its `init`. It is a module of the package rather than
-- a body of `init.lua` for one reason: six language packages then have identical
-- `init.lua` files, and the part of this that can be wrong is data.
--
-- Read by `require "python.syntax"` from init.lua. Nothing else may require it,
-- because a definition added twice is a definition that shadows the first one for
-- the rest of the session.
return {
  files = { "%.py$", "%.pyw$" },
  headers = "^#!.*[ /]python",
  comment = "#",
  patterns = {
    { pattern = { "#", "\n" },            type = "comment"  },
    { pattern = { '[ruU]?"', '"', '\\' }, type = "string"   },
    { pattern = { "[ruU]?'", "'", '\\' }, type = "string"   },
    { pattern = { '"""', '"""' },         type = "string"   },
    { pattern = "0x[%da-fA-F]+",          type = "number"   },
    { pattern = "-?%d+[%d%.eE]*",         type = "number"   },
    { pattern = "-?%.?%d+",               type = "number"   },
    { pattern = "[%+%-=/%*%^%%<>!~|&]",   type = "operator" },
    { pattern = "[%a_][%w_]*%f[(]",       type = "function" },
    { pattern = "[%a_][%w_]*",            type = "symbol"   },
  },
  symbols = {
    ["class"]    = "keyword",
    ["finally"]  = "keyword",
    ["is"]       = "keyword",
    ["return"]   = "keyword",
    ["continue"] = "keyword",
    ["for"]      = "keyword",
    ["lambda"]   = "keyword",
    ["try"]      = "keyword",
    ["def"]      = "keyword",
    ["from"]     = "keyword",
    ["nonlocal"] = "keyword",
    ["while"]    = "keyword",
    ["and"]      = "keyword",
    ["global"]   = "keyword",
    ["not"]      = "keyword",
    ["with"]     = "keyword",
    ["as"]       = "keyword",
    ["elif"]     = "keyword",
    ["if"]       = "keyword",
    ["or"]       = "keyword",
    ["else"]     = "keyword",
    ["import"]   = "keyword",
    ["pass"]     = "keyword",
    ["break"]    = "keyword",
    ["except"]   = "keyword",
    ["in"]       = "keyword",
    ["del"]      = "keyword",
    ["raise"]    = "keyword",
    ["yield"]    = "keyword",
    ["assert"]   = "keyword",
    ["self"]     = "keyword2",
    ["None"]     = "literal",
    ["True"]     = "literal",
    ["False"]    = "literal",
  }
}
