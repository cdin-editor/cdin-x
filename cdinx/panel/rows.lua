-- Turning a flat catalog into rows the panel can draw.
--
-- Pure as well: it takes entries and a query and hands back rows. The panel
-- decides what is selectable, this decides what exists, and a bug in either
-- one is then findable without a window.
--
-- Three sections, in the order that answers "what is here, and what is
-- mine":
--
--   IN THE EDITOR  what the build or the installed set brought: not
--                  installable, not removable, but visibly present. It used
--                  to be missing from the list entirely, which made the panel
--                  of a fresh build look broken rather than empty.
--   INSTALLED      what the user put here, split by category, each one on or
--                  off.
--   AVAILABLE      what the catalog offers and this does not have.
local Search = require "cdinx.panel.search"

local Rows = {}

Rows.CATEGORY_ORDER = {
  "core", "syntax", "lsp", "formatters", "git", "debug", "ui", "utils",
  "integration", "optional", "themes", "other",
}

Rows.CATEGORY_NAMES = {
  core = "Core", syntax = "Syntax", lsp = "LSP", formatters = "Formatters",
  git = "Git", debug = "Debug", ui = "Interface", utils = "Utilities",
  integration = "Integrations", optional = "Optional", themes = "Themes",
  other = "Other",
}

-- Categories in a fixed order, then anything not in the table, alphabetically.
-- A grouping whose order comes out of a hash iteration is a grouping that
-- reshuffles between two runs over the same catalog.
local function ordered_categories(group)
  local out, seen = {}, {}
  for _, cat in ipairs(Rows.CATEGORY_ORDER) do
    if group[cat] then
      out[#out + 1] = cat
      seen[cat] = true
    end
  end
  local extra = {}
  for cat in pairs(group) do
    if not seen[cat] then extra[#extra + 1] = cat end
  end
  table.sort(extra)
  for _, cat in ipairs(extra) do out[#out + 1] = cat end
  return out
end

local function by_name(a, b)
  return (a.name or "") < (b.name or "")
end

-- entries: array of { name, category, version, description, status, locked,
--                     source }
-- query:  the filter, "" for none.
-- notice: an optional line about where extensions would come from, shown at
--         the end of the list when the panel has nothing installable to offer.
-- store_total: an optional human size for the Installed section ("412 KiB"), or
--         nil. It arrives separately because it is a property of the store, not
--         of any entry, and summing it here would mean trusting every entry to
--         carry one. Named in full because `total` below already means the entry
--         count, and two totals in one function is how the wrong one gets read.
--
-- Returns { rows, counts, matched, total, query }. A row is
--   { kind = "section" | "category" | "entry" | "empty" | "notice", ... }
function Rows.build(entries, query, notice, store_total)
  query = Search.normalize(query)

  local buckets = { editor = {}, installed = {}, available = {} }
  local counts  = { editor = 0, installed = 0, available = 0 }
  local matched_scores = {}
  local matched, total = 0, 0

  for _, entry in ipairs(entries) do
    total = total + 1
    local score = Search.score(entry, query)
    if score then
      matched = matched + 1
      matched_scores[#matched_scores + 1] = { entry = entry, score = score }
      local group = entry.group or "available"
      buckets[group] = buckets[group] or {}
      table.insert(buckets[group], entry)
      counts[group] = (counts[group] or 0) + 1
    end
  end

  local rows = {}

  local function add_section(key, label, with_categories)
    local list = buckets[key]
    if not list or #list == 0 then return end

    rows[#rows + 1] = { kind = "section", key = key, label = label,
      count = counts[key] }

    -- A package's features, indented under it.
    --
    -- A helper rather than inline in both branches, because there are two branches
    -- and a feature row added to only one of them is a feature that appears under
    -- an installed package and vanishes under a build one -- which is exactly where
    -- the packages with the most features are: vim, the workspace.
    local function emit(entry)
      rows[#rows + 1] = { kind = "entry", entry = entry }
      for _, feature in ipairs(entry.features or {}) do
        rows[#rows + 1] = { kind = "feature", entry = entry, feature = feature }
      end
    end

    if not with_categories then
      table.sort(list, by_name)
      for _, entry in ipairs(list) do
        emit(entry)
      end
      return
    end

    -- Ranked by the search, not by name: a filter exists to bring the best
    -- match to the top, and then sorting alphabetically undoes it.
    if query ~= "" then
      local by_name_of = {}
      for _, item in ipairs(matched_scores) do by_name_of[item.entry.name] = item.score end
      table.sort(list, function(a, b)
        local sa, sb = by_name_of[a.name] or 0, by_name_of[b.name] or 0
        if sa ~= sb then return sa > sb end
        return by_name(a, b)
      end)
    else
      table.sort(list, by_name)
    end

    local group = {}
    for _, entry in ipairs(list) do
      local cat = entry.category or "other"
      group[cat] = group[cat] or {}
      table.insert(group[cat], entry)
    end

    for _, cat in ipairs(ordered_categories(group)) do
      rows[#rows + 1] = { kind = "category",
        label = Rows.CATEGORY_NAMES[cat] or cat }
      for _, entry in ipairs(group[cat]) do
        emit(entry)
      end
    end
  end

  add_section("editor", "In the editor", false)
  -- The total is the section's answer to "how much": per-package sizes live on
  -- the rows, and this is the number they add up to.
  local installed_label = "Installed"
  if store_total and store_total ~= "" and store_total ~= "0 B" then
    installed_label = "Installed (" .. store_total .. ")"
  end
  add_section("installed", installed_label, true)
  add_section("available", "Available", true)

  if #rows == 0 then
    -- One row, saying so. An empty panel and a panel that failed are the same
    -- picture, and only one of them is what happened.
    rows[#rows + 1] = {
      kind = "empty",
      text = query ~= ""
        and ("Nothing matches " .. Search.normalize(query))
        or  "No extensions found",
    }
  end

  -- The last row says where extensions would come from, when the answer is
  -- "nowhere yet". It goes at the end rather than the top: the list above it is
  -- true and useful, and a panel that opens with an explanation instead of a
  -- list reads as a dialog.
  if notice and notice ~= "" then
    rows[#rows + 1] = { kind = "notice", text = notice }
  end

  return {
    rows    = rows,
    counts  = counts,
    matched = matched,
    total   = total,
    query   = query,
  }
end

-- The row the cursor should land on after a rebuild.
--
-- Rebuilds happen while browsing (an install changes the list) and while
-- typing (every character changes it), and a cursor that jumps to the top
-- every time is how a filter ends up feeling broken. So:
--
--   keep_name  the extension the cursor was on, if it survived: stay on it
--   otherwise   the nearest entry to `from`, forward first then backward,
--               so a list that shrinks keeps you near where you were
--   otherwise   the first entry in the list
function Rows.nearest(rows, from, keep_name)
  local function is_entry(i)
    local row = rows[i]
    return row ~= nil and row.kind == "entry"
  end

  if keep_name then
    for i, row in ipairs(rows) do
      if row.kind == "entry" and row.entry.name == keep_name then return i end
    end
  end

  from = from or 1
  for i = from, #rows do
    if is_entry(i) then return i end
  end
  for i = math.min(from, #rows) - 1, 1, -1 do
    if is_entry(i) then return i end
  end
  for i = 1, #rows do
    if is_entry(i) then return i end
  end
  return 1
end

return Rows
