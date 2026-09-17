-- The rows of the "language of this docset" picker.
--
-- The names offered are the configured lists plus every language already
-- recorded on an installed docset (languages.available), so a name typed once
-- comes back for the next docset. Typing narrows them; when what was typed
-- names none of them -- neither a name nor an alias -- the first row offers to
-- take it as a new name, so pressing enter on an unknown word adds it.
--
-- Kept apart from the picker itself so that it can be tested without a UI.
local M = {}

--- The rows for a typed pattern, best match first.
---@param names string[] the names on offer
---@param pattern? string what the user typed
---@return { name: string, add?: boolean }[]
function M.rows(names, pattern)
  pattern = vim.trim(pattern or "")
  local matches = names
  if pattern ~= "" then
    matches = vim.fn.matchfuzzy(names, pattern)
  end
  local rows = vim.tbl_map(function(name)
    return { name = name }
  end, matches)
  if pattern ~= "" and not require("apidocs.languages").named(pattern, names) then
    table.insert(rows, 1, { name = pattern, add = true })
  end
  return rows
end

return M
