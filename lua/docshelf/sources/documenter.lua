-- The Documenter.jl source adapter (Julia packages, and any Documenter site).
--
-- Julia's packages are registered in the General registry, but their
-- documentation lives wherever each package deploys it: nearly all of it is
-- built with Documenter.jl and pushed to the repository's GitHub Pages, so it
-- answers at https://<owner>.github.io/<Repo>.jl/stable/, redirected to the
-- project's own domain where it has one (measured 2026-09-26: 10 of 12
-- popular packages; Plots and Makie are elsewhere). Julia's own manual is on
-- devdocs already.
--
-- Every Documenter site publishes, beside its pages (measured on DataFrames
-- 1.8.2 and Julia 1.13):
--   * siteinfo.js      the version the site was built for ("v1.8.2");
--   * search_index.js  every page, section and docstring, each with the page
--                      and id it lives at ("lib/functions/#DataFrames.select");
--   * a page per folder ("lib/functions/"), with the site's root written into
--                      it as documenterBaseURL ("../..").
--
-- This adapter turns that into the index/db pair the installer expects (see
-- sources/devdocs.lua):
--   * a search over the names in the General registry (one request, kept for
--     the session); a pick is resolved to the package's site by the address
--     above;
--   * any Documenter site by its URL, whatever page of it was typed;
--   * a docset "<package>~<version>" (DataFrames~1.8.2), the site it came
--     from remembered in ".documenter_sites.json" beside the installed docsets;
--   * a page per folder, keyed by its path without the "/" ("lib/functions",
--     "index" for the home page); entries: every page, every section and
--     every docstring.
local anchors = require("docshelf.anchors")
local fetching = require("docshelf.fetch")
local html_text = require("docshelf.html")
local links = require("docshelf.links")

local M = {}

M.origin = "documenter"

M.language = "Julia"

local registry = "https://raw.githubusercontent.com/JuliaRegistries/General/master/"

local user_agent = "docshelf.nvim (https://github.com/ChrisGVE/docshelf.nvim)"

-- --------------------------------------------------------- remembered sites

local sites_file = ".documenter_sites.json"

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

-- ------------------------------------------------------------ the registry

-- The General registry's packages, name to folder, fetched once per session:
-- a search runs at every keystroke.
local catalogue

--- Forget the fetched registry (for the specs).
function M.reset()
  catalogue = nil
end

local function curl(url, system, extra)
  local cmd = { "curl", "-sfL", "--max-time", "60", "-A", user_agent }
  vim.list_extend(cmd, extra or {})
  cmd[#cmd + 1] = url
  return system(cmd)
end

local function packages(system)
  if not catalogue then
    local res = curl(registry .. "Registry.toml", system)
    if res.code ~= 0 then
      error("could not fetch Julia's General registry (curl exit " .. tostring(res.code) .. ")", 0)
    end
    local found = {}
    for name, path in (res.stdout or ""):gmatch('name%s*=%s*"([^"]+)"%s*,%s*path%s*=%s*"([^"]+)"') do
      found[name] = path
    end
    if next(found) == nil then
      error("Julia's General registry lists no packages", 0)
    end
    catalogue = found
  end
  return catalogue
end

--- The registered packages whose name holds `query`, whatever the case. The
--- version is left for `resolve`: it is read from the package's own site.
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

--- The folder name a project gives: "DataFrames.jl" is DataFrames, and
--- anything a folder name cannot carry is "_".
local function project_name(text)
  local name = vim.trim(html_text.text(text)):gsub("%.jl$", ""):gsub("[^%w%.%-_]+", "_")
  name = name:gsub("^_+", ""):gsub("_+$", "")
  return name ~= "" and name or nil
end

local function docset_name(name, version)
  if version then
    return name .. "~" .. version
  end
  return name
end

--- Read the Documenter site holding the page at `url`: its root, the version
--- it was built for and the project it names.
---@return { base: string, version?: string, project?: string }
local function read_site(url, system)
  local res = curl(url, system, { "-w", "\n%{url_effective}" })
  if res.code ~= 0 then
    error("could not fetch " .. url, 0)
  end
  local page, landed = (res.stdout or ""):match("^(.*)\n([^\n]*)$")
  local root = page and page:match('documenterBaseURL%s*=%s*"([^"]*)"')
  if not root then
    error(url .. " is not a page of a Documenter site", 0)
  end
  local base = absolute(landed ~= "" and landed or url, root):gsub("/*$", "") .. "/"
  local info = curl(base .. "siteinfo.js", system)
  local version = info.code == 0 and (info.stdout or ""):match('DOCUMENTER_CURRENT_VERSION%s*=%s*"v?([^"]+)"')
  local project = page:match('class="docs%-package%-name".-<a[^>]*>(.-)</a>')
    or page:match("<title>.*·%s*(.-)</title>")
  return {
    base = base,
    version = version and (version:gsub("[^%w%.%-_]+", "_")) or nil,
    project = project and project_name(project),
  }
end

-- The index of the last probe or install, kept between the from_url, index
-- and db calls of one install so the site is asked for it once.
local read = {}

--- Where the site of a registered package answers: its GitHub Pages.
local function pages_address(name, system)
  local path = packages(system)[name]
  if not path then
    error("Julia's General registry has no package " .. name, 0)
  end
  local res = curl(registry .. path .. "/Package.toml", system)
  local repo = res.code == 0 and (res.stdout or ""):match('\nrepo%s*=%s*"([^"]+)"')
  local owner, project = (repo or ""):match("^https://github%.com/([^/]+)/(.-)%.git$")
  if not owner then
    error(name .. " is not on GitHub, so docshelf cannot find its documentation: type its URL instead", 0)
  end
  return "https://" .. owner .. ".github.io/" .. project .. "/stable/"
end

--- The docset for the newest documentation of a registered package, read
--- from the package's site.
---@param name string
---@param system fun(cmd: string[]): vim.SystemCompleted
---@return string docset e.g. "DataFrames~1.8.2"
function M.resolve(name, system)
  local address = pages_address(name, system)
  local ok, site = pcall(read_site, address, system)
  if not ok then
    error("no Documenter site for " .. name .. " at " .. address .. ": type its documentation URL instead", 0)
  end
  local docset = docset_name(name, site.version)
  remember_site(docset, { url = site.base, name = name })
  return docset
end

--- Parse a site's search_index.js into its pages and entries.
local function read_index(body)
  local json = body:match("^[^{]*(%b{})")
  local ok, decoded = pcall(vim.json.decode, json or "")
  if not (ok and type(decoded) == "table" and type(decoded.docs) == "table") then
    error("the site's search_index.js is not Documenter's search index", 0)
  end
  return decoded.docs
end

local function fetch_index(base, system)
  local res = curl(base .. "search_index.js", system)
  if res.code ~= 0 then
    error("no search index at " .. base .. "search_index.js", 0)
  end
  return read_index(res.stdout or "")
end

-- A docstring's category in the pickers' words.
local categories = {
  section = "Sections",
  ["function"] = "Functions",
  method = "Methods",
  type = "Types",
  macro = "Macros",
  constant = "Constants",
  keyword = "Keywords",
  module = "Modules",
}

--- A page id as plain text: the rule every source shares, after the one
--- place Documenter disagrees with itself -- a "\" in a name is written "\\"
--- in the page's ids and links but "\" in the index.
local function plain(id)
  return anchors.hex_id((id:gsub("\\\\", "\\"):gsub("%%5[cC]%%5[cC]", "%%5C")))
end

--- A location's page key and the path it is fetched from: the home page is
--- "index", fetched from the site's root.
local function page_of(location)
  local page = location:gsub("#.*$", "")
  local key = page:gsub("index%.html$", ""):gsub("%.html$", ""):gsub("/$", "")
  return key == "" and "index" or key, page
end

--- The pages and entries a search index describes.
local function read_docs(docs)
  local entries, pages, order = {}, {}, {}
  for _, doc in ipairs(docs) do
    if type(doc.location) == "string" and type(doc.title) == "string" then
      local key, path = page_of(doc.location)
      if not pages[key] then
        pages[key] = path
        order[#order + 1] = key
        -- every page is an entry: the installer finds where a link to
        -- "lib/functions#x" goes through the entry of its page
        entries[#entries + 1] = { name = type(doc.page) == "string" and doc.page or key, path = key, type = "Pages" }
      end
      local anchor = doc.location:match("#(.+)$")
      entries[#entries + 1] = {
        name = doc.title,
        path = anchor and (key .. "#" .. plain(anchor)) or key,
        type = categories[doc.category] or "Entries",
      }
    end
  end
  table.sort(order)
  return { entries = entries, pages = pages, order = order }
end

--- The docset a documentation URL offers: one row, which already knows how
--- many pages the install will fetch.
---@param url string
---@param system fun(cmd: string[]): vim.SystemCompleted
---@return { name: string, version?: string, pages: integer, url: string }[]
function M.from_url(url, system)
  if not url:match("^https?://[^%s]+$") then
    return {}
  end
  local site = read_site((vim.trim(url):gsub("[?#].*$", "")), system)
  if not site.project then
    error(url .. " names no project", 0)
  end
  local held = read_docs(fetch_index(site.base, system))
  local docset = docset_name(site.project, site.version)
  held.base = site.base
  read[docset] = held
  remember_site(docset, { url = site.base, name = site.project })
  return { { name = site.project, version = site.version, pages = #held.order, url = site.base } }
end

--- The release a docset holds: the version its site was built for, which the
--- docset is named for.
---@param docset string e.g. "DataFrames~1.8.2"
function M.release(docset)
  return docset:match("~([^~]+)$")
end

--- The docset the site offers today: its version read again, named the way an
--- install names it.
---@param docset string
---@param system fun(cmd: string[]): vim.SystemCompleted
---@return string? docset nil when the site a docset came from is not known
function M.latest(docset, system)
  local known = M.site(docset)
  if not known then
    return nil
  end
  local site = read_site(known.url, system)
  local name = known.name or docset:gsub("~[^~]*$", "")
  local latest = docset_name(name, site.version)
  remember_site(latest, { url = site.base, name = name })
  return latest
end

local function loaded(docset, system)
  if read[docset] then
    return read[docset]
  end
  local site = M.site(docset)
  if not site then
    error(
      "docshelf does not know which site "
        .. docset
        .. " came from; install it again by typing its documentation URL in the install picker",
      0
    )
  end
  local held = read_docs(fetch_index(site.url, system))
  held.base = site.url
  read[docset] = held
  return held
end

function M.index(docset, _, system)
  return { entries = loaded(docset, system).entries }
end

-- ------------------------------------------------------------ the pages

--- The page itself: Documenter's <article class="content">, up to the footer
--- that follows it (the article holds articles of its own, one per
--- docstring, so its closing tag cannot mark the end).
local function main_content(html)
  local start = html:find('<article class="content"', 1, true)
  if not start then
    return html:match("<body[^>]*>(.*)</body>") or html
  end
  local stop = html:find('<nav class="docs-footer"', start, true)
  return html:sub(start, stop and stop - 1 or -1)
end

local function clean_page(html)
  local body = main_content(html)
    :gsub("<script.-</script>", "")
    :gsub("<style.-</style>", "")
    :gsub("<svg.-</svg>", "")
    -- the permalink beside every heading, and the empty anchor after it
    :gsub(
      '<a class="docs%-heading%-anchor%-permalink"[^>]*>.-</a>',
      ""
    )
    :gsub('<a id="[^"]*"></a>', "")
    :gsub('<a class="docs%-heading%-anchor"[^>]*>(.-)</a>', "%1")
    -- the link to the source of every docstring on GitHub
    :gsub('<a class="docs%-sourcelink"[^>]*>.-</a>', "")
    -- a docstring's name and category become a heading holding the id: the
    -- installer names an entry by the text right after its id, and in the
    -- <summary> a link and a <code> come first
    :gsub(
      '<summary[^>]-%sid="([^"]*)"[^>]*>(.-)</summary>',
      function(id, inner)
        return '<h4 id="'
          .. id
          .. '">'
          .. html_text.text(inner):gsub("[&<>]", {
            ["&"] = "&amp;",
            ["<"] = "&lt;",
            [">"] = "&gt;",
          })
          .. "</h4>"
      end
    )
    :gsub("</?details[^>]*>", "")
    -- a code block names its language on the <code> inside it
    :gsub(
      '<pre><code class="language%-(%w+)[^"]*">(.-)</code></pre>',
      '<pre data-language="%1">%2</pre>'
    )
  return anchors.plain_fragments(anchors.name_the_anchors(body, nil, plain), plain)
end

function M.db(docset, _, system, report)
  local held = loaded(docset, system)
  read[docset] = nil
  local requests = {}
  for _, key in ipairs(held.order) do
    requests[#requests + 1] = { key = key, url = held.base .. held.pages[key] }
  end
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local fetched = fetching.pages(requests, dir, system, report)
  local known = {}
  for key in pairs(fetched) do
    known[key] = true
  end
  local db = {}
  for key, path in pairs(fetched) do
    local handle = assert(io.open(path, "r"))
    local html = handle:read("*a")
    handle:close()
    local served = held.pages[key]
    db[key] = links.rewrite_html(clean_page(html), {
      dir = key:match("^(.*)/[^/]*$") or "",
      -- a page is served as a folder, and writes its links against it
      from = served:match("/$") and served or nil,
      -- a link to the site's root is a link to the home page
      key_of = function(path)
        return (page_of(path))
      end,
      known = known,
      base = held.base,
    })
  end
  vim.fn.delete(dir, "rf")
  return db
end

-- Exposed for the specs.
M._internal = { absolute = absolute, page_of = page_of, plain = plain, clean_page = clean_page }

return M
