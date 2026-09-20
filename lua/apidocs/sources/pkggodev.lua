-- The pkg.go.dev source adapter (Go packages).
--
-- pkg.go.dev has no archive to download and no search we may ask: its
-- robots.txt disallows /search?*, so a name typed in the install picker is not
-- something this source can answer. What it does have is one HTML page per
-- package, served under the package's own import path, and that page carries
-- everything an install needs: the version it documents, every symbol it
-- documents (each anchor is tagged with its Go kind), and the subpackages
-- underneath it. So a docset is named the way a Sphinx one is -- by pasting
-- the documentation URL, which here is the pkg.go.dev address of the package.
--
-- A docset is the package that address names plus every package below it,
-- internal ones excepted: those cannot be imported from outside the module,
-- and pkg.go.dev itself hides them behind a toggle. One page is one HTTP
-- request, as with Sphinx, so the row shown before the pick says how many.
--
-- The import path a docset came from is remembered in ".pkggodev_packages.json"
-- beside the installed docsets: the folder name (example.com_widget~1.2.3)
-- cannot carry a path, and without it an installed docset could not be
-- installed again.
local M = {}

M.origin = "pkg.go.dev"

M.language = "Go"

local base = "https://pkg.go.dev"

local packages_file = ".pkggodev_packages.json"

local function data_folder()
  return require("apidocs.common").data_folder()
end

--- The remembered packages, { [docset] = { path = ..., version = ... } }.
function M.packages_path()
  return data_folder() .. packages_file
end

local function read_packages()
  local path = M.packages_path()
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  local ok, known = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
  end)
  return (ok and type(known) == "table") and known or {}
end

local function remember(docset, entry)
  local known = read_packages()
  known[docset] = entry
  vim.fn.mkdir(data_folder(), "p")
  pcall(vim.fn.writefile, { vim.json.encode(known) }, M.packages_path())
end

--- The package a docset was installed from, or nil.
---@param docset string
function M.package(docset)
  local entry = read_packages()[docset]
  return type(entry) == "table" and entry or nil
end

-- ------------------------------------------------------------------ fetching

local function fetch(url, system)
  local res = system({ "curl", "-sfL", "--max-time", "60", url })
  if res.code ~= 0 then
    error("pkg.go.dev did not answer " .. url .. " (curl exit " .. tostring(res.code) .. ")", 0)
  end
  return res.stdout
end

--- Looks like a pkg.go.dev address, so the install picker should ask this
--- source about it rather than search a registry for the text.
---@param text string
function M.is_url(text)
  return vim.trim(text):match("^https?://pkg%.go%.dev/[^%s]+$") ~= nil
end

-- ------------------------------------------------------------- reading a page

--- The import path an address or an href names, with the "@version" a
--- pkg.go.dev link carries taken off: "/example.com/widget@v1.2.3/render" is
--- the package "example.com/widget/render".
local function import_path(path)
  return (path:gsub("^/", ""):gsub("@[^/]*", ""):gsub("[?#].*$", ""):gsub("/+$", ""))
end

--- What a package page says about itself: the package it documents, the
--- version, and the packages listed under Directories. Only the subpackages
--- are read from the table, so a page fetched for its symbols costs nothing
--- extra.
local function read_page(html)
  local canonical = html:match('data%-canonical%-url%-path="([^"]*)"')
  local version = html:match('data%-version="([^"]*)"')
  local module = html:match('data%-modulepath="([^"]*)"')
  if not canonical or canonical == "" then
    error("that pkg.go.dev page does not name a package", 0)
  end
  local path = import_path(canonical)
  local subs = {}
  local directories = html:match('<div class="UnitDirectories.-</table>')
  if directories then
    for href in directories:gmatch('<a href="(/[^"]*)"') do
      local sub = import_path(href)
      -- Only what lies under this package, and never an internal package:
      -- those cannot be imported from outside their module.
      local under = sub:sub(1, #path + 1) == path .. "/"
      if under and not (sub .. "/"):find("/internal/") then
        subs[#subs + 1] = { path = sub, href = href }
      end
    end
  end
  table.sort(subs, function(a, b)
    return a.path < b.path
  end)
  return { path = path, version = version, module = module or path, href = canonical, subs = subs }
end

--- Where pkg.go.dev serves a package. The "@version" is never reconstructed:
--- it does not sit in one place. A module's own package carries it on the
--- module path (/github.com/spf13/cobra@v1.10.2/doc), the standard library
--- carries it on the package path (/net/http/cgi@go1.27.1), and the version
--- the page reports is not always the one the address uses -- net/http says
--- "v1.27.1" and is served at "@go1.27.1". So every address here is one the
--- site itself wrote: the canonical path of the page, or a link out of its
--- own Directories table.
local function address_of(href)
  return base .. href
end

--- The docset an import path and a version name: the path with everything a
--- folder name cannot carry turned into "_", and the version without Go's
--- leading "v". The whole path is kept because only the whole path is unique
--- -- a dozen modules have a package called "server".
local function docset_name(path, version)
  local name = path:gsub("[^%w%.%-_]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  local release = (version or ""):gsub("^v", ""):gsub("[^%w%.%-_]+", "_")
  if release == "" then
    return name
  end
  return name .. "~" .. release
end

--- The page key a package gets inside the docset: the root package is named
--- for its last path element, and everything below it hangs off that -- so
--- "example.com/widget" is "widget" and its "render" is "widget/render".
local function page_key(root, path)
  local stem = root:match("([^/]+)$") or root
  if path == root then
    return stem
  end
  return stem .. "/" .. path:sub(#root + 2)
end

-- What the probe and the install have read, kept between the from_url, index
-- and db calls of one install so a page is asked for once.
local read = {}

local function docset_state(docset, system)
  local state = read[docset]
  if state then
    return state
  end
  local entry = M.package(docset)
  if not entry or type(entry.path) ~= "string" then
    error(
      "apidocs does not know which package " .. docset .. " came from;"
        .. " install it again by typing its pkg.go.dev address in the install picker",
      0
    )
  end
  local html = fetch(address_of(entry.href or ("/" .. entry.path)), system)
  local page = read_page(html)
  state = {
    root = page.path,
    version = page.version,
    href = page.href,
    subs = page.subs,
    html = { [page.path] = html },
  }
  read[docset] = state
  return state
end

-- -------------------------------------------------------------- the contract

--- The docset a pkg.go.dev address offers. One request -- the package's own
--- page -- so the row shown before the pick already knows the package, its
--- version, and how many pages the install will fetch.
---@param url string
---@param system fun(cmd: string[], opts?: table): vim.SystemCompleted
---@return { name: string, version?: string, pages: integer, url: string }[]
function M.from_url(url, system)
  if not M.is_url(url) then
    return {}
  end
  local address = vim.trim(url):gsub("[?#].*$", ""):gsub("/+$", "")
  local html = fetch(address, system)
  local page = read_page(html)
  local docset = docset_name(page.path, page.version)
  read[docset] = {
    root = page.path,
    version = page.version,
    href = page.href,
    subs = page.subs,
    html = { [page.path] = html },
  }
  remember(docset, { path = page.path, version = page.version, href = page.href })
  return {
    {
      name = page.path,
      version = page.version and page.version:gsub("^v", "") or nil,
      pages = #page.subs + 1,
      url = address_of(page.href),
    },
  }
end

--- The docset pkg.go.dev offers today for the package a docset came from. The
--- package is remembered, so its page is read again and named the way an
--- install names it: a module that has tagged v1.10.0 since gives
--- ...cobra~1.10.0 where ...cobra~1.9.1 is installed. The new name is
--- remembered against the same package, which is what lets it be installed.
---@param docset string
---@param system fun(cmd: string[], opts?: table): vim.SystemCompleted
---@return string? docset nil when the package a docset came from is not known
function M.latest(docset, system)
  local entry = M.package(docset)
  if not entry or type(entry.path) ~= "string" then
    return nil
  end
  local html = fetch(address_of(entry.href or ("/" .. entry.path)), system)
  local page = read_page(html)
  local name = docset_name(page.path, page.version)
  read[name] = {
    root = page.path,
    version = page.version,
    href = page.href,
    subs = page.subs,
    html = { [page.path] = html },
  }
  remember(name, { path = page.path, version = page.version, href = page.href })
  return name
end

--- The release a docset holds: the version its page named, which the docset is
--- named for.
---@param docset string
function M.release(docset)
  local _, version = docset:match("^(.-)~([^~]*)$")
  return version
end

--- The language a docset documents. Every package here is Go, so this never
--- has to look anything up.
---@param _docset string
function M.language_of(_docset)
  return M.language
end

-- The Go kinds pkg.go.dev tags an anchor with, and what the installer should
-- call them. A kind not named here is still offered, under its own name.
local kinds = {
  constant = "Constants",
  variable = "Variables",
  ["function"] = "Functions",
  type = "Types",
  method = "Methods",
  field = "Fields",
}

--- Every package of the docset, in install order: the root first, then its
--- subpackages, each as { path = <import path>, key = <page key> }.
local function package_list(state)
  local list = { { path = state.root, key = page_key(state.root, state.root), href = state.href } }
  for _, sub in ipairs(state.subs) do
    list[#list + 1] = { path = sub.path, key = page_key(state.root, sub.path), href = sub.href }
  end
  return list
end

local function page_html(state, package, system)
  if not state.html[package.path] then
    state.html[package.path] = fetch(address_of(package.href), system)
  end
  return state.html[package.path]
end

--- The documentation of a page, without the site around it: everything pkg.go.dev
--- wraps a package in -- the header, the search box, the footer, the scripts --
--- lies outside <div class="Documentation-content">, and the Directories table
--- that follows is kept because it is how a reader walks into a subpackage.
---
--- Three things inside it go as well. The page's own Index section lists every
--- symbol on the page, which is what the picker already is, and each install
--- splits a page per symbol anyway -- so it would be repeated into every one of
--- them. The "go to" pilcrows link a heading to itself, and a split page has no
--- headings left to go to: they are the whole of what dangles otherwise. And
--- the source link wraps the symbol's own name, so it is unwrapped rather than
--- dropped, leaving the name readable.
local function documentation(html)
  local start = html:find('<div class="Documentation%-content')
  local body = start and html:sub(start) or html
  body = body:match("^(.-)</article>") or body
  body = body
    :gsub("<script.-</script>", "")
    :gsub('<section class="Documentation%-index".-</section>', "")
    :gsub('<a class="[%w%-]*idLink"[^>]*>.-</a>', "")
    :gsub('<a class="Documentation%-source"[^>]*>(.-)</a>', "%1")
    -- pkg.go.dev puts its "jump to" search form inside the article; a form is
    -- never documentation, and its options are site paths of their own.
    :gsub("<form.-</form>", "")
  return body
end

--- The symbols a page documents. pkg.go.dev tags every documented anchor with
--- the Go kind it is, which is what makes this source cheap to index: the
--- page is its own index.
local function symbols(html)
  local found = {}
  for id, kind in documentation(html):gmatch('id="([^"]+)"[^>]-data%-kind="([^"]+)"') do
    found[#found + 1] = { id = id, type = kinds[kind] or kind }
  end
  return found
end

function M.index(docset, _, system)
  local state = docset_state(docset, system)
  local entries = {}
  for _, package in ipairs(package_list(state)) do
    local html = page_html(state, package, system)
    -- The package itself is a page, so it is an entry of its own, named by the
    -- import path a reader would write.
    entries[#entries + 1] = { name = package.path, path = package.key, type = "Packages" }
    local short = package.path:match("([^/]+)$")
    for _, symbol in ipairs(symbols(html)) do
      entries[#entries + 1] = {
        name = short .. "." .. symbol.id,
        path = package.key .. "#" .. symbol.id,
        type = symbol.type,
      }
    end
  end
  return { entries = entries }
end

--- `path` written from the directory `dir`, going up no further than it has
--- to. A page key here is both a page and a directory -- "widget" holds
--- "widget/render" -- so the target's own directory is what `dir` is compared
--- against, and a link from widget/render back to widget is "../widget".
local function relative_to(dir, path)
  local from = vim.split(dir, "/", { trimempty = true })
  local to = vim.split(path, "/", { trimempty = true })
  local shared = 0
  while from[shared + 1] and to[shared + 1] and shared + 1 < #to and from[shared + 1] == to[shared + 1] do
    shared = shared + 1
  end
  local out = {}
  for _ = shared + 1, #from do
    out[#out + 1] = ".."
  end
  for i = shared + 1, #to do
    out[#out + 1] = to[i]
  end
  return table.concat(out, "/")
end

--- Where a link should point once the page is a buffer. A link to another
--- package of this docset becomes that package's page; every other
--- site-relative link -- the standard library, another module, pkg.go.dev's
--- own pages -- becomes an address on pkg.go.dev, and an address elsewhere is
--- left alone.
local function rewrite_href(href, dir, keys, page_href)
  if href:match("^%a[%w+.-]*:") or href:match("^#") or href == "" then
    return href
  end
  if href:sub(1, 1) == "?" then
    -- Another view of this same page ("?tab=versions"), written the short way.
    -- Relative to a file on disk it is a file that does not exist.
    return base .. (page_href or ""):gsub("[?#].*$", "") .. href
  end
  if href:sub(1, 1) ~= "/" then
    return href
  end
  local target, anchor = href:match("^([^#]*)(#?.*)$")
  -- "?tab=versions", "?tab=imports": the same package, but a page of the site
  -- rather than a page of the documentation. It is an address, not a docset
  -- page -- taking the query off would point it at the docs it is not.
  local key = not target:find("?", 1, true) and keys[import_path(target)] or nil
  if key then
    return relative_to(dir, key) .. anchor
  end
  return base .. href
end

function M.db(docset, _, system)
  local state = docset_state(docset, system)
  local list = package_list(state)
  local keys = {}
  for _, package in ipairs(list) do
    keys[package.path] = package.key
  end
  local db = {}
  for _, package in ipairs(list) do
    local html = documentation(page_html(state, package, system))
    local dir = package.key:match("^(.*)/[^/]*$") or ""
    local function rewrite(attribute)
      return function(value)
        return " " .. attribute .. '="' .. rewrite_href(value, dir, keys, package.href) .. '"'
      end
    end
    -- src as well as href: an <img> left site-relative is a link to nowhere
    -- once the page is a file on disk.
    db[package.key] = (
      html:gsub(' ?href="([^"]*)"', rewrite("href")):gsub(' ?src="([^"]*)"', rewrite("src"))
    )
  end
  read[docset] = nil
  return db
end

M._internal = {
  read_page = read_page,
  docset_name = docset_name,
  page_key = page_key,
  relative_to = relative_to,
}

return M
