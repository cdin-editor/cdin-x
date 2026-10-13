-- luacheck configuration for cdin-x.
--
-- `globals` is empty because nothing in this repository is allowed to create a
-- global. `read_globals` holds what cdin provides and this repository reads.
-- Each name here is checked against cdin's source rather than remembered:
--
--   set from C in `lua_setup_globals`: ARGS, VERSION, PLATFORM, SCALE, EXEFILE,
--     and LOGFILE
--   set by cdin's Lua bootstrap:      PATHSEP, EXEDIR
--   exposed as globals by C:          system, renderer
--
-- Two are listed defensively rather than because they exist today: `CDIN_VERSION`
-- is a *C macro* (`-DCDIN_VERSION=...`) and is not a Lua global, but host.lua falls
-- back to it in case a host starts setting one, and reading a global it does not
-- define is not a bug. `LOGFILE` is real and unused -- a place where a log path is
-- reachable without going through the log itself.
--
-- Anything else that shows up as undefined is a bug to fix, not a name to add:
-- `core`, for instance, is a module and has to be required.
std = "lua54"
max_line_length = 100

-- One writable global field, and it is not a global in the sense that matters.
-- The loader hangs its shared state off the `package` table so that reloading
-- cdinx/manager/loader.lua finds what the previous copy left instead of
-- installing a second searcher. It has to be *writable* -- the module creates it
-- on first use -- which is why it is here and not in `read_globals`. No name is
-- created; a field on a table the host already made is.
globals = { "package.cdinx_store" }

read_globals = {
  "ARGS", "VERSION", "PLATFORM", "SCALE", "EXEFILE", "EXEDIR", "PATHSEP",
  "system", "renderer", "CDIN_VERSION", "LOGFILE",
}

files["scripts/"] = {
  -- The dev scripts run with plain lua and no editor: they shell out and read
  -- files by path, which is the whole of what they do.
  read_globals = { "io", "os", "arg", "package", "debug" },
}
