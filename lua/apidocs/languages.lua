-- Link documentation sources to their language.
--
-- Selecting a language's reference (python~3.14) usually means "this language
-- and its libraries": when coding you want both, unless you are zooming in on
-- one package. So a selected language pulls in the installed packages of that
-- language (numpy, scikit_learn), while a package selected on its own stays on
-- its own. Tools (git, redis) belong to no language and pull in nothing.
--
-- Versions are deliberately not linked: packages rarely declare an upper bound
-- on the language version, so any python~3.x pulls in every Python package.
-- Another version of the language itself (python~3.13) is a different
-- reference and is never pulled in.
--
-- The data lives in source_languages.lua (hand-maintained) and
-- linguist_languages.lua (generated).

local M = {}

local function family(slug)
  return (slug:gsub("~.*$", ""))
end

--- The table entry for a source, or nil when the source is not in the table.
---@param slug string an installed source name, e.g. "python~3.14"
---@param sources? table defaults to the shipped source_languages table
---@return { kind: "language"|"package"|"tool", language?: string }?
function M.of(slug, sources)
  sources = sources or require("apidocs.source_languages")
  return sources[family(slug)]
end

--- Installed sources pulled in by the selected ones: the packages of every
--- selected language, minus what is already selected. Sorted.
---@param selected string[]
---@param installed string[]
---@param sources? table
---@return string[]
function M.pulled_in(selected, installed, sources)
  local chosen, wanted = {}, {}
  for _, slug in ipairs(selected) do
    chosen[slug] = true
    local entry = M.of(slug, sources)
    if entry and entry.kind == "language" then
      wanted[entry.language] = true
    end
  end
  local result = {}
  for _, slug in ipairs(installed) do
    local entry = M.of(slug, sources)
    if not chosen[slug] and entry and entry.kind == "package" and wanted[entry.language] then
      table.insert(result, slug)
    end
  end
  table.sort(result)
  return result
end

return M
