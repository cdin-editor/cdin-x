-- The part of a seam's lifecycle that features and with genuinely share.
--
-- A seam is a file inside a package that registers something when both sides are
-- ready: a feature (`features/<key>.lua`) a package can switch off, or a `with`
-- entry (`with/<file>.lua`) that wires two packages together. Both are required
-- as a module, both must return a table carrying `enable()`, and both are called
-- the same way. That shared part lives here.
--
-- Why it is its own file. It was duplicated, and the duplication was not
-- harmless: `with` dropped the cached module when `enable()` raised and
-- `features` did not, so a feature whose enable raised stayed cached as a
-- half-built module and every retry was handed that same copy. The two copies
-- drifted because there were two of them. One copy cannot drift from itself, and
-- this is the step that drifted.
--
-- What is deliberately NOT here, and why:
--
--   * how a seam's module name is derived -- features builds one from the
--     package and the key, with resolves a path that may not be a module name at
--     all, and that check has to happen before anything is required;
--   * where a raised seam is recorded and under what key;
--   * the order seams come down in. Both callers sort, but they sort different
--     things: features holds the module itself in its table, while with holds a
--     record wrapped around it, so a shared sort would have to be told which of
--     the two shapes it is looking at before it could read an order off it. That
--     is an adapter for one comparison, and it stays with the caller. (with's
--     sort read `_order` off the record instead of the module and so did not
--     sort at all; that is fixed in with.lua, not here.)
--
-- Every message here is built from `who.pkg`, `who.kind`, `who.name` and
-- `who.file`, which is what lets the two callers keep their own wording
-- (`feature "x"` against `with "y"`, `features/x.lua` against the path the author
-- wrote) without either of them owning the logic.
local Seam = {}

--- Requires a seam module, checks its shape, raises it, and forgets it if the
--- raise did not work out.
---
--- The `package.loaded` reset is the reason this function exists rather than a
--- plain `require`: `require` caches on success, so a module whose `enable()`
--- raised is left cached as a half-built copy whose own guard may already claim
--- it is on. A retry then receives that copy and does nothing, or registers a
--- second time. Clearing the cache makes the retry re-read the file.
---
--- Three kinds of failure, and only one of them is this function's to handle. A
--- loader that raised is never cached by `require` at all, so it already re-reads
--- on a retry. A module that loaded but has the wrong shape -- not a table, or no
--- `enable()` -- stays in `package.loaded`, so a retry is handed that same copy
--- and fails again without re-reading. Nothing was registered on the way to that
--- failure, so it repeats rather than corrupting: the error is the same and the
--- result is the same nil either way. What it costs is that a file corrected on
--- disk mid-session is not re-read until the editor restarts, and that the cached
--- entry is visible to anything else that requires the same name. That is
--- accepted deliberately: a wrong shape is a packaging mistake, `check.lua` R8
--- catches most of them before they ship, and the remedy there is to update the
--- package rather than toggle it. An `enable()` that raised is the third kind and
--- the one evicted above, because there the module is half-built rather than
--- merely wrong.
---
--- `pass_arg` exists because the two callers disagree, and the difference is
--- observable: `features` always passes an argument, even a nil one, while `with`
--- calls `enable()` with none. `f(nil)` and `f()` are the same to most functions
--- and different to anything reading `select("#", ...)`, so the distinction is
--- kept rather than normalised away.
--- @param module_name string  the module to require
--- @param who table  { pkg, kind, name, file }  how this seam is named in a message
--- @param arg any|nil  the argument for enable(), ignored unless pass_arg
--- @param pass_arg boolean|nil  true to call enable(arg), false/nil for enable()
--- @return table|nil mod
--- @return string|nil err
function Seam.raise(module_name, who, arg, pass_arg)
  local ok, mod = pcall(require, module_name)
  if not ok then
    return nil,
      string.format("%s: %s %q did not load: %s", who.pkg, who.kind, who.name, tostring(mod))
  end
  if type(mod) ~= "table" then
    return nil, string.format("%s: %s must return a table, got %s", who.pkg, who.file, type(mod))
  end
  if type(mod.enable) ~= "function" then
    return nil, string.format("%s: %s has no enable()", who.pkg, who.file)
  end

  local raised, err
  if pass_arg then
    raised, err = pcall(mod.enable, arg)
  else
    raised, err = pcall(mod.enable)
  end
  if not raised then
    package.loaded[module_name] = nil
    return nil,
      string.format("%s: %s %q failed to enable: %s", who.pkg, who.kind, who.name, tostring(err))
  end

  return mod
end

return Seam
