-- The gemdocs.org source adapter (Ruby gems, documented by YARD).
--
-- gemdocs.org builds every gem's YARD documentation ahead of time and serves
-- it as static pages (measured 2026-09-26, nokogiri 1.19.2):
--   * gems/<gem>/latest               a 302 to gems/<gem>/<version>/, the
--                                     newest version gemdocs has BUILT (not
--                                     always the newest release: nokogiri
--                                     1.19.4 was a plain 404);
--   * gems/<gem>/<v>/class_list.html  every class and module, as links titled
--                                     "Nokogiri::XML::NodeSet (class)";
--   * gems/<gem>/<v>/method_list.html every method, linked to its anchor
--                                     ("Nokogiri/XML/NodeSet.html#&-instance_method");
--   * gems/<gem>/<v>/file_list.html   the extra files (the README is
--                                     index.html);
--   * one page per class or module, its documentation in <div id="content">.
-- It has no search API (search?q= is an HTML page of names), so a search asks
-- rubygems.org, and the version is resolved from gemdocs on pick.
--
-- This adapter turns that into the index/db pair the installer expects (see
-- sources/devdocs.lua):
--   * a docset is "<gem>~<version>" (nokogiri~1.19.2);
--   * a page per class, module and extra file, keyed by its path without
--     ".html" (Nokogiri/XML/NodeSet);
--   * entries: every class and module, every method as YARD names it
--     ("Nokogiri::XML::NodeSet#css", "Nokogiri::HTML4::Document.parse"),
--     every constant, and the extra files;
--   * links to a page of the docset name it; any other link is an address on
--     gemdocs.org.
--
-- YARD's ids hold Ruby's operator names ("&-instance_method",
-- "[]=-instance_method", "--instance_method" for "-"). Every id is made plain
-- by a rule that keeps two operators apart: a character that is not a letter,
-- digit, "_" or "-" is written "." and its two hex digits ("&" is ".26").
local anchors = require("docshelf.anchors")
local fetching = require("docshelf.fetch")
local html_text = require("docshelf.html")
local links = require("docshelf.links")

local M = {}

M.origin = "gemdocs.org"

M.language = "Ruby"

local site = "https://gemdocs.org/gems/"
local rubygems = "https://rubygems.org/api/v1/"

local user_agent = "docshelf.nvim (https://github.com/ChrisGVE/docshelf.nvim)"

local function curl(url, system)
  return system({ "curl", "-sfL", "-A", user_agent, url })
end

--- The gems rubygems.org finds for `query`, the most downloaded first (its
--- own order is by relevance, and puts nokogiri eighth for "noko"). A row has
--- no version: the one gemdocs has built is asked on pick.
---@param query string
---@param system fun(cmd: string[]): vim.SystemCompleted
---@return { name: string }[]
function M.search(query, system)
  local res = curl(rubygems .. "search.json?query=" .. vim.uri_encode(query, "rfc2396"), system)
  if res.code ~= 0 then
    error("could not search rubygems.org (curl exit " .. tostring(res.code) .. ")", 0)
  end
  local ok, found = pcall(vim.json.decode, res.stdout)
  if not ok or not vim.islist(found) then
    error("rubygems.org answered a search with something other than a list of gems", 0)
  end
  local gems = vim.tbl_filter(function(gem)
    return type(gem) == "table" and type(gem.name) == "string"
  end, found)
  table.sort(gems, function(a, b)
    return (tonumber(a.downloads) or 0) > (tonumber(b.downloads) or 0)
  end)
  return vim.tbl_map(function(gem)
    return { name = gem.name }
  end, gems)
end

--- The docset for the newest version of `name` gemdocs.org has built: its
--- `latest` address answers with a redirect naming it.
---@param name string
---@param system fun(cmd: string[]): vim.SystemCompleted
---@return string docset e.g. "nokogiri~1.19.2"
function M.resolve(name, system)
  local latest = site .. vim.uri_encode(name, "rfc2396") .. "/latest"
  local res = system({ "curl", "-s", "-A", user_agent, "-o", "/dev/null", "-w", "%{redirect_url}", latest })
  local version = res.code == 0 and (res.stdout or ""):match("/gems/[^/]+/([^/]+)/?$")
  if not version then
    error("gemdocs.org has no documentation for " .. name, 0)
  end
  return name .. "~" .. version
end

local function split_docset(docset)
  local gem, version = docset:match("^(.+)~([%w%.%-_]+)$")
  if not gem then
    error("a gemdocs.org docset is <gem>~<version>, got " .. docset, 0)
  end
  return gem, version
end

--- The release a docset holds: it is named for the exact version it came from.
---@param docset string e.g. "nokogiri~1.19.2"
function M.release(docset)
  local _, version = split_docset(docset)
  return version
end

--- The docset gemdocs.org offers for this gem today; comparing it with the
--- docset's own name is how an update is noticed.
---@param docset string
---@param system fun(cmd: string[]): vim.SystemCompleted
function M.latest(docset, system)
  return M.resolve((split_docset(docset)), system)
end

-- ------------------------------------------------------------- the ids

local function url_decode(text)
  return (text:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

--- An id as plain text: decoded as a link and as HTML would write it, then
--- every character that is not a letter, digit, "_" or "-" written "." and
--- its two hex digits. "&" and "-" stay apart ("..26-instance_method" is
--- never "--instance_method"), and a link meets the id it names.
local function plain_id(id)
  return (
    html_text.decode_entities(url_decode(id)):gsub("[^%w_%-]", function(char)
      return string.format(".%02X", char:byte())
    end)
  )
end

-- What YARD calls a member, by the end of its anchor, in the pickers' words.
local member_types = {
  ["-instance_method"] = "Instance Methods",
  ["-class_method"] = "Class Methods",
  ["-constant"] = "Constants",
}

local function member_type(anchor)
  for suffix, name in pairs(member_types) do
    if anchor:sub(-#suffix) == suffix then
      return name
    end
  end
  return "Methods"
end

local object_types = { class = "Classes", module = "Modules" }

-- ------------------------------------------------------------ the lists

--- The links of one of YARD's lists: { href, name, kind } where the title is
--- "<name> (<kind>)".
local function list_links(html)
  local out = {}
  for href, title in html:gmatch('<a href="([^"]+)" title="([^"]*)"') do
    local name, kind = html_text.decode_entities(title):match("^(.-) %((.+)%)$")
    out[#out + 1] = { href = href, name = name or html_text.decode_entities(title), kind = kind }
  end
  return out
end

local function page_key(href)
  return (href:gsub("%.html$", ""))
end

-- ------------------------------------------------------------ the pages

local function main_content(html)
  local start = html:find('<div id="content"', 1, true)
  local body = start and html:sub(start) or html
  local stop = body:find('<div id="footer"', 1, true)
  return stop and body:sub(1, stop - 1) or body
end

local function clean_page(html, names)
  local body = main_content(html)
    :gsub("<script.-</script>", "")
    -- the source of every method, as a table of line numbers beside the code
    :gsub(
      '<table class="source_code">.-</table>',
      ""
    )
    -- "collapse", "show all": switches for the site's script
    :gsub('<a href="#"[^>]*>.-</a>', "")
  return anchors.plain_fragments(anchors.name_the_anchors(body, names, plain_id), plain_id)
end

-- What each install read in index, kept for its db call.
local read = {}

local function read_gem(docset, system, report)
  local gem, version = split_docset(docset)
  local base = site .. gem .. "/" .. version .. "/"
  local lists = {}
  for _, list in ipairs({ "class_list", "method_list", "file_list" }) do
    local res = curl(base .. list .. ".html", system)
    if res.code ~= 0 then
      error("gemdocs.org has no documentation for " .. gem .. " " .. version, 0)
    end
    lists[list] = list_links(res.stdout)
  end

  local entries, pages, names = {}, {}, {}
  local function add_page(key)
    if not pages[key] then
      pages[key] = true
      names[key] = {}
    end
  end
  for _, object in ipairs(lists.class_list) do
    local type = object_types[object.kind]
    if type then
      local key = page_key(object.href)
      add_page(key)
      entries[#entries + 1] = { name = object.name, path = key, type = type }
    end
  end
  for _, method in ipairs(lists.method_list) do
    local file, anchor = method.href:match("^([^#]+)#(.+)$")
    if file then
      local key, id = page_key(file), plain_id(anchor)
      add_page(key)
      names[key][id] = names[key][id] or method.name
      entries[#entries + 1] = { name = method.name, path = key .. "#" .. id, type = member_type(anchor) }
    end
  end
  for _, file in ipairs(lists.file_list) do
    local key = page_key(file.href)
    add_page(key)
    entries[#entries + 1] = { name = gem .. " " .. file.name, path = key, type = "Guides" }
  end

  local requests = {}
  for key in pairs(pages) do
    requests[#requests + 1] = { key = key, url = base .. key .. ".html" }
  end
  table.sort(requests, function(a, b)
    return a.key < b.key
  end)
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

  -- constants are in no list: each is a <dt> on its class's page
  local class_of = {}
  for _, entry in ipairs(entries) do
    if entry.type == "Classes" or entry.type == "Modules" then
      class_of[entry.path] = entry.name
    end
  end
  for key, html in pairs(held) do
    for constant in main_content(html):gmatch('<dt id="([^"]*)%-constant"') do
      local id = plain_id(constant .. "-constant")
      local name = (class_of[key] and class_of[key] .. "::" or "") .. html_text.decode_entities(constant)
      names[key][id] = names[key][id] or name
      entries[#entries + 1] = { name = name, path = key .. "#" .. id, type = "Constants" }
    end
  end

  -- an entry on a page gemdocs did not serve would open nothing
  entries = vim.tbl_filter(function(entry)
    return held[entry.path:match("^[^#]+")] ~= nil
  end, entries)
  return { base = base, pages = held, names = names, entries = entries }
end

function M.index(docset, _, system, report)
  read[docset] = read_gem(docset, system, report)
  return { entries = read[docset].entries }
end

function M.db(docset, _, system, report)
  local gem = read[docset] or read_gem(docset, system, report)
  read[docset] = nil
  local known = {}
  for key in pairs(gem.pages) do
    known[key] = true
  end
  local db = {}
  for key, html in pairs(gem.pages) do
    db[key] = links.rewrite_html(clean_page(html, gem.names[key]), {
      dir = key:match("^(.*)/[^/]*$") or "",
      known = known,
      base = gem.base,
    })
  end
  return db
end

M._internal = { plain_id = plain_id }

return M
