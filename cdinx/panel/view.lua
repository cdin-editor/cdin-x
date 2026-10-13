-- The panel's view: rows, cursor, scrolling, and how it looks.
--
-- Three bands, fixed, so the panel reads the same at any height: a title, the
-- filter (only while there is a filter, so the list gets the space when there
-- is nothing to filter), and a footer of keys. The list is the only thing
-- that scrolls, and it scrolls under the title rather than with it.
--
-- Every column is measured from the font rather than guessed, because the
-- version and the status sit at the right edge and a guessed width is how two
-- labels end up printed on top of each other.
local Host = require "cdinx.host"
local common = require "core.utils.common"
local style  = require "core.style"
local View   = require "core.views.view"
local Rows   = require "cdinx.panel.rows"

local PanelView = View:extend()

-- A status is a word, not a symbol: "off" and "on" read at a glance where a
-- dash and a dot do not, and this panel is mostly read, not scanned.
local STATUS_LABEL = {
  editor    = "in editor",
  installed = "enabled",
  disabled  = "disabled",
  available = "not installed",
}

-- Colours come from the active theme, so the panel follows whichever one is
-- on. Every theme defines git_added (green) and git_modified (yellow), which
-- already mean "present and fine" and "present but off" everywhere else in the
-- editor, so they are reused rather than inventing colours that clash with a
-- palette. Each has a fallback for a theme that lacks it.
--
--   enabled        green      installed and running
--   disabled       yellow     installed, switched off
--   not installed  dim        on offer
--   in editor      accent     part of the build
local STATUS_COLOR = {
  editor    = { "accent" },
  installed = { "git_added", "accent" },
  disabled  = { "git_modified", "dim" },
  available = { "dim" },
}

local function status_color(status)
  for _, key in ipairs(STATUS_COLOR[status] or { "dim" }) do
    if style[key] then return style[key] end
  end
  return style.dim
end

local function status_of(entry)
  return entry.status or "available"
end


function PanelView:new(collect)
  PanelView.super.new(self)
  -- collect() returns entries, and optionally a notice: one line about where
  -- extensions would come from. Two values because the notice is not an entry
  -- and must not be able to be filtered, counted or selected.
  self.collect   = collect
  self.visible   = false
  self.init_size = true
  self.query     = ""
  self.searching = false
  self.row    = 1
  self.hovered   = nil
  self.rows      = {}
  self.counts    = {}
  self.matched   = 0
  self.total     = 0
  self._dirty    = true
  self.dragging_scrollbar = false
end

function PanelView:get_name() return "Extensions" end

-- ── rows ────────────────────────────────────────────────────────────────

function PanelView:invalidate()
  self._dirty = true
  Host.core.redraw = true
end

function PanelView:_ensure_rows()
  if not self._dirty then return end
  local entries, notice, total = self.collect()
  local built = Rows.build(entries, self.query, notice, total)
  self.rows    = built.rows
  self.counts  = built.counts
  self.matched = built.matched
  self.total   = built.total
  self._dirty  = false
  -- Keep the cursor on the same entry when the list changed underneath it,
  -- and on an entry when it did not.
  self.row  = Rows.nearest(self.rows, self.row)
  Host.core.redraw  = true
end

function PanelView:refilter()
  -- The query has changed, so the cursor has to be re-seated on what is
  -- actually there. Doing it from the NEW rows is the whole fix for "it says
  -- it found two but there is nothing to select": the old row index pointed at
  -- a header, or past the end, and nothing moved it back.
  local entries, notice, total = self.collect()
  local built = Rows.build(entries, self.query, notice, total)
  self.rows    = built.rows
  self.counts  = built.counts
  self.matched = built.matched
  self.total   = built.total
  self._dirty  = false
  self.row  = Rows.nearest(self.rows, 1)
  self.scroll.to.y = 0
  Host.core.redraw = true
end

function PanelView:_row_selectable(i)
  local row = self.rows[i]
  return row ~= nil and row.kind == "entry"
end

--- The row at an index, after making sure it exists.
---
--- Added because a caller asking "what is under the cursor" otherwise has to
--- reach into `self.rows` and call `_ensure_rows` first, and getting that order
--- wrong means reading a stale row -- which for a switch is a toggle applied to the
--- wrong feature.
--- @param i number
--- @return table|nil
function PanelView:row_at(i)
  self:_ensure_rows()
  return self.rows[i]
end

--- The feature row at an index, or nil.
--- @param i number
--- @return table|nil
function PanelView:feature_at(i)
  local row = self:row_at(i)
  if row and row.kind == "feature" then return row end
  return nil
end

function PanelView:_next_entry(from, dir)
  local i = from
  while i >= 1 and i <= #self.rows do
    if self:_row_selectable(i) then return i end
    i = i + dir
  end
  return nil
end

function PanelView:move_cursor(dir)
  self:_ensure_rows()
  local found = self:_next_entry(self.row + dir, dir)
  if not found then
    -- Wrap, and wrap to an entry: a list that wraps onto a section header is
    -- a list where enter does nothing and nobody can tell why.
    found = dir > 0 and self:_next_entry(1, 1) or self:_next_entry(#self.rows, -1)
  end
  if found then
    self:set_row(found)
  end
end

function PanelView:set_row(i)
  self.row = i
  self:scroll_to_cursor()
  Host.core.redraw = true
end

function PanelView:scroll_to_cursor()
  local h = self:get_item_height()
  local y = (self.row - 1) * h
  local visible = self:get_list_height()
  if y < self.scroll.to.y then
    self.scroll.to.y = y
  elseif y + h > self.scroll.to.y + visible then
    self.scroll.to.y = y + h - visible
  end
end

function PanelView:entry_at_cursor()
  local row = self.rows[self.row]
  return (row and row.kind == "entry") and row.entry or nil
end

-- ── geometry ────────────────────────────────────────────────────────────

function PanelView:get_item_height()
  return style.font:get_height() + style.padding.y
end

function PanelView:get_title_height()
  return style.font:get_height() + style.padding.y * 2
end

function PanelView:get_filter_height()
  if self.query == "" and not self.searching then return 0 end
  return style.font:get_height() + style.padding.y * 2
end

function PanelView:get_footer_height()
  return style.font:get_height() + style.padding.y * 2
end

function PanelView:get_list_top()
  return self:get_title_height() + self:get_filter_height()
end

function PanelView:get_list_height()
  return math.max(0, self.size.y - self:get_list_top() - self:get_footer_height())
end

function PanelView:get_scrollable_size()
  return #self.rows * self:get_item_height()
end

-- ── input ───────────────────────────────────────────────────────────────

function PanelView:on_text_input(text)
  -- Only while searching. Everywhere else the panel is a list, not a prompt,
  -- and a keystroke must not silently become a filter.
  if not self.searching then return end
  self.query = self.query .. text
  self:refilter()
end

function PanelView:search_delete()
  if self.query == "" then return end
  self.query = self.query:sub(1, math.max(0, #self.query - 1))
  self:refilter()
end

function PanelView:search_clear()
  self.query = ""
  self.searching = false
  self:refilter()
end

-- Submitting keeps the filter and puts the cursor on the best match, so
-- browsing the results does not throw the search away.
function PanelView:search_submit()
  self.searching = false
  self:refilter()
end

function PanelView:each_row()
  return coroutine.wrap(function()
    self:_ensure_rows()
    local h = self:get_item_height()
    local y = self:get_list_top() - self.scroll.y + style.padding.y
    for i, row in ipairs(self.rows) do
      coroutine.yield(i, row, self.position.x, y, self.size.x, h)
      y = y + h
    end
  end)
end

function PanelView:on_mouse_moved(px, py, ...)
  PanelView.super.on_mouse_moved(self, px, py, ...)
  local top = self:get_list_top()
  local bottom = self.size.y - self:get_footer_height()
  self.hovered = nil
  if py >= top and py < bottom then
    local i = math.floor((py - top + self.scroll.y - style.padding.y)
      / self:get_item_height()) + 1
    if self:_row_selectable(i) then self.hovered = i end
  end
  -- `cursor` is the base class's MOUSE cursor style, read by RootView to
  -- decide what shape the pointer takes. The row the keyboard is on is
  -- `row`. They were once the same field, and every mouse move over the panel
  -- handed the row number to system.set_cursor().
  self.cursor = self.hovered and "hand" or "arrow"
  Host.core.redraw = true
end

function PanelView:on_mouse_pressed(button, x, y, clicks)
  if PanelView.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  if button ~= "left" then return end
  if not self.hovered then return end
  self:set_row(self.hovered)
  -- A double click does what return does: toggling is the one action a user
  -- reaches for first, and making them find the right key first is the kind
  -- of thing that makes a panel feel unfamiliar.
  if clicks >= 2 then
    require("core.input.command").perform("pluginmanager:toggle-cursor")
  end
end

function PanelView:update()
  -- Rows are built here rather than at draw time so the cursor is seated on an
  -- entry before anything can ask about it. A view whose state depends on
  -- having been drawn is a view that is wrong on the first keystroke.
  self:_ensure_rows()

  local dest = self.visible and self.target_width or 0
  if self.init_size then
    self.size.x = dest
    self.init_size = false
  else
    self:move_towards(self.size, "x", dest)
  end
  PanelView.super.update(self)
end

-- ── drawing ─────────────────────────────────────────────────────────────

local function band(self, height, color)
  if height <= 0 then return 0 end
  Host.renderer.draw_rect(self.position.x, self.position.y, self.size.x, height, color)
  Host.renderer.draw_rect(self.position.x, self.position.y + height - style.divider_size,
    self.size.x, style.divider_size, style.divider)
  return height
end

function PanelView:_draw_title()
  local font = style.font
  local lh = self:get_item_height()
  local h = self:get_title_height()

  Host.renderer.draw_rect(self.position.x, self.position.y, self.size.x, h,
    style.background2)

  local counts = self.counts or {}
  local summary = string.format("%d in editor  %d installed  %d available",
    counts.editor or 0, counts.installed or 0, counts.available or 0)
  local sw = font:get_width(summary)

  local x = self.position.x + style.padding.x
  local w = self.size.x - style.padding.x * 2
  common.draw_text(font, style.accent, "Extensions", nil, x,
    self.position.y + style.padding.y, w - sw - style.padding.x, lh)
  common.draw_text(font, style.dim, summary, "right", x,
    self.position.y + style.padding.y, w, lh)

  Host.renderer.draw_rect(self.position.x, self.position.y + h - style.divider_size,
    self.size.x, style.divider_size, style.divider)
  return h
end

function PanelView:_draw_filter()
  local h = self:get_filter_height()
  if h == 0 then return 0 end

  local font = style.font
  local lh = self:get_item_height()
  Host.renderer.draw_rect(self.position.x, self.position.y + self:get_title_height(),
    self.size.x, h, style.background)

  local x = self.position.x + style.padding.x
  local w = self.size.x - style.padding.x * 2
  local y = self.position.y + self:get_title_height() + style.padding.y

  -- The caret is the whole point: this is a field being typed into, and a
  -- filter without one looks like a label.
  local text = self.query ~= "" and ("search: " .. self.query) or "search: "
  common.draw_text(font, style.text, text, nil, x, y, w, lh)

  if self.searching then
    local cx = x + font:get_width(text)
    Host.renderer.draw_rect(math.floor(cx + 2), y + 2, math.max(1, math.floor(Host.scale)),
      font:get_height() - 4, style.accent)
  end

  local found = string.format("%d of %d", self.matched, self.total)
  common.draw_text(font, self.matched > 0 and style.dim or style.accent, found,
    "right", x, y, w, lh)

  return h
end

function PanelView:_draw_footer()
  local font = style.font
  local lh = self:get_item_height()
  local h = self:get_footer_height()
  local y = self.position.y + self.size.y - h

  Host.renderer.draw_rect(self.position.x, y, self.size.x, h, style.background2)
  Host.renderer.draw_rect(self.position.x, y, self.size.x, style.divider_size,
    style.divider)

  local hints = self.searching
    and "type to filter   backspace delete   enter keep   esc done"
    or  "j/k move   / search   space on/off   f feature   i install   u remove   ? more"
  common.draw_text(font, style.dim, hints, nil,
    self.position.x + style.padding.x, y + style.padding.y,
    self.size.x - style.padding.x * 2, lh)
  return h
end

local function draw_section(self, row, x, y, w, h)
  local font = style.font
  local count = row.count and ("  " .. row.count) or ""
  local color = style.dim
  if row.key == "installed" then color = status_color("installed") end
  common.draw_text(font, color, string.upper(row.label) .. count, nil,
    x + style.padding.x, y, w - style.padding.x, h)
end

local function draw_category(self, row, x, y, w, h)
  common.draw_text(style.font, style.line_number2, "  " .. row.label, nil,
    x + style.padding.x, y, w - style.padding.x, h)
end

local function draw_empty(self, row, x, y, w, h)
  common.draw_text(style.font, style.dim, row.text, nil,
    x + style.padding.x, y, w - style.padding.x, h)
end

-- The notice sits at the end of the list and is the only row that explains
-- itself, so it is the only one drawn in the accent colour: a list of two
-- entries with a line under it saying why there are two and not forty should
-- be the first thing a new user's eye lands on after the list.
local function draw_notice(self, row, x, y, w, h)
  common.draw_text(style.font, style.line_number2, row.text, nil,
    x + style.padding.x, y, w - style.padding.x, h)
end

function PanelView:_draw_entry(row, index, x, y, w, h)
  local font   = style.font
  local entry  = row.entry
  local status = status_of(entry)

  local selected = index == self.row
  local hovered  = index == self.hovered

  if selected then
    Host.renderer.draw_rect(x, y, w, h, style.line_highlight)
    Host.renderer.draw_rect(x, y, math.ceil(2 * Host.scale), h, style.accent)
  elseif hovered then
    Host.renderer.draw_rect(x, y, w, h, style.line_highlight)
  end

  -- Right column first: its width is what the name column gets, and it is
  -- the one that varies (a version, or no version).
  local label = STATUS_LABEL[status] or status
  local right = label
  -- An operation in flight owns the column: "cloning…" is the thing worth reading
  -- while it runs, and the version it will replace is not installed yet anyway.
  if entry.progress then
    right = entry.progress
  else
    if entry.version and entry.version ~= "" then
      right = entry.version .. "   " .. label
    end
    -- The on-disk size of an installed package, from the lock. Missing for old
    -- installs that predate the lock carrying bytes, and absent rather than zero
    -- then: "0 B" would claim a measurement that was never taken.
    if entry.size then
      right = entry.size .. "   " .. right
    end
  end
  -- A package with features says so, and says how many are off. Without this the
  -- feature rows below it are the only sign, which means a user has to scroll to
  -- discover that a package is divisible at all -- and the count of *off* ones is
  -- the thing worth reading before expanding it.
  local features = entry.features
  if features and #features > 0 then
    local off = 0
    for _, feature in ipairs(features) do
      if not feature.on then off = off + 1 end
    end
    if off > 0 then
      right = string.format("%d/%d off   ", off, #features) .. right
    end
  end
  local rw = font:get_width(right)
  common.draw_text(font, status_color(status), right, "right",
    x, y, w - style.padding.x, h)

  -- Marker. One column, fixed width, whatever the status: a column that
  -- changes width per row is a column nothing else can line up with.
  local marker_w = math.ceil(font:get_width("M"))
  local marker = ({ editor = "#", installed = "x", disabled = "o",
    available = "+" })[status] or "+"
  common.draw_text(font, status_color(status), marker, nil,
    x + style.padding.x, y, marker_w, h)

  local name_x = x + style.padding.x + marker_w + style.padding.x
  local name_w = w - (name_x - x) - rw - style.padding.x * 2
  local color = style.text
  if status == "editor" or status == "available" then color = style.dim end
  if status == "disabled" then color = style.dim end
  if name_w > 10 then
    Host.core.push_clip_rect(name_x, y, name_w, h)
    common.draw_text(font, color, entry.name or "", nil, name_x, y, name_w, h)
    Host.core.pop_clip_rect()
  end
end

--- A feature row: indented under its package, dim, and read-only.
---
--- Deliberately not selectable. Pressing space on a package installs, enables or
--- disables it; that is the operation with a lifecycle behind it and the one users
--- reach for. A feature is a switch *inside* the package, and making it a target
--- of the same key would mean one key doing two unrelated things depending on
--- which kind of row the cursor happened to be on. It is drawn because a user
--- cannot turn off what they cannot see.
function PanelView:_draw_feature(row, index, x, y, w, h)
  local font    = style.font
  local feature = row.feature
  if not feature then return end

  local hovered = index == self.hovered
  if hovered then
    Host.renderer.draw_rect(x, y, w, h, style.line_highlight)
  end

  -- "on"/"off" rather than a tick: it is a word the panel already uses everywhere
  -- else, and a switch that is off is the thing being read.
  local right = feature.on and "on" or "off"
  local rw = font:get_width(right)
  common.draw_text(font, feature.on and style.git_added or style.git_modified,
    right, "right", x, y, w - style.padding.x, h)

  -- Two indents past the name column, so the relationship is visible without the
  -- row needing to be selected to make sense.
  local name_x = x + style.padding.x * 4 + math.ceil(font:get_width("M"))
  local name_w = w - (name_x - x) - rw - style.padding.x * 2

  -- Dim for a default, full colour for a choice. That difference is the whole
  -- point of the row: it shows which switches are the user's.
  local color = style.dim
  if feature.chosen then color = style.text end
  -- On but not running is a third state, and it is the one worth noticing: the
  -- feature was asked for and could not start.
  if feature.on and not feature.running then color = style.git_modified end

  if name_w > 10 then
    Host.core.push_clip_rect(name_x, y, name_w, h)
    common.draw_text(font, color, feature.label or "", nil, name_x, y, name_w, h)
    Host.core.pop_clip_rect()
  end
end

function PanelView:draw()
  self:draw_background(style.background)

  self:_draw_title()
  self:_draw_filter()

  local top = self:get_list_top()
  local bottom = self.size.y - self:get_footer_height()

  Host.core.push_clip_rect(self.position.x, top + self.position.y, self.size.x,
    math.max(0, bottom - top))
  for index, row, x, y, w, h in self:each_row() do
    if y + h >= top and y < bottom then
      if row.kind == "section" then
        draw_section(self, row, x, y, w, h)
      elseif row.kind == "category" then
        draw_category(self, row, x, y, w, h)
      elseif row.kind == "empty" then
        draw_empty(self, row, x, y, w, h)
      elseif row.kind == "notice" then
        draw_notice(self, row, x, y, w, h)
      elseif row.kind == "feature" then
        self:_draw_feature(row, index, x, y, w, h)
      else
        self:_draw_entry(row, index, x, y, w, h)
      end
    end
  end
  Host.core.pop_clip_rect()

  self:draw_scrollbar()
  self:_draw_footer()
end

return PanelView
