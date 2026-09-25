-- The pkg.odin-lang.org source adapter (Odin's standard library and vendor
-- bindings).
--
-- Odin has no package manager, so there is no registry to search: the site
-- documents one fixed catalogue, the collections that ship with the compiler.
-- Two files say everything (measured 2026-09-25):
--   * /pkg-data.js, the site's own search data (4.8 MB): every package with
--     its collection (base, core, vendor), its path ("/core/fmt") and its
--     declarations, each with a kind. Its first line names the Odin version
--     it was generated with ("dev-2026-09"), and the server answers a range
--     request, so the version costs a few hundred bytes. It is JavaScript
--     rather than JSON: trailing commas, and line breaks inside comments.
--   * one HTML page per package at /<path>/, a declaration being an
--     <h3 id="<name>">.
--
-- A docset per package would be 236 installs, so a docset is a collection
-- group instead:
--   * "odin~<version>"        base and core, the standard library -- named
--                             for the language, so it is Odin's reference;
--   * "odin_vendor~<version>" the vendor bindings (raylib, sdl, vulkan...).
-- The site only ever documents the newest build, so an install always holds
-- today's version, and its name says which one that was.
--
-- This adapter turns that into the index/db pair the installer expects (see
-- sources/devdocs.lua): a package is an entry named by its import path
-- ("encoding/json"), each declaration one qualified by it
-- ("encoding/json.marshal"); pages keep the documentation only, and links
-- between packages of the docset become page keys, every other link an
-- address on the site.
local fetching = require("docshelf.fetch")
local links = require("docshelf.links")

local M = {}

M.origin = "pkg.odin-lang.org"

M.language = "Odin"

local site = "https://pkg.odin-lang.org/"
local catalogue_url = site .. "pkg-data.js"

local user_agent = "docshelf.nvim (https://github.com/ChrisGVE/docshelf.nvim)"

-- The docsets this source offers, and the collections each one holds.
local groups = {
  odin = { base = true, core = true },
  odin_vendor = { vendor = true },
}
local group_names = { "odin", "odin_vendor" }

-- What a declaration's kind is called in the pickers.
local kinds = {
  b = "Builtins",
  c = "Constants",
  g = "Procedure Groups",
  p = "Procedures",
  t = "Types",
  v = "Variables",
}

--- The docsets whose name holds `query`, ignoring case. The list is fixed, so
--- this makes no request; the version is read when a row is picked.
---@param query string
---@return { name: string }[]
function M.search(query, _)
  local rows = {}
  for _, name in ipairs(group_names) do
    if name:find(query:lower(), 1, true) then
      rows[#rows + 1] = { name = name }
    end
  end
  return rows
end

--- The Odin version the site documents today, from the catalogue's first line.
local function current_version(system)
  local res = system({ "curl", "-sfL", "-A", user_agent, "-r", "0-511", catalogue_url }, { text = true })
  local version = res.code == 0 and (res.stdout or ""):match("Generated with odin version (%S+)")
  if not version then
    error("pkg.odin-lang.org did not say which Odin version it documents", 0)
  end
  return version
end

--- The docset to install for `name`: that group at today's version.
---@param name string
---@param system fun(cmd: string[], opts?: table): vim.SystemCompleted
---@return string docset e.g. "odin~dev-2026-09"
function M.resolve(name, system)
  if not groups[name] then
    error("pkg.odin-lang.org has no docset " .. name .. " (it offers " .. table.concat(group_names, " and ") .. ")", 0)
  end
  return name .. "~" .. current_version(system)
end

local function split_docset(docset)
  local name, version = docset:match("^(.+)~([%w%.%-]+)$")
  if not (name and groups[name]) then
    error("a pkg.odin-lang.org docset is odin~<version> or odin_vendor~<version>, got " .. docset, 0)
  end
  return name, version
end

--- The release a docset holds: it is named for the version it came from.
---@param docset string e.g. "odin~dev-2026-09"
function M.release(docset)
  local _, version = split_docset(docset)
  return version
end

--- The docset the site offers for this group today; comparing it with the
--- docset's own name is how an update is noticed.
---@param docset string
---@param system fun(cmd: string[], opts?: table): vim.SystemCompleted
function M.latest(docset, system)
  return M.resolve((split_docset(docset)), system)
end

-- -------------------------------------------------------- the catalogue

local json_escapes = { ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

--- The catalogue's JavaScript object as JSON: a comma before a closing
--- bracket is dropped, and a line break inside a string is escaped. Strings
--- are walked quote to quote, so their text is never touched otherwise.
local function to_json(text)
  local out, at, in_string = {}, 1, false
  while true do
    local next_at = text:find(in_string and '[\\"\n\r\t]' or '[",]', at)
    if not next_at then
      out[#out + 1] = text:sub(at)
      return table.concat(out)
    end
    out[#out + 1] = text:sub(at, next_at - 1)
    local char = text:sub(next_at, next_at)
    if char == '"' then
      in_string = not in_string
      out[#out + 1] = char
      at = next_at + 1
    elseif char == "\\" then
      -- an escape is copied whole, so an escaped quote does not end the string
      out[#out + 1] = text:sub(next_at, next_at + 1)
      at = next_at + 2
    elseif char == "," then
      if not text:find("^%s*[}%]]", next_at + 1) then
        out[#out + 1] = char
      end
      at = next_at + 1
    else
      out[#out + 1] = json_escapes[char]
      at = next_at + 1
    end
  end
end

--- The packages of the catalogue, each { key, name, entities }: its key is its
--- path without the leading "/" ("core/encoding/json"), its name the import
--- path inside its collection ("encoding/json").
local function read_catalogue(system)
  local res = system({ "curl", "-sfL", "-A", user_agent, catalogue_url }, { text = true })
  if res.code ~= 0 then
    error("could not fetch " .. catalogue_url .. " (curl exit " .. tostring(res.code) .. ")", 0)
  end
  local object = (res.stdout or ""):match("var%s+odin_pkg_data%s*=%s*(.*)$")
  local ok, data = pcall(vim.json.decode, to_json((object or ""):gsub(";%s*$", "")))
  if not (ok and type(data) == "table" and type(data.packages) == "table") then
    error(catalogue_url .. " is not the catalogue this adapter knows how to read", 0)
  end
  local packages = {}
  for _, package in pairs(data.packages) do
    if type(package.path) == "string" and type(package.collection) == "string" then
      local key = package.path:gsub("^/", ""):gsub("/$", "")
      packages[#packages + 1] = {
        key = key,
        collection = package.collection,
        name = key:gsub("^[^/]+/", ""),
        entities = type(package.entities) == "table" and package.entities or {},
      }
    end
  end
  table.sort(packages, function(a, b)
    return a.key < b.key
  end)
  return packages
end

-- The catalogue of each install, kept between its index and db calls.
local read = {}

local function packages_of(docset, system)
  if not read[docset] then
    local name = split_docset(docset)
    read[docset] = vim.tbl_filter(function(package)
      return groups[name][package.collection] == true
    end, read_catalogue(system))
  end
  return read[docset]
end

function M.index(docset, _, system)
  local entries = {}
  for _, package in ipairs(packages_of(docset, system)) do
    entries[#entries + 1] = { name = package.name, path = package.key, type = "Packages" }
    for _, entity in ipairs(package.entities) do
      if type(entity.name) == "string" then
        entries[#entries + 1] = {
          name = package.name .. "." .. entity.name,
          path = package.key .. "#" .. entity.name,
          type = kinds[entity.kind] or "Declarations",
        }
      end
    end
  end
  return { entries = entries }
end

-- ------------------------------------------------------------ the pages

--- The documentation of a package page: from its overview to its list of
--- source files, without the navigation, sidebar and table of contents.
local function main_content(html)
  local start = html:find('<div id="pkg%-top"') or html:find("<article") or 1
  local body = html:sub(start)
  local stop = body:find('<h2 id="pkg%-source%-files"') or body:find("</article>")
  return stop and body:sub(1, stop - 1) or body
end

local function clean_page(html)
  local body = main_content(html)
    :gsub("<script.-</script>", "")
    -- a declaration's heading holds a link to itself, a hidden "¶" and a
    -- link to its source: the heading is the name alone
    :gsub(
      '<div class="doc%-source">.-</div>',
      ""
    )
    :gsub('<span class="a%-hidden">.-</span>', "")
    :gsub('<a class="doc%-id%-link"[^>]*>(.-)</a>', "%1")
  body = body:gsub("(<h%d[^>]*>)%s*<span>(.-)</span>%s*(</h%d>)", "%1%2%3")
  -- collapsible blocks: the empty toggle goes, a label stays as a line
  body = body
    :gsub('<summary class="hideme">.-</summary>', "")
    :gsub("<summary[^>]*>(.-)</summary>", "<p>%1</p>")
    :gsub("</?details[^>]*>", "")
  return body
end

--- A link from the site's root ("/core/strings/#Builder") written relative to
--- the page holding it when it names a page of the docset; `links` sends any
--- other one to the site.
local function root_links_to_keys(html, dir, known)
  return (
    html:gsub('href="/([^"#]*)(#?[^"]*)"', function(path, anchor)
      local key = path:gsub("/$", "")
      if known[key] then
        return 'href="' .. links.relative(dir, key) .. anchor .. '"'
      end
      return nil
    end)
  )
end

function M.db(docset, _, system, report)
  local packages = packages_of(docset, system)
  read[docset] = nil
  local requests = {}
  for _, package in ipairs(packages) do
    requests[#requests + 1] = { key = package.key, url = site .. package.key .. "/" }
  end
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local files = fetching.pages(requests, dir, system, report)
  local known = {}
  for key in pairs(files) do
    known[key] = true
  end
  local db = {}
  for key, path in pairs(files) do
    local file = assert(io.open(path, "r"))
    local html = file:read("*a")
    file:close()
    local page_dir = key:match("^(.*)/[^/]*$") or ""
    db[key] = links.rewrite_html(root_links_to_keys(clean_page(html), page_dir, known), {
      dir = page_dir,
      known = known,
      base = site,
    })
  end
  vim.fn.delete(dir, "rf")
  return db
end

M._internal = { to_json = to_json }

return M
