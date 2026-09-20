-- The rows of the install picker, and the order they are offered in.
--
-- The picker offers two kinds of row from one list. A devdocs row is one of
-- the ~830 docsets in the catalogue, known before a key is pressed. A registry
-- row is a package a source was asked about as the name was typed (see
-- registry.lua); it arrives late, and may not know its version yet.
--
-- Typing filters and orders both. The picker runs live -- every keystroke goes
-- to the registries -- so snacks does no matching of its own, and this module
-- does it instead, with snacks' own matcher when it can be had so that the
-- order is the one the rest of the editor gives.
local M = {}

local folders = require("apidocs.folders")

-- Enough to lift an exact name over any other match of the same quality.
local exact_bonus = 1000

--- Order `items` by how well each one's `text` answers `typed`, dropping the
--- ones that do not. An empty query keeps every item, in the order given.
---@param items table[]
---@param typed string
function M.order(items, typed)
  if typed == "" then
    return items
  end
  local ok, Matcher = pcall(require, "snacks.picker.core.matcher")
  if not ok then
    -- Without snacks' matcher, a plain case-insensitive substring: fewer rows
    -- than a fuzzy match would offer, never a wrong one.
    local needle = typed:lower()
    return vim.tbl_filter(function(item)
      return item.text:lower():find(needle, 1, true) ~= nil
    end, items)
  end
  local matcher = Matcher.new()
  matcher:init(typed)
  -- snacks scores how well the typed characters fit, not how much else the row
  -- holds, so "aeson" and "aeson-pretty" score the same for "aeson". A row
  -- that IS what was typed is what was asked for: it goes first.
  local exact = typed:lower()
  local scored = {}
  for index, item in ipairs(items) do
    local score = matcher:match(item)
    if score > 0 then
      if item.text:lower() == exact then
        score = score + exact_bonus
      end
      scored[#scored + 1] = { item = item, score = score, index = index }
    end
  end
  table.sort(scored, function(a, b)
    if a.score == b.score then
      return a.index < b.index
    end
    return a.score > b.score
  end)
  return vim.tbl_map(function(entry)
    return entry.item
  end, scored)
end

--- A row for a package a registry answered with. `slug` is the folder it would
--- install into, which is only known once the version is: a registry that
--- returns none leaves the row to be resolved when it is picked.
---@param row { name: string, version?: string, origin: string }
---@param language? string the language the row's source documents
function M.registry_row(row, language)
  local label = row.version and (row.name .. "~" .. row.version) or row.name
  return {
    text = label,
    label = label,
    language = language or "",
    origin = row.origin,
    name = row.name,
    version = row.version,
    slug = row.version and folders.name(row.name .. "~" .. row.version, row.origin) or nil,
  }
end

--- The picker's title, with what is still being waited on. Registries are
--- community-run and can take seconds: without this the picker looks finished
--- while answers are still coming.
---@param base string
---@param pending string[] origins still being waited on
function M.title(base, pending)
  if #pending == 0 then
    return base
  end
  if #pending == 1 then
    return base .. " · searching " .. pending[1] .. "…"
  end
  return base .. " · searching " .. #pending .. " registries…"
end

return M
