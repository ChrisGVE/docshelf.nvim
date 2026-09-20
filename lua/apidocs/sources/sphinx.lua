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

M.origin = "sphinx"

-- Sphinx's default domain is Python and most Sphinx sites are Python
-- projects, so this is what a docset falls back to. It is only a fallback:
-- `language_of` reads the language the site's own inventory shows, and the
-- installer prefers that.
M.language = "Python"

local sites_file = ".sphinx_sites.json"

local function data_folder()
  return require("apidocs.common").data_folder()
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
      "apidocs does not know which site "
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
-- is offered under its own name, so a domain apidocs has never seen still
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
  local entries, pages, order, domains = {}, {}, {}, {}
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
          local domain = item.role:match("^([^:]+)")
          domains[domain] = (domains[domain] or 0) + 1
          entries[#entries + 1] = {
            name = (item.dispname ~= "-" and item.dispname ~= "") and item.dispname or item.name,
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

-- How many pages one curl call fetches. A Sphinx site has no archive, so the
-- pages come one request each; curl is asked for a batch at a time so that the
-- install can say how far along it is, and reuses one connection for all of
-- them.
local batch_size = 200

local function curl_parallel(system)
  local res = system({ "curl", "--help", "all" }, { text = true })
  return res.code == 0 and (res.stdout or ""):find("--parallel-max", 1, true) ~= nil
end

--- Fetch `keys` into `dir`, at most `sources.workers()` at once, reporting as
--- each batch lands. Returns the file each page was written to.
local function fetch_pages(held, keys, dir, system, report)
  local parallel = curl_parallel(system)
  local files, done = {}, 0
  for start = 1, #keys, batch_size do
    local config, batch = {}, {}
    for i = start, math.min(start + batch_size - 1, #keys) do
      local key = keys[i]
      local out = dir .. "/" .. key:gsub("/", "%%2F")
      batch[#batch + 1] = { key = key, out = out }
      config[#config + 1] = 'url = "' .. held.base .. held.inventory.pages[key] .. '"'
      config[#config + 1] = 'output = "' .. out .. '"'
    end
    local config_path = vim.fn.tempname()
    vim.fn.writefile(config, config_path)
    local cmd = { "curl", "-sfL", "--max-time", "120" }
    if parallel then
      -- required here, not at the top: sources/init.lua loads this adapter.
      local workers = require("apidocs.sources").workers()
      vim.list_extend(cmd, { "--parallel", "--parallel-max", tostring(workers) })
    end
    vim.list_extend(cmd, { "-K", config_path })
    -- A page that 404s is skipped, not fatal: an inventory can name a document
    -- the site no longer publishes, and one missing page is no reason to lose
    -- the other 2670.
    system(cmd)
    for _, page in ipairs(batch) do
      if vim.fn.filereadable(page.out) == 1 then
        files[page.key] = page.out
      end
    end
    done = math.min(done + batch_size, #keys)
    if report then
      report("fetching pages " .. done .. "/" .. #keys)
    end
  end
  return files
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

--- Resolve `href` against the directory of the page holding it, the way a
--- browser would.
local function resolve_path(dir, href)
  local segments = vim.split(dir, "/", { trimempty = true })
  for _, part in ipairs(vim.split(href, "/", { trimempty = true })) do
    if part == ".." then
      table.remove(segments)
    elseif part ~= "." then
      segments[#segments + 1] = part
    end
  end
  return table.concat(segments, "/")
end

--- `path` written from `dir`, climbing no further than it has to: the
--- installer reads a link against the page key of the page holding it, which
--- cannot climb above the docset.
local function relative_to(dir, path)
  local from = vim.split(dir, "/", { trimempty = true })
  local to = vim.split(path, "/", { trimempty = true })
  local shared = 0
  while from[shared + 1] and from[shared + 1] == to[shared + 1] do
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

--- Where a link should point once the page is a buffer. A link to another page
--- of this docset becomes that page's key; anything else -- the theme's static
--- files, a genindex, another site -- becomes an address back on the site.
local function rewrite_href(href, dir, base, known)
  if href:match("^%a[%w+.-]*:") or href:match("^#") or href == "" then
    return href
  end
  if href:match("^//") then
    return "https:" .. href
  end
  if href:match("^/") then
    local root = base:match("^(%a+://[^/]+)") or base
    return root .. href
  end
  local target, anchor = href:match("^([^#]*)(#?.*)$")
  if target == "" then
    return href
  end
  local resolved = resolve_path(dir, target)
  local key = resolved:gsub("%.html$", ""):gsub("/$", "")
  if known[key] then
    return relative_to(dir, key) .. anchor
  end
  return base .. resolved .. anchor
end

local function clean_page(html, key, base, known)
  local body = main_content(html)
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
  local dir = key:match("^(.*)/[^/]*$") or ""
  return (
    body:gsub(' ?href="([^"]*)"', function(href)
      return ' href="' .. rewrite_href(href, dir, base, known) .. '"'
    end)
  )
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
      db[key] = clean_page(html, key, held.base, known)
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
  clean_page = clean_page,
  rewrite_href = rewrite_href,
  page_of = page_of,
}

return M
