-- Shell execution as a capability.
--
-- This is the only part of vim mode that is not really about editing:
-- ":!cmd" needs somewhere to run a command and somewhere to put the
-- output. Integrations reuse it rather than each writing their own
-- io.popen wrapper (with/git.lua runs every git command through here).
--
-- Layout of this directory:
--   init.lua     capture / run / run_in_buffer / platform
--   commands.lua the vim-shell:* commands
--   keymap.lua   key bindings for those commands
--
-- The commands and bindings live in their own files, and register /
-- unregister are explicit, so disabling the shell leaves nothing behind.
local core   = require "core"
local Doc    = require "core.doc"
local config = require "core.config"

local M = {}

M.IS_WIN = PATHSEP == "\\"

if config.shell_win         == nil then config.shell_win         = "cmd" end
if config.shell_capture_win == nil then config.shell_capture_win = "cmd" end

-- ── quoting ──────────────────────────────────────────────────────────────
function M.shell_quote(s)
  if M.IS_WIN then
    return '"' .. s:gsub('"', '""') .. '"'
  end
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

function M.capture(cmd)
  local full
  if not M.IS_WIN then
    full = cmd .. " 2>&1"
  elseif config.shell_capture_win == "powershell" then
    full = 'powershell -NoProfile -NonInteractive -Command "'
        .. cmd:gsub('"', '\\"') .. ' 2>&1"'
  else
    full = 'cmd /c "' .. cmd .. '" 2>&1'
  end

  local ok, fp = pcall(io.popen, full, "r")
  if not ok or not fp then
    return nil, ("shell: could not launch: %s"):format(cmd)
  end
  local out     = fp:read("*a")
  local success = fp:close()
  if success == false then
    return out or "", ("shell: command exited with error: %s"):format(cmd)
  end
  return out or "", nil
end

-- Fire and forget — no buffer, no waiting.
function M.run(cmd)
  system.exec(cmd)
end

function M.run_in_buffer(cmd)
  core.log("shell: running %s", cmd)

  local output, err = M.capture(cmd)
  local header = ("-- :!%s\n-- %s\n\n"):format(cmd, os.date("%Y-%m-%d %H:%M:%S"))
  local content = header .. (output or "") .. (err and ("\n\n-- [error] " .. err) or "")

  local doc = Doc()
  doc:text_input(content)
  doc:set_selection(1, 1)
  -- The output is not a file the user edited, so it is not unsaved work.
  -- text_input() moved the undo index, which left the doc dirty; without
  -- clean() every :q after a :! asked to discard "unsaved changes" to a
  -- buffer of command output.
  doc:clean()
  doc.name = ":!" .. cmd
  function doc:get_name() return self.name end
  core.root_view:open_doc(doc)

  if err then core.error("shell: %s", err) else core.log("shell: done") end
end

-- Ask for a command line, then run what was typed. Bound to
-- vim-shell:run-custom.
function M.prompt_and_run()
  core.command_view:enter(":! shell command", function(cmd)
    if cmd == "" then core.error("shell: empty command"); return end
    M.run_in_buffer(cmd)
  end, function() return {} end)
  core.command_view:set_text("")
end

-- Open a separate terminal window. Non-blocking: cdin keeps running.
--
-- `system.exec` starts a process; it does not go through a shell. `start` is a
-- cmd *builtin*, so handing it straight over asks the loader for an executable
-- called "start", finds none, and fails in silence — which is what
-- `vim-shell:open-terminal` was doing on Windows: the command ran, the key did
-- nothing, and nothing was logged. Every other Windows call site in this
-- repository wraps in `cmd.exe /C` for the same reason (see
-- `cdinx/manager/fetch.lua` and `X/core/git/manager/ops.lua`).
--
-- `-NoExit` matters as much as the wrapping: without it the new shell runs,
-- prints its prompt, and closes before anyone can type.
function M.open_terminal()
  if not M.IS_WIN then
    local term = os.getenv("TERMINAL") or os.getenv("TERM_PROGRAM") or "xterm"
    system.exec(term)
    return
  end
  local shell = config.shell_win
  local target
  if shell == "powershell" then
    target = "powershell -NoExit"
  elseif shell == "pwsh" then
    target = "pwsh -NoExit"
  else
    target = "cmd"
  end
  system.exec('cmd.exe /C start ' .. target)
end

function M.platform()
  if M.IS_WIN then return "windows" end
  local out = M.capture("uname -s") or ""
  if out:find("Darwin") then return "macos" end
  return "linux"
end

return M
