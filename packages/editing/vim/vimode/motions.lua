-- Vim's motions: a key, and where the cursor goes when you press it.
--
-- This file used to be a table of key -> cdin command name. It is now a table
-- of key -> *rule*, and that change is the whole fix.
--
-- The old table could only answer one question — "which command does this key
-- run?" — which works right up until an operator needs to know where a motion
-- *ended*. `dw` is not `d` followed by `w`: it is one range from the cursor to
-- wherever `w` would have gone, and whether the character it landed on belongs
-- to that range is exactly what separates `de` from `dw`. A command name
-- cannot carry that, so the operator had nothing to work with and `d` gave up.
--
-- So a motion is a `run` that answers an endpoint, plus the facts an operator
-- needs about it:
--
--   inclusive   does the character the motion lands on belong to the range?
--               `$`, `e` and `f` are inclusive; `h`, `w` and `b` are not, which
--               is why `de` stops on the last letter and `dw` eats the space.
--   linewise    is the range whole lines whatever the columns say? `j`, `G` and
--               `}` are, so `dj` takes two lines and not the text between them.
--
-- `run` may return a third value, an `inclusive` that overrides the field, for
-- the motions whose answer depends on state: `;` is inclusive when the last
-- find was an `f` and exclusive when it was a `t`, and only the caller knows
-- which was typed.
--
-- A motion may also answer `span` outright, for the one case where vim does
-- something from/to arithmetic cannot express: `%` with the cursor on a bracket
-- takes *both* brackets, not the one under the cursor through to the other.
--
-- Nothing here touches a view, a mode or the clipboard. Every entry is a
-- function of (document, line, column, count, context), which is what lets
-- normal mode, a pending operator and `.` share one definition of where `w`
-- goes instead of three that agree until one of them is changed.
local text = require "vim.vimode.text"

local M = {}

-- ── the count ────────────────────────────────────────────────────────────
--
-- A count of 0 means "none was typed", and every motion that repeats something
-- turns that into 1 here. It has to be a real distinction rather than a
-- convenience: `G` with no count goes to the last line of the file while `1G`
-- goes to line 1, so a motion that cannot tell them apart makes one of those
-- two keys wrong. Passing 0 for "unset" keeps the distinction without threading
-- a second value beside the first — and 0 is not something a user can mean,
-- because in vim a leading `0` is the start-of-line motion rather than part of
-- a count.
local function times(count)
  return count > 0 and count or 1
end

-- ── word motions ─────────────────────────────────────────────────────────
--
-- vim's `w` is not "skip to the next word", it is "leave whatever run you are
-- in, then skip whitespace" — which is why `dw` on the middle of a word eats
-- the rest of that word, and why `w` does not jump to the next one. Getting
-- this wrong is the commonest way a `w` stops feeling like vim's, so the rules
-- are written out rather than folded into one clever line.

local function word_forward(doc, line, col, count, bigword)
  for _ = 1, times(count) do
    if not text.is_blank(text.char(doc, line, col)) then
      local l, c = text.run_end(doc, line, col, bigword)
      line, col = text.next(doc, l, c)
    else
      line, col = text.next(doc, line, col)
    end
    line, col = text.skip_blanks(doc, line, col)
  end
  return line, col
end

-- Backward is three steps and the order matters. Stepping back *first* is what
-- makes `b` from the first character of a word land on the previous word
-- rather than on the word the cursor is already standing at.
local function word_back(doc, line, col, count, bigword)
  for _ = 1, times(count) do
    line, col = text.skip_blanks_back(doc, text.prev(doc, line, col))
    if text.is_blank(text.char(doc, line, col)) then break end
    line, col = text.run_start(doc, line, col, bigword)
  end
  return line, col
end

-- `e` is "the end of the word I am on, or of the next one if I am already
-- there", so the run end is computed first and only stepped past when the
-- cursor is already sitting on it.
local function word_end(doc, line, col, count, bigword)
  for _ = 1, times(count) do
    local l, c = text.run_end(doc, line, col, bigword)
    if l ~= line or c ~= col then
      line, col = l, c
    else
      local nl, nc = text.skip_blanks(doc, text.next(doc, l, c))
      if nl == l and nc == c then break end
      line, col = text.run_end(doc, nl, nc, bigword)
    end
  end
  return line, col
end

-- ── sentences ────────────────────────────────────────────────────────────
--
-- A sentence ends at `.`, `!`, `?` or `:` *followed by whitespace*, and both
-- motions land on the first non-blank of a sentence. Requiring the trailing
-- space is what stops a version number, a path or a URL from ending a
-- sentence halfway through a line.
--
-- The scan is line by line rather than over the whole buffer joined into one
-- string. That keeps the arithmetic in (line, column) honest, and it is also
-- why a terminator at the very end of a line falls through to the first
-- non-blank of the next line instead of stopping on the newline.

local SENTENCE_END = "[%.!?:]%s"

-- The same pattern with a position capture in front, for the one place that
-- needs every match rather than the first. `string.gmatch` yields what
-- *matched* — `". "` — and not where, so walking the matches backwards needs
-- the offset, and `tonumber(". ")` is nil.
local SENTENCE_AT = "()([%.!?:]%s)"

local function sentence_forward(doc, line, col)
  local total = text.line_count(doc)
  for l = line, total do
    local body = text.body(doc, l)
    local from = (l == line) and (col + 1) or 1
    local at = body:find(SENTENCE_END, from)
    if at then
      local next_word = body:find("%S", at + 1)
      if next_word then return l, next_word end
    end
    if l < total then
      local on_next = text.body(doc, l + 1):find("%S")
      if on_next then return l + 1, on_next end
    end
  end
  return total, text.first_nonblank(doc, total)
end

-- Where the sentence containing (line, col) begins, and which terminator
-- begins it — the second answer is what `(` needs, because the sentence before
-- this one is the one that starts after the terminator *before* this one's.
--
-- Both are reported because the terminator position is not something the
-- caller can work out afterwards: `gmatch` hands back an offset with no line,
-- and the sentence may have started on an earlier line entirely.
local function sentence_start(doc, line, col)
  for l = line, 1, -1 do
    local body = text.body(doc, l)
    local stop = (l == line) and (col - 1) or (#body + 1)
    local at
    for offset in body:gmatch(SENTENCE_AT) do
      if offset <= stop then at = offset else break end
    end
    if at then
      local next_word = body:find("%S", at + 1)
      if next_word then return l, next_word, l, at end
      for above = l - 1, 1, -1 do
        local first = text.body(doc, above):find("%S")
        if first then return above, first, l, at end
      end
    end
  end
  -- No terminator anywhere above: this is the first sentence in the file.
  return 1, text.first_nonblank(doc, 1)
end

local function sentence_back(doc, line, col)
  local l, c, term_line, term_col = sentence_start(doc, line, col)
  if not term_line then return l, c end
  return sentence_start(doc, term_line, term_col)
end

-- ── paragraphs ───────────────────────────────────────────────────────────
--
-- A paragraph is a run of non-blank lines, so both directions are the same
-- shape twice over: cross the blank lines, then cross the paragraph.
--
-- Backward steps back one line *before* doing either half. Without that, `{`
-- pressed on the first line of a paragraph has nothing to cross and stays
-- where it is — but the previous paragraph is the one before it, and a `{`
-- that does not move from the top of a paragraph is the single most noticeable
-- way a paragraph motion is wrong.
--
-- `moved` is what stops the loop at the top or the bottom of the document,
-- where a step either way is not available.

local function paragraph(doc, line, forward, count)
  local total = text.line_count(doc)
  for _ = 1, times(count) do
    if forward then
      while line < total and text.is_blank_line(doc, line) do line = line + 1 end
      while line < total and not text.is_blank_line(doc, line) do line = line + 1 end
    else
      if line > 1 then line = line - 1 end
      while line > 1 and text.is_blank_line(doc, line) do line = line - 1 end
      while line > 1 and not text.is_blank_line(doc, line - 1) do line = line - 1 end
    end
  end
  return line, text.first_nonblank(doc, line)
end

-- ── find-a-character ─────────────────────────────────────────────────────
--
-- `f`, `F`, `t` and `T` cannot be resolved from one key: the next key is part
-- of the motion. They carry `targets`, and keys.lua passes the character
-- through `ctx.find` without ever learning which pair was typed.
--
-- The four share one resolver because they differ only in direction and in
-- whether they stop one short. `;` and `,` replay whatever was last typed, in
-- that order, and answer their inclusivity at run time — which is the reason
-- `run` may return a third value.

local function find_forward(doc, line, col, target)
  for at = col + 1, text.last_col(doc, line) do
    if text.char(doc, line, at) == target then return line, at end
  end
  return nil
end

local function find_back(doc, line, col, target)
  for at = col - 1, 1, -1 do
    if text.char(doc, line, at) == target then return line, at end
  end
  return nil
end

local function resolve_find(doc, line, col, ctx, forward, till)
  local find = ctx and ctx.find
  if not find or not find.char then return nil end
  -- Not `forward and find_forward(...) or find_back(...)`: an `and`/`or` chain
  -- keeps only the first value of a multi-value call, so the column would
  -- arrive as nil and the next step would compare against nothing.
  local l, c
  if forward then
    l, c = find_forward(doc, line, col, find.char)
  else
    l, c = find_back(doc, line, col, find.char)
  end
  if not l then return nil end
  if till then
    -- `t` and `T` stop one short, and "short" means short of the target in
    -- the direction of travel.
    if forward then l, c = text.prev(doc, l, c) else l, c = text.next(doc, l, c) end
  end
  return l, c, not till
end

-- ── one-line movement ────────────────────────────────────────────────────
--
-- Neither `h` nor `l` crosses a line boundary. `doc:position_offset` does
-- cross, which is right for the host's own cursor helpers and wrong here:
-- vim's `l` at the end of a line stops, and so `dl` at the end of a line is not
-- a request to delete the newline.

local function step_left(doc, line, col, count)
  for _ = 1, times(count) do
    if col <= 1 then break end
    line, col = text.prev(doc, line, col)
  end
  return line, col
end

local function step_right(doc, line, col, count)
  local last = text.eol(doc, line)
  for _ = 1, times(count) do
    if col >= last then break end
    line, col = text.next(doc, line, col)
  end
  return line, col
end

-- Vertical movement carries the column down and clamps it per line, rather
-- than going through the host's `doc:move-to-next-line`. That command keeps a
-- *pixel* offset across lines, which is the right answer for an arrow key and
-- the wrong one here: `3j` should land on the column it started from, and a
-- pixel offset re-derives itself from wherever the previous step clamped, so
-- the third line down can end up somewhere the second never suggested.
local function vertical(doc, line, col, count, step)
  local target = text.clamp(doc, line + step * times(count), 1)
  return target, math.min(col, text.eol(doc, target))
end

-- ── the tables ───────────────────────────────────────────────────────────
--
-- Two, because `g` is a two-key sequence and only some of what follows it is
-- vim's. keys.lua asks these first and the plugin registry second, which is
-- what lets an integration add `gt` without vim core having to know what a tab
-- is.

M.normal = {}
M.prefixed = {}

local function motion(key, spec) M.normal[key] = spec end
local function prefixed(key, spec) M.prefixed[key] = spec end

-- characters
motion("h", { run = step_left })
motion("l", { run = step_right })
motion("j", { run = function(doc, l, c, n) return vertical(doc, l, c, n,  1) end, linewise = true })
motion("k", { run = function(doc, l, c, n) return vertical(doc, l, c, n, -1) end, linewise = true })

-- Within a line. `$` moves down `count - 1` lines first, which is what makes
-- `2$` the end of the line below rather than a case of its own.
--
-- `last_col`, not `eol`, and the difference is one column on every line. `eol`
-- is one *past* the last character — it is the newline — and it is the right
-- answer for the end of a span and for where `A` types, but not for where the
-- caret stands. `$` puts the caret on the last character, so `$` overshot by
-- one, `End` overshot by one, and `2$` overshot by one on the line below.
-- `text.last_col` is documented as "where `$` puts the cursor in vim"; it was
-- written and then not used here.
--
-- `inclusive` because the character `$` lands on belongs to the range: `d$` from
-- the middle of `abcdef` removes `def` and leaves `ab`. Without it `d$` left
-- the last character behind, and the header of this file already promised the
-- opposite.
motion("$", { run = function(doc, l, c, n)
  local target = text.clamp(doc, l + times(n) - 1, 1)
  return target, text.last_col(doc, target)
end, inclusive = true })
motion("0", { run = function(doc, l) return l, 1 end })
motion("^", { run = function(doc, l) return l, text.first_nonblank(doc, l) end })
-- `|` stops at the last character too: vim's `|` is "column n", and no column
-- is past the end of the line.
motion("|", { run = function(doc, l, c, n) return l, math.min(times(n), text.last_col(doc, l)) end })

-- words
motion("w", { run = function(doc, l, c, n) return word_forward(doc, l, c, n, false) end })
motion("W", { run = function(doc, l, c, n) return word_forward(doc, l, c, n, true) end })
motion("b", { run = function(doc, l, c, n) return word_back(doc, l, c, n, false) end })
motion("B", { run = function(doc, l, c, n) return word_back(doc, l, c, n, true) end })
motion("e", { run = function(doc, l, c, n) return word_end(doc, l, c, n, false) end, inclusive = true })
motion("E", { run = function(doc, l, c, n) return word_end(doc, l, c, n, true) end,  inclusive = true })

-- whole lines
motion("G", { run = function(doc, l, c, n)
  local target = (n > 0) and text.clamp(doc, n, 1) or text.line_count(doc)
  return target, text.first_nonblank(doc, target)
end, linewise = true })

motion("+", { run = function(doc, l, c, n)
  local target = text.clamp(doc, l + times(n), 1)
  return target, text.first_nonblank(doc, target)
end, linewise = true })

motion("-", { run = function(doc, l, c, n)
  local target = text.clamp(doc, l - times(n), 1)
  return target, text.first_nonblank(doc, target)
end, linewise = true })

motion("}", { run = function(doc, l, c, n) return paragraph(doc, l, true,  n) end, linewise = true })
motion("{", { run = function(doc, l, c, n) return paragraph(doc, l, false, n) end, linewise = true })
motion(")", { run = function(doc, l, c, n)
  for _ = 1, times(n) do l, c = sentence_forward(doc, l, c) end
  return l, c
end, linewise = true })
motion("(", { run = function(doc, l, c, n)
  for _ = 1, times(n) do l, c = sentence_back(doc, l, c) end
  return l, c
end, linewise = true })

-- find a character on this line
motion("f", { targets = true,
  run = function(doc, l, c, n, ctx) return resolve_find(doc, l, c, ctx, true,  false) end })
motion("F", { targets = true,
  run = function(doc, l, c, n, ctx) return resolve_find(doc, l, c, ctx, false, false) end })
motion("t", { targets = true,
  run = function(doc, l, c, n, ctx) return resolve_find(doc, l, c, ctx, true,  true) end })
motion("T", { targets = true,
  run = function(doc, l, c, n, ctx) return resolve_find(doc, l, c, ctx, false, true) end })
motion(";", { run = function(doc, l, c, n, ctx)
  local find = ctx and ctx.find
  if not find then return l, c end
  return resolve_find(doc, l, c, ctx, find.forward, find.till)
end })
motion(",", { run = function(doc, l, c, n, ctx)
  local find = ctx and ctx.find
  if not find then return l, c end
  return resolve_find(doc, l, c, ctx, not find.forward, find.till)
end })

-- The matching bracket. `match_bracket` reports the pair in document order, so
-- the endpoint is whichever end the cursor is not already on; and when the
-- cursor is not on a bracket at all — `%` pressed in the middle of an
-- expression — it is the closing one.
motion("%", {
  inclusive = true,
  run = function(doc, l, c)
    local m = text.match_bracket(doc, l, c)
    if not m then return l, c end
    if m[1] == l and c <= m[2] then return m[3], m[4] end
    return m[1], m[2]
  end,
  span = function(doc, l, c)
    local m = text.match_bracket(doc, l, c)
    if not m then return nil end
    -- Through locals rather than inline, because `text.next` answers a line
    -- *and* a column: written as an argument it would pass both, and
    -- `text.span` would read the line as its end column.
    local end_line, end_col = text.next(doc, m[3], m[4])
    return text.span(m[1], m[2], end_line, end_col)
  end,
})

-- The two sentence questions, published because `is` and `as` need exactly
-- these and must not define their own idea of where a sentence begins.
M.sentence_start    = sentence_start
M.sentence_forward  = sentence_forward

-- ── after "g" ────────────────────────────────────────────────────────────

prefixed("g", { run = function(doc, l, c, n)
  local target = text.clamp(doc, (n > 0) and n or 1, 1)
  return target, text.first_nonblank(doc, target)
end, linewise = true })

prefixed("_", { run = function(doc, l) return l, text.last_nonblank(doc, l) end })

-- ── resolving ────────────────────────────────────────────────────────────
--
-- `count` is 0 when none was typed. The four answers are the endpoint, whether
-- the character there belongs to an operator's range, whether the range is
-- whole lines, and — when the motion overrides both — the span itself.
--
-- A motion that answers nothing at all (an unmatched bracket, a find that runs
-- off the end of the line) returns nil, and the caller leaves the cursor
-- where it was. That is what vim does when it beeps.

function M.span_for(spec, doc, line, col, count, ctx)
  if not spec then return nil end
  if spec.span then
    return spec.span(doc, line, col, count, ctx)
  end
  local l, c, inclusive, linewise = M.resolve(spec, doc, line, col, count, ctx)
  if not l then return nil end
  if linewise then
    return text.line_span(doc, line, col, l, c)
  end
  return text.motion_span(doc, line, col, l, c, inclusive)
end

function M.resolve(spec, doc, line, col, count, ctx)
  if not spec or not spec.run then return nil end
  local l, c, inclusive = spec.run(doc, line, col, count, ctx)
  if l == nil then return nil end
  if inclusive == nil then inclusive = spec.inclusive end
  return l, c, inclusive == true, spec.linewise == true
end

return M