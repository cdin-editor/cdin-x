-- Vim mode's load point: it takes over key dispatch and delegates every
-- decision to keys.lua, then wires up the sub-modules that make up the
-- feature.
--
-- Layout of this directory:
--   init.lua       patches keymap.on_key_pressed; the single load point
--   keys.lua       the normal/visual key reader, the state machine
--   text.lua       position and range arithmetic over a document
--   motions.lua    where a key sends the caret, and whether an operator should
--                  include the character it lands on
--   textobjects.lua the i/a objects: two keys naming a region rather than a
--                  place
--   operators.lua  doing something with a span, and the clipboard they share
--   mode.lua       per-view mode state (normal/insert/visual/visual-line) + label
--   status.lua     the mode pill and the home-screen help entries
--
-- The split is not arbitrary. `text.lua` is arithmetic, `motions.lua` and
-- `textobjects.lua` are rules that use it, `operators.lua` is the only place
-- that changes a buffer, and `keys.lua` is the only place that knows a key
-- exists. An operator needs to know where a motion *ended*, which is why the
-- motion table is not a list of command names — see the header of motions.lua.
local core    = require "core"
local config  = require "core.config"
local keymap  = require "core.input.keymap"
local keys    = require "vim.vimode.keys"
local mode    = require "vim.vimode.mode"
local status  = require "vim.vimode.status"

local M = {}

local original_on_key_pressed = keymap.on_key_pressed

function core.get_vim_mode_label()
  if not config.vim_mode_enabled then return nil end
  local view = core.active_docview()
  if not view then return nil end
  return mode.label(view)
end

function M.register()
  status.register()

  keymap.on_key_pressed = function(k)
    local ok, handled = core.try(keys.handle_key, k)
    if ok and handled then
      if system.suppress_next_textinput then
        system.suppress_next_textinput()
      end
      return true
    end
    return original_on_key_pressed(k)
  end
end

function M.unregister()
  keymap.on_key_pressed = original_on_key_pressed
  keys.reset()
end

return M