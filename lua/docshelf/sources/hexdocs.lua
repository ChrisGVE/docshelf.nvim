-- The hexdocs.pm source adapter (Elixir, Erlang and Gleam packages on hex.pm).
--
-- hex.pm keeps each release's documentation as one tarball,
-- repo.hex.pm/docs/<name>-<version>.tar.gz: the same HTML hexdocs.pm serves,
-- with the search index its generator wrote beside it. Two generators write
-- them, and ExDoc has changed its index three times, so the entries come from
-- whichever of these the tarball holds (measured on real tarballs):
--   * search_data.json            Gleam's own generator, {items, proglang}
--   * dist/search_data-<hash>.js  ExDoc 0.30 on, searchData={items = [...]}
--   * dist/search_items-<hash>.js ExDoc 0.20 to 0.2x, searchNodes=[...]; it is
--                                 JavaScript, and ecto 2.2.12 escapes "#" as
--                                 "\#", which JSON refuses
--   * dist/sidebar_items-<hash>.js older ExDoc, sidebarNodes = modules with
--                                 their functions, types, callbacks, macros
-- Every item names a title, a kind and a "Page.html#anchor" ref.
--
-- This adapter turns that into the index/db pair the installer expects (see
-- sources/devdocs.lua):
--   * a docset is "<package>~<version>" (jason~1.4.4);
--   * every item whose page is in the tarball is an entry, typed by its kind;
--   * pages keep their documentation only, each detail's id moves onto its
--     signature (the installer reads the text that follows an id), links
--     between pages become page keys and every other link an address on
--     hexdocs.pm.
--
-- A hex.pm package may be written in Elixir, Erlang or Gleam, and neither a
-- search nor the package record says which. The docs do: Gleam's index names
-- its language, and ExDoc links a stylesheet per language
-- (html-elixir-<hash>.css, html-erlang-<hash>.css). So this source declares
-- the languages it may document, and each docset gets its own once installed.
local links = require("docshelf.links")

local M = {}

M.origin = "hexdocs.pm"

M.languages = { "Elixir", "Erlang", "Gleam" }

local registry = "https://hex.pm/api/packages"
local tarballs = "https://repo.hex.pm/docs/"
local site = "https://hexdocs.pm/"

local user_agent = "docshelf.nvim (https://github.com/ChrisGVE/docshelf.nvim)"

local function fetch_json(url, system)
  local res = system({ "curl", "-sfL", "-A", user_agent, "-H", "Accept: application/json", url })
  if res.code ~= 0 then
    return nil, res.code
  end
  local ok, body = pcall(vim.json.decode, res.stdout)
  if not ok then
    error("hex.pm answered " .. url .. " with something that is not JSON", 0)
  end
  return body
end

local function is_prerelease(version)
  return version:find("-", 1, true) ~= nil
end

--- The release of a package whose documentation to fetch: its newest stable
--- release when that one has docs, else the newest stable release that does,
--- else the newest documented prerelease. hex.pm lists releases newest first.
---@return string? version
local function documented_release(package)
  local releases = type(package.releases) == "table" and package.releases or {}
  local documented = {}
  for _, release in ipairs(releases) do
    if type(release) == "table" and release.has_docs and type(release.version) == "string" then
      documented[#documented + 1] = release.version
    end
  end
  if vim.tbl_contains(documented, package.latest_stable_version) then
    return package.latest_stable_version
  end
  for _, version in ipairs(documented) do
    if not is_prerelease(version) then
      return version
    end
  end
  return documented[1]
end

--- The packages hex.pm finds for `query`, most downloaded lately first (its
--- search has no order of relevance; its default is by name), each at the
--- release `resolve` would pick. A package with no documentation is left out.
---@param query string
---@param system fun(cmd: string[]): vim.SystemCompleted
---@return { name: string, version: string }[]
function M.search(query, system)
  local body, code = fetch_json(registry .. "?search=" .. vim.uri_encode(query, "rfc2396") .. "&sort=recent_downloads", system)
  if not body then
    error("could not search hex.pm (curl exit " .. tostring(code) .. ")", 0)
  end
  if not vim.islist(body) then
    error("hex.pm answered a search with something other than a list of packages", 0)
  end
  local rows = {}
  for _, package in ipairs(body) do
    local version = type(package) == "table" and type(package.name) == "string" and documented_release(package)
    if version then
      rows[#rows + 1] = { name = package.name, version = version }
    end
  end
  return rows
end

--- The docset for the release of a package whose documentation to fetch.
---@param name string
---@param system fun(cmd: string[]): vim.SystemCompleted
---@return string docset e.g. "jason~1.4.4"
function M.resolve(name, system)
  local package = fetch_json(registry .. "/" .. name, system)
  local version = type(package) == "table" and documented_release(package)
  if not version then
    error("no documentation on hexdocs.pm for " .. name, 0)
  end
  return name .. "~" .. version
end

local function split_docset(docset)
  local name, version = docset:match("^(.+)~([%w%.%-%+]+)$")
  if not name then
    error("a hexdocs.pm docset is <package>~<version>, got " .. docset, 0)
  end
  return name, version
end

--- The release a docset holds: it is named for the exact version it came from.
---@param docset string e.g. "jason~1.4.4"
function M.release(docset)
  local _, version = split_docset(docset)
  return version
end

--- The docset hex.pm offers for this package today; comparing it with the
--- docset's own name is how an update is noticed.
---@param docset string
---@param system fun(cmd: string[]): vim.SystemCompleted
function M.latest(docset, system)
  return M.resolve((split_docset(docset)), system)
end

local function read_file(path)
  local file = assert(io.open(path, "r"))
  local contents = file:read("*a")
  file:close()
  return contents
end

--- ExDoc's index files are JavaScript: `name=<value>;`. The value is JSON
--- except for escapes only JavaScript knows ("\#"), which stand for the
--- character itself.
local function read_script(path)
  local value = read_file(path):match("^[^=]*=(.*)$") or ""
  value = value:gsub(";%s*$", "")
  value = value:gsub("\\(.)", function(char)
    return char:match('["\\/bfnrtu]') and ("\\" .. char) or char
  end)
  return vim.json.decode(value)
end

local function first_file(folder, pattern)
  return vim.fn.glob(folder .. "/" .. pattern, false, true)[1]
end

-- What an item's kind is called in the pickers.
local kinds = {
  module = "Modules",
  exception = "Exceptions",
  protocol = "Protocols",
  behaviour = "Behaviours",
  task = "Mix Tasks",
  ["function"] = "Functions",
  macro = "Macros",
  type = "Types",
  opaque = "Types",
  callback = "Callbacks",
  macrocallback = "Callbacks",
  value = "Values",
  extras = "Guides",
  page = "Guides",
}

-- The member lists of a module in old ExDoc's sidebar, by the kind they hold.
local sidebar_members = { functions = "function", types = "type", callbacks = "callback", macros = "macro" }

--- Items { title, type, ref } out of an old ExDoc sidebar: modules,
--- exceptions, protocols and tasks, each with its members.
local function sidebar_items(nodes)
  local items = {}
  for group, kind in pairs({ modules = "module", exceptions = "exception", protocols = "protocol", tasks = "task" }) do
    for _, node in ipairs(nodes[group] or {}) do
      items[#items + 1] = { title = node.title or node.id, type = kind, ref = node.id .. ".html" }
      for list, member_kind in pairs(sidebar_members) do
        for _, member in ipairs(node[list] or {}) do
          items[#items + 1] = {
            title = node.id .. "." .. member.id,
            type = member_kind,
            ref = node.id .. ".html#" .. member.anchor,
          }
        end
      end
    end
  end
  for _, extra in ipairs(nodes.extras or {}) do
    items[#items + 1] = { title = extra.title or extra.id, type = "extras", ref = extra.id .. ".html" }
  end
  return items
end

--- The items of a tarball's search index, and the language it names (Gleam's
--- does; ExDoc's does not).
---@return table[] items, string? language
local function read_index(folder)
  local gleam = folder .. "/search_data.json"
  if vim.fn.filereadable(gleam) == 1 then
    local data = vim.json.decode(read_file(gleam))
    local items = {}
    for _, item in ipairs(data.items or {}) do
      local title = item.title
      if item.type ~= "module" and item.type ~= "page" and item.parentTitle then
        title = item.parentTitle .. "." .. item.title
      end
      items[#items + 1] = { title = title, type = item.type, ref = item.ref }
    end
    local language = type(data.proglang) == "string" and (data.proglang:gsub("^%l", string.upper)) or nil
    return items, language
  end
  local search_data = first_file(folder, "dist/search_data-*.js")
  if search_data then
    return read_script(search_data).items or {}
  end
  local search_items = first_file(folder, "dist/search_items-*.js")
  if search_items then
    return read_script(search_items)
  end
  local sidebar = first_file(folder, "dist/sidebar_items-*.js")
  if sidebar then
    return sidebar_items(read_script(sidebar))
  end
  return {}
end

--- A page that only sends the browser elsewhere (ExDoc's index.html).
local function is_redirect(html)
  return html:sub(1, 1024):find('http%-equiv="refresh"') ~= nil
end

-- ExDoc's own pages, which are not documentation.
local not_documentation = { ["404"] = true, search = true }

--- Every page of the tarball, keyed by its path without ".html".
local function pages(folder)
  local found = {}
  for path, kind in vim.fs.dir(folder, { depth = 10 }) do
    local key = kind == "file" and path:match("^(.*)%.html$")
    if key and not not_documentation[key] and not is_redirect(read_file(folder .. "/" .. path)) then
      found[key] = folder .. "/" .. path
    end
  end
  return found
end

--- ExDoc links one stylesheet per language: html-elixir-<hash>.css.
local function exdoc_language(files)
  for _, file in pairs(files) do
    local language = read_file(file):match("html%-(%l+)%-%w+%.css")
    if language then
      return (language:gsub("^%l", string.upper))
    end
  end
  -- ExDoc documented only Elixir before it learnt Erlang
  return "Elixir"
end

-- The downloaded tarball of each install, kept between its index and db calls,
-- and the language each docset turned out to be written in.
local downloaded = {}
local languages = {}

local function download(docset, system)
  local name, version = split_docset(docset)
  local url = tarballs .. name .. "-" .. version .. ".tar.gz"
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local tarball = dir .. ".tar.gz"
  if system({ "curl", "-sfL", "-A", user_agent, "-o", tarball, url }).code ~= 0 then
    error("no documentation on hexdocs.pm for " .. name .. " " .. version, 0)
  end
  if system({ "tar", "-xzf", tarball, "-C", dir }).code ~= 0 then
    error("could not unpack " .. url, 0)
  end
  os.remove(tarball)
  -- Gleam's tarballs store their top-level files with no permissions at all
  system({ "chmod", "-R", "u+rwX", dir })
  local items, language = read_index(dir)
  local files = pages(dir)
  languages[docset] = language or exdoc_language(files)
  return { folder = dir, items = items, pages = files, name = name, version = version }
end

local function held(docset, system)
  downloaded[docset] = downloaded[docset] or download(docset, system)
  return downloaded[docset]
end

--- A page's <title> without the package ExDoc appends ("API Reference — jason
--- v1.4.4" is "API Reference").
local function page_title(file)
  local title = read_file(file):match("<title>%s*(.-)%s*</title>")
  title = title and title:gsub("%s+—.*$", "")
  return title ~= "" and title or nil
end

function M.index(docset, _, system)
  local docs = held(docset, system)
  local entries, listed = {}, {}
  for _, item in ipairs(docs.items) do
    local page, anchor = tostring(item.ref):match("^(.-)%.html(.*)$")
    if page and docs.pages[page] and type(item.title) == "string" then
      entries[#entries + 1] = {
        name = item.title,
        path = page .. anchor,
        type = kinds[item.type] or tostring(item.type):gsub("^%l", string.upper),
      }
      listed[page .. anchor] = true
    end
  end
  -- A page no index lists (ExDoc leaves out its API reference) is an entry
  -- all the same: the installer can only follow a link to a page it can name.
  local unlisted = vim.tbl_filter(function(key)
    return not listed[key]
  end, vim.tbl_keys(docs.pages))
  table.sort(unlisted)
  for _, key in ipairs(unlisted) do
    entries[#entries + 1] = { name = page_title(docs.pages[key]) or key, path = key, type = "Guides" }
  end
  return { entries = entries }
end

--- The language a docset is written in, known once it has been downloaded.
---@param docset string
---@return string?
function M.language_of(docset)
  return languages[docset]
end

--- The part of a page that is documentation: ExDoc's content column, or the
--- <main> of Gleam's pages, without the search bar, sidebar and footer.
local function main_content(html)
  local start = html:find('<div id="top%-content"')
    or html:find('<div id="content"')
    or html:find('<div class="content%-inner"')
    or html:find("<main")
  local body = start and html:sub(start) or html
  local stop = body:find("<footer") or body:find("</main>")
  return stop and body:sub(1, stop - 1) or body
end

local function clean_page(html)
  local body = main_content(html)
    :gsub("<script.-</script>", "")
    :gsub("<button.-</button>", "")
    :gsub("<svg.-</svg>", "")
    -- the link icons beside every heading and signature, and the source links
    :gsub(
      '<a[^>]-class="[^"]-hover%-link[^"]-"[^>]*>.-</a>',
      ""
    )
    :gsub('<a[^>]-class="detail%-link"[^>]*>.-</a>', "")
    :gsub('<a[^>]-class="[^"]-icon%-action[^"]-"[^>]*>.-</a>', "")
    :gsub('<a class="member%-source".-</a>', "")
    :gsub("<i [^>]*></i>", "")
    :gsub('<span class="sr%-only">.-</span>', "")
  -- A detail's id sits on its container, whose content begins with a header
  -- block: move it onto the signature, and drop the empty alias ids (a
  -- function's other arities) that nothing lists.
  body = body:gsub('(<%a+ class="detail") id="([^"]*)"(>.-<%w+)(%s[^>]-class="signature")', '%1%3 id="%2"%4')
  body = body:gsub('<span id="[^"]*"></span>', "")
  -- a heading that is a link to itself (Gleam) is just its text
  body = body:gsub('(<h%d[^>]*>)%s*<a href="#[^"]*">(.-)</a>', "%1%2")
  return body
end

function M.db(docset, _, system)
  local docs = held(docset, system)
  downloaded[docset] = nil
  local known = {}
  for key in pairs(docs.pages) do
    known[key] = true
  end
  local db = {}
  for key, file in pairs(docs.pages) do
    db[key] = links.rewrite_html(clean_page(read_file(file)), {
      dir = key:match("^(.*)/[^/]*$") or "",
      known = known,
      base = site .. docs.name .. "/" .. docs.version .. "/",
    })
  end
  vim.fn.delete(docs.folder, "rf")
  return db
end

return M
