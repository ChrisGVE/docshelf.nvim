-- The Sphinx source adapter (any documentation site built with Sphinx).
--
-- Sphinx is not a registry: it is the tool behind thousands of separate sites
-- (numpy.org/doc/stable, docs.python.org/3, a project's own Read the Docs
-- page), each one standing alone. There is nothing to search, so a docset is
-- named by giving its documentation URL, and everything else is read from the
-- one file every Sphinx site publishes: objects.inv, its inventory.
--
-- The inventory is four plain header lines and then a zlib stream of one line
-- per documented item, "name domain:role priority uri dispname". It names the
-- project and its version, so a row can read "numpy~2.5 · 2671 pages" before
-- anything is downloaded -- which matters here more than for any other source,
-- because a Sphinx site offers no archive: the pages come one HTTP request at
-- a time, and numpy's are 2671 of them.
--
-- The site a docset came from is remembered in ".sphinx_sites.json" beside the
-- installed docsets, since the folder name (numpy~2.5~~sphinx) cannot carry a
-- URL. That file is what lets an installed docset be installed again later.
local M = {}

local fetching = require("docshelf.fetch")
local links = require("docshelf.links")

M.origin = "sphinx"

-- Sphinx's default domain is Python and most Sphinx sites are Python
-- projects, so this is what a docset falls back to. It is only a fallback:
-- `language_of` reads the language the site's own inventory shows, and the
-- installer prefers that.
M.language = "Python"

local sites_file = ".sphinx_sites.json"

local function data_folder()
  return require("docshelf.common").data_folder()
end

--- The remembered sites, { [docset] = { url = ..., language = ... } }.
function M.sites_path()
  return data_folder() .. sites_file
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
  vim.fn.mkdir(data_folder(), "p")
  pcall(vim.fn.writefile, { vim.json.encode(sites) }, M.sites_path())
end

--- The site a docset was installed from, or nil.
---@param docset string
function M.site(docset)
  local site = read_sites()[docset]
  return type(site) == "table" and site or nil
end

local function site_or_error(docset)
  local site = M.site(docset)
  if not site or type(site.url) ~= "string" then
    error(
      "docshelf does not know which site "
        .. docset
        .. " came from;"
        .. " install it again by typing its documentation URL in the install picker",
      0
    )
  end
  return site
end

-- ---------------------------------------------------------------- inventory

--- A documentation URL with one trailing slash, and objects.inv dropped from
--- the end if that is what was given.
local function base_url(url)
  url = vim.trim(url):gsub("[?#].*$", "")
  url = url:gsub("objects%.inv$", "")
  return (url:gsub("/*$", "")) .. "/"
end

--- Looks like a documentation URL, so the install picker should ask about it
--- rather than search a registry for it.
---@param text string
function M.is_url(text)
  return text:match("^https?://[^%s]+$") ~= nil
end

local function fetch(url, out, system)
  return system({ "curl", "-sfL", "--max-time", "60", "-o", out, url }).code == 0
end

--- Inflate a raw zlib stream. Neovim has no zlib of its own and macOS ships
--- LibreSSL, whose openssl has no `zlib` command, so this uses python3 when
--- there is one and gzip otherwise: a zlib stream is a gzip stream with a
--- different two-byte header, so prepending a gzip header and dropping those
--- two bytes is enough. gzip then reports a CRC error on the adler32 checksum
--- that follows, having already written every byte -- so the output is what
--- decides here, not the exit code.
---@param payload string the compressed bytes
---@param system fun(cmd: string[], opts?: table): vim.SystemCompleted
---@return string
local function inflate(payload, system)
  local path = vim.fn.tempname()
  local file = assert(io.open(path, "wb"))
  file:write(payload)
  file:close()
  if vim.fn.executable("python3") == 1 then
    local res = system({
      "python3",
      "-c",
      'import sys, zlib; sys.stdout.buffer.write(zlib.decompress(open(sys.argv[1], "rb").read()))',
      path,
    }, { text = true })
    if res.code == 0 and res.stdout ~= "" then
      return res.stdout
    end
  end
  local gzip = vim.fn.tempname()
  local header = "\\x1f\\x8b\\x08\\x00\\x00\\x00\\x00\\x00\\x00\\x03"
  local res = system({
    "sh",
    "-c",
    "{ printf '"
      .. header
      .. "'; tail -c +3 "
      .. vim.fn.shellescape(path)
      .. "; } > "
      .. vim.fn.shellescape(gzip)
      .. "; gzip -dc "
      .. vim.fn.shellescape(gzip),
  }, { text = true })
  if res.stdout == nil or res.stdout == "" then
    error("could not read the inventory: neither python3 nor gzip could decompress it", 0)
  end
  return res.stdout
end

-- Sphinx's own inventory line: the name may hold spaces ("C order"), so it is
-- read non-greedily and everything after it is anchored to the fields that
-- cannot. See sphinx.util.inventory, which uses this exact shape.
local function parse_line(line)
  local name, role, priority, uri, dispname = line:match("^(.-)%s+(%S+)%s+(%-?%d+)%s*(%S*)%s+(.*)$")
  if not name or name == "" then
    return nil
  end
  return { name = name, role = role, priority = priority, uri = uri, dispname = dispname }
end

-- What each domain role is called in the reading list. A role that is not here
-- is offered under its own name, so a domain docshelf has never seen still
-- shows up.
local role_labels = {
  ["std:doc"] = "Pages",
  ["std:label"] = "Sections",
  ["std:term"] = "Glossary",
  ["std:option"] = "Options",
  ["std:envvar"] = "Environment Variables",
  ["py:module"] = "Modules",
  ["py:class"] = "Classes",
  ["py:exception"] = "Exceptions",
  ["py:function"] = "Functions",
  ["py:method"] = "Methods",
  ["py:attribute"] = "Attributes",
  ["py:property"] = "Properties",
  ["py:data"] = "Data",
  ["c:function"] = "C Functions",
  ["c:macro"] = "C Macros",
  ["c:type"] = "C Types",
  ["c:struct"] = "C Structs",
  ["c:member"] = "C Members",
  ["c:var"] = "C Variables",
  ["c:enum"] = "C Enums",
  ["c:enumerator"] = "C Enumerators",
  ["cpp:class"] = "C++ Classes",
  ["cpp:function"] = "C++ Functions",
  ["cpp:type"] = "C++ Types",
  ["js:function"] = "JavaScript Functions",
  ["js:class"] = "JavaScript Classes",
  ["js:method"] = "JavaScript Methods",
  ["js:attribute"] = "JavaScript Attributes",
}

-- A C function's parameters are listed in the inventory one entry each. They
-- document nothing on their own -- the function's page already shows them --
-- and on a C-heavy site they outnumber everything else, so they are not
-- entries. (numpy: 1166 of 8274.)
local not_an_entry = { ["c:functionParam"] = true }

-- The domain an inventory is mostly written in, and the language that means.
-- Sphinx's roles carry it: a site whose entries are mostly "c:" documents C,
-- whatever the language its examples are written in.
--
-- The "std" domain is not in the vote and must not be: it is every page, every
-- section label and every glossary term, so on a documentation-heavy site it
-- outnumbers the API it describes (numpy: 3343 std against 2535 py and 2369 c)
-- and every site would come out as no language at all.
local domain_languages = { py = "Python", c = "C", cpp = "C++", js = "JavaScript" }

--- A page key (what the installer stores a page under) and the address it is
--- fetched from. Sphinx's html builder writes "guide/intro.html"; its dirhtml
--- builder writes "guide/intro/".
local function page_of(uri)
  local page = uri:gsub("#.*$", "")
  if page == "" then
    return nil
  end
  local key = page:gsub("%.html$", ""):gsub("/$", "")
  if key == "" then
    key = "index"
  end
  return key, page
end

--- Read an inventory into the docset it describes, its entries and its pages.
---@param body string the inflated inventory
---@param header table { project = ..., version = ... }
local function read_inventory(body, header)
  local entries, pages, order, domains, anchors = {}, {}, {}, {}, {}
  for line in vim.gsplit(body, "\n", { plain = true }) do
    if vim.trim(line) ~= "" then
      local item = parse_line(line)
      if item and not not_an_entry[item.role] then
        local key, fetch_path = page_of(item.uri)
        if key then
          if not pages[key] then
            pages[key] = fetch_path
            order[#order + 1] = key
          end
          local anchor = item.uri:match("#(.*)$")
          if anchor then
            anchor = anchor:gsub("%$", item.name)
          end
          local shown = (item.dispname ~= "-" and item.dispname ~= "") and item.dispname or item.name
          if anchor then
            anchors[key] = anchors[key] or {}
            anchors[key][anchor] = shown
          end
          local domain = item.role:match("^([^:]+)")
          domains[domain] = (domains[domain] or 0) + 1
          entries[#entries + 1] = {
            name = shown,
            path = anchor and (key .. "#" .. anchor) or key,
            type = role_labels[item.role] or item.role,
          }
        end
      end
    end
  end
  local top, best = nil, 0
  for domain, count in pairs(domains) do
    if domain_languages[domain] and count > best then
      top, best = domain, count
    end
  end
  table.sort(order)
  return {
    project = header.project,
    version = header.version,
    entries = entries,
    pages = pages,
    order = order,
    anchors = anchors,
    language = domain_languages[top],
  }
end

--- Fetch and read a site's inventory.
---@param url string a documentation URL, already normalised by base_url
---@param system fun(cmd: string[], opts?: table): vim.SystemCompleted
local function inventory(url, system)
  local path = vim.fn.tempname()
  if not fetch(url .. "objects.inv", path, system) then
    error("no Sphinx inventory at " .. url .. "objects.inv", 0)
  end
  local file = assert(io.open(path, "rb"))
  local raw = file:read("*a")
  file:close()
  if not raw:match("^# Sphinx inventory version 2") then
    error(url .. "objects.inv is not a version 2 Sphinx inventory", 0)
  end
  local header, offset = {}, 1
  for _ = 1, 4 do
    local stop = raw:find("\n", offset, true)
    if not stop then
      error(url .. "objects.inv stops inside its header", 0)
    end
    local line = raw:sub(offset, stop - 1)
    local key, value = line:match("^#%s*(%a+):%s*(.*)$")
    if key then
      header[key:lower()] = vim.trim(value)
    end
    offset = stop + 1
  end
  if not header.project or header.project == "" then
    error(url .. "objects.inv names no project", 0)
  end
  return read_inventory(inflate(raw:sub(offset), system), header)
end

--- The docset a project and version name: "numpy~2.5", or "numpy" where the
--- site publishes no version. The project name is the site's own, lowercased
--- and with anything a folder name cannot carry turned into "_".
local function docset_name(project, version)
  local name = project:lower():gsub("[^%w%.%-_]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  if name == "" then
    name = "docs"
  end
  if version and version ~= "" then
    return name .. "~" .. (version:gsub("[^%w%.%-_]+", "_"))
  end
  return name
end

-- The inventory of the last probe or install, kept between the index and db
-- calls of one install so the site is asked for it once.
local read = {}

-- ------------------------------------------------------------- the contract

--- The docset a documentation URL offers. One request -- the inventory -- so
--- the row shown before the pick already knows the project, its version and
--- how many pages the install will fetch.
---@param url string
---@param system fun(cmd: string[], opts?: table): vim.SystemCompleted
---@return { name: string, version?: string, pages: integer, url: string }[]
function M.from_url(url, system)
  if not M.is_url(url) then
    return {}
  end
  local base = base_url(url)
  local inv = inventory(base, system)
  local docset = docset_name(inv.project, inv.version)
  read[docset] = { base = base, inventory = inv }
  remember_site(docset, { url = base, language = inv.language })
  local name, version = docset:match("^(.-)~([^~]*)$")
  return {
    {
      name = name or docset,
      version = version,
      pages = #inv.order,
      url = base,
    },
  }
end

--- The release a docset holds: the version its own site published, which the
--- docset is named for.
---@param docset string
function M.release(docset)
  local _, version = docset:match("^(.-)~([^~]*)$")
  return version
end

--- The docset the site offers today. The site a docset came from is
--- remembered, so its inventory is read again and named the same way an
--- install names it: a project that has published 2.6 since gives numpy~2.6
--- where numpy~2.5 is installed. The new name is remembered against the same
--- site, which is what lets it be installed.
---@param docset string
---@param system fun(cmd: string[], opts?: table): vim.SystemCompleted
---@return string? docset nil when the site a docset came from is not known
function M.latest(docset, system)
  local site = M.site(docset)
  if not site or type(site.url) ~= "string" then
    return nil
  end
  local inv = inventory(site.url, system)
  local name = docset_name(inv.project, inv.version)
  read[name] = { base = site.url, inventory = inv }
  remember_site(name, { url = site.url, language = inv.language })
  return name
end

--- The language the site's inventory shows it documents, which is better than
--- this adapter's fallback: a Sphinx site can document C or JavaScript just as
--- well as Python.
---@param docset string
function M.language_of(docset)
  local site = M.site(docset)
  return site and site.language or nil
end

local function loaded(docset, system)
  if read[docset] then
    return read[docset]
  end
  local site = site_or_error(docset)
  local base = base_url(site.url)
  local held = { base = base, inventory = inventory(base, system) }
  read[docset] = held
  return held
end

function M.index(docset, _, system)
  local held = loaded(docset, system)
  return { entries = held.inventory.entries }
end

-- ------------------------------------------------------------ fetching pages

--- Fetch `keys` into `dir` through `docshelf.fetch`, reporting as each batch
--- lands. Returns the file each page was written to.
local function fetch_pages(held, keys, dir, system, report)
  local requests = {}
  for _, key in ipairs(keys) do
    requests[#requests + 1] = { key = key, url = held.base .. held.inventory.pages[key] }
  end
  return fetching.pages(requests, dir, system, report)
end

-- ---------------------------------------------------------- cleaning a page

-- Where a Sphinx theme keeps the page itself, best first. The themes differ
-- (pydata writes <article class="bd-article">, furo <article role="main">,
-- the classic and Read the Docs themes <div class="body" role="main">), so
-- this is a ladder rather than one selector, ending at <body> so that a theme
-- nobody has seen still installs.
local containers = {
  { tag = "div", pattern = '<div[^>]*itemprop="articleBody"[^>]*>' },
  { tag = "article", pattern = '<article[^>]*role="main"[^>]*>' },
  { tag = "article", pattern = '<article[^>]*class="[^"]*bd%-article[^"]*"[^>]*>' },
  { tag = "div", pattern = '<div[^>]*class="body"[^>]*role="main"[^>]*>' },
  { tag = "div", pattern = '<div[^>]*class="[^"]*document[^"]*"[^>]*>' },
  { tag = "main", pattern = "<main[^>]*>" },
  { tag = "body", pattern = "<body[^>]*>" },
}

--- The text from `open_at` to the tag's own closing tag, counting the ones
--- nested inside it so that an inner <div> does not end an outer one.
local function balanced(html, tag, open_at, after_open)
  local depth, at = 1, after_open
  local open_pattern = "<" .. tag .. "[%s>]"
  local close_pattern = "</" .. tag .. ">"
  while depth > 0 do
    local next_open = html:find(open_pattern, at)
    local next_close = html:find(close_pattern, at)
    if not next_close then
      return html:sub(open_at)
    end
    if next_open and next_open < next_close then
      depth = depth + 1
      at = next_open + 1
    else
      depth = depth - 1
      at = next_close + #close_pattern
    end
  end
  return html:sub(open_at, at - 1)
end

local function main_content(html)
  for _, container in ipairs(containers) do
    local open_at, after_open = html:find(container.pattern)
    if open_at then
      return balanced(html, container.tag, open_at, after_open + 1)
    end
  end
  return html
end

--- Sphinx hangs a documented item's id on the <dt> that carries its
--- signature: <dt class="sig" id="attrs.field"><span>…</span>…</dt>. The
--- installer finds the text an id names by looking at what follows the tag
--- holding it, and after such a <dt> comes another tag, never text -- so
--- every link to an item resolved to the top of its page instead of to the
--- item (measured on attrs: 683 of 870 links).
---
--- The name is already known, from the inventory, so the id moves onto a
--- heading of its own carrying it, and the signature keeps everything else,
--- including the links inside it. The page reads better for it: the item's
--- name becomes a heading rather than part of a run-on signature.
local function name_the_anchors(html, names)
  if not names then
    return html
  end
  -- A module marker, or a label written before a section rather than on it, is
  -- an empty <span> carrying only the id. Nothing follows it either, so the
  -- same treatment applies: the inventory's display name becomes the heading
  -- the link lands on.
  html = html:gsub('<span%s+id="([^"]*)"%s*></span>', function(id)
    if not names[id] then
      return nil
    end
    return '<h4 id="' .. id .. '">' .. names[id] .. "</h4>"
  end)
  return (
    html:gsub("<dt([^>]*)>", function(attributes)
      local id = attributes:match('id="([^"]*)"')
      if not id or not names[id] then
        return nil
      end
      local rest = attributes:gsub('%s*id="[^"]*"', "")
      return '<h4 id="' .. id .. '">' .. names[id] .. "</h4><dt" .. rest .. ">"
    end)
  )
end

--- `served` is the path the page was fetched from: a dirhtml page
--- ("guide/intro/") writes its links against its own folder.
local function clean_page(html, key, base, known, names, served)
  local body = name_the_anchors(main_content(html), names)
  body = body
    :gsub("<script.-</script>", "")
    :gsub("<style.-</style>", "")
    -- The "¶" a Sphinx theme puts beside every heading is a link to the
    -- heading itself: noise in a buffer, and one more link to resolve.
    :gsub(
      '<a class="headerlink"[^>]*>.-</a>',
      ""
    )
    :gsub('<a[^>]*class="headerlink"[^>]*>.-</a>', "")
  -- A link to another page of this docset becomes that page's key; anything
  -- else -- the theme's static files and images, a genindex, another site --
  -- becomes an address back on the site.
  return links.rewrite_html(body, {
    dir = key:match("^(.*)/[^/]*$") or "",
    from = served and served:match("/$") and served or nil,
    known = known,
    base = base,
  })
end

function M.db(docset, _, system, report)
  local held = loaded(docset, system)
  read[docset] = nil
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local files = fetch_pages(held, held.inventory.order, dir, system, report)
  local known = {}
  for key in pairs(files) do
    known[key] = true
  end
  local db = {}
  for key, path in pairs(files) do
    local file = io.open(path, "r")
    if file then
      local html = file:read("*a")
      file:close()
      db[key] = clean_page(html, key, held.base, known, held.inventory.anchors[key], held.inventory.pages[key])
    end
  end
  return db
end

-- Exposed for the specs: the pieces above are what the install depends on, and
-- they are worth pinning on their own.
M._internal = {
  base_url = base_url,
  parse_line = parse_line,
  read_inventory = read_inventory,
  docset_name = docset_name,
  main_content = main_content,
  name_the_anchors = name_the_anchors,
  clean_page = clean_page,
  page_of = page_of,
}

return M
