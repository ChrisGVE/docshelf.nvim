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
-- The language of an installed docset is decided once, at install, and kept
-- in the install manifest (see metadata.lua). In order:
--   1. the source declares it (a Hackage package is Haskell);
--   2. a devdocs docset whose family is in source_languages.lua takes the
--      table's answer (hand-maintained, so it may lag behind devdocs);
--   3. otherwise a docset whose whole family name (the part before "~") is
--      the name or a Linguist alias of a language in the user's list is that
--      language's own reference (python~3.15 -> Python, cpp -> C++);
--   4. anything else is Unknown, and the user can assign it a language from
--      their list. An assignment is final: to change it, reinstall.
-- The user's list is set in setup() (`languages = { add = {...} }` extends the
-- defaults below, `languages = { only = {...} }` replaces them).
--
-- The data lives in source_languages.lua (hand-maintained) and
-- linguist_languages.lua (generated).

local M = {}

--- The languages offered by default: names from linguist_languages.lua.
M.defaults = {
  "Python", "Rust", "C", "C++", "Java", "TypeScript", "JavaScript", "Go", "Odin", "Zig", "SQL",
  "Markdown",
  "JSON", "JSON with Comments", "JSON5", "JSONLD", "OASv2-json", "OASv3-json",
  "YAML", "MiniYAML", "OASv2-yaml", "OASv3-yaml",
  "TOML", "Typst",
}

local configured = M.defaults

--- The Linguist spelling of a language name, matched without regard to case;
--- nil when Linguist has no such language.
---@param name string
---@return string?
function M.canonical(name)
  local linguist = require("apidocs.linguist_languages")
  if linguist[name] then
    return name
  end
  local wanted = name:lower()
  for known in pairs(linguist) do
    if known:lower() == wanted then
      return known
    end
  end
end

local function canonical_list(names, what)
  if type(names) ~= "table" then
    error("apidocs: languages." .. what .. " must be a list of language names, got " .. vim.inspect(names), 0)
  end
  local list = {}
  for _, name in ipairs(names) do
    local known = type(name) == "string" and M.canonical(name)
    if not known then
      error("apidocs: languages." .. what .. ": " .. vim.inspect(name) .. " is not a GitHub Linguist language", 0)
    end
    if not vim.tbl_contains(list, known) then
      table.insert(list, known)
    end
  end
  return list
end

--- Apply setup()'s `languages` option. An invalid value raises an error and
--- leaves the list unchanged.
---@param opts? { add?: string[], only?: string[] }
function M.configure(opts)
  opts = opts or {}
  if type(opts) ~= "table" then
    error("apidocs: languages must be a table like { add = { ... } }, got " .. vim.inspect(opts), 0)
  end
  for key in pairs(opts) do
    if key ~= "add" and key ~= "only" then
      error("apidocs: languages accepts `add` or `only`, not " .. vim.inspect(key), 0)
    end
  end
  if opts.add and opts.only then
    error("apidocs: languages takes `add` or `only`, not both", 0)
  end
  if opts.only then
    configured = canonical_list(opts.only, "only")
  else
    configured = vim.list_extend(vim.deepcopy(M.defaults), canonical_list(opts.add or {}, "add"))
    configured = canonical_list(configured, "add")
  end
end

--- The languages a docset can be assigned, in the user's order.
---@return string[]
function M.list()
  return vim.deepcopy(configured)
end

--- The family of a docset: its folder name up to the first "~"
--- (python~3.14 -> python, text~2.1.2~~hackage.haskell.org -> text).
local function family(slug)
  return (slug:gsub("~.*$", ""))
end
M.family = family

--- Whether a docset family is the name, or a Linguist alias, of a language.
---@param fam string
---@param language string a Linguist name
local function names_language(fam, language)
  fam = fam:lower()
  if fam == language:lower() then
    return true
  end
  local entry = require("apidocs.linguist_languages")[language]
  return entry ~= nil and vim.tbl_contains(entry.aliases, fam)
end

--- The table entry for a source, or nil when the source is not in the table.
---@param slug string an installed source name, e.g. "python~3.14"
---@param sources? table defaults to the shipped source_languages table
---@return { kind: "language"|"package"|"tool", language?: string }?
function M.of(slug, sources)
  sources = sources or require("apidocs.source_languages")
  return sources[family(slug)]
end

--- Rule 3: a docset named after a language in the user's list is that
--- language's reference. Nil when no configured language matches.
---@param slug string
---@return { kind: "language", language: string }?
function M.guess(slug)
  local fam = family(slug)
  for _, language in ipairs(configured) do
    if names_language(fam, language) then
      return { kind = "language", language = language }
    end
  end
end

--- The language of a docset being installed (rules 1-3), or nil for Unknown.
---@param slug string the installed folder name
---@param opts { devdocs: boolean, declared?: string } devdocs: the docset comes
---  from devdocs (only then does the shipped table apply); declared: the
---  language its source declares
---@return { kind: "language"|"package"|"tool", language?: string }?
function M.resolve(slug, opts)
  if opts.declared then
    local kind = names_language(family(slug), opts.declared) and "language" or "package"
    return { kind = kind, language = opts.declared }
  end
  if opts.devdocs then
    local entry = M.of(slug)
    if entry then
      return vim.deepcopy(entry)
    end
  end
  return M.guess(slug)
end

--- The link recorded when the user assigns `language` to an Unknown docset:
--- its reference when the docset is named after it, a package otherwise.
---@param slug string
---@param language string
---@return { kind: "language"|"package", language: string }? link, string? why
function M.for_assignment(slug, language)
  local known = M.canonical(language)
  if not known or not vim.tbl_contains(configured, known) then
    return nil, vim.inspect(language) .. " is not in the configured language list"
  end
  return { kind = names_language(family(slug), known) and "language" or "package", language = known }
end

--- What a picker shows for a docset's language: the language, "Tool" for a
--- docset that belongs to none, or "Unknown".
---@param link? { kind: string, language?: string }
---@return string
function M.label(link)
  if link == nil then
    return "Unknown"
  end
  if link.kind == "tool" then
    return "Tool"
  end
  return link.language
end

--- The recorded links of installed docsets (see metadata.installed_languages).
local function installed_links(installed)
  return require("apidocs.metadata").installed_languages(installed)
end

--- Installed docsets with no known language, sorted.
---@param installed string[]
---@param links? table<string, table> slug -> link; defaults to the manifest
---@return string[]
function M.unknown(installed, links)
  links = links or installed_links(installed)
  local result = vim.tbl_filter(function(slug)
    return links[slug] == nil
  end, installed)
  table.sort(result)
  return result
end

--- Installed sources pulled in by the selected ones: the packages of every
--- selected language, minus what is already selected. Sorted.
---@param selected string[]
---@param installed string[]
---@param links? table<string, table> slug -> link; defaults to the manifest
---@return string[]
function M.pulled_in(selected, installed, links)
  links = links or installed_links(installed)
  local chosen, wanted = {}, {}
  for _, slug in ipairs(selected) do
    chosen[slug] = true
    local entry = links[slug]
    if entry and entry.kind == "language" then
      wanted[entry.language] = true
    end
  end
  local result = {}
  for _, slug in ipairs(installed) do
    local entry = links[slug]
    if not chosen[slug] and entry and entry.kind == "package" and wanted[entry.language] then
      table.insert(result, slug)
    end
  end
  table.sort(result)
  return result
end

return M
