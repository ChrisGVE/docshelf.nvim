-- The ocaml.org source adapter (opam packages, documented by odoc).
--
-- ocaml.org builds every opam package's odoc documentation and serves it as
-- pages (measured 2026-09-26, lwt 6.1.2):
--   * packages/search?q=<query>          an HTML list of packages, best match
--                                        first, each row with its version and,
--                                        when ocaml.org has built them, a link
--                                        to its documentation;
--   * p/<pkg>/latest/doc/index.html      the newest documentation; its <head>
--                                        already names the version
--                                        (/p/lwt/6.1.2/doc/), so 4 KB are read;
--   * p/<pkg>/<v>/search-index/<any>     odoc's own index, as JavaScript: every
--                                        module, type, value, constructor, …
--                                        with its prefix, kind and address (the
--                                        last segment only busts caches);
--   * one page per module, module type, class and extra file, its
--     documentation in <div class="odoc …">, framed by the site's sidebars.
-- robots.txt allows every agent but a few named crawlers.
--
-- This adapter turns that into the index/db pair the installer expects (see
-- sources/devdocs.lua):
--   * a docset is "<pkg>~<version>" (lwt~6.1.2);
--   * a page per address the index names outside src/ (the source listings),
--     keyed by its path without "/index.html" or ".html" (lwt/Lwt/Infix; the
--     package's own page is "index");
--   * entries: everything the index names, as odoc names it ("Lwt.bind",
--     "Lwt.state.Return"), and each page;
--   * links to a page of the docset name it; any other link is an address on
--     ocaml.org -- including odoc's links to other packages, which climb out
--     of this one ("../../../../../../u/<hash>/ocaml-compiler/…").
--
-- odoc's ids hold OCaml's operators ("val-(>>=)", written "val-(&gt;&gt;=)"
-- in the page) and a constructor's type ("type-state.Return"). Every id is
-- made plain by `anchors.hex_id`, as for gemdocs.org.
local anchors = require("docshelf.anchors")
local fetching = require("docshelf.fetch")
local links = require("docshelf.links")

local M = {}

M.origin = "ocaml.org"

M.language = "OCaml"

local host = "https://ocaml.org/"

local user_agent = "docshelf.nvim (https://github.com/ChrisGVE/docshelf.nvim)"

local function curl(url, system, extra)
  local cmd = { "curl", "-sfL", "-A", user_agent }
  vim.list_extend(cmd, extra or {})
  cmd[#cmd + 1] = url
  return system(cmd)
end

--- The packages ocaml.org finds for `query`, in its own order (best match
--- first), leaving out those it has no documentation for.
---@param query string
---@param system fun(cmd: string[]): vim.SystemCompleted
---@return { name: string, version?: string }[]
function M.search(query, system)
  local res = curl(host .. "packages/search?q=" .. vim.uri_encode(query, "rfc2396"), system)
  if res.code ~= 0 then
    error("could not search ocaml.org (curl exit " .. tostring(res.code) .. ")", 0)
  end
  local rows = {}
  local results = res.stdout:match("<ol.*") or ""
  for row in results:gmatch("<li(.-)</li>") do
    local name = row:match('href="/p/([^/"]+)/latest"')
    if name and row:find("/latest/doc/index.html", 1, true) then
      -- the version is the first plain <div> of the row's details
      local details = row:match("gap%-x%-6(.*)$") or ""
      rows[#rows + 1] = { name = name, version = details:match("<div>%s*([^<%s]+)%s*</div>") }
    end
  end
  return rows
end

--- The docset for the newest version of `name` ocaml.org documents: the head
--- of its latest documentation page names it.
---@param name string
---@param system fun(cmd: string[]): vim.SystemCompleted
---@return string docset e.g. "lwt~6.1.2"
function M.resolve(name, system)
  local url = host .. "p/" .. vim.uri_encode(name, "rfc2396") .. "/latest/doc/index.html"
  local res = curl(url, system, { "-r", "0-4095" })
  local prefix = "/p/" .. name .. "/"
  local version
  local at = res.code == 0 and 1 or nil
  while at do
    local start = res.stdout:find(prefix, at, true)
    if not start then
      break
    end
    local candidate = res.stdout:sub(start + #prefix):match('^([^/"]+)/doc/')
    if candidate and candidate ~= "latest" then
      version = candidate
      break
    end
    at = start + 1
  end
  if not version then
    error("ocaml.org has no documentation for " .. name, 0)
  end
  return name .. "~" .. version
end

local function split_docset(docset)
  local package, version = docset:match("^(.+)~([%w%.%-_+]+)$")
  if not package then
    error("an ocaml.org docset is <package>~<version>, got " .. docset, 0)
  end
  return package, version
end

--- The release a docset holds: it is named for the exact version it came from.
---@param docset string e.g. "lwt~6.1.2"
function M.release(docset)
  local _, version = split_docset(docset)
  return version
end

--- The docset ocaml.org offers for this package today; comparing it with the
--- docset's own name is how an update is noticed.
---@param docset string
---@param system fun(cmd: string[]): vim.SystemCompleted
function M.latest(docset, system)
  return M.resolve((split_docset(docset)), system)
end

-- ------------------------------------------------------------ the index

local plain_id = anchors.hex_id

-- What odoc calls an item, in the pickers' words.
local kinds = {
  module = "Modules",
  module_type = "Module Types",
  class = "Classes",
  class_type = "Class Types",
  type = "Types",
  value = "Values",
  exception = "Exceptions",
  constructor = "Constructors",
  field = "Fields",
  method = "Methods",
  extension = "Extensions",
}

--- A page's key from its path inside the documentation folder.
local function page_key(path)
  if path == "index.html" then
    return "index"
  end
  return (path:gsub("/index%.html$", ""):gsub("%.html$", ""))
end

--- odoc's index is JavaScript: `let documents = [ … ];` and then the script
--- that searches it. The list ends at the line after it -- a comment's own
--- line breaks are written "\u000A", so a raw one only ends a statement.
local function documents(script)
  local open = script:find("[", 1, true)
  local stop = script:find("\nconst ", 1, true) or #script
  local close
  for at = stop, open or 1, -1 do
    if script:sub(at, at) == "]" then
      close = at
      break
    end
  end
  local ok, list = pcall(vim.json.decode, open and close and script:sub(open, close) or "")
  if not ok or not vim.islist(list) then
    error("ocaml.org answered with a search index docshelf cannot read", 0)
  end
  return list
end

-- What each install read in index, kept for its db call.
local read = {}

local function read_package(docset, system, report)
  local package, version = split_docset(docset)
  local site = "p/" .. package .. "/" .. version .. "/doc/"
  local res = curl(host .. "p/" .. package .. "/" .. version .. "/search-index/docshelf", system)
  if res.code ~= 0 then
    error("ocaml.org has no documentation for " .. package .. " " .. version, 0)
  end

  -- the path each page is served at, by key, in the index's order
  local entries, paths, names, order = {}, {}, {}, {}
  local function add_page(key, path)
    if not paths[key] then
      paths[key] = path
      names[key] = {}
      order[#order + 1] = key
    end
  end
  local has_entry = {}
  for _, item in ipairs(documents(res.stdout)) do
    local url = type(item) == "table" and type(item.url) == "string" and item.url or ""
    local path, anchor = url:match("^/" .. vim.pesc(site) .. "([^#]*)#?(.*)$")
    if path and not path:match("^src/") and path:match("%.html$") then
      local key = page_key(path)
      add_page(key, path)
      local name = item.name or ""
      if item.prefixname and item.prefixname ~= "" then
        name = item.prefixname .. "." .. name
      end
      if item.kind == "page" then
        -- the package's own page, a library's list of modules, or an extra
        -- file ("lwt README")
        local library = path:match("^([^/]+)/index%.html$")
        if key == "index" then
          entries[#entries + 1] = { name = package, path = key, type = "Guides" }
        elseif library then
          entries[#entries + 1] = { name = "Library " .. library, path = key, type = "Libraries" }
        else
          entries[#entries + 1] = { name = package .. " " .. key, path = key, type = "Guides" }
        end
        has_entry[key] = true
      elseif kinds[item.kind] then
        if anchor == "" then
          entries[#entries + 1] = { name = name, path = key, type = kinds[item.kind] }
          has_entry[key] = true
        else
          local id = plain_id(anchor)
          names[key][id] = names[key][id] or name
          entries[#entries + 1] = { name = name, path = key .. "#" .. id, type = kinds[item.kind] }
        end
      end
    end
  end
  -- every page is an entry: the installer finds where a link to
  -- "page#anchor" goes through the entry of its page
  for _, key in ipairs(order) do
    if not has_entry[key] then
      entries[#entries + 1] = { name = package .. " " .. key, path = key, type = "Guides" }
    end
  end

  local requests = {}
  for _, key in ipairs(order) do
    requests[#requests + 1] = { key = key, url = host .. site .. paths[key] }
  end
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local fetched = fetching.pages(requests, dir, system, report)
  local held = {}
  for key, file in pairs(fetched) do
    local handle = assert(io.open(file, "r"))
    held[key] = handle:read("*a")
    handle:close()
  end
  vim.fn.delete(dir, "rf")

  -- an entry on a page ocaml.org did not serve would open nothing
  entries = vim.tbl_filter(function(entry)
    return held[entry.path:match("^[^#]+")] ~= nil
  end, entries)
  return { site = site, paths = paths, pages = held, names = names, entries = entries }
end

function M.index(docset, _, system, report)
  read[docset] = read_package(docset, system, report)
  return { entries = read[docset].entries }
end

-- ------------------------------------------------------------ the pages

--- The documentation of a page, without the site's sidebars and scripts.
local function main_content(html)
  local start = html:find('<div class="odoc', 1, true)
  local body = start and html:sub(start) or html
  local stop = body:find("<script", 1, true) or body:find("<footer", 1, true)
  return stop and body:sub(1, stop - 1) or body
end

local function clean_page(html)
  return (
    main_content(html)
      -- a link to the item's source listing, beside every item
      :gsub(
        '<a href="[^"]*" class="source_link">Source</a>',
        ""
      )
      -- the empty link odoc puts before each id, for the site's hover icon
      :gsub(
        '<a href="[^"]*" class="anchor"></a>',
        ""
      )
  )
end

function M.db(docset, _, system, report)
  local package = read[docset] or read_package(docset, system, report)
  read[docset] = nil
  local known = {}
  for key in pairs(package.pages) do
    known[key] = true
  end
  -- A page's links are read against its place on the site, so that odoc's
  -- links to other packages, which climb out of this one, land on
  -- ocaml.org; a link inside the package comes back to its key.
  local function key_of(resolved)
    if resolved:sub(1, #package.site) == package.site then
      return page_key(resolved:sub(#package.site + 1))
    end
    return resolved
  end
  local db = {}
  for key, html in pairs(package.pages) do
    local body = links.rewrite_html(clean_page(html), {
      dir = key:match("^(.*)/[^/]*$") or "",
      from = package.site .. (package.paths[key]:match("^(.*/)") or ""),
      known = known,
      base = host,
      key_of = key_of,
    })
    db[key] = anchors.plain_fragments(anchors.name_the_anchors(body, package.names[key], plain_id), plain_id)
  end
  return db
end

M._internal = { plain_id = plain_id, page_key = page_key }

return M
