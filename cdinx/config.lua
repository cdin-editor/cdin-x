-- CDIN-X runtime defaults.
local config = require "core.config"
local sep = PATHSEP or package.config:sub(1, 1)
local is_win = sep == "\\"

local function env(name)
  local v = os.getenv(name)
  return v and v ~= "" and v or nil
end

local home
local config_home
local data_home

if is_win then
  home = env("USERPROFILE") or env("HOME") or "."
  config_home = env("APPDATA") or (home .. "\\AppData\\Roaming")
  data_home = env("LOCALAPPDATA") or env("APPDATA") or (home .. "\\AppData\\Local")
else
  home = env("HOME") or "."
  config_home = env("XDG_CONFIG_HOME") or (home .. "/.config")
  data_home = env("XDG_DATA_HOME") or (home .. "/.local/share")
end

local base_config = config_home .. sep .. "cdin"
local base_data   = data_home .. sep .. "cdin"

config.site_dir       = config.site_path()

config.bundle_dir     = config.bundle_dir or config.data_dir

config.user_root      = config.user_root or base_config
config.user_dir       = config.user_dir or (base_config .. sep .. "user")

config.legacy_extension_dir = config.extension_dir and nil
                            or (base_data .. sep .. "extensions")
config.extension_dir  = config.extension_dir
                     or (base_data .. sep .. "extensions" .. sep .. "X")
config.registry_dir   = config.registry_dir or (env("CDIN_X_REGISTRY")
                                        or (base_data .. sep .. "registry" .. sep .. "cdin-x"))
-- Where third-party installs live: `<name>/` holds only the selected runtime
-- files, never a `.git`. Flat, like a build's `data/packages/`, and for the same
-- reason -- the kernel reads it as an ordinary catalog source, so the shape is one
-- rule rather than two. `cache/` holds transient clones, deleted after each
-- install whether it succeeded or not.
config.store_dir      = config.store_dir or (base_data .. sep .. "packages")
config.cache_dir      = config.cache_dir or (base_data .. sep .. "cache")
config.state_file     = config.state_file or (base_data .. sep .. "extensions.lua")
-- The user's own choices, next to their init.lua and not beside the state file.
-- Two different directories on purpose: `state_file` is written by the editor and
-- lives with the machine's data; this one is written by the user and lives with
-- their configuration, where they will look for it.
config.packages_file  = config.packages_file or (base_config .. sep .. "packages.lua")
-- Beside `packages.lua`, not beside the state file: the lock is what the user
-- would commit and share, and a file in the machine's data directory is neither.
-- `<data>/extensions.lua` stays the editor's own record; this is its reviewable
-- projection, and either one can be rebuilt from the other.
config.lock_file      = config.lock_file or (base_config .. sep .. "cdin-x.lock")
-- The one place the registry is named. Nothing derives a second URL from it:
-- the catalog is read out of the clone this fetches, so there is no raw-file
-- base URL to keep in step with the branch.
config.registry_url   = config.registry_url or "https://github.com/m-mdy-m/cdin-x.git"

return config