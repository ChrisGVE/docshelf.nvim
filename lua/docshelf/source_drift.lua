-- Drift check for source_languages.lua against the devdocs catalogue.
--
-- source_languages.lua is hand-maintained, so it goes stale when devdocs adds
-- or retires a source. This module compares it with the catalogue
-- (https://devdocs.io/docs.json) and PROPOSES rows; it never writes the table.
-- A proposal is seeded from the source's GitHub repository language, which is
-- what the program is written in (git: C), so every proposal needs a person;
-- without one, the source's own name is proposed, as for a tool.
-- A row that exists but is wrong cannot be detected here.
--
-- Driven by scripts/check_source_languages.lua; tested offline by
-- tests/source_drift_spec.lua.
local M = {}

--- Collapse catalogue entries into families (the slug before "~").
---@param catalogue table[] docs.json entries
---@return table<string, {name: string, code: string?}>
function M.families(catalogue)
  local families = {}
  for _, entry in ipairs(catalogue) do
    local family = entry.slug:match("^[^~]+")
    if not families[family] then
      families[family] = { name = entry.name, code = entry.links and entry.links.code }
    end
  end
  return families
end

--- Families missing from the table, and rows whose family left the catalogue.
---@param catalogue table[] docs.json entries
---@param table_ table<string, table> source_languages.lua
---@return {missing: table[], gone: string[]}
function M.check(catalogue, table_)
  local families = M.families(catalogue)
  local missing, gone = {}, {}
  for family, info in pairs(families) do
    if not table_[family] then
      missing[#missing + 1] = { family = family, name = info.name, code = info.code }
    end
  end
  for family in pairs(table_) do
    if not families[family] then
      gone[#gone + 1] = family
    end
  end
  table.sort(missing, function(a, b)
    return a.family < b.family
  end)
  table.sort(gone)
  return { missing = missing, gone = gone }
end

--- "owner/repo" from a GitHub URL, or nil for anything else.
---@param url string?
---@return string?
function M.github_repo(url)
  if not url then
    return nil
  end
  local repo = url:match("^https://github%.com/([^/]+/[^/]+)")
  return repo and repo:gsub("%.git$", "")
end

--- A table row to paste into source_languages.lua, marked as unchecked.
---@param missing {family: string, name: string}
---@param repo_language string? the repository's GitHub language
---@return string
function M.proposal(missing, repo_language)
  if repo_language then
    return string.format(
      '  ["%s"] = { language = "%s" }, -- %s -- PROPOSED from repo language, check it',
      missing.family,
      repo_language,
      missing.name
    )
  end
  return string.format(
    '  ["%s"] = { language = "%s" }, -- %s -- PROPOSED, no repo language found, check it',
    missing.family,
    missing.name,
    missing.name
  )
end

--- Rows that break the table's own rules, one message each, sorted by family.
---@param table_ table<string, table> source_languages.lua
---@return string[]
function M.row_errors(table_)
  local families = vim.tbl_keys(table_)
  table.sort(families)
  local errors = {}
  for _, family in ipairs(families) do
    local row = table_[family]
    local message
    if type(row.language) ~= "string" or row.language:match("^%s*$") then
      message = "a row needs a language"
    else
      for field in pairs(row) do
        if field ~= "language" then
          message = string.format('unexpected field "%s"', tostring(field))
        end
      end
    end
    if message then
      errors[#errors + 1] = family .. ": " .. message
    end
  end
  return errors
end

return M
