-- The DocC source adapter (any documentation site built with DocC).
--
-- DocC is Apple's documentation compiler, and like Sphinx it is not a registry
-- but the tool behind many separate sites: developer.apple.com's whole API
-- reference, docs.swift.org, and every Swift package that publishes its own
-- documentation. There is nothing to search, so a docset is named by giving
-- the documentation URL of one module -- and everything the install needs is
-- read from the two things every DocC site publishes:
--
--   * a navigator index, one request, naming every page of the site with its
--     title and its kind, so the row can read "swiftui · 8351 pages" before
--     anything is downloaded;
--   * one render-JSON document per page, which is what the site's own
--     JavaScript draws. docc_render.lua turns it into the HTML the installer
--     expects.
--
-- Two layouts exist and both are served in the wild, so which one a site uses
-- is probed rather than guessed from its host: developer.apple.com serves the
-- JSON under "/tutorials/data", and a site built by `docc convert` serves it
-- under "/data", with its index at "/index/index.json".
--
-- The cost is one HTTP request per page, as with Sphinx, and the biggest
-- module is far larger than any Sphinx site: SwiftUI alone is over 8000 pages.
-- That is why the page count is shown before the pick.
--
-- The site a docset came from is remembered in ".docc_sites.json" beside the
-- installed docsets, since the folder name cannot carry a URL.
local M = {}

M.origin = "docc"

-- Every DocC site documents Swift (some also carry the Objective-C spelling of
-- the same symbols; the Swift tree is the one read).
M.language = "Swift"

local sites_file = ".docc_sites.json"

local function data_folder()
  return require("apidocs.common").data_folder()
end

--- The remembered sites, { [docset] = { url = ..., module = ..., layout = ... } }.
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

-- ------------------------------------------------------------------ the site

--- Looks like a documentation URL, so the install picker should ask this
--- source about it rather than search a registry for the text.
---@param text string
function M.is_url(text)
  return vim.trim(text):match("^https?://[^%s]+/documentation/[^%s]*$") ~= nil
end

--- What a documentation URL names: the site it is on, and the module it points
--- into. "https://developer.apple.com/documentation/swiftui/text" is the
--- module "swiftui" on "https://developer.apple.com"; a DocC site published
--- under a path of its own keeps that path
--- ("https://docs.swift.org/swift-book").
---@param url string
---@return { base: string, module: string }
local function split_url(url)
  local address = vim.trim(url):gsub("[?#].*$", "")
  local base, rest = address:match("^(.-)/documentation/?(.*)$")
  if not base or base == "" then
    error("that is not a DocC documentation URL: it has no /documentation/ in it", 0)
  end
  local module = rest:match("^([^/]+)") or ""
  if module == "" then
    error("that URL names no module to install: " .. url, 0)
  end
  return { base = base, module = module:lower() }
end

local function fetch(url, system)
  local res = system({ "curl", "-sfL", "--max-time", "60", url }, { text = true })
  if res.code ~= 0 or not res.stdout or res.stdout == "" then
    return nil
  end
  return res.stdout
end

local function decode(text, what)
  local ok, value = pcall(vim.json.decode, text)
  if not ok or type(value) ~= "table" then
    error(what .. " is not the JSON a DocC site serves", 0)
  end
  return value
end

-- Where the two layouts keep the render JSON and the navigator index. Apple's
-- own site is the first; everything `docc convert` produces is the second.
local layouts = {
  apple = {
    page = function(base, path)
      return base .. "/tutorials/data" .. path .. ".json"
    end,
    index = function(base, module)
      return base .. "/tutorials/data/index/" .. module
    end,
  },
  docc = {
    page = function(base, path)
      return base .. "/data" .. path .. ".json"
    end,
    index = function(base, _)
      return base .. "/index/index.json"
    end,
  },
}

--- Which layout a site serves, found by asking it for the module's own page.
--- It is probed rather than read off the hostname: a DocC site can be hosted
--- anywhere, and a host name is not a promise about paths.
---@return string layout, string page the module page already fetched
local function probe_layout(base, module, system)
  for _, name in ipairs({ "docc", "apple" }) do
    local page = fetch(layouts[name].page(base, "/documentation/" .. module), system)
    if page then
      return name, page
    end
  end
  error(base .. " does not serve DocC documentation for " .. module, 0)
end

-- ------------------------------------------------------------------ the index

-- What the navigator calls a node, and what the installer should call it. A
-- kind not named here is still offered, under its own name.
local kinds = {
  module = "Modules",
  struct = "Structures",
  class = "Classes",
  enum = "Enumerations",
  protocol = "Protocols",
  typealias = "Type Aliases",
  associatedtype = "Associated Types",
  method = "Methods",
  property = "Properties",
  init = "Initializers",
  func = "Functions",
  ["var"] = "Variables",
  case = "Enumeration Cases",
  subscript = "Subscripts",
  macro = "Macros",
  op = "Operators",
  article = "Guides",
  collection = "Collections",
  sampleCode = "Sample Code",
  overview = "Tutorials",
  project = "Tutorials",
  symbol = "Symbols",
}

--- The page key a documentation path gets inside the docset: the path with
--- "/documentation/" taken off, so "/documentation/swiftui/text" is
--- "swiftui/text" and the module itself is "swiftui".
local function page_key(path)
  return (path:gsub("^/documentation/", ""):gsub("/+$", ""))
end

--- The tree the navigator index holds for a language: the Swift one where
--- there is one, since that is the spelling these docsets document.
local function language_tree(index)
  local languages = index.interfaceLanguages
  if type(languages) ~= "table" then
    error("that DocC index names no languages", 0)
  end
  if type(languages.swift) == "table" and #languages.swift > 0 then
    return languages.swift
  end
  for _, tree in pairs(languages) do
    if type(tree) == "table" and #tree > 0 then
      return tree
    end
  end
  error("that DocC index is empty", 0)
end

--- The words a Swift declaration puts before the name it declares. A navigator
--- title for a symbol IS its declaration ("func generateToken(completionHandler:
--- (Data?, (any Error)?) -> Void)"), which is far more than a picker row wants
--- and long enough to matter: in SwiftUI the longest is 400 characters, and the
--- installer names a file after the entry, capped at 255.
local declaration_words = {
  ["actor"] = true,
  ["associatedtype"] = true,
  ["case"] = true,
  ["class"] = true,
  ["convenience"] = true,
  ["enum"] = true,
  ["final"] = true,
  ["func"] = true,
  ["indirect"] = true,
  ["infix"] = true,
  ["init"] = false, -- a name, not a word before one: kept
  ["let"] = true,
  ["macro"] = true,
  ["mutating"] = true,
  ["nonmutating"] = true,
  ["operator"] = true,
  ["postfix"] = true,
  ["prefix"] = true,
  ["protocol"] = true,
  ["required"] = true,
  ["static"] = true,
  ["struct"] = true,
  ["subscript"] = false, -- likewise
  ["typealias"] = true,
  ["var"] = true,
}

--- What to call a page, given what the navigator calls it and where the site
--- keeps it. A title that is a declaration becomes the name it declares plus
--- the argument labels, which is what the page is called everywhere else
--- ("photosPicker(ispresented:selection:)"); the labels come from the path,
--- since that is where DocC writes them. Every other title -- an article, a
--- sample, a guide -- is prose and is left exactly as it is.
local function short_name(title, path)
  local first = title:match("^(%a+)%s") or title:match("^(%a+)[(<]")
  -- "init" and "subscript" are names rather than words before one, so a title
  -- starting with either is still a declaration to shorten.
  if not first or declaration_words[first] == nil then
    return title
  end
  local rest = title
  while true do
    local word, tail = rest:match("^(%a+)%s+(.*)$")
    if not word or declaration_words[word] ~= true then
      break
    end
    rest = tail
  end
  -- The name runs to whatever ends it: the argument list, the type annotation,
  -- a generic parameter list.
  local name = rest:match("^([^%s(:<]+)") or rest
  if name == "" then
    return title
  end
  local labels = path:match("([^/]*%b())$")
  if labels then
    local arguments = labels:match("(%b())")
    return name .. (arguments or "")
  end
  return name
end

--- Every page of one module, in the order the navigator lists them: its own
--- page first, then what hangs below it.
---
--- A node marked `external` is left out -- it is a page of another module, or
--- of another site altogether, and following those would pull in the whole of
--- developer.apple.com one link at a time. A groupMarker has no page: it is
--- the heading a navigator writes above a run of siblings.
---
--- The name an entry gets carries the type it belongs to ("View.frame(_:)"),
--- because a name on its own repeats: nearly every Swift type has a `body` and
--- an `init`. Only a type owns its members that way -- a navigator also nests
--- pages under groupings ("Presentation modifiers"), and those say nothing
--- about what a symbol is.
local owning_kinds = {
  struct = true,
  class = true,
  enum = true,
  protocol = true,
  typealias = true,
  actor = true,
  macro = true,
  symbol = true,
}

--- The longest name that still leaves the page key whole in the file the
--- installer writes (255, less ".html.md", less the "#key" it appends). The
--- key is unique and the name is not, so it is the name that gives way: a key
--- cut short is two pages sharing one file, which is a page lost.
local name_budget = 255 - 8 - 8

local function fit(name, key)
  local room = name_budget - #key
  if #name <= room then
    return name
  end
  if room <= 4 then
    return name:sub(1, math.max(room, 1))
  end
  return name:sub(1, room - 3) .. "..."
end

---@param tree table[] the language tree of the navigator index
---@param module string
---@return { path: string, key: string, name: string, type: string }[]
local function pages_of(tree, module)
  local prefix = "/documentation/" .. module
  local found, seen = {}, {}
  local function walk(nodes, owner)
    for _, node in ipairs(nodes or {}) do
      local path = node.path
      local mine = type(path) == "string"
        and not node.external
        and (path:lower() == prefix or path:lower():sub(1, #prefix + 1) == prefix .. "/")
      local title = node.title or ""
      if mine and not seen[path] then
        seen[path] = true
        local key = page_key(path)
        local name = short_name(title, path)
        if owner and owner ~= "" and name ~= "" then
          name = owner .. "." .. name
        end
        found[#found + 1] = {
          path = path,
          key = key,
          name = fit(name, key:gsub("/", "_")),
          type = kinds[node.type] or node.type or "Symbols",
        }
      end
      -- What a child belongs to: the type or protocol above it, never the
      -- module ("SwiftUI.View" says nothing "View" does not) and never a
      -- grouping the navigator invented to hold a run of pages.
      local child_owner = owner
      if mine and node.children and owning_kinds[node.type] then
        child_owner = short_name(title, path)
      end
      walk(node.children, child_owner)
    end
  end
  walk(tree, nil)
  return found
end

--- The docset a module names: the module path, with anything a folder name
--- cannot carry turned into "_". DocC publishes no version of its own -- a
--- framework's documentation is the documentation of whatever SDK the site
--- serves -- so there is no "~version" here.
local function docset_name(module)
  local name = module:lower():gsub("[^%w%.%-_]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  return name ~= "" and name or "docs"
end

-- What a probe or an install has read, kept between the from_url, index and db
-- calls of one install so the site is asked for its index once.
local read = {}

local function site_or_error(docset)
  local site = M.site(docset)
  if not site or type(site.url) ~= "string" or type(site.module) ~= "string" then
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

--- Read a site's index for one module: one request, plus at most two while the
--- layout is being probed.
local function load_site(base, module, layout, system)
  local page
  if not layout then
    layout, page = probe_layout(base, module, system)
  end
  local index = fetch(layouts[layout].index(base, module), system)
  if not index then
    error(base .. " serves no navigator index for " .. module, 0)
  end
  local pages = pages_of(language_tree(decode(index, "the navigator index")), module)
  if #pages == 0 then
    error(base .. " documents no module called " .. module, 0)
  end
  return { base = base, module = module, layout = layout, pages = pages, module_page = page }
end

local function loaded(docset, system)
  if read[docset] then
    return read[docset]
  end
  local site = site_or_error(docset)
  local held = load_site(site.url, site.module, site.layout, system)
  read[docset] = held
  return held
end

-- -------------------------------------------------------------- the contract

--- The docset a documentation URL offers. The site is asked for the module's
--- page (to find which layout it serves) and for its navigator index, so the
--- row shown before the pick already knows how many pages the install will
--- fetch -- which matters here more than anywhere else: a large framework is
--- thousands of requests.
---@param url string
---@param system fun(cmd: string[], opts?: table): vim.SystemCompleted
---@return { name: string, version?: string, pages: integer, url: string }[]
function M.from_url(url, system)
  if not M.is_url(url) then
    return {}
  end
  local where = split_url(url)
  local held = load_site(where.base, where.module, nil, system)
  local docset = docset_name(where.module)
  read[docset] = held
  remember_site(docset, { url = held.base, module = held.module, layout = held.layout })
  return {
    {
      name = where.module,
      pages = #held.pages,
      url = held.base .. "/documentation/" .. held.module,
    },
  }
end

--- The release a docset holds. A DocC site publishes no version of its own, so
--- there is none unless the docset name carries one.
---
--- For the same reason this adapter declares no `latest`: with no version on
--- either side there is nothing an update check could compare, and a DocC
--- docset is never reported as out of date. Reinstalling it is how it is
--- refreshed.
---@param docset string
function M.release(docset)
  local _, version = docset:match("^(.-)~([^~]*)$")
  return version
end

--- The language a docset documents. Every DocC site here is read through its
--- Swift tree, so this never has to look anything up.
---@param _docset string
function M.language_of(_docset)
  return M.language
end

function M.index(docset, _, system)
  local held = loaded(docset, system)
  local entries = {}
  for _, page in ipairs(held.pages) do
    entries[#entries + 1] = { name = page.name, path = page.key, type = page.type }
  end
  return { entries = entries }
end

-- ------------------------------------------------------------ fetching pages

-- How many pages one curl call fetches. A DocC site has no archive, so the
-- pages come one request each; curl is asked for a batch at a time so the
-- install can say how far along it is, and reuses one connection for all of
-- them.
local batch_size = 200

local function curl_parallel(system)
  local res = system({ "curl", "--help", "all" }, { text = true })
  return res.code == 0 and (res.stdout or ""):find("--parallel-max", 1, true) ~= nil
end

--- Fetch every page of `held` into `dir`, at most `sources.workers()` at once,
--- reporting as each batch lands. Returns the file each page was written to.
local function fetch_pages(held, dir, system, report)
  local parallel = curl_parallel(system)
  local files, done = {}, 0
  local pages = held.pages
  for start = 1, #pages, batch_size do
    local config, batch = {}, {}
    for i = start, math.min(start + batch_size - 1, #pages) do
      local page = pages[i]
      local out = dir .. "/" .. page.key:gsub("/", "%%2F")
      batch[#batch + 1] = { key = page.key, out = out }
      config[#config + 1] = 'url = "' .. layouts[held.layout].page(held.base, page.path) .. '"'
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
    -- A page that 404s is skipped, not fatal: a navigator index can name a
    -- page the site no longer serves, and one missing page is no reason to
    -- lose the other 8350.
    system(cmd)
    for _, page in ipairs(batch) do
      if vim.fn.filereadable(page.out) == 1 then
        files[page.key] = page.out
      end
    end
    done = math.min(done + batch_size, #pages)
    if report then
      report("fetching pages " .. done .. "/" .. #pages)
    end
  end
  return files
end

-- --------------------------------------------------------------- the links

--- `path` written from `dir`, climbing no further than it has to: the
--- installer reads a link against the page key of the page holding it.
---
--- A page key here is both a page and a directory -- "widget/wheel" holds
--- "widget/wheel/spin()" -- so one segment of the target is always written
--- out, even when the target IS the directory: from a symbol's page, its own
--- type is "../wheel", never the empty string. An empty href is how a link to
--- a parent page became a link to the docset folder (found by the devicecheck
--- install, and the same defect pkg.go.dev's adapter had to fix).
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

--- A site-relative URL as an address. A DocC site published under a path of
--- its own ("https://docs.swift.org/swift-book") writes some URLs from the
--- site root and some from its own base, so which one this is decides which
--- it is joined to.
local function address(base, url)
  if url:match("^%a[%w+.-]*:") then
    return url
  end
  if url:match("^//") then
    return "https:" .. url
  end
  if url:sub(1, 1) ~= "/" then
    return base .. "/" .. url
  end
  local root, path = base:match("^(%a+://[^/]+)(.*)$")
  if not root then
    return base .. url
  end
  if path ~= "" and (url .. "/"):sub(1, #path + 1) == path .. "/" then
    return root .. url
  end
  return root .. path .. url
end

--- The href a reference of a page should get: another page of this docset
--- becomes that page, and everything else -- a page of the site this docset
--- does not hold, an image, an outside link -- becomes an address.
local function href_of(reference, base, keys, dir)
  if type(reference) ~= "table" then
    return nil
  end
  local url = reference.url
  if type(url) ~= "string" or url == "" then
    -- An image names its file in its variants instead, one per scale and
    -- appearance; the plain light one reads best in a buffer.
    local variants = reference.variants
    if type(variants) == "table" then
      local chosen = variants[1]
      for _, variant in ipairs(variants) do
        if not vim.tbl_contains(variant.traits or {}, "dark") then
          chosen = variant
          break
        end
      end
      url = chosen and chosen.url
    end
  end
  if type(url) ~= "string" or url == "" then
    return nil
  end
  local target, anchor = url:match("^([^#]*)(#?.*)$")
  local key = keys[page_key(target):lower()]
  if key then
    return relative_to(dir, key) .. anchor
  end
  return address(base, url)
end

--- The page a render-JSON document becomes, with every link in it resolved.
---@param page table the decoded render JSON
---@param opts { base: string, keys: table<string, string>, key: string }
function M.render(page, opts)
  local references = type(page.references) == "table" and page.references or {}
  local dir = opts.key:match("^(.*)/[^/]*$") or ""
  local ctx = {
    reference = function(identifier)
      local reference = references[identifier]
      return type(reference) == "table" and reference or nil
    end,
    resolve = function(identifier)
      local reference = references[identifier]
      if not reference then
        -- A reference the page does not carry may still be an address: DocC
        -- uses the URL itself as the identifier of an outside link.
        if type(identifier) == "string" and identifier:match("^%a[%w+.-]*:") then
          return identifier
        end
        return nil
      end
      return href_of(reference, opts.base, opts.keys, dir)
    end,
  }
  return require("apidocs.docc_render").page(page, ctx)
end

function M.db(docset, _, system, report)
  local held = loaded(docset, system)
  read[docset] = nil
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local files = fetch_pages(held, dir, system, report)
  local keys = {}
  for key in pairs(files) do
    keys[key:lower()] = key
  end
  local db = {}
  for key, path in pairs(files) do
    local file = io.open(path, "r")
    if file then
      local text = file:read("*a")
      file:close()
      local ok, page = pcall(vim.json.decode, text)
      -- A page that is not the JSON it should be is skipped, for the same
      -- reason a 404 is: one page is no reason to lose the install.
      if ok and type(page) == "table" then
        db[key] = M.render(page, { base = held.base, keys = keys, key = key })
      end
    end
  end
  return db
end

M._internal = {
  split_url = split_url,
  page_key = page_key,
  pages_of = pages_of,
  short_name = short_name,
  docset_name = docset_name,
  relative_to = relative_to,
  address = address,
  language_tree = language_tree,
  layouts = layouts,
}

return M
