-- Registers the javascript syntax definition, and cannot take it back.
--
-- The whole file, because there is only one thing to do and the reason it cannot
-- be undone is the interesting part.
--
-- `core.syntax.add` appends to a list the host walks backwards, and the contract
-- says plainly that there is no `remove`: a definition added from a package's
-- `init` lasts for the session. So `unload` is empty, and that is the documented
-- shape rather than an oversight -- the alternative would be reaching into the
-- host's table to find and cut the entry, which the contract's "never write to
-- them" forbids and which would leave the tokenizer holding a table this package
-- no longer owns.
--
-- What the empty `unload` does mean in practice: switching this package off stops
-- it being loaded, and does not stop a .js file being highlighted by the
-- definition it already registered. The definition and the package are no longer
-- the same thing after the first `init`.
--
-- The guard is not decoration. This file is dofile'd as the entry point and may
-- also be require'd by another package, and those are two module instances with
-- two independent guards; without it, both register and the second definition
-- wins -- which would look correct and be reached only by a reinstall.
local M = {}

function M.init()
  if M.registered then return end
  M.registered = true
  require("core.syntax").add(require("lang-javascript.syntax"))
end

function M.unload()
  M.registered = false
end

return M
