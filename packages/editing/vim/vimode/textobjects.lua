-- Vim's text objects: two keys that name a *region* rather than a place.
--
-- This is the half of the report that says `yi"` and `di"` do nothing, and it
-- is missing for a reason that is not obvious from the outside. `d` needs to
-- know what to delete; a motion tells it where the cursor should end up, which
-- is not the same thing. `di"` does not mean "delete to the character after the
-- next quote" — it means "delete the text between these two quotes", a region
-- chosen by a rule of its own that has nothing to do with where the cursor was
-- pointing. So there is no motion that expresses it, and a table of motions
-- cannot grow one.
--
-- An object is therefore a span and nothing else: `find(name, doc, line, col)`
-- answers the half-open range the name covers, or nil when the name does not
-- cover anything here — `di(` outside a bracket, `di"` on a line with one
-- quote. Nil is not an error. It is what vim beeps at, and it is the answer
-- that lets the operator do nothing instead of guessing.
--
-- Like motions, every entry is a function of (document, line, column) and
-- touches no view and no clipboard, so normal mode, an operator and `.` all
-- agree about what `a"` means.
local text    = require "vim.vimode.text"
local motions = require "vim.vimode.motions"

local M = {}

-- ── words ────────────────────────────────────────────────────────────────
--
-- `iw` is the run of same-class characters around the cursor, whatever class
-- that is: a word on a letter, a run of punctuation on a comma, and the
-- whitespace itself on a space. That is not a simplification, it is vim's
-- rule, and it is why `diw` on a comma removes the comma rather than the whole
-- sentence it sits in.
--
-- `aw` is that run plus one piece of surrounding whitespace. Which piece is
-- decided by whether there is any after — and that is the part worth spelling
-- out, because `aw` at the end of a line takes the *leading* space, and an
-- implementation that only ever looks forward deletes the newline instead.

local function word_object(doc, line, col, around, bigword)
  local from_l, from_c = text.run_start(doc, line, col, bigword)
  local _, to_c = text.run_end(doc, line, col, bigword)

  if not around then
    return text.span(from_l, from_c, line, to_c + 1)
  end

  -- Punctuation glued to the word belongs to it as far as `aw` is concerned:
  -- `aw` on the `a` of `a, b` takes `a, ` and not `a`. Without this, `daw` on a
  -- comma-separated list leaves the commas behind, which is the complaint that
  -- makes people reach for `x` instead.
  if not bigword then
    local probe_l, probe_c = text.next(doc, line, to_c)
    if probe_l == line and probe_c <= text.last_col(doc, line)
      and text.class_of(text.char(doc, probe_l, probe_c), false) == "punct" then
      -- Through a local: `run_end` answers a line *and* a column, and
      -- assigning it to one name would leave `to_c` holding the line number.
      local _, punct_end = text.run_end(doc, probe_l, probe_c, false)
      to_c = punct_end
    end
  end

  -- Whitespace after, if this line has any. The newline column does not count:
  -- `last_col` is the last real character, and treating the newline as
  -- whitespace would make `aw` at the end of a line extend forwards into the
  -- next one instead of taking the space before it.
  local next_l, next_c = text.next(doc, line, to_c)
  if next_l == line and next_c <= text.last_col(doc, next_l)
    and text.is_blank(text.char(doc, next_l, next_c)) then
    local end_l, end_c = next_l, next_c
    for scan = next_c + 1, text.last_col(doc, line) do
      if not text.is_blank(text.char(doc, line, scan)) then break end
      end_l, end_c = line, scan
    end
    return text.span(from_l, from_c, end_l, end_c + 1)
  end

  -- ...and failing that the whitespace before, which is what `aw` falls back
  -- to on the last word of a line. An implementation that only ever looks
  -- forward reaches the newline instead and deletes it.
  while from_c > 1 do
    local prev_l, prev_c = text.prev(doc, from_l, from_c)
    if not text.is_blank(text.char(doc, prev_l, prev_c)) then break end
    from_l, from_c = prev_l, prev_c
  end
  return text.span(from_l, from_c, line, to_c + 1)
end

-- ── quotes ───────────────────────────────────────────────────────────────
--
-- All of them are collected and then paired by *alternation*: the first is an
-- opening quote, the second closes it, the third opens the next pair, and so
-- on. Pairing neighbours instead — "the nearest quote before, and the nearest
-- after" — is wrong the moment a line holds two separate quoted strings, and
-- wrong in the way that is hardest to notice: in `"a" and "b"` with the cursor
-- on the `d` of `and`, adjacency hands back the space between the strings and
-- `di"` deletes ` and `.
--
-- Given the pairing, the choice is then:
--
--   on a quote     an odd-numbered quote opens the pair, an even one closes it
--   inside a pair  that pair
--   otherwise      the next pair forward, else the previous one

local function quote_pair(doc, line, col, quote)
  local at = {}
  for c = 1, text.last_col(doc, line) do
    if text.char(doc, line, c) == quote then at[#at + 1] = c end
  end
  if #at < 2 then return nil end

  for i = 1, #at do
    if at[i] == col then
      if i % 2 == 1 then
        if at[i + 1] then return at[i], at[i + 1] end
      else
        return at[i - 1], at[i]
      end
      return nil
    end
  end

  for i = 1, #at - 1, 2 do
    if at[i] <= col and col < at[i + 1] then return at[i], at[i + 1] end
  end
  for i = 1, #at - 1, 2 do
    if at[i] > col then return at[i], at[i + 1] end
  end
  -- The last pair, which may start one earlier if the final quote is
  -- unpaired.
  local last = (#at % 2 == 0) and (#at - 1) or (#at - 2)
  if last >= 1 then return at[last], at[last + 1] end
  return nil
end

-- ── bracket pairs ────────────────────────────────────────────────────────
--
-- Unlike quotes, a bracket pair *encloses*. `di(` means the contents of the
-- innermost pair around the cursor, so this walks back to the nearest unmatched
-- opener and then forward to its partner — and because it starts by looking at
-- the cursor's own column, a cursor sitting on a bracket is treated as being
-- inside it, which is what makes `di(` work when the caret is up against the
-- bracket rather than in the middle of the text.

local function enclosing_bracket(doc, line, col, open, close)
  local depth, start = 0, nil
  for c = col, 1, -1 do
    local char = text.char(doc, line, c)
    if char == close then
      depth = depth + 1
    elseif char == open then
      if depth == 0 then start = c break end
      depth = depth - 1
    end
  end
  if not start then return nil end

  local nested = 0
  for c = start + 1, text.last_col(doc, line) do
    local char = text.char(doc, line, c)
    if char == open then
      nested = nested + 1
    elseif char == close then
      if nested == 0 then return start, c end
      nested = nested - 1
    end
  end
  return nil
end

-- ── tags ─────────────────────────────────────────────────────────────────
--
-- The one object that has to see past the end of the line, and the reason
-- `text.flat` exists. An HTML tag opens on one line and closes forty lines
-- later, so the name is found backwards from the cursor and its partner
-- forwards from there, both in the flattened buffer.
--
-- The name is read from the *innermost* `<` before the cursor, which is the
-- opening tag when the cursor is in the body and the tag itself when it is up
-- against one — the same "a bracket you are standing on is one you are inside"
-- rule the bracket objects use.

local function tag_object(doc, line, col, around)
  local flat, index = text.flat(doc)
  local at = index[line] + col - 1

  -- The innermost tag that starts at or before the cursor: the opening tag of
  -- the body the cursor is in, or the tag the cursor is itself up against.
  --
  -- Scanned over the whole flattened text rather than over the part before the
  -- cursor, because a truncation at the cursor cuts a tag *name* in half — the
  -- cursor on the `v` of `<div>` sees `<di`, the closing search then asks for
  -- `</di>` and finds nothing, and `dit` reports no tag where there plainly is
  -- one. The `break` is what keeps it from walking the rest of the document.
  local open_at, closing, name
  for at_from, is_close, tag in flat:gmatch("()(<%/?)([%a_][%w_%.%-]*)") do
    if at_from > at then break end
    open_at, closing, name = at_from, is_close, tag
  end
  if not open_at then return nil end

  if closing == "/" then
    -- Standing on a closing tag: the opening one is behind us. Find the last
    -- "<name" before it that is not itself a closing tag.
    local before = flat:sub(1, open_at - 1)
    local start
    for found, is_close in before:gmatch("()(<%/?)" .. name:gsub("%W", "%%%0")) do
      if is_close ~= "</" then start = found end
    end
    if not start then return nil end
    local stop = flat:find(">", open_at, true)
    if not stop then return nil end
    local stop_l, stop_c = text.position_at(index, stop + 1)
    local start_l, start_c = text.position_at(index, start)
    if around then
      return text.span(start_l, start_c, stop_l, stop_c + 1)
    end
    -- inner: from just past the ">" of the opening tag to just before the "<"
    local body_l, body_c = text.position_at(index, start + #name + 2)
    return text.span(body_l, body_c, stop_l, stop_c)
  end

  local stop = flat:find(">", open_at, true)
  if not stop then return nil end
  -- Not `plain`: the pattern is `</name` followed by optional space and `>`,
  -- and a plain search would look for the literal text "</name%s*>" and never
  -- find it. The name is escaped because it came from the document.
  local close_at = flat:find("</" .. name:gsub("%W", "%%%0") .. "%s*>", stop)
  if not close_at then return nil end
  local close_stop = flat:find(">", close_at, true)

  local start_l, start_c = text.position_at(index, open_at)
  if around then
    local end_l, end_c = text.position_at(index, close_stop + 1)
    return text.span(start_l, start_c, end_l, end_c)
  end
  local body_l, body_c = text.position_at(index, stop + 1)
  local end_l, end_c = text.position_at(index, close_at)
  return text.span(body_l, body_c, end_l, end_c)
end

-- ── paragraphs and sentences ─────────────────────────────────────────────

local function paragraph_object(doc, line, around)
  -- On a blank line the paragraph *is* that line. Walking outwards from here
  -- would silently hand back the paragraph above or below, so `dip` on an empty
  -- line would delete somebody's text.
  if text.is_blank_line(doc, line) then
    return text.span(line, 1, line, math.huge, true)
  end

  local total = text.line_count(doc)
  local first = line
  while first > 1 and not text.is_blank_line(doc, first - 1) do first = first - 1 end

  -- The loop leaves `last` on the first blank line at or after `line`, because
  -- it advances before it tests. Step back off it, so the paragraph stops at
  -- its own last line rather than swallowing the blank that follows.
  local last = line
  while last < total and not text.is_blank_line(doc, last) do last = last + 1 end
  last = math.max(last - 1, line)

  -- `ap` also takes the blank line that follows, which is what makes it
  -- possible to `dap` twice and be left with blank lines rather than with the
  -- next paragraph's text merged onto the end of this one.
  if around and last < total then last = last + 1 end
  return text.span(first, 1, last, math.huge, true)
end

-- The exclusive end of the text before (line, col), with trailing whitespace
-- stepped over. `is` needs it so the span stops on the full stop rather than
-- swallowing the space after it — which is what vim's `dis` does, and why
-- `dis` twice leaves a double space.
local function end_of_text(doc, line, col)
  while true do
    local prev_l, prev_c = text.prev(doc, line, col)
    if not text.is_blank(text.char(doc, prev_l, prev_c)) then return line, col end
    line, col = prev_l, prev_c
  end
end

local function sentence_object(doc, line, col, around)
  local start_l, start_c = motions.sentence_start(doc, line, col)
  local next_l, next_c = motions.sentence_forward(doc, line, col)
  local end_l, end_c = end_of_text(doc, next_l, next_c)
  if around then
    return text.span(start_l, start_c, end_l, end_c)
  end
  return text.span(line, col, end_l, end_c)
end

-- ── the table ────────────────────────────────────────────────────────────
--
-- Keyed by the two characters as they are typed: the `i`/`a` and then the name.
-- `b` is an alias for `(` because vim spells it both ways and `dib` is muscle
-- memory for as many people as `di(`.

M.objects = {}

M.objects["iw"] = function(doc, l, c) return word_object(doc, l, c, false, false) end
M.objects["aw"] = function(doc, l, c) return word_object(doc, l, c, true,  false) end
M.objects["iW"] = function(doc, l, c) return word_object(doc, l, c, false, true) end
M.objects["aW"] = function(doc, l, c) return word_object(doc, l, c, true,  true) end

for _, quote in ipairs({ '"', "'" }) do
  M.objects["i" .. quote] = function(doc, l, c)
    local a, b = quote_pair(doc, l, c, quote)
    if not a then return nil end
    return text.span(l, a + 1, l, b)
  end
  M.objects["a" .. quote] = function(doc, l, c)
    local a, b = quote_pair(doc, l, c, quote)
    if not a then return nil end
    return text.span(l, a, l, b + 1)
  end
end

for _, pair in ipairs({ { "(", ")" }, { "[", "]" }, { "{", "}" }, { "<", ">" } }) do
  local open, close = pair[1], pair[2]
  M.objects["i" .. open] = function(doc, l, c)
    local a, b = enclosing_bracket(doc, l, c, open, close)
    if not a then return nil end
    return text.span(l, a + 1, l, b)
  end
  M.objects["a" .. open] = function(doc, l, c)
    local a, b = enclosing_bracket(doc, l, c, open, close)
    if not a then return nil end
    return text.span(l, a, l, b + 1)
  end
end

-- One assignment each, not `M.objects["ib"], M.objects["i("] = M.objects["i("]`.
-- A multiple assignment takes only as many values as the right-hand side
-- produces, and a table index produces exactly one, so the *second* target is
-- assigned nil — which deletes the very entry being aliased. The symptom is
-- `dib` working and `di(` silently doing nothing, which is a strange enough
-- pair of facts that it is worth the comment.
M.objects["ib"] = M.objects["i("]
M.objects["ab"] = M.objects["a("]

M.objects["it"] = function(doc, l, c) return tag_object(doc, l, c, false) end
M.objects["at"] = function(doc, l, c) return tag_object(doc, l, c, true) end
M.objects["ip"] = function(doc, l, c) return paragraph_object(doc, l, false) end
M.objects["ap"] = function(doc, l, c) return paragraph_object(doc, l, true) end
M.objects["is"] = function(doc, l, c) return sentence_object(doc, l, c, false) end
M.objects["as"] = function(doc, l, c) return sentence_object(doc, l, c, true) end

-- `in` and `an` — "the next occurrence of the word under the cursor" — are not
-- here, and that is a deliberate omission rather than an oversight. They need
-- a document-wide search and then a decision about which of several matches to
-- take, and cdin's search is a plugin rather than something vim core may reach
-- for. What they would do is `*` then `c` then `w`, and an integration that
-- wants them can register them through the key registry once search exists.

function M.find(name, doc, line, col)
  local object = M.objects[name]
  if not object then return nil end
  return object(doc, line, col)
end

return M