-- The rows of the filter picker: which docsets to offer, in what order, and
-- what each one shows. Kept apart from the picker itself so the ordering --
-- which is the part with a rule behind it -- can be tested without a UI.
--
-- The order is the state being edited, read top to bottom: what the filter
-- holds, then what those choices pull in, then everything else. A filter that
-- sat below the fold would look like no filter at all.

local M = {}

--- A row per installed docset.
---
--- `active` is 1 for a docset picked directly and 2 for one a language pulled
--- in; `via` names the docset that pulled it in. The picker draws those
--- differently -- a pulled-in docset is searched, but it was not chosen, and
--- unticking it would not do anything.
---@param installed string[]
---@param links table<string, { language?: string, kind?: string }>
---@param selected string[]? the filter as picked, or nil for none
---@return { name: string, text: string, language: string, pad: string, active?: integer, via?: string }[]
function M.rows(installed, links, selected)
  local languages = require("apidocs.languages")
  local display = require("apidocs.folders").display

  local active, via = {}, {}
  for _, name in ipairs(selected or {}) do
    active[name] = 1
  end
  for _, name in ipairs(selected and languages.pulled_in(selected, installed, links) or {}) do
    active[name] = 2
    local language = links[name] and links[name].language
    for _, chosen in ipairs(selected) do
      local entry = links[chosen]
      if entry and entry.kind == "language" and entry.language == language then
        via[name] = chosen
        break
      end
    end
  end

  local names = vim.deepcopy(installed)
  table.sort(names, function(a, b)
    local ra, rb = active[a] or 3, active[b] or 3
    if ra ~= rb then
      return ra < rb
    end
    if display(a) ~= display(b) then
      return display(a) < display(b)
    end
    return a < b
  end)

  local width = 0
  for _, name in ipairs(names) do
    width = math.max(width, vim.fn.strdisplaywidth(languages.label(links[name])))
  end

  return vim.tbl_map(function(name)
    local language = languages.label(links[name])
    return {
      name = name,
      -- Both halves are searchable, so typing a language narrows to it --
      -- including "Unknown", which is how the docsets with no language yet
      -- are found.
      text = language .. " " .. display(name),
      language = language,
      pad = string.rep(" ", width - vim.fn.strdisplaywidth(language)),
      active = active[name],
      via = via[name],
    }
  end, names)
end

return M
