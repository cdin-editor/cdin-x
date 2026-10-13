-- Vim's position arithmetic, over a document.
--
-- Everything in vimode that has to know *where* something is goes through
-- here: stepping one character, running to the end of a run of characters of
-- one class, and turning a motion plus its inclusivity into the half-open
-- span that the operators work on.
--
-- This is one module rather than four because the alternative is four places
-- each doing their own `col = col + 1`, and three of them get it wrong for a
-- multi-byte character. Stepping is `doc:position_offset` plus
-- `common.is_utf8_cont`, both from the host, so `l` moves one *character* and
-- not one byte — the same rule the editor's own Ctrl+arrow keys obey, which is
-- why `l` and Ctrl+Right agree here instead of drifting apart.
--
-- ── coordinates ──────────────────────────────────────────────────────────
-- A position is (line, column), both 1-based, and a column counts bytes from
-- the start of the line *including its newline*. `doc.lines[1] == "abc\n"`
-- therefore has four columns, 1..4, and column 4 is the newline itself. That
-- is exactly what `doc:sanitize_position` clamps to, so every position this
-- module produces is already inside what the host will accept, and none of
-- the callers below has to clamp again.
--
-- A span is { l1, c1, l2, c2, linewise } and is half-open: c2 is one *past*
-- the last character in it. That is `doc:get_text`'s and `doc:remove`'s own
-- convention (`self.lines[line1]:sub(col1, col2 - 1)`), and adopting it here
-- is the point — a range that had to be translated on every call site is a
-- range that eventually gets translated wrong in one of them.
local config = require "core.config"
local common = require "core.utils.common"

local M = {}

-- ── the document, as far as this module is concerned ─────────────────────

function M.line_count(doc)
  return #doc.lines
end

-- A line without its newline. Vim's "end of line" is the last character of
-- this, never the newline, so every end-of-line calculation starts here.
function M.body(doc, line)
  local text = doc.lines[line]
  if not text then return "" end
  if text:sub(-1) == "\n" then return text:sub(1, -2) end
  return text
end

-- One past the last character of the body: where the newline sits, or one
-- past the end of a line that has none. This is the column to use as the
-- *end* of a span, and as a cursor position it is the last position cdin
-- accepts on the line.
function M.eol(doc, line)
  return #M.body(doc, line) + 1
end

-- The column of the last character of the body — where `$` puts the cursor
-- in vim. An empty line has no last character, so it answers with the start
-- of the line rather than column 0, which the host would clamp anyway.
function M.last_col(doc, line)
  local body = M.body(doc, line)
  if body == "" then return 1 end
  return #body
end

function M.clamp(doc, line, col)
  local last_line = M.line_count(doc)
  line = common.clamp(line, 1, last_line)
  col  = common.clamp(col, 1, #doc.lines[line])
  return line, col
end

-- ── stepping ─────────────────────────────────────────────────────────────

function M.char(doc, line, col)
  return doc:get_char(line, col)
end

-- One character forward. The `repeat` is not an optimisation, it is the whole
-- point: `doc:position_offset` moves *bytes*, and the byte after the first of
-- a multi-byte character is a continuation byte, so a single step can land in
-- the middle of one. The host's own `translate.next_char` skips them exactly
-- this way.
--
-- Note what `doc:get_char` hands back: `self.lines[line]:sub(col, col)` — one
-- *byte*, not one character, which is why "is this a continuation byte" is a
-- meaningful question to ask of its result and why this function can be
-- written as a loop at all. It also means every caller below classifies
-- characters a byte at a time, so a letter outside ASCII is two or three "word
-- bytes" rather than one — which is the right answer, and the same one
-- cdin's `non_word_chars` lookup gives, because that lookup is over the same
-- single bytes.
function M.next(doc, line, col)
  local char
  repeat
    line, col = doc:position_offset(line, col, 1)
    char = doc:get_char(line, col)
  until not common.is_utf8_cont(char)
  return line, col
end

function M.prev(doc, line, col)
  local char
  repeat
    line, col = doc:position_offset(line, col, -1)
    char = doc:get_char(line, col)
  until not common.is_utf8_cont(char)
  return line, col
end

function M.next_line(doc, line)
  return M.clamp(doc, line + 1, 1)
end

function M.prev_line(doc, line)
  return M.clamp(doc, line - 1, 1)
end

-- ── character classes ────────────────────────────────────────────────────
--
-- `non_word_chars` is cdin's, read rather than restated. It is what the
-- editor's own Ctrl+arrow and Ctrl+Backspace already use, so a word in vim
-- mode is the same word the host thinks it is — restating it here would be a
-- second definition that agrees today and drifts the first time somebody adds
-- a character to it.

function M.is_word(char)
  if char == nil or char == "" then return false end
  return not config.non_word_chars:find(char, nil, true)
end

function M.is_blank(char)
  return char == nil or char == "" or char == " " or char == "\t" or char == "\n"
end

-- The three classes vim counts a "word" as: a keyword run, a run of
-- punctuation, and whitespace. `W`, `B` and `E` collapse the first two, which
-- is the whole difference between a word and a WORD.
function M.class_of(char, bigword)
  if M.is_blank(char) then return "blank" end
  if bigword then return "word" end
  return M.is_word(char) and "word" or "punct"
end

-- ── runs ─────────────────────────────────────────────────────────────────
--
-- `run_end` is the last column of the unbroken run of characters *of the same
-- class as the one at (line, col)* that starts there; `run_start` the first.
-- Deriving the class from the character under the cursor rather than taking it
-- as an argument is what makes "run of word characters", "run of non-blank"
-- and "run of the same punctuation" one function instead of three near-copies.
-- `bigword` collapses punctuation into the word class, which is the whole
-- difference between `w` and `W`.
--
-- Neither crosses a line boundary. A run stops at the newline, which is what
-- makes `w` at the end of a line step onto the first character of the next one
-- instead of into the middle of it.
--
-- Both stop when stepping returns the position they were given. That is not a
-- theoretical case: `doc:position_offset` clamps at the end of the document,
-- so at the very last character `M.next` returns where it started, and a loop
-- that only tested "did the class change" would never terminate.

function M.run_end(doc, line, col, bigword)
  local want = M.class_of(doc:get_char(line, col), bigword)
  local last = M.last_col(doc, line)
  while true do
    local l, c = M.next(doc, line, col)
    if l ~= line or c == col or c > last then return line, col end
    if M.class_of(doc:get_char(l, c), bigword) ~= want then return line, col end
    line, col = l, c
  end
end

function M.run_start(doc, line, col, bigword)
  local want = M.class_of(doc:get_char(line, col), bigword)
  while true do
    local l, c = M.prev(doc, line, col)
    if l ~= line or c == col or c < 1 then return line, col end
    if M.class_of(doc:get_char(l, c), bigword) ~= want then return line, col end
    line, col = l, c
  end
end

-- Forward to the next character that is not whitespace, crossing lines — which
-- is what makes it the newline that terminates it, exactly as vim's does.
--
-- The end-of-document case is the interesting one. `doc:position_offset`
-- clamps, so past the last character `M.next` returns where it started and a
-- loop that only tested the class would never end. What vim does at the end of
-- a file is stop on the last real character rather than run off it, so that is
-- what the fallback walks back to.
function M.skip_blanks(doc, line, col)
  while M.is_blank(doc:get_char(line, col)) do
    local l, c = M.next(doc, line, col)
    if l == line and c == col then
      local pl, pc = M.prev(doc, line, col)
      if not M.is_blank(doc:get_char(pl, pc)) then return pl, pc end
      return line, col
    end
    line, col = l, c
  end
  return line, col
end

-- Backward to the previous non-whitespace character, for the same reason and
-- with the same ending: at the top of the document there is nothing before,
-- and the position is left alone.
function M.skip_blanks_back(doc, line, col)
  while M.is_blank(doc:get_char(line, col)) do
    local l, c = M.prev(doc, line, col)
    if l == line and c == col then return line, col end
    line, col = l, c
  end
  return line, col
end

-- The first non-blank column of a line, or 1 for an empty one. `^`, `+`, `-`
-- and the line motions all start here, and `$`'s partner `g_` is the last.
function M.first_nonblank(doc, line)
  local at = M.body(doc, line):find("%S")
  return at or 1
end

-- The last non-blank column of a line — `g_`, and the partner of
-- `first_nonblank`. Trailing whitespace is stripped first because a pattern
-- anchored at the end cannot skip it: `%S+$` finds nothing in "abc  ", since
-- the run of non-blanks is not what ends the string. Columns are byte offsets,
-- and the bytes being removed are ASCII, so stripping them cannot shift a
-- column.
function M.last_nonblank(doc, line)
  local trimmed = M.body(doc, line):gsub("%s+$", "")
  if trimmed == "" then return M.last_col(doc, line) end
  return #trimmed
end

function M.is_blank_line(doc, line)
  return doc.lines[line]:find("^%s*$") ~= nil
end

-- ── the buffer as one string ─────────────────────────────────────────────
--
-- A few text objects are not line-shaped: an HTML tag opens on one line and
-- closes forty lines later, and a bracket pair around a block of text does the
-- same. Working in (line, column) for those means threading two coordinates
-- through every step, so those two cases flatten the buffer once and work in
-- offsets instead.
--
-- The answer is a string and a table of line-start offsets, because the offset
-- -> (line, column) direction is the one that is needed at both ends and it is
-- the one that cannot be recovered by counting. `lines[1]` and `lines[2]` keep
-- their own newlines, so the concatenated string is byte-for-byte the file and
-- a line's start offset is the running sum of the lengths before it.

function M.flat(doc)
  local parts, index, at = {}, {}, 1
  for i = 1, #doc.lines do
    index[i] = at
    parts[#parts + 1] = doc.lines[i]
    at = at + #doc.lines[i]
  end
  return table.concat(parts), index
end

-- The other direction: an offset in the flat string back to a position.
-- Linear, because the lines walked are the ones between the answer and
-- wherever the search started, and a document-wide jump is at most one pass.
function M.position_at(index, offset)
  local line = 1
  for i = #index, 1, -1 do
    if index[i] <= offset then line = i break end
  end
  return line, offset - index[line] + 1
end

-- ── spans ────────────────────────────────────────────────────────────────

function M.span(l1, c1, l2, c2, linewise)
  return { l1, c1, l2, c2, linewise or false }
end

-- The span an operator takes when the motion lands on `target`.
--
-- This is where vim's inclusive/exclusive distinction becomes arithmetic, and
-- it is the single rule the whole of `dw`, `de`, `d$`, `db` and `d2w` comes
-- out of. Inclusivity applies *in the direction the motion moved*:
--
--   target at or after `from`   ->  [from, target + inclusive)
--   target before `from`        ->  [target - inclusive, from)
--
-- So `dh` on `b` in `abc` — `h` is exclusive, so the range is `[c-1, c)` and
-- the character under the cursor is what goes. `d$` from the second
-- character of `abcd` — `$` is inclusive, so the range is `[2, 5)` and `bcd`
-- goes. `db` on `bar` in `foo bar` — `b` is exclusive, so the range is
-- `[1, 5)` and the space goes with the word, which is what vim does and what
-- makes `db` twice over empty the line rather than leave a gap.
function M.motion_span(doc, from_line, from_col, line, col, inclusive)
  local forward = line > from_line or (line == from_line and col >= from_col)
  if forward then
    local l, c = line, col
    if inclusive then l, c = M.next(doc, l, c) end
    return M.span(from_line, from_col, l, c)
  end
  local l, c = line, col
  if inclusive then l, c = M.prev(doc, l, c) end
  return M.span(l, c, from_line, from_col)
end

-- Whole lines, from the first column of the first to one past the last
-- character of the last. `math.huge` for the end column is the host's own
-- "end of this line" idiom — `doc:sanitize_position` clamps it — and it is
-- what `doc:delete-lines` uses, so the two agree on where a line stops.
function M.line_span(doc, from_line, from_col, line, col)
  if line < from_line or (line == from_line and col < from_col) then
    from_line, line = line, from_line
  end
  return M.span(from_line, 1, line, math.huge, true)
end

-- A span nothing can be done with. `x` on the last character of the only line
-- produces one, and `delete` over an empty span would push an undo entry that
-- restores nothing.
-- Close a linewise span over the line break at its end.
--
-- A linewise range is open for a yank and closed for a delete, and that is not
-- a detail — it is the difference between `y}` leaving the text available and
-- `d}` removing the lines. `dj` over lines 1 and 2 of a three-line file has to
-- remove the newline after line 2 as well, or line 2 is left behind as a blank
-- line and the caret has nothing to stand on. Extending the span to the first
-- column of the following line is what takes it.
--
-- The last line of the document has no following line, so the span stops at the
-- end of its own text instead. `math.huge` is the host's own "end of this line"
-- idiom, and `doc:remove` clamps it — but the *line* has to be clamped here, or
-- a one-line document asks for line 2, `doc:sanitize_position` folds it back to
-- line 1, and the span collapses to nothing. That is not a corner case: it is
-- what `yy` does on a new file.
function M.close_lines(doc, span)
  if not span[5] then return span end
  if span[3] + 1 <= M.line_count(doc) then
    return M.span(span[1], 1, span[3] + 1, 1, true)
  end
  return M.span(span[1], 1, span[3], math.huge, true)
end

function M.is_empty(doc, span)
  if span == nil then return true end
  return span[1] > span[3]
      or (span[1] == span[3] and span[2] >= span[4])
end

function M.text(doc, span)
  return doc:get_text(span[1], span[2], span[3], span[4])
end

-- Move the caret to the start of a span, or as close as the document allows.
-- After a delete the span's start is where vim leaves the cursor, and after a
-- yank it is where a paste would put the text, so both use this.
function M.place(doc, span)
  return M.clamp(doc, span[1], span[2])
end

-- ── brackets ─────────────────────────────────────────────────────────────
--
-- Shared rather than written twice: `%` needs the bracket matching the one
-- under the cursor, and `i(`, `a{`, `it` and friends need the pair that
-- *encloses* it. That is the same walk from a different starting column, so
-- it is one function here instead of two that agree until they don't.
--
-- The match is looked for on the current line only. That is a real limit and
-- not an oversight: a bracket that closes on a later line is common in prose
-- and rare on a command line, while a document-wide scan would make `d%`
-- delete across the whole buffer every time an unbalanced bracket appeared
-- earlier in the file. No match answers nil, which callers turn into "do
-- nothing" — the way vim beeps.

M.OPEN  = { ["("] = ")", ["["] = "]", ["{"] = "}", ["<"] = ">" }
M.CLOSE = { [")"] = "(", ["]"] = "[", ["}"] = "{", [">"] = "<" }

-- Walk one direction from just past (line, col) looking for the bracket that
-- closes the one we are standing on, allowing that bracket to nest. `deeper`
-- is the one a nested copy would be, `shallower` the one that finishes a
-- nesting level; both are the same character for an unpaired bracket.
local function scan(doc, line, col, step, deeper, shallower)
  local last = M.last_col(doc, line)
  local depth, at = 0, col
  while true do
    at = at + step
    if step > 0 and at > last then return nil end
    if step < 0 and at < 1 then return nil end
    local char = doc:get_char(line, at)
    if char == deeper then
      depth = depth + 1
    elseif char == shallower then
      if depth == 0 then return at end
      depth = depth - 1
    end
  end
end

-- The bracket matching the one at (line, col), or nil.
--
-- A table and not a list of return values, because every caller needs more
-- than one of the answers and a multi-value call assigned to one name keeps
-- only the first of them. The shape is { l1, c1, l2, c2, open, close }, with
-- the two positions in document order — so `d%` and `da(` build the same span
-- without walking the line twice.
function M.match_bracket(doc, line, col)
  line, col = M.clamp(doc, line, col)
  local char = doc:get_char(line, col)

  if not (M.OPEN[char] or M.CLOSE[char]) then
    -- Not on a bracket: take the first one at or after the cursor, which is
    -- what `%` does when it is pressed in the middle of an expression.
    local at, last = col, M.last_col(doc, line)
    while at <= last do
      local c = doc:get_char(line, at)
      if M.OPEN[c] or M.CLOSE[c] then
        return M.match_bracket(doc, line, at)
      end
      at = at + 1
    end
    return nil
  end

  if M.OPEN[char] then
    local at = scan(doc, line, col, 1, char, M.OPEN[char])
    if not at then return nil end
    return { line, col, line, at, char, M.OPEN[char] }
  end

  local at = scan(doc, line, col, -1, char, M.CLOSE[char])
  if not at then return nil end
  return { line, at, line, col, M.CLOSE[char], char }
end

return M