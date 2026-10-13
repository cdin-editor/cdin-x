-- Vim-style modal editing and the ex command line.
--
-- Vim core owns *only* vim's own vocabulary — motions, operators, the ex-commands
-- for files, the shell escape, the mode pill. Everything that needs another
-- package's behaviour is a `with` entry under `with/`, and everything that is
-- vim's own surface but optional is a feature under `features/`. Both reach vim
-- through the single registry in registry.lua (ex-commands, the Ctrl+W map, the
-- "g" map, single keys, and events).
--
-- Layout:
--   package.lua    the manifest: data only, read in a sandbox
--   init.lua       this file — the one load point
--   registry.lua   the extension points features and with-entries register into
--   commands.lua   vim's own cdin commands
--   keymap.lua     vim's own non-modal key bindings
--   ex/            the ":" command line, split by concern
--   shell/         running shell commands and showing their output
--   vimode/        modal editing: the key reader, motions, text objects,
--                  the operators, mode state, and the status pill
--   menus/         vim's file, shell and build menus
--   plugin-manager/ the "M" key
--   features/      menus.lua, plugin-manager.lua
--   with/          git.lua, search.lua, tab.lua, treeview.lua, window.lua
--   git/ search/ tab/ treeview/ window/
--                  the modules each with-entry owns
--
-- Two ordering rules hold the whole thing together, and both come from where
-- `vim.main` is defined.
--
-- It is defined *here*, in init, rather than in the menus feature. Four things
-- extend it — the plugin-manager feature and the git, search and treeview
-- with-entries — and `menu.extend` asserts the menu exists. Had the definition
-- lived in an optional part, whether an extender worked would have depended on
-- two optional things happening to load in the right order. init always runs
-- first, so `vim.main` is always there.
--
-- And it is guarded rather than required, because the `menu` package is optional.
-- A user with vim and no menus gets every key and no menu, which is the same
-- degradation every menu extender already had.
local menus_menu = nil

local M = {}

-- `vim_mode_enabled` is a *host* config key, not a package option: the host reads
-- it, so it is written at the top level. `vim.vim_mode_enabled` would be a key
-- nothing reads. The default lives here because package.lua is data and cannot be
-- required.
M.config = { vim_mode_enabled = true }

local loaded = nil

function M.init(core, config)
  if loaded then return end

  -- Apply this plugin's own default, before anything reads it.
  --
  -- M.config above is a declaration, not an application: nothing in the runtime
  -- copies it onto config, so a default written there and nowhere else is simply
  -- never set. Every gate in vim mode tests
  -- `if not config.vim_mode_enabled then return false end`, so with the value left
  -- nil the key handler bails on the first keystroke and vim mode is silently off
  -- — which looks exactly like "vim is not loaded" and sends you looking for a key
  -- to turn it on with.
  --
  -- The guard is `== nil`, not `=`, so a user who set it in their
  -- ~/.config/cdin/user/init.lua keeps their value. That file runs before plugins,
  -- which is why this works.
  if config.vim_mode_enabled == nil then
    config.vim_mode_enabled = M.config.vim_mode_enabled
  end

  local ex       = require "vim.ex"
  local vimode   = require "vim.vimode"
  local commands = require "vim.commands"
  local keymap   = require "vim.keymap"
  local shell_commands = require "vim.shell.commands"
  local shell_keymap   = require "vim.shell.keymap"

  -- Order matters: the commands and keys have to exist before anything can
  -- trigger them, and ex must have its own commands registered before the first
  -- ":w" can be typed.
  commands.register()
  keymap.register()
  shell_commands.register()
  shell_keymap.register()
  ex.register()
  vimode.register()

  -- `vim.main` last, and before any feature or with-entry can extend it.
  local ok, registry = pcall(require, "menu.impl")
  if ok and type(registry) == "table" then
    -- The registry is handed to register() rather than required inside
    -- with/menus/menu.lua, because that file has to stay requireable without the
    -- menu package -- it is what the menu exists for. So the one place that
    -- certainly has the registry is the one that passes it.
    menus_menu = require "vim.with.menus.menu"
    menus_menu.register(registry)
  end

  loaded = {
    ex = ex, vimode = vimode, commands = commands, keymap = keymap,
    shell_commands = shell_commands, shell_keymap = shell_keymap,
  }

  core.log("Vim extension loaded")
end

function M.unload()
  if not loaded then return end
  -- Unwind in the reverse order of registration. The menu is unregistered last
  -- because it was registered last, and the menu extenders -- features and
  -- with-entries -- are already down by the time this runs: the kernel tears them
  -- down before it calls unload.
  loaded.vimode.unregister()
  loaded.ex.unregister()
  loaded.shell_keymap.unregister()
  loaded.shell_commands.unregister()
  loaded.keymap.unregister()
  loaded.commands.unregister()
  if menus_menu then menus_menu.unregister(); menus_menu = nil end
  loaded = nil
end

return M