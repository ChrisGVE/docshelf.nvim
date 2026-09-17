-- Link documentation sources to their language.
--
-- Every docset has one flat `language`: a programming language (Python), a
-- file format (YAML) or a tool (Git). setup() takes the three as separate
-- lists only for convenience; they are concatenated into one list and nothing
-- downstream tells them apart. Each entry has a displayed name and aliases
-- that also match it (TypeScript: ts, GitHub: gh, ripgrep: rg).
--
-- Selecting a language's own reference (python~3.14) usually means "this
-- language and its libraries": when coding you want both, unless you are
-- zooming in on one package. So a selected reference pulls in every other
-- installed docset of that language (numpy, scikit_learn), while anything
-- else selected on its own stays on its own. Another version of the reference
-- itself (python~3.13) is a different reference and is never pulled in.
--
-- Whether a docset is its language's reference is derived, never stored by
-- hand: it is when its family (the part before "~") equals the language's
-- name or one of its aliases (python -> Python, openjdk -> Java alias).
--
-- The language of an installed docset is decided at install and kept in the
-- install manifest (see metadata.lua). In order:
--   1. the source declares it (a Hackage package is Haskell);
--   2. a devdocs docset whose family is in source_languages.lua takes the
--      table's answer (hand-maintained, so it may lag behind devdocs);
--   3. otherwise a docset whose family is the name or an alias of an entry in
--      the user's list is that entry (python~3.15 -> Python, cpp -> C++);
--   4. anything else is Unknown.
-- The user can give any installed docset another language from the list; that
-- choice wins over rules 1-3 from then on.

local M = {}

--- Aliases shipped for well-known names, whether or not the name is in the
--- user's list: they spell the name the way docset families do.
M.known = {
  { "Python", aliases = { "py", "python3" } },
  { "Rust", aliases = { "rs" } },
  { "C" },
  { "C++", aliases = { "cpp", "cxx" } },
  { "Java", aliases = { "openjdk" } },
  { "TypeScript", aliases = { "ts" } },
  { "JavaScript", aliases = { "js" } },
  { "Go", aliases = { "golang" } },
  { "Odin" },
  { "Zig" },
  { "SQL", aliases = { "postgresql", "sqlite" } },
  { "Bash", aliases = { "sh" } },
  { "Zsh" },
  { "Fish" },
  { "Markdown", aliases = { "md" } },
  { "JSON" },
  { "YAML", aliases = { "yml" } },
  { "TOML" },
  { "Typst" },
  { "Git" },
  { "GitHub", aliases = { "gh" } },
  { "Jujutsu", aliases = { "jj" } },
  { "Docker", aliases = { "docker compose" } },
  { "tmux" },
  { "herdr" },
  { "Neovim", aliases = { "nvim" } },
  { "Make", aliases = { "gnu_make" } },
  { "CMake" },
  { "Homebrew", aliases = { "brew" } },
  { "curl" },
  { "ripgrep", aliases = { "rg" } },
  { "fd" },
  { "jq" },
  { "SSH", aliases = { "openssh" } },
  -- not in the defaults; named differently by devdocs
  { "Fortran", aliases = { "gnu_fortran" } },
  { "COBOL", aliases = { "gnu_cobol" } },
  { "Tcl", aliases = { "tcl_tk" } },
  { "XSLT", aliases = { "xslt_xpath" } },
  { "SCSS", aliases = { "sass" } },
  { "TeX", aliases = { "latex" } },
  { "MATLAB", aliases = { "octave" } },
  { "HCL", aliases = { "opentofu", "terraform" } },
  { "Emacs Lisp", aliases = { "elisp" } },
  { "Linux man pages", aliases = { "man" } },
}

--- The lists offered by default, by name.
M.defaults = {
  languages = {
    "Python",
    "Rust",
    "C",
    "C++",
    "Java",
    "TypeScript",
    "JavaScript",
    "Go",
    "Odin",
    "Zig",
    "SQL",
    "Bash",
    "Zsh",
    "Fish",
  },
  formats = {
    "Markdown",
    "JSON",
    "JSON with Comments",
    "JSON5",
    "JSONLD",
    "OASv2-json",
    "OASv3-json",
    "YAML",
    "MiniYAML",
    "OASv2-yaml",
    "OASv3-yaml",
    "TOML",
    "Typst",
  },
  tools = {
    "Git",
    "GitHub",
    "Jujutsu",
    "Docker",
    "tmux",
    "herdr",
    "Neovim",
    "Make",
    "CMake",
    "Homebrew",
    "curl",
    "ripgrep",
    "fd",
    "jq",
    "SSH",
  },
}

local list_names = { "languages", "formats", "tools" }

--- The form names are compared in: lowercase, with runs of spaces and
--- punctuation other than + and # turned into "_" (GNU Make -> gnu_make).
---@param name string
---@return string
local function key(name)
  return (name:lower():gsub("[^%w+#]+", "_"))
end
M.key = key

local known_by_key = {}
for _, entry in ipairs(M.known) do
  known_by_key[key(entry[1])] = entry
end

--- An entry { name, aliases } from a setup() item: a name, or a table
--- { "Name", aliases = { ... } }. A name the shipped list knows takes its
--- spelling and aliases; aliases given by the user are added to them.
local function entry_of(item, where)
  local name, extra = item, {}
  if type(item) == "table" then
    name, extra = item[1], item.aliases or {}
  end
  if type(name) ~= "string" or name:match("^%s*$") then
    error("apidocs: " .. where .. ": " .. vim.inspect(item) .. " is not a name or { name, aliases = {...} }", 0)
  end
  if type(extra) ~= "table" then
    error("apidocs: " .. where .. ": aliases of " .. name .. " must be a list of strings", 0)
  end
  local known = known_by_key[key(name)]
  local entry = { name = known and known[1] or name, aliases = {} }
  for _, alias in ipairs(vim.list_extend(vim.deepcopy(known and known.aliases or {}), extra)) do
    if type(alias) ~= "string" then
      error("apidocs: " .. where .. ": aliases of " .. name .. " must be a list of strings", 0)
    end
    if not vim.tbl_contains(entry.aliases, alias) then
      table.insert(entry.aliases, alias)
    end
  end
  return entry
end

local function one_list(what, opts)
  local where = what
  if opts == nil then
    opts = {}
  end
  if type(opts) ~= "table" then
    error("apidocs: " .. where .. " must be a table like { add = { ... } }, got " .. vim.inspect(opts), 0)
  end
  for k in pairs(opts) do
    if k ~= "add" and k ~= "only" then
      error("apidocs: " .. where .. " accepts `add` or `only`, not " .. vim.inspect(k), 0)
    end
  end
  if opts.add and opts.only then
    error("apidocs: " .. where .. " takes `add` or `only`, not both", 0)
  end
  local items = opts.only or vim.list_extend(vim.deepcopy(M.defaults[what]), opts.add or {})
  if type(items) ~= "table" then
    error("apidocs: " .. where .. " must list names, got " .. vim.inspect(items), 0)
  end
  local entries = {}
  for _, item in ipairs(items) do
    table.insert(entries, entry_of(item, where))
  end
  return entries
end

--- Merge entries naming the same thing, and refuse a name or alias that
--- would match two different entries.
local function merged(entries)
  local result, owner = {}, {}
  for _, entry in ipairs(entries) do
    local existing = owner[key(entry.name)]
    if existing and key(existing.name) == key(entry.name) then
      for _, alias in ipairs(entry.aliases) do
        if not vim.tbl_contains(existing.aliases, alias) then
          table.insert(existing.aliases, alias)
        end
      end
      entry = existing
    else
      table.insert(result, entry)
    end
    for _, word in ipairs(vim.list_extend({ entry.name }, entry.aliases)) do
      local other = owner[key(word)]
      if other and other ~= entry then
        error("apidocs: " .. vim.inspect(word) .. " would name both " .. other.name .. " and " .. entry.name, 0)
      end
      owner[key(word)] = entry
    end
  end
  return result, owner
end

local configured, by_key

--- Apply setup()'s `languages`, `formats` and `tools` options. An invalid
--- value raises an error and leaves the list unchanged.
---@param opts? { languages?: table, formats?: table, tools?: table }
function M.configure(opts)
  opts = opts or {}
  if type(opts) ~= "table" then
    error("apidocs: language options must be a table, got " .. vim.inspect(opts), 0)
  end
  local all = {}
  for _, what in ipairs(list_names) do
    vim.list_extend(all, one_list(what, opts[what]))
  end
  configured, by_key = merged(all)
end

M.configure({})

--- The names a docset can be given, in the user's order.
---@return string[]
function M.list()
  return vim.tbl_map(function(entry)
    return entry.name
  end, configured)
end

--- The configured entries, { name, aliases }.
function M.entries()
  return vim.deepcopy(configured)
end

--- The configured name a word refers to (by name or alias, ignoring case);
--- nil when no entry matches.
---@param word string
---@return string?
function M.find(word)
  local entry = by_key[key(word)]
  return entry and entry.name
end

--- The family of a docset: its folder name up to the first "~"
--- (python~3.14 -> python, text~2.1.2~~hackage.haskell.org -> text).
local function family(slug)
  return (slug:gsub("~.*$", ""))
end
M.family = family

--- Whether a docset is `language`'s own reference: its family is the
--- language's name or one of its aliases, from the user's list, or from the
--- shipped aliases when the language is not listed.
---@param slug string
---@param language string
---@return "language"|"package"
function M.kind(slug, language)
  local entry = by_key[key(language)] or known_by_key[key(language)]
  local names = { language }
  if entry then
    names = vim.list_extend({ entry.name or entry[1] }, vim.deepcopy(entry.aliases or {}))
  end
  local fam = key(family(slug))
  for _, name in ipairs(names) do
    if key(name) == fam then
      return "language"
    end
  end
  return "package"
end

--- A link { kind, language } for a docset, the language spelled as listed.
local function link(slug, language)
  language = M.find(language) or language
  return { kind = M.kind(slug, language), language = language }
end
M.link = link

--- The table's language for a source, or nil when the source is not in it.
---@param slug string an installed source name, e.g. "python~3.14"
---@param sources? table defaults to the shipped source_languages table
---@return string?
function M.of(slug, sources)
  sources = sources or require("apidocs.source_languages")
  local row = sources[family(slug)]
  return row and row.language
end

--- Rule 3: a docset named after an entry in the user's list is that entry's
--- reference. Nil when no entry matches.
---@param slug string
---@return { kind: "language", language: string }?
function M.guess(slug)
  local name = M.find(family(slug))
  if name then
    return { kind = "language", language = name }
  end
end

--- The language of a docset being installed (rules 1-3), or nil for Unknown.
---@param slug string the installed folder name
---@param opts { devdocs: boolean, declared?: string } devdocs: the docset comes
---  from devdocs (only then does the shipped table apply); declared: the
---  language its source declares
---@return { kind: "language"|"package", language: string }?
function M.resolve(slug, opts)
  if opts.declared then
    return link(slug, opts.declared)
  end
  local listed = opts.devdocs and M.of(slug)
  if listed then
    return link(slug, listed)
  end
  return M.guess(slug)
end

--- The link recorded when the user gives a docset `language`, which must be
--- in the configured list.
---@param slug string
---@param language string
---@return { kind: "language"|"package", language: string }? link, string? why
function M.for_assignment(slug, language)
  if not M.find(language) then
    return nil, vim.inspect(language) .. " is not in the configured list"
  end
  return link(slug, language)
end

--- What a picker shows for a docset's language.
---@param link? { language: string }
---@return string
function M.label(link_)
  return link_ and link_.language or "Unknown"
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

--- Installed docsets pulled in by the selected ones: for every selected
--- reference, the other docsets of its language that are not references
--- themselves, minus what is already selected. Sorted.
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
      wanted[key(entry.language)] = true
    end
  end
  local result = {}
  for _, slug in ipairs(installed) do
    local entry = links[slug]
    if not chosen[slug] and entry and entry.kind == "package" and wanted[key(entry.language)] then
      table.insert(result, slug)
    end
  end
  table.sort(result)
  return result
end

return M
