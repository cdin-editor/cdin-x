-- Vim's normal- and visual-mode key handling.
--
-- This file owns only *vim's own* vocabulary: motions, the i/a/o entry points,
-- operators (d, y, c, =, gu, gU, g~ and the two shifts), counts, the two-key
-- sequences, and the modes. Every key that belongs to some other plugin is
-- looked up in the registry (vim.registry) after vim's own keys have
-- declined it, which is why there is no `if k == "/"` or `if k == "m"` here:
--
--   / n N *        -> with/search.lua        (registry.call_key)
--   m              -> with/menus.lua          (registry.call_key)
--   shift+m        -> with/plugin-manager.lua(registry.call_key)
--   tab            -> with/window.lua        (registry.call_key)
--   gt / gT        -> with/tab.lua           (registry.call_gmap)
--   ctrl+w {c}     -> with/window.lua        (registry.wmap_get)
--
-- ── what was broken, and why ─────────────────────────────────────────────
--
-- The reader used to hold one piece of half-typed state: a key and a count
-- buffer. `d` set `pending`, and the very next key ran `abandon_sequence`, which
-- threw `pending` away because that key was not `d` — so `dw` was `w`, and `dw`
-- moved the cursor instead of deleting a word. Operators composed with nothing,
-- because there was no composition to compose: the reader had a table of
-- key -> command name, and a command name cannot say where a motion *ended*,
-- which is the only thing an operator needs to know. And the count buffer was
-- parsed and then read by exactly one key, `gt`, so `3x` cut one character.
--
-- So there are six kinds of half-typed state now instead of one, and the count
-- is consumed by everything rather than by `gt`.
local core      = require "core"
local config    = require "core.config"
local command   = require "core.input.command"
local keymap    = require "core.input.keymap"
local registry  = require "vim.registry"
local exline    = require "vim.ex.commandline"
local mode      = require "vim.vimode.mode"
local motions   = require "vim.vimode.motions"
local objects   = require "vim.vimode.textobjects"
local operators = require "vim.vimode.operators"
local text      = require "vim.vimode.text"

local M = {}

-- How long the *sequences* stay live. A pending operator and a pending find do
-- not use this: vim waits for them indefinitely and so should this, because the
-- point of `d` followed by a motion is the moment in between where you read the
-- line before deciding. `Esc` is the way out of both.
local SEQUENCE_TIMEOUT = 0.6

-- ── what a key *is* ──────────────────────────────────────────────────────
--
-- The host reports the *unshifted* key and a separate shift flag — SDL's
-- `GetKeyName` for the 4 key is "4", and holding shift turns it into "$". A
-- punctuation key therefore arrives in one of two spellings: as the base key
-- with shift held (`4` and shift for `$`, `'` and shift for `"`), or as the
-- character itself (`4` plain for `$`, `"` plain for `"`).
--
-- Both are accepted, and that is not belt-and-braces. Without the table below
-- `"` is read as `'` with shift held, the capitals table has no branch for it,
-- and the key is swallowed — so `yi"`, `di"` and `ci"` do nothing at all, with
-- no error and nothing on screen to say why. That is the bug this reader is
-- being rewritten for.
local SHIFTED = {
  ["1"] = "!",  ["2"] = "@",  ["3"] = "#",  ["4"] = "$",  ["5"] = "%",
  ["6"] = "^",  ["7"] = "&",  ["8"] = "*",  ["9"] = "(",  ["0"] = ")",
  ["-"] = "_",  ["="] = "+",  ["["] = "{",  ["]"] = "}",  ["\\"] = "|",
  [";"] = ":",  ["'"] = '"',  [","] = "<",  ["."] = ">",  ["/"] = "?",
  ["`"] = "~",
}

-- The keys the host reports by name, spelled the way vim spells the motion they
-- mean.
--
-- The host reports a key it cannot print by its name — `up`, `left`, `home` —
-- and vim has *none* of those keys at all, so without this table they reach the
-- motion table as the word "home", match nothing, and are then swallowed by the
-- reader. In insert mode that is invisible, because insert mode is not reading
-- keys at all and the host moves the caret. In normal and visual mode the caret
-- simply does not go anywhere, with nothing on screen to say why — which reads
-- as "Home is broken in vim mode" rather than as "this plugin does not
-- implement Home".
--
-- Character-wise on purpose for the four arrows: they are the same motions as
-- `hjkl`, so a count works (`3` then right-arrow), an operator works (`d` then
-- right-arrow), and visual mode extends the selection the way `l` does. Not
-- word-wise, which some configurations bind, and which would silently change
-- what `d` then right-arrow deletes.
--
-- `home` is `0` and `end` is `$` because that is what they are in vim — column
-- one and the last character of the line, not the first non-blank — and because
-- it is what the host's own `home` / `end` already do. `space` is `l` for the
-- same reason `right` is: vim has no space bar either, and a space that does
-- nothing in normal mode is not vim. `return` is `+`, the first non-blank of
-- the line below, which is vim's `<CR>`; left alone it would reach the host's
-- `doc:newline` and open a line in normal mode.
local NAMED = {
  left = "h", right = "l", up = "k", down = "j",
  home = "0", ["end"] = "$",
  space = "l",
  ["return"] = "+", ["keypad enter"] = "+",
}

-- The character a key produces, whichever spelling it arrived in.
--
-- A shifted letter comes out uppercase, so the rest of this file compares
-- against `D` and `J` rather than against `d` and `j` — which is the point of
-- the capitals table at all. `token_for` below keeps the lowercase base for the
-- registry's `shift+` spelling.
local function character(k, shift)
  if shift then
    local shifted = SHIFTED[k]
    if shifted then return shifted end
    if k:match("^%l$") then return k:upper() end
  end
  return k
end

-- The name the plugin registry is asked about.
--
-- A shifted symbol goes by its character, so `*` arrives as `"*"` and not as
-- `"shift+8"`; an uppercase letter keeps the `shift+` spelling, because that is
-- how an integration registers it — with/search.lua binds `["shift+n"]` for `N`. A
-- binding whose spelling never arrives cannot fire, which is why with/search.lua's
-- `*`, registered as `"*"`, was dead until this table existed.
local function token_for(k, shift)
  if not shift then return k end
  local shifted = SHIFTED[k]
  if shifted then return shifted end
  if k:match("^%l$") then return "shift+" .. k end
  return k
end

-- ── half-typed state ─────────────────────────────────────────────────────
--
-- One table, discriminated by `kind`, rather than six variables. The kinds are
-- mutually exclusive by construction — you cannot be waiting for a motion and a
-- target character at once — and keeping them together is what makes `M.reset` a
-- single assignment and makes it obvious that `Esc` clears exactly one thing.
--
--   operator     waiting for a motion, for `i`/`a`, or for itself again (`dd`)
--   operator_g   waiting for the second key of `dgg`
--   object       waiting for the name in `di"`
--   g            waiting for the second key of a `g` sequence
--   find         waiting for the target character of `f`
--   replace      waiting for the character of `r`
--   ctrl_w       waiting for the window command of `Ctrl+W`
local pending   = nil
local count_buf = ""
local last      = nil   -- the last change, for `.`
local remembered = nil  -- the last f/F/t/T, for `;` and `,`

local function stale()
  return not (pending and system.get_time() - pending.t < SEQUENCE_TIMEOUT)
end

-- Drop any half-typed state. Used when leaving insert mode and on unload.
function M.reset()
  pending   = nil
  count_buf = ""
end

-- A digit that belongs to a count. A leading `0` does not: in vim it is the
-- start-of-line motion, and `0` joins a count only once one has started, so
-- that `20` and `100` work and `0` still goes to the first column.
local function is_count_digit(k, buf)
  return k:match("^%d$") and (k ~= "0" or buf ~= "")
end

-- `2d3w` deletes six words in vim: the counts on either side of the operator
-- multiply. With only one of them it is that one, and with neither it is 0,
-- which every motion reads as "no count was typed" — `G` needs that to tell
-- `G` from `1G`.
local function combine(pre, post)
  pre, post = pre or 0, post or 0
  if pre > 0 and post > 0 then return pre * post end
  if pre > 0 then return pre end
  return post
end

-- ── the document ─────────────────────────────────────────────────────────

local function cursor(doc)
  local line, col = doc:get_selection()
  return line, col
end

-- What is selected, as a span, or nil when nothing is. `get_selection(true)`
-- sorts, so a selection dragged upwards comes back the right way round.
local function selection_span(doc)
  if not doc:has_selection() then return nil end
  local l1, c1, l2, c2 = doc:get_selection(true)
  return text.span(l1, c1, l2, c2)
end

-- ── running a change ─────────────────────────────────────────────────────
--
-- One entry point for `dw`, `di"` and `.`, so the repeat key is the same code the
-- key press was rather than a second copy of it that could disagree.
--
-- `last` records *what was asked for*, not the span that came out: the span is
-- recomputed at the new cursor position when `.` is pressed, which is the whole
-- reason `.` is useful on the next line rather than a replay at old coordinates.
local function change(view, op, remember)
  local changed, insert = operators.apply(op, view.doc, view, remember.span)
  if not changed then return false end
  last = { op = op, kind = remember.kind, key = remember.key,
           count = remember.count, name = remember.name }
  mode.set(view, insert and mode.INSERT or mode.NORMAL)
  return true
end

-- `cw` is the one place where `c` is not `d`: on a non-blank it behaves like
-- `ce`, so changing a word does not also eat the space after it. Someone typing
-- `cw` to fix a typo and losing the word boundary notices immediately.
--
-- Only on a non-blank. On whitespace `cw` really is `dw`, and turning that into
-- `ce` would leave the caret stranded past the word.
local function motion_for_c(op, char, doc, line, col)
  if op == "c" and char == "w" and not text.is_blank(text.char(doc, line, col)) then
    return motions.normal["e"]
  end
  return motions.normal[char]
end

-- The span `op` + `char` covers from (line, col).
local function motion_span(doc, op, char, line, col, count, ctx)
  return motions.span_for(motion_for_c(op, char, doc, line, col),
                          doc, line, col, count, ctx)
end

-- ── `.` ──────────────────────────────────────────────────────────────────
--
-- Replays the last change at the *new* cursor position. Only operators set
-- `last`; `x`, `p` and `r` are single-key commands with a count and no motion
-- behind them, and a repeat that silently forgot them would be worse than one
-- that never offered them. They leave `last` alone, so `.` after `x` repeats
-- whatever operator ran before it — which is what vim does.
local function repeat_last(view)
  if not last then return false end
  local doc = view.doc
  local line, col = cursor(doc)
  local span

  if last.kind == "motion" then
    span = motion_span(doc, last.op, last.key, line, col, last.count, nil)
  elseif last.kind == "object" then
    span = objects.find(last.name, doc, line, col)
  elseif last.kind == "eol" then
    span = text.span(line, col, line, text.eol(doc, line))
  elseif last.kind == "line" then
    span = text.line_span(doc, line, 1, line, 1)
  end

  if not span or text.is_empty(doc, span) then return false end
  return change(view, last.op, { span = span, kind = last.kind, key = last.key,
                                 count = last.count, name = last.name })
end

-- ── capitalised keys ─────────────────────────────────────────────────────
--
-- Reached only once the motion table and the operator table have both declined
-- the character. That is why `D` can mean "delete to end of line" while `d` is
-- an operator waiting for a motion: they are different keys, and vim has always
-- given them different meanings.
--
-- It answers "did I claim this key", and false means *nobody* has yet — the
-- registry has not been asked and the host has not seen it. A bare `return true`
-- here is what made every key the host reports by name vanish: a shifted `f3`,
-- which matches no branch, still reported itself handled, so `f3` reached
-- neither the integration that registered it nor the host.
local function handle_shifted(view, char, count)
  local doc  = view.doc
  local line, col = cursor(doc)
  local ok = false

  -- `char` is already uppercase by the time it reaches here: `character()`
  -- turns a shifted letter into its capital, so every comparison below is
  -- against `D` and `J`, never against `d` and `j`. Comparing against the
  -- lowercase and relying on the caller to shift the flag separately is what
  -- let `D` reach the operator table as a plain `d` and become a pending delete
  -- instead of deleting to the end of the line.

  if char == "G" then
    pending = { kind = "g", t = system.get_time() }
    return true
  elseif char == "I" then
    doc:set_selection(line, text.first_nonblank(doc, line))
    mode.set(view, mode.INSERT)
    ok = true
  elseif char == "A" then
    doc:set_selection(line, text.eol(doc, line))
    mode.set(view, mode.INSERT)
    ok = true
  elseif char == "O" then
    command.perform("doc:newline-above")
    mode.set(view, mode.INSERT)
    ok = true
  elseif char == "V" then
    if mode.get(view) == mode.VISUAL_LINE then
      doc:set_selection(line, col)
      mode.set(view, mode.NORMAL)
    else
      doc:set_selection(line, 1, line, math.huge)
      mode.set(view, mode.VISUAL_LINE)
    end
    ok = true
  elseif char == "S" then
    return change(view, "c", { span = text.line_span(doc, line, 1, line, 1), kind = "line" })
  elseif char == "D" then
    return change(view, "d", { span = text.span(line, col, line, text.eol(doc, line)), kind = "eol" })
  elseif char == "C" then
    return change(view, "c", { span = text.span(line, col, line, text.eol(doc, line)), kind = "eol" })
  elseif char == "Y" then
    operators.apply("y", doc, view, text.line_span(doc, line, 1, line, 1))
    ok = true
  elseif char == "X" then
    for _ = 1, (count > 0 and count or 1) do command.perform("doc:backspace") end
    ok = true
  elseif char == "P" then
    operators.paste(doc, line, col, true)
    ok = true
  elseif char == "J" then
    doc:set_selection(line, 1)
    command.perform("doc:join-lines")
    ok = true
  elseif char == "~" then
    operators.apply("g~", doc, view, text.span(line, col, line, col + 1))
    local l, c = text.next(doc, line, col)
    doc:set_selection(l, c)
    ok = true
  elseif char == "H" or char == "M" or char == "L" then
    -- The viewport is the host's to answer; `get_visible_line_range` is the same
    -- method its own page commands use, and the guard is what keeps `H` a no-op
    -- rather than an error if that ever stops being true.
    if view.get_visible_line_range then
      local first, bottom = view:get_visible_line_range()
      local target = first
      if char == "M" then
        target = math.floor((first + bottom) / 2)
      elseif char == "L" then
        target = bottom
      end
      local at = text.clamp(doc, target, 1)
      doc:set_selection(at, math.min(col, text.eol(doc, at)))
    end
    ok = true
  end
  return ok
end

-- ── normal mode's own commands ───────────────────────────────────────────
--
-- It answers "did I claim this key", and false means the chain matched nothing
-- — not that the key was dealt with. `handle_normal` reads that as "ask the
-- registry, then let the host have it".
--
-- The distinction is the whole of the second bug this file had. A trailing
-- `return true` here made every key the host reports by name — `pageup`,
-- `delete`, `f3` — answer "handled" without being handled, so it reached
-- neither `registry.call_key` nor the host: pressing Home did nothing at all,
-- and the plugin registry's own single keys (`tab` for the window integration,
-- `/` and `n` for search) could never fire from here either, because the line
-- below that was supposed to ask it was unreachable.
local function handle_command(view, char, count)
  local doc  = view.doc
  local line, col = cursor(doc)
  local times = count > 0 and count or 1
  local ok = false

  if char == "i" then
    mode.set(view, mode.INSERT)
    ok = true
  elseif char == "a" then
    local l, c = text.next(doc, line, col)
    doc:set_selection(l, c)
    mode.set(view, mode.INSERT)
    ok = true
  elseif char == "o" then
    command.perform("doc:newline-below")
    mode.set(view, mode.INSERT)
    ok = true
  elseif char == "v" then
    if mode.get(view) == mode.VISUAL then
      doc:set_selection(line, col)
      mode.set(view, mode.NORMAL)
    else
      doc:set_selection(line, col, line, col)
      mode.set(view, mode.VISUAL)
    end
    ok = true
  elseif char == "x" then
    -- Select, then cut. Not `doc:delete`: that command removes the character but
    -- never touches the clipboard, so `x` followed by `p` would paste whatever
    -- was copied last. Going through `doc:cut` is what puts the character on the
    -- clipboard and is the same path the old reader used, which is why `x`
    -- behaved correctly before and `r` did not.
    local l, c = line, col
    for _ = 1, times do l, c = text.next(doc, l, c) end
    if text.text(doc, text.span(line, col, l, c)) == "" then return true end
    doc:set_selection(line, col, l, c)
    command.perform("doc:cut")
    ok = true
  elseif char == "s" then
    -- s: like `cl` — one character, then insert.
    local l, c = text.next(doc, line, col)
    local span = text.span(line, col, l, c + 1)
    if not text.is_empty(doc, span) then
      return change(view, "c", { span = span, kind = "motion", key = "l", count = times })
    end
    ok = true
  elseif char == "p" then
    operators.paste(doc, line, col, false)
    ok = true
  elseif char == "u" then
    command.perform("doc:undo")
    ok = true
  elseif char == "r" then
    -- r is vim's replace-one-character. This is the one key whose meaning this
    -- reader changes: `r` used to be redo here, and it is now `Ctrl+Y`, which is
    -- already cdin's own redo stroke — so the host loses nothing and `r<char>`
    -- finally does something.
    pending = { kind = "replace", count = times, line = line, col = col,
                t = system.get_time() }
    ok = true
  elseif char == "." then
    return repeat_last(view)
  end
  return ok
end

-- ── visual mode ──────────────────────────────────────────────────────────
--
-- Vim's own keys first, then the plugin registry, then the motions. A key the
-- visual reader declines falls through to normal handling at the end of
-- `M.handle_key`, which is how `gg` and `G` keep working while a selection is
-- live and how an integration can add a visual key without shadowing a
-- normal-mode one.
local function handle_visual(view, char, tok, count)
  local doc     = view.doc
  local current = mode.get(view)
  local line, col = cursor(doc)
  local _, _, anchor_line, anchor_col = doc:get_selection()

  local span = selection_span(doc)
  -- Visual-line works on whole lines whatever the selection says, because a
  -- cdin selection cannot include a line's terminating newline: the furthest
  -- column a selection can reach is the newline itself. Without this, `V` then
  -- `d` would empty the line and leave it standing.
  if span and current == mode.VISUAL_LINE then
    span = text.span(span[1], 1, span[3], math.huge, true)
  end
  if span then
    if char == "d" or char == "x" then
      operators.apply("d", doc, view, span)
      doc:set_selection(line, col)
      mode.set(view, mode.NORMAL)
      return true
    elseif char == "c" then
      operators.apply("c", doc, view, span)
      mode.set(view, mode.INSERT)
      return true
    elseif char == "y" then
      operators.apply("y", doc, view, span)
      mode.set(view, mode.NORMAL)
      return true
    elseif char == ">" or char == "<" then
      operators.apply(char, doc, view, span)
      return true
    elseif char == "=" then
      operators.apply("=", doc, view, span)
      return true
    elseif char == "u" then
      operators.apply("gu", doc, view, span)
      return true
    elseif char == "U" then
      operators.apply("gU", doc, view, span)
      return true
    end
  end

  -- `v` and `V` leave, and `o` swaps which end the caret is on.
  --
  -- No shift flag is consulted anywhere in this function. `char` is already the
  -- character the key produced, so `V` arrives as `V` and `v` as `v` and the two
  -- are told apart by comparison rather than by a second piece of state that has
  -- to be kept in step with the first.
  if char == "v" or char == "V" then
    if char == "V" and current ~= mode.VISUAL_LINE then
      doc:set_selection(line, 1, line, math.huge)
      mode.set(view, mode.VISUAL_LINE)
    else
      doc:set_selection(line, col)
      mode.set(view, mode.NORMAL)
    end
    return true
  end
  if char == "o" then
    doc:set_selection(anchor_line, anchor_col, line, col)
    return true
  end

  -- A text object re-aims the selection, resolved from the caret — which is what
  -- makes `vi"` inside a quoted string select the string rather than whatever
  -- pair happens to enclose the other end of the selection.
  if char == "i" or char == "a" then
    pending = { kind = "object", prefix = char, line = line, col = col,
                t = system.get_time() }
    return true
  end

  if registry.call_visual_key(tok, view) then return true end

  -- Movements extend the selection to where they land. The count reaches here
  -- from `M.handle_key`, which drains the digits first: `3l` from a selection
  -- grows it by three characters, and dropping the count would make every
  -- counted movement in visual mode move by one.
  local spec = motions.normal[char]
  if spec and not spec.targets then
    local l, c, inclusive = motions.resolve(spec, doc, line, col, count or 0,
                                            { find = remembered })
    if not l then return true end
    if current == mode.VISUAL_LINE then
      local from = math.min(l, anchor_line)
      local to   = math.max(l, anchor_line)
      doc:set_selection(from, 1, to, math.huge)
    else
      -- The selection covers both ends, and a cdin selection is half-open, so
      -- the far end has to be one past the character it lands on. The far end is
      -- whichever of the anchor and the landing is *later* — not always the
      -- landing, because `h` from the fourth character selects the two
      -- characters between the new position and where the anchor still is.
      --
      -- `motions`' own inclusive flag is deliberately not consulted here: it
      -- answers whether an *operator* includes the endpoint, and `l` is
      -- exclusive there while `v` `l` plainly selects two characters.
      local from_line, from_col, to_line, to_col
      if l < anchor_line or (l == anchor_line and c <= anchor_col) then
        from_line, from_col, to_line, to_col = l, c, anchor_line, anchor_col
      else
        from_line, from_col, to_line, to_col = anchor_line, anchor_col, l, c
      end
      local end_line, end_col = text.next(doc, to_line, to_col)
      doc:set_selection(from_line, from_col, end_line, end_col)
    end
    return true
  end

  return false
end

-- ── the half-typed states ────────────────────────────────────────────────
--
-- `char` is the character the pending state was waiting for. Every branch
-- answers true for "handled", and false only for "I do not know what this is" —
-- which `M.handle_key` then turns into "start over from this key", so that a
-- mistyped `d` costs the `d` and not the `w` after it.
local function resolve_pending(view, char)
  local doc  = view.doc
  local kind = pending.kind

  -- `f` and `r` are waiting for a *character*, and the keys that are not
  -- characters arrive as names: `up`, `f5`, `pageup`. Letting one through would
  -- have `r` insert the string "up" into the buffer, or send `f` looking for a
  -- two-character sequence it can never match. Abandoning the sequence is what
  -- vim does — an arrow is a key of its own, not a target — and returning false
  -- lets the caller handle it as one, so the caret moves instead.
  if (kind == "find" or kind == "replace") and #char ~= 1 then
    pending, count_buf = nil, ""
    return false
  end

  if kind == "ctrl_w" then
    pending, count_buf = nil, ""
    local wcmd = registry.wmap_get(char)
    if wcmd then command.perform(wcmd) end
    return true
  end

  if kind == "find" then
    local find = pending.find
    find.char, find.forward, find.till = char, pending.forward, pending.till
    local after, op = pending.after, pending.op
    local line, col = pending.line, pending.col
    local count = combine(pending.pre, tonumber(pending.op_count))
    pending, count_buf = nil, ""
    -- `;` and `,` replay this, so it outlives the key that set it. Recorded even
    -- when the find matched nothing, which is vim's rule: `;` repeats the last
    -- `f`/`t` you typed, not the last one that happened to work.
    remembered = find
    local ctx = { find = remembered }
    if op then
      local span = motion_span(doc, op, after, line, col, count, ctx)
      if not span or text.is_empty(doc, span) then return true end
      return change(view, op, { span = span, kind = "motion", key = after, count = count })
    end
    local l, c = motions.resolve(motions.normal[after], doc, line, col, count, ctx)
    if l then doc:set_selection(l, c) end
    return true
  end

  if kind == "replace" then
    local count, line, col = pending.count, pending.line, pending.col
    pending, count_buf = nil, ""
    local end_col = math.min(col + count, #doc.lines[line] + 1)
    if text.text(doc, text.span(line, col, line, end_col)) == "" then return true end
    doc:remove(line, col, line, end_col)
    doc:insert(line, col, char)
    return true
  end

  if kind == "g" then
    local line, col = cursor(doc)
    local count = tonumber(count_buf) or 0
    pending, count_buf = nil, ""

    -- `gu`, `gU` and `g~` are operators: they want a motion or an object next,
    -- exactly as `d` does.
    if operators.is_operator("g" .. char) then
      pending = { kind = "operator", op = "g" .. char, line = line, col = col,
                  op_count = "", pre = count, t = system.get_time() }
      return true
    end

    -- `gg` and `g_` are motions. `gt`/`gT` belong to whichever plugin owns tabs
    -- and are asked about only after vim's own `g` keys have declined.
    local spec = motions.prefixed[char]
    if spec then
      local l, c = motions.resolve(spec, doc, line, col, count, nil)
      if l then doc:set_selection(l, c) end
      return true
    end
    registry.call_gmap("g" .. char, count)
    return true
  end

  if kind == "operator_g" then
    local line, col, op = pending.line, pending.col, pending.op
    pending, count_buf = nil, ""
    local spec = motions.prefixed[char]
    if not spec then return true end
    local span = motions.span_for(spec, doc, line, col, pending.pre or 0, nil)
    if not span or text.is_empty(doc, span) then return true end
    return change(view, op, { span = span, kind = "motion", key = "g" .. char, count = 0 })
  end

  if kind == "object" then
    local name = pending.prefix .. char
    local line, col, op = pending.line, pending.col, pending.op
    pending, count_buf = nil, ""
    local span = objects.find(name, doc, line, col)
    if not span then return true end
    if op then
      if text.is_empty(doc, span) then return true end
      return change(view, op, { span = span, kind = "object", name = name })
    end
    -- No operator behind it: this is a text object re-aiming a selection.
    doc:set_selection(span[1], span[2], span[3], span[4])
    return true
  end

  -- `operator` is the only kind that reads the next key as a count or a motion.
  if kind == "operator" then
    local line, col, op = pending.line, pending.col, pending.op

    if is_count_digit(char, pending.op_count) then
      pending.op_count = pending.op_count .. char
      return true
    end
    if char == "i" or char == "a" then
      pending.kind, pending.prefix = "object", char
      return true
    end
    if char == "g" then
      pending.kind = "operator_g"
      return true
    end

    local spec = motions.normal[char]
    if not spec then
      local lines = combine(pending.pre, tonumber(pending.op_count))
      pending, count_buf = nil, ""
      -- `dd`, `yy`, `cc`: the operator repeated is a whole-line operation, and
      -- the counts from either side of it multiply the way `2d3w` does.
      if char == op then
        local total = text.line_count(doc)
        local span  = text.line_span(doc, line, 1,
                                     math.min(line + math.max(lines, 1) - 1, total), 1)
        return change(view, op, { span = span, kind = "line" })
      end
      return true
    end

    local count = combine(pending.pre, tonumber(pending.op_count))
    if spec.targets then
      pending.kind, pending.after, pending.find = "find", char, {}
      pending.forward = (char == "f" or char == "t")
      pending.till = (char == "t" or char == "T")
      pending.op_count = ""
      return true
    end

    pending, count_buf = nil, ""
    local span = motion_span(doc, op, char, line, col, count, nil)
    if not span or text.is_empty(doc, span) then return true end
    return change(view, op, { span = span, kind = "motion", key = char, count = count })
  end

  return false
end

-- ── normal mode ──────────────────────────────────────────────────────────
local function handle_normal(view, k, tok, shift)
  local char = character(k, shift)

  if pending then
    if resolve_pending(view, char) then return true end
    -- Nothing claimed the key and the sequence had expired: start again from
    -- here rather than swallowing the key.
    if stale() then pending, count_buf = nil, "" end
  end

  if is_count_digit(char, count_buf) then
    count_buf = count_buf .. char
    return true
  end
  local count = tonumber(count_buf) or 0
  count_buf = ""

  -- A capital letter is the one spelling both vocabularies claim, and it is the
  -- one case where the lookup order has to flip.
  --
  -- Shift and `d` arrives as the character `d`, so `operators.is_operator`
  -- claims it and `D` silently becomes a pending delete. The same happens to
  -- `C`, `S`, `Y` and — worst — `J`, which the motion table answers as `6j` when
  -- a count was typed first. So a shifted *letter* skips both tables entirely.
  --
  -- Within the capitals, the registry is asked first: `N` is both vim's "search
  -- backwards" (which vim core cannot have, because search is a plugin) and
  -- with/search.lua's "previous find", and `M` is both vim's "middle of the screen"
  -- and a menu. Only shifted letters need this, and every other capital —
  -- G, I, A, O, V, S, D, C, Y, X, P, J, H, L, U — is unambiguously vim's.
  local capital = shift and char:match("^%u$") ~= nil

  if not capital then
    if operators.is_operator(char) then
      local line, col = cursor(view.doc)
      pending = { kind = "operator", op = char, line = line, col = col,
                  op_count = "", pre = count, t = system.get_time() }
      return true
    end

    local spec = motions.normal[char]
    if spec then
      local line, col = cursor(view.doc)
      if spec.targets then
        pending = { kind = "find", after = char, find = {}, line = line, col = col,
                    op_count = "", pre = count,
                    forward = (char == "f" or char == "t"),
                    till = (char == "t" or char == "T"),
                    t = system.get_time() }
        return true
      end
      local l, c = motions.resolve(spec, view.doc, line, col, count,
                                   { find = remembered })
      if l then view.doc:set_selection(l, c) end
      return true
    end
  end

  if shift then
    -- Also the route by which `*` reaches the `with` entry on `search`: the host sends it as the
    -- 8 key with shift held, and this is where it becomes the character.
    if registry.call_key(tok, view) then return true end
    return handle_shifted(view, char, count)
  end

  if handle_command(view, char, count) then return true end

  -- Vim has declined it and so has the registry: this key belongs to somebody
  -- else. That is the fall-through the host needs, and it only exists because
  -- `handle_command` answers false for a key it did not match.
  if registry.call_key(tok, view) then return true end

  -- One last distinction, and it is the whole of the named-key bug. A key the
  -- host *prints* is ours to swallow — vim beeps at a letter it does not know,
  -- and swallowing it is what the beep is made of. A key the host reports *by
  -- name* is not ours at all: `pageup` is a page, `f3` is a function key,
  -- `delete` is whatever the host bound it to. Answering "handled" for one of
  -- those is how Home and PageUp came to do nothing at all, silently, in normal
  -- mode only.
  return #char == 1
end

-- ── page movement ────────────────────────────────────────────────────────
--
-- `Ctrl+F` and `Ctrl+B` go to the host, which already has whole-page commands
-- and the only honest notion of a page — the visible line range. There is no
-- half-page command there, so `Ctrl+U` and `Ctrl+D` are half of that range
-- worked out here.
--
-- `Ctrl+D` shadows the host's `doc:select-word`, and `Ctrl+F` is free because
-- the file finder is on `Ctrl+P`. Losing select-word costs `iw`, which is what
-- it did anyway.
local function half_page(view, down)
  if not view.get_visible_line_range then return false end
  local doc = view.doc
  local first, bottom = view:get_visible_line_range()
  local half = math.max(1, math.floor((bottom - first) / 2))
  local line, col = cursor(doc)
  local target = text.clamp(doc, line + (down and half or -half), 1)
  doc:set_selection(target, math.min(col, text.eol(doc, target)))
  return true
end

-- ── entry point ──────────────────────────────────────────────────────────
function M.handle_key(k)
  if not config.vim_mode_enabled then return false end

  if core.active_view == core.command_view then
    if k == "up" and keymap.modkeys.ctrl then return exline.history_prev() end
    if k == "down" and keymap.modkeys.ctrl then return exline.history_next() end
    return false
  end

  local view = core.active_docview()

  -- Ctrl+W is armed *before* the ctrl guard below, because that guard sends
  -- every ctrl key back to the host, and `Ctrl+W {c}` is a sequence of two.
  if k == "ctrl+w" and view and mode.get(view) ~= mode.INSERT then
    pending = { kind = "ctrl_w", t = system.get_time() }
    count_buf = ""
    return true
  end

  if k:find("ctrl") or k:find("alt") then
    if not view or mode.get(view) == mode.INSERT then return false end
    -- Redo. Undo is `u`, as in vim; this is cdin's own redo stroke, so nothing
    -- is taken away from the host to give `r` back its vim meaning.
    if k == "ctrl+y" then
      command.perform("doc:redo")
      return true
    elseif k == "ctrl+f" then
      command.perform("doc:move-to-next-page")
      return true
    elseif k == "ctrl+b" then
      command.perform("doc:move-to-previous-page")
      return true
    elseif k == "ctrl+u" then
      return half_page(view, false)
    elseif k == "ctrl+d" then
      return half_page(view, true)
    end
    return false
  end

  if keymap.modkeys.ctrl or keymap.modkeys.alt or keymap.modkeys.altgr then
    return false
  end

  local shift = keymap.modkeys.shift
  local tok   = token_for(k, shift)

  -- A key the host reports by name is the vim motion it means, but only while
  -- the document is the focused view.
  --
  -- The gate is the whole point. The tree, the project-search list and the
  -- autocomplete popup all bind these same names, and they want them exactly as
  -- the host spells them; translating here without it would take `space` and
  -- the arrows away from every one of them the moment a document was open
  -- somewhere. Same idiom as treeview's `when_focused`.
  --
  -- `tok` is built above this line on purpose: the registry is asked about
  -- `"up"` and about `"home"`, not about the key they became, so an integration
  -- that later wants to claim one still can.
  if view and core.active_view == view then
    local named = NAMED[k]
    if named then
      -- The shift flag goes with the name, and that is the whole reason it is
      -- cleared rather than kept. `shift+left` is the host's "extend the
      -- selection", and in vim that is what a plain `h` already does in visual
      -- mode; left set, the same key would become `H` and throw the caret to the
      -- top of the window, and `shift+home` would become `)`.
      k, shift = named, false
    end
  end

  -- Whether the focused document is being typed into, asked once. The `:` check
  -- below runs *above* the guard at the bottom of this function that hands
  -- insert mode every key back to the host, and two separate answers to "is this
  -- insert mode?" is how shift+; came to open the ex line while somebody was
  -- trying to type a colon into a buffer.
  local inserting = view and mode.get(view) == mode.INSERT

  -- Shift and `;` is `:`, the way it is in every terminal. Checked against the
  -- base key rather than the character, because `;` reaches here as the base key
  -- with shift held and there is no other key that could mean the ex line.
  --
  -- Insert mode is the one mode this key does not claim, and it has to decline
  -- it right here rather than leave it to the guard below: this check comes
  -- first, so by the time that guard runs the line is already open. In insert
  -- mode the reader owns no keys at all — the host moves the caret and inserts
  -- text — so `:` is text, and returning false is what lets it reach the buffer.
  if shift and k == ";" then
    if inserting then return false end
    exline.open()
    return true
  end

  if not view then
    return registry.call_key(tok, nil) or false
  end

  if k == "escape" then
    M.reset()   -- drop any half-typed sequence and count
    local current = mode.get(view)
    if current == mode.INSERT then
      mode.set(view, mode.NORMAL)
      command.perform("doc:move-to-previous-char")
    else
      -- Leaving a selection collapses it rather than leaving it highlighted for
      -- the next command to trip over.
      mode.set(view, mode.NORMAL)
      command.perform("doc:select-none")
    end
    return true
  end

  if inserting then
    return false
  end

  if mode.is_visual(mode.get(view)) then
    -- Digits first, exactly as in normal mode: `3l` and `2j` have to grow a
    -- selection rather than move the caret one step.
    local vchar = character(k, shift)
    if is_count_digit(vchar, count_buf) then
      count_buf = count_buf .. vchar
      return true
    end
    local vcount = tonumber(count_buf) or 0
    count_buf = ""
    if handle_visual(view, vchar, tok, vcount) then return true end
    -- Unclaimed visual-mode keys fall through to normal handling, which is how
    -- "gg" and friends keep working while a selection is active.
  end

  return handle_normal(view, k, tok, shift)
end

return M