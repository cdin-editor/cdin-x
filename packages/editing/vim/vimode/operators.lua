-- Doing something with a span: the operators, and the clipboard they share.
--
-- The span is already decided by motions.lua or textobjects.lua; this file only
-- has to act on it. What varies between the operators is three things, and
-- spelling them out is most of the file:
--
--   change      `d` and `c` take the text out of the buffer. `y` does not.
--   caret       after a change the caret sits at the start of what was removed,
--               which is where the next character goes; after a yank it stays
--               put, because nothing happened to the text under it.
--   next mode   `c` leaves insert mode's entry to the caller, and only `c`.
--
-- Two of the operators are not about text at all — `=` and `>` / `<` are about
-- lines — and they work by putting the span on the document's selection and
-- handing over to the host's own `doc:indent`. That indirection is deliberate:
-- the host already knows the indent string, the tab setting and what counts as
-- a blank line, and a second implementation here would drift from it.
local command = require "core.input.command"
local text    = require "vim.vimode.text"

local M = {}

-- ── the table ────────────────────────────────────────────────────────────
--
-- `linewise` forces whole lines whatever the span says, because `>` applied to
-- a character-wise motion indents the *line* the character is on. That is not
-- a quirk of this implementation; it is what `>` means.

M.OPERATORS = {
  ["d"]  = { change = true },
  ["y"]  = {},
  ["c"]  = { change = true, insert = true },
  ["="]  = { indent = "indent" },
  [">"]  = { indent = "indent",   linewise = true },
  ["<"]  = { indent = "unindent", linewise = true },
  ["gu"] = { case = "lower" },
  ["gU"] = { case = "upper" },
  ["g~"] = { case = "toggle" },
}

function M.is_operator(key)
  return M.OPERATORS[key] ~= nil
end

-- ── case ─────────────────────────────────────────────────────────────────
--
-- `string.lower` and `string.upper` are the host's own, reached through
-- `doc:upper-case` and `doc:lower-case` below. Toggle has no host equivalent,
-- so it is spelled here: upper the lowercase runs, then lower whatever the
-- first pass made uppercase.
--
-- Byte-wise, like the host's own case commands. That is a real limitation for
-- a non-ASCII letter and it is the host's limitation too — the same one
-- `doc:upper-case` has — rather than one introduced here.

local function toggle_case(chunk)
  return (chunk:gsub("%l", string.upper):gsub("%U", string.lower))
end

-- ── the clipboard ────────────────────────────────────────────────────────
--
-- A linewise span is closed over its line break *before* the text is taken, not
-- only before it is deleted. `yk` has to put the newline on the clipboard, or
-- `p` pastes the next line's first character onto the end of this one instead
-- of adding a line — and the difference is invisible until the second time you
-- do it.

local function take(doc, span)
  local closed = text.close_lines(doc, span)
  local chunk  = text.text(doc, closed)
  system.set_clipboard(chunk)
  return closed, chunk
end

-- ── applying ─────────────────────────────────────────────────────────────
--
-- Answers whether the buffer changed, and whether the caller should enter
-- insert mode. A nil span is not an error: it is what `di(` outside a bracket
-- and `d;` with nothing to repeat hand back, and the answer is "nothing
-- happened" in both cases rather than a guess.

function M.apply(op, doc, view, span)
  local spec = M.OPERATORS[op]
  if not spec or not span then return false, false end

  -- An indent operator always works on whole lines, so `>` with a character
  -- motion behind it still shifts the line.
  if spec.indent then
    local closed = text.close_lines(doc, text.span(span[1], 1, span[3], span[4], true))
    doc:set_selection(closed[1], 1, closed[3], math.huge)
    command.perform("doc:" .. spec.indent)
    doc:set_selection(closed[1], 1)
    return true, false
  end

  if spec.case then
    -- The host's `doc:replace` works on whatever is selected, and on the whole
    -- document when nothing is — so the span has to be on the selection first,
    -- or `gUw` on one word would rewrite the file.
    doc:set_selection(span[1], span[2], span[3], span[4])
    if spec.case == "lower" then
      command.perform("doc:lower-case")
    elseif spec.case == "upper" then
      command.perform("doc:upper-case")
    else
      doc:replace(toggle_case)
    end
    doc:set_selection(text.place(doc, span))
    return true, false
  end

  if not spec.change then
    take(doc, span)
    return false, false
  end

  local closed = take(doc, span)
  doc:remove(closed[1], closed[2], closed[3], closed[4])
  -- On the last line of the file the span's column can be past the end of what
  -- is left, so the caret is placed through the same clamp everything else uses.
  doc:set_selection(text.place(doc, text.span(closed[1], closed[2], closed[1], closed[2])))
  return true, spec.insert == true
end

-- ── pasting ──────────────────────────────────────────────────────────────
--
-- `p` and `P`, which are the other end of the clipboard the operators write.
-- `p` puts the text *after* the character under the caret and `P` before it,
-- which is one character of movement apart — and in vim that difference is the
-- whole reason both keys exist, since a line pasted with `p` lands after the
-- caret and one pasted with `P` lands before it.
--
-- Stepping by a character and not by a byte is `text.next`'s job: on a line
-- with a multi-byte character in it, `p` after that character has to land after
-- the character and not after its first byte.

function M.paste(doc, line, col, before)
  local chunk = system.get_clipboard()
  if not chunk or chunk == "" then return false end
  chunk = chunk:gsub("\r", "")

  -- A selection would be replaced rather than pasted around, and there is no
  -- such thing as a selection in normal mode anyway.
  doc:set_selection(line, col)
  if not before then
    local l, c = text.next(doc, line, col)
    doc:set_selection(l, c)
  end
  doc:text_input(chunk)
  return true
end

return M