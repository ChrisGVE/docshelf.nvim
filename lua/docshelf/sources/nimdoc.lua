-- The nimdoc source adapter (Nim packages, and any site `nim doc` built).
--
-- Nim's packages are listed in nim-lang/packages' packages.json, but their
-- documentation lives wherever each package deploys it. What there is, is
-- nearly always built by `nim doc --project --index:on` and pushed to the
-- repository's GitHub Pages, so it answers at
-- https://<owner>.github.io/<repo>/; a package may also declare its own
-- address as "doc". Measured 2026-09-26 over the 2,948 listed packages: 351
-- sites answer one way or the other (340 at the GitHub Pages address, 45 by
-- the declared one), among them pixie, jsony, zippy, mummy, cligen, npeg,
-- regex and arraymancer. Nim's own standard library is on devdocs already.
--
-- Every nimdoc site publishes, beside its pages (measured on pixie, built by
-- Nim 2.2 in 2026, and argparse, built in 2023):
--   * theindex.html  a "Modules:" line linking every module page, every
--                    symbol with the page and id it lives at, and the day it
--                    was generated ("Generated: 2026-09-13 16:47:14 UTC");
--   * a page per module ("pixie/paints.html"), its symbols grouped in
--                    sections named for their kind ("Types", "Procs",
--                    "Templates"), each symbol a <div id> whose id holds its
--                    signature ("colorStop,Color,float32"). Only the pages
--                    name the kind on both generations: the index of 2023
--                    does not.
-- The sites name no version of the package, so a docset is named for the day
-- its site was generated.
--
-- This adapter turns that into the index/db pair the installer expects (see
-- sources/devdocs.lua):
--   * a search over the names in the package list (one request, kept for the
--     session); a pick is resolved to the package's site by the addresses
--     above;
--   * any nimdoc site by its URL, whatever page of it was typed;
--   * a docset "<package>~<day>" (pixie~2026-09-13), the site it came from
--     remembered in ".nimdoc_sites.json" beside the installed docsets;
--   * a page per module, keyed by its path without ".html" ("pixie/paints");
--     entries: every module page and every symbol, typed by its section.
local anchors = require("docshelf.anchors")
local fetching = require("docshelf.fetch")
local html_text = require("docshelf.html")
local links = require("docshelf.links")

local M = {}

M.origin = "nimdoc"

M.language = "Nim"

local registry = "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json"

local user_agent = "docshelf.nvim (https://github.com/ChrisGVE/docshelf.nvim)"

-- --------------------------------------------------------- remembered sites

local sites_file = ".nimdoc_sites.json"

--- Where the remembered sites are kept, { [docset] = { url = ..., name = ... } }.
function M.sites_path()
  return require("docshelf.common").data_folder() .. sites_file
end

local function read_sites()
  local path = M.sites_path()
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  local ok, sites = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
  end)
  return (ok and type(sites) == "table") and sites or {}
end

local function remember_site(docset, site)
  local sites = read_sites()
  sites[docset] = site
  vim.fn.mkdir(vim.fn.fnamemodify(M.sites_path(), ":h"), "p")
  pcall(vim.fn.writefile, { vim.json.encode(sites) }, M.sites_path())
end

--- The site a docset was installed from, or nil.
---@param docset string
function M.site(docset)
  local site = read_sites()[docset]
  return (type(site) == "table" and type(site.url) == "string") and site or nil
end

-- ------------------------------------------------------------ the package list

-- The listed packages by name, fetched once per session: a search runs at
-- every keystroke.
local catalogue

-- The site of the last probe or install, kept between the index and db calls
-- of one install so its pages are fetched once.
local read = {}

--- Forget the fetched package list and any site read (for the specs).
function M.reset()
  catalogue = nil
  read = {}
end

local function curl(url, system, extra)
  local cmd = { "curl", "-sfL", "--max-time", "60", "-A", user_agent }
  vim.list_extend(cmd, extra or {})
  cmd[#cmd + 1] = url
  return system(cmd)
end

local function packages(system)
  if not catalogue then
    local res = curl(registry, system)
    if res.code ~= 0 then
      error("could not fetch Nim's package list (curl exit " .. tostring(res.code) .. ")", 0)
    end
    local ok, list = pcall(vim.json.decode, res.stdout or "")
    if not (ok and type(list) == "table") then
      error("Nim's package list is not the JSON list it should be", 0)
    end
    local found = {}
    for _, package in ipairs(list) do
      if type(package) == "table" and type(package.name) == "string" then
        found[package.name] = package
      end
    end
    if next(found) == nil then
      error("Nim's package list holds no packages", 0)
    end
    catalogue = found
  end
  return catalogue
end

--- The listed packages whose name holds `query`, whatever the case; an
--- alias is listed too, and resolved to the package it names. The version is
--- left for `resolve`: it is read from the package's own site.
---@param query string
---@param system fun(cmd: string[]): vim.SystemCompleted
---@return { name: string }[]
function M.search(query, system)
  local needle = query:lower()
  local names = {}
  for name in pairs(packages(system)) do
    if name:lower():find(needle, 1, true) then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return vim.tbl_map(function(name)
    return { name = name }
  end, names)
end

-- ------------------------------------------------------------ reading a site

--- `href` resolved against the address `url`, as a browser would.
local function absolute(url, href)
  if href:match("^%a[%w+.-]*://") then
    return href
  end
  local root, path = url:match("^(%a[%w+.-]*://[^/]+)(.*)$")
  local dir = href:match("^/") and "" or path:gsub("[^/]*$", "")
  return root .. "/" .. links.resolve(dir, href)
end

local function is_local(href)
  return href ~= "" and not href:match("^%a[%w+.-]*:") and not href:match("^/")
end

--- The pages a site's theindex.html names: every module on its "Modules:"
--- line, and every page a symbol lives on. Keys are paths without ".html".
local function read_index(body)
  local pages, order = {}, {}
  local function add(href)
    local path = href:gsub("#.*$", "")
    if is_local(path) and path:match("%.html$") and path ~= "theindex.html" then
      local key = path:gsub("%.html$", "")
      if not pages[key] then
        pages[key] = path
        order[#order + 1] = key
      end
    end
  end
  local modules = body:match("Modules:(.-)<br") or ""
  for href in modules:gmatch('href="([^"]*)"') do
    add(href)
  end
  for href in body:gmatch('data%-doc%-search%-tag="[^"]*"%s*href="([^"]*)"') do
    add(href)
  end
  table.sort(order)
  return {
    version = body:match("Generated: (%d%d%d%d%-%d%d%-%d%d)"),
    pages = pages,
    order = order,
  }
end

--- Read the nimdoc site holding the page at `url`: its root, the day it was
--- generated and the pages its index names.
---@return { base: string, version?: string, pages: table<string, string>, order: string[] }
local function read_site(url, system)
  local res = curl(url, system, { "-w", "\n%{url_effective}" })
  if res.code ~= 0 then
    error("could not fetch " .. url, 0)
  end
  local page, landed = (res.stdout or ""):match("^(.*)\n([^\n]*)$")
  landed = (landed and landed ~= "") and landed or url
  if not (page and (page:find("nimdoc.out.css", 1, true) or page:find("dochack.js", 1, true))) then
    error(url .. " is not a page of a nimdoc site", 0)
  end
  local index_url, index = landed, page
  if not landed:match("theindex%.html$") then
    -- every page links the index in its sidebar ("../theindex.html")
    local href = page:match('<div id="global%-links">.-href="([^"]*theindex%.html)"')
    if not href then
      error(url .. " links to no index of its site", 0)
    end
    index_url = absolute(landed, href)
    local found = curl(index_url, system)
    if found.code ~= 0 then
      error("no index at " .. index_url, 0)
    end
    index = found.stdout or ""
  end
  local site = read_index(index)
  if #site.order == 0 then
    error(index_url .. " names no pages", 0)
  end
  site.base = index_url:gsub("theindex%.html$", "")
  return site
end

--- A name a folder can carry: anything else is "_".
local function folder_name(name)
  return (name:gsub("[^%w%.%-_]+", "_"))
end

local function docset_name(name, version)
  if version then
    return folder_name(name) .. "~" .. version
  end
  return folder_name(name)
end

--- The project a site documents: its top module, the one page at the root
--- whose name heads the others ("pixie" of "pixie/paints"); failing that,
--- the folder the site is served from, less a "nim-" or ".nim" around it.
local function project_of(site)
  local top
  for _, key in ipairs(site.order) do
    if not key:find("/", 1, true) then
      if
        site.pages[key]
        and vim.iter(site.order):any(function(other)
          return vim.startswith(other, key .. "/")
        end)
      then
        return key
      end
      top = top == nil and key or false
    end
  end
  if top then
    return top
  end
  local folder = site.base:match("([^/]+)/$") or ""
  folder = folder:gsub("^nim%-", ""):gsub("%-nim$", ""):gsub("%.nim$", "")
  return folder ~= "" and folder or nil
end

--- The docset for a listed package's documentation, read from its site: at
--- the address it declares, else where GitHub Pages serves its repository.
---@param name string
---@param system fun(cmd: string[]): vim.SystemCompleted
---@return string docset e.g. "pixie~2026-09-13"
function M.resolve(name, system)
  local package = packages(system)[name]
  if not package then
    error("Nim's package list has no package " .. name, 0)
  end
  if type(package.alias) == "string" then
    name = package.alias
    package = packages(system)[name]
    if not package then
      error("Nim's package list has no package " .. name, 0)
    end
  end
  local addresses = {}
  if type(package.doc) == "string" and package.doc:match("^https?://") then
    addresses[#addresses + 1] = package.doc
  end
  local owner, repo = (package.url or ""):match("^https?://github%.com/([^/]+)/([^/#?]+)")
  if owner then
    addresses[#addresses + 1] = "https://"
      .. owner:lower()
      .. ".github.io/"
      .. repo:gsub("%.git$", "")
      .. "/theindex.html"
  end
  for _, address in ipairs(addresses) do
    local ok, site = pcall(read_site, address, system)
    if ok then
      local docset = docset_name(name, site.version)
      remember_site(docset, { url = site.base, name = name })
      return docset
    end
  end
  error("no nimdoc site found for " .. name .. ": type its documentation URL instead", 0)
end

--- The docset a documentation URL offers: one row, which already knows how
--- many pages the install will fetch.
---@param url string
---@param system fun(cmd: string[]): vim.SystemCompleted
---@return { name: string, version?: string, pages: integer, url: string }[]
function M.from_url(url, system)
  url = vim.trim(url)
  if not url:match("^https?://[^%s]+$") then
    return {}
  end
  local site = read_site((url:gsub("[?#].*$", "")), system)
  local project = project_of(site)
  if not project then
    error(url .. " names no project", 0)
  end
  remember_site(docset_name(project, site.version), { url = site.base, name = project })
  return { { name = project, version = site.version, pages = #site.order, url = site.base } }
end

--- The release a docset holds: the day its site was generated, which the
--- docset is named for.
---@param docset string e.g. "pixie~2026-09-13"
function M.release(docset)
  return docset:match("~([^~]+)$")
end

--- The docset the site offers today: its day read again, named the way an
--- install names it.
---@param docset string
---@param system fun(cmd: string[]): vim.SystemCompleted
---@return string? docset nil when the site a docset came from is not known
function M.latest(docset, system)
  local known = M.site(docset)
  if not known then
    return nil
  end
  local site = read_site(known.url .. "theindex.html", system)
  local name = known.name or docset:gsub("~[^~]*$", "")
  local latest = docset_name(name, site.version)
  remember_site(latest, { url = site.base, name = name })
  return latest
end

-- ------------------------------------------------------------ the entries

-- The sections of a module page whose symbols are entries, named as the
-- pickers show them; "Imports" and "Exports" only link other modules.
local kinds = {
  Types = true,
  Vars = true,
  Lets = true,
  Consts = true,
  Procs = true,
  Funcs = true,
  Methods = true,
  Iterators = true,
  Converters = true,
  Macros = true,
  Templates = true,
}

--- Every symbol of a module page, with the kind of the section it is in.
---@return { id: string, kind: string }[]
local function symbols(html)
  local starts = {}
  for start in html:gmatch('()<div class="section" id="%d+">') do
    starts[#starts + 1] = start
  end
  local found = {}
  for i, start in ipairs(starts) do
    local section = html:sub(start, (starts[i + 1] or #html + 1) - 1)
    local kind = section:match('<h1><a class="toc%-backref"[^>]*>(.-)</a></h1>')
    if kind and kinds[kind] then
      -- a symbol is a <div id> (a site built in 2021 wrote an empty <a id>
      -- before it instead), and nimdoc groups a name's overloads in a
      -- "<name>-procs-all" <div> of their own
      for _, pattern in ipairs({ '<div id="([^"]+)">', '<a id="([^"]+)"></a>' }) do
        for id in section:gmatch(pattern) do
          if not id:match("%-%l+%-all$") then
            found[#found + 1] = { id = id, kind = kind }
          end
        end
      end
    end
  end
  return found
end

--- `params` without the constraints of their generic types, as Nim's own
--- index writes them: "seq[T: int or float]" is "seq[T]".
local function without_constraints(params)
  local out, depth, skipping = {}, 0, nil
  for char in params:gmatch(".") do
    if char == "[" then
      depth = depth + 1
    elseif char == "]" then
      depth = depth - 1
    end
    if skipping then
      -- the constraint ends with its brackets, or at the next parameter
      if depth < skipping or (depth == skipping and char == ",") then
        skipping = nil
        out[#out + 1] = char
      end
    elseif char == ":" and depth > 0 then
      skipping = depth
    else
      out[#out + 1] = char
    end
  end
  return table.concat(out)
end

--- A symbol's name in the pickers, from its id: the module, the name and the
--- parameter types ("paints.colorStop(Color, float32)"). nimdoc marks a
--- template, converter, macro or iterator apart from a proc of the same
--- signature by a letter after its name ("[].t", "parseSomePaint.c"): the
--- name is shown without it.
local function symbol_name(module, id)
  local text = html_text.decode_entities(id)
  local name, params = text:match("^([^,]*)(.*)$")
  name = name:gsub("(.)%.%l$", "%1")
  local signature = params ~= "" and "(" .. without_constraints(params:sub(2)):gsub(",", ", ") .. ")" or ""
  return module .. "." .. name .. signature
end

-- The longest plain id kept whole.
local longest_id = 57

--- A symbol's id as plain text (anchors.hex_id), short enough to name a
--- file by. nimdoc spells a generic's constraint into the id
--- ("applyOpacity,seq[T: int or int8 or ...]"), so an id can run to hundreds
--- of bytes once plain, and the installer names each entry's file after it: a
--- long one keeps its start and ends in a hash of the whole, the same for the
--- symbol and for every link to it.
local function plain(id)
  local text = anchors.hex_id(id)
  if #text <= longest_id then
    return text
  end
  return text:sub(1, longest_id - 9) .. "-" .. vim.fn.sha256(text):sub(1, 8)
end

--- A site's pages, fetched, with the entries they hold.
local function read_package(docset, system, report)
  local known = M.site(docset)
  if not known then
    error(
      "docshelf does not know which site "
        .. docset
        .. " came from; install it again by typing its documentation URL in the install picker",
      0
    )
  end
  local site = read_site(known.url .. "theindex.html", system)
  local requests = {}
  for _, key in ipairs(site.order) do
    requests[#requests + 1] = { key = key, url = site.base .. site.pages[key] }
  end
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local fetched = fetching.pages(requests, dir, system, report)
  local held = {}
  for key, path in pairs(fetched) do
    local handle = assert(io.open(path, "r"))
    held[key] = handle:read("*a")
    handle:close()
  end
  vim.fn.delete(dir, "rf")

  -- only a page the site served has entries: one it did not would open nothing
  local entries, names = {}, {}
  for _, key in ipairs(site.order) do
    if held[key] then
      names[key] = {}
      -- every page is an entry: the installer finds where a link to
      -- "pixie/paints#x" goes through the entry of its page
      entries[#entries + 1] = { name = key, path = key, type = "Modules" }
      local module = key:match("[^/]+$")
      for _, symbol in ipairs(symbols(held[key])) do
        local id = plain(symbol.id)
        local name = symbol_name(module, symbol.id)
        names[key][id] = names[key][id] or name
        entries[#entries + 1] = { name = name, path = key .. "#" .. id, type = symbol.kind }
      end
    end
  end
  return { base = site.base, pages = held, names = names, entries = entries }
end

function M.index(docset, _, system, report)
  read[docset] = read_package(docset, system, report)
  return { entries = read[docset].entries }
end

-- ------------------------------------------------------------ the pages

--- The page itself: nimdoc's content column, up to the footer that follows
--- it (the sidebar before it holds the theme switch, the search box and the
--- table of contents).
local function main_content(html)
  local start = html:find('id="content"', 1, true)
  if not start then
    return html:match("<body[^>]*>(.*)</body>") or html
  end
  start = html:find(">", start, true) + 1
  local stop = html:find('<div class="twelve-columns footer"', start, true)
  return html:sub(start, stop and stop - 1 or -1)
end

local function clean_page(key, html, names)
  local body = main_content(html)
    :gsub("<script.-</script>", "")
    :gsub("<style.-</style>", "")
    :gsub('<div id="tocRoot"></div>', "")
    -- the "Source" and "Edit" links on GitHub beside every symbol, with the
    -- spaces nimdoc writes after each
    :gsub(
      '<a%s[^>]-class="link%-seesrc"[^>]*>.-</a>[&nbsp;]*',
      ""
    )
    -- the "..." a browser shows in place of the hidden pragmas, which a site
    -- built in 2021 wraps in braces of its own
    :gsub(
      '<span><span class="Other">{</span><span class="Other pragmadots">%.%.%.</span><span class="Other">}</span></span>',
      ""
    )
    :gsub(
      '<span class="Other pragmadots">%.%.%.</span>',
      ""
    )
    -- a section's heading links to itself
    :gsub('<h1><a class="toc%-backref"[^>]*>(.-)</a></h1>', "<h2>%1</h2>")
  return "<h1>" .. key .. "</h1>" .. anchors.name_the_anchors(body, names, plain)
end

function M.db(docset, _, system, report)
  local site = read[docset] or read_package(docset, system, report)
  read[docset] = nil
  local known = {}
  for key in pairs(site.pages) do
    known[key] = true
  end
  local db = {}
  for key, html in pairs(site.pages) do
    -- links are rewritten before their anchors are made plain: an anchor on
    -- another site keeps the spelling that site gave it
    db[key] = anchors.plain_fragments(
      links.rewrite_html(clean_page(key, html, site.names[key]), {
        dir = key:match("^(.*)/[^/]*$") or "",
        known = known,
        base = site.base,
      }),
      plain
    )
  end
  return db
end

-- Exposed for the specs.
M._internal = { symbol_name = symbol_name, project_of = project_of, read_index = read_index }

return M
