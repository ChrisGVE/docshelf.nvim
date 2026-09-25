-- The metacpan.org source adapter (Perl distributions on CPAN).
--
-- MetaCPAN's API (fastapi.metacpan.org/v1) answers everything this needs
-- (measured 2026-09-25):
--   * search/autocomplete/suggest?q=  modules matching what was typed, each
--                                     with its distribution and release
--                                     ("Moose-2.4000");
--   * release/<dist>                  the latest release of a distribution;
--   * release/_search, file/_search   Elasticsearch queries: which author
--                                     uploaded a given version, and which
--                                     files of that release carry
--                                     documentation (Moose: 133);
--   * pod/<AUTHOR>/<release>/<path>?content-type=text/html
--                                     a file's POD as an HTML fragment, a
--                                     table of contents first, then headings
--                                     and =item terms each with an id.
--
-- This adapter turns that into the index/db pair the installer expects (see
-- sources/devdocs.lua):
--   * a docset is "<distribution>~<version>" (Moose~2.4000);
--   * a page per documented module, keyed by its name with "::" as "/"
--     (Moose::Util is "Moose/Util"): a key read as "Moose:" would be a URL
--     scheme;
--   * the module is an entry, and so is every heading below the top level
--     and every =item, named "<module> <heading>" and typed by the top-level
--     section holding it ("Methods", "Exported Functions");
--   * links to a module of the docset become page keys, every other link an
--     address on metacpan.org.
--
-- A heading's own id is its whole text ("is_role($package_or_obj)"), but
-- other pages link to the short id POD puts inside it ("Moose::Util#is_role").
-- The short id becomes the heading's id, so that an entry and the links to it
-- agree, and the installer reads the heading's text right after its id.
local fetching = require("docshelf.fetch")
local html_text = require("docshelf.html")
local links = require("docshelf.links")

local M = {}

M.origin = "metacpan.org"

M.language = "Perl"

local api = "https://fastapi.metacpan.org/v1/"
local site = "https://metacpan.org/"

local user_agent = "docshelf.nvim (https://github.com/ChrisGVE/docshelf.nvim)"

-- More documented files than any release holds (perl itself: 346).
local most_files = 5000

local function request(cmd, system)
  local res = system(cmd)
  if res.code ~= 0 then
    return nil, res.code
  end
  local ok, body = pcall(vim.json.decode, res.stdout)
  if not ok or type(body) ~= "table" then
    error("MetaCPAN answered " .. cmd[#cmd] .. " with something that is not JSON", 0)
  end
  return body
end

local function get(path, system)
  return request({ "curl", "-sfL", "-A", user_agent, api .. path }, system)
end

--- An Elasticsearch query against one of the API's indices.
local function query(index, body, system)
  local cmd = { "curl", "-sfL", "-A", user_agent, "-H", "Content-Type: application/json" }
  vim.list_extend(cmd, { "-X", "POST", "-d", vim.json.encode(body), api .. index .. "/_search" })
  local answer, code = request(cmd, system)
  if not answer then
    error("could not query MetaCPAN's " .. index .. " index (curl exit " .. tostring(code) .. ")", 0)
  end
  local hits = type(answer.hits) == "table" and answer.hits.hits or {}
  return vim.tbl_map(function(hit)
    return hit._source or {}
  end, hits)
end

--- The distributions MetaCPAN suggests for `query`, in its order, each at the
--- release it names. Suggestions are modules, so a distribution is listed
--- once, where its first module is.
---@param query string
---@param system fun(cmd: string[]): vim.SystemCompleted
---@return { name: string, version: string }[]
function M.search(query, system)
  local body, code = get("search/autocomplete/suggest?q=" .. vim.uri_encode(query, "rfc2396"), system)
  if not body then
    error("could not search MetaCPAN (curl exit " .. tostring(code) .. ")", 0)
  end
  local rows, seen = {}, {}
  for _, suggestion in ipairs(type(body.suggestions) == "table" and body.suggestions or {}) do
    local dist, release = suggestion.distribution, suggestion.release
    if type(dist) == "string" and type(release) == "string" and not seen[dist] then
      seen[dist] = true
      rows[#rows + 1] = { name = dist, version = release:sub(#dist + 2) }
    end
  end
  return rows
end

--- The docset for the latest release of a distribution. A module name
--- ("Moose::Role") is read as the distribution it is usually the main module
--- of ("Moose-Role").
---@param name string
---@param system fun(cmd: string[]): vim.SystemCompleted
---@return string docset e.g. "Moose~2.4000"
function M.resolve(name, system)
  local dist = name:gsub("::", "-")
  local release = get("release/" .. vim.uri_encode(dist, "rfc2396"), system)
  if not (release and type(release.name) == "string" and type(release.distribution) == "string") then
    error("no distribution " .. dist .. " on MetaCPAN", 0)
  end
  -- the version as the release is named ("perl-5.44.0"), which is what a
  -- search row shows; the record's own version field may be numified
  -- ("5.044000")
  local prefix = release.distribution .. "-"
  if release.name:sub(1, #prefix) ~= prefix then
    error("MetaCPAN named the latest release of " .. dist .. " " .. release.name, 0)
  end
  return release.distribution .. "~" .. release.name:sub(#prefix + 1)
end

local function split_docset(docset)
  local dist, version = docset:match("^(.+)~([%w%.%-_]+)$")
  if not dist then
    error("a metacpan.org docset is <distribution>~<version>, got " .. docset, 0)
  end
  return dist, version
end

--- The release a docset holds: it is named for the exact version it came from.
---@param docset string e.g. "Moose~2.4000"
function M.release(docset)
  local _, version = split_docset(docset)
  return version
end

--- The docset MetaCPAN offers for this distribution today; comparing it with
--- the docset's own name is how an update is noticed.
---@param docset string
---@param system fun(cmd: string[]): vim.SystemCompleted
function M.latest(docset, system)
  return M.resolve((split_docset(docset)), system)
end

-- ------------------------------------------------------- the release

--- Who uploaded this version of the distribution. A release is named
--- "<distribution>-<version>"; an upload by someone without permission on the
--- distribution comes last.
local function find_release(dist, version, system)
  local releases = query("release", {
    size = 10,
    _source = { "name", "author", "authorized" },
    query = { bool = { must = { { term = { name = dist .. "-" .. version } } } } },
  }, system)
  table.sort(releases, function(a, b)
    return a.authorized == true and b.authorized ~= true
  end)
  local release = releases[1]
  if not (release and type(release.name) == "string" and type(release.author) == "string") then
    error("MetaCPAN has no release " .. version .. " of " .. dist, 0)
  end
  return release
end

--- The documented files of a release, one per module name: where two files
--- document the same name (a script and its module), the one under lib/ wins,
--- then the shorter path.
---@return { module: string, key: string, path: string }[]
local function documented_files(release, system)
  local files = query("file", {
    size = most_files,
    _source = { "documentation", "path" },
    query = {
      bool = {
        must = {
          { term = { release = release.name } },
          { term = { author = release.author } },
          { exists = { field = "documentation" } },
          { term = { indexed = true } },
        },
      },
    },
  }, system)
  local function better(path, than)
    local in_lib, than_in_lib = path:match("^lib/") ~= nil, than:match("^lib/") ~= nil
    if in_lib ~= than_in_lib then
      return in_lib
    end
    if #path ~= #than then
      return #path < #than
    end
    return path < than
  end
  local best = {}
  for _, file in ipairs(files) do
    local module, path = file.documentation, file.path
    if type(module) == "string" and type(path) == "string" then
      local held = best[module]
      if not held or better(path, held.path) then
        best[module] = { module = module, key = (module:gsub("::", "/")), path = path }
      end
    end
  end
  local out = vim.tbl_values(best)
  table.sort(out, function(a, b)
    return a.key < b.key
  end)
  return out
end

-- ------------------------------------------------------------ the pages

--- A top-level section's title as an entry type: POD writes them in capitals
--- ("EXPORTED FUNCTIONS"), the pickers show "Exported Functions".
local function section_type(title)
  if title ~= title:upper() then
    return title
  end
  return (title:lower():gsub("(%w)(%w*)", function(first, rest)
    return first:upper() .. rest
  end))
end

--- A POD page ready for the installer, and what it holds: the table of
--- contents goes, and every heading and =item keeps one id -- the short one
--- POD nests inside it when no other heading of the page has it -- written as
--- plain text. MetaCPAN writes an id escaped ("&#39;#&#39;-not-allowed") and
--- a link to it decoded ("'#'-not-allowed"), and the installer splits a link
--- on every "#", so a "#" or a character that needs escaping becomes "-".
--- `renamed` says which id each old one (decoded) became, so links can follow.
---@return string html, { id: string, text: string, section: string }[] headings, table<string, string> renamed
local function name_the_headings(fragment)
  local body = fragment:gsub("^%s*<nav>.-</nav>", "")
  local taken = {}
  for tag, id in body:gmatch('<(%w+) id="([^"]*)">') do
    if tag:match("^h%d$") or tag == "dt" then
      taken[html_text.decode_entities(id)] = true
    end
  end
  local function plain_id(id)
    local plain = id:gsub('[#"<>&%s]', "-")
    if plain ~= id then
      while taken[plain] do
        plain = plain .. "-"
      end
      taken[plain] = true
    end
    return plain
  end
  -- the text of the heading last seen at each level: an entry's type is the
  -- heading holding it
  local open = {}
  local headings, renamed = {}, {}
  body = body:gsub('<(%w+) id="([^"]*)">(.-)</%1>', function(tag, id, inner)
    local level = tonumber(tag:match("^h(%d)$"))
    if not level and tag ~= "dt" then
      return nil
    end
    id = html_text.decode_entities(id)
    local short = inner:match('^%s*<a id="([^"]*)"></a>')
    short = short and html_text.decode_entities(short)
    inner = inner:gsub('<a id="[^"]*"></a>', "")
    local chosen = id
    if short and not taken[short] then
      chosen = short
      taken[short] = true
    end
    chosen = plain_id(chosen)
    renamed[id] = chosen
    local text = html_text.text(inner)
    local holder
    for above = (level or 7) - 1, 1, -1 do
      holder = holder or open[above]
    end
    if level then
      open[level] = text
      for below = level + 1, 6 do
        open[below] = nil
      end
    end
    if level ~= 1 and text ~= "" then
      headings[#headings + 1] = { id = chosen, text = text, section = holder and section_type(holder) or "Sections" }
    end
    return "<" .. tag .. ' id="' .. chosen .. '">' .. inner .. "</" .. tag .. ">"
  end)
  return body, headings, renamed
end

local function url_decode(text)
  return (text:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

--- Every link of a page, rewritten: one to a module of the docset (by name,
--- or by its file in the release) names that page, one within the page follows
--- its heading's new id, and any other one stays an address on metacpan.org.
---@param page { key: string, html: string, renamed: table<string, string> }
---@param pages table<string, { renamed: table<string, string> }> by key
---@param key_of_path table<string, string> a documented file's key, by path
local function rewrite_links(page, pages, key_of_path, known)
  local dir = page.key:match("^(.*)/[^/]*$") or ""
  local function anchor_in(key, anchor)
    if anchor == "" then
      return ""
    end
    local id = url_decode(anchor:sub(2))
    -- an id the page no longer has (perldiag renames its messages) is made
    -- plain like the ids it does have, so the link still opens the page
    return "#" .. (pages[key].renamed[id] or id:gsub('[#"<>&%s]', "-")):gsub("%%", "%%25")
  end
  local html = page.html:gsub('href="#([^"]*)"', function(anchor)
    return 'href="' .. anchor_in(page.key, "#" .. anchor) .. '"'
  end)
  html = html:gsub('href="https://metacpan%.org/pod/([^"#]*)(#?[^"]*)"', function(target, anchor)
    target = url_decode(target)
    local key = key_of_path[target:match("^distribution/[^/]+/(.+)$") or target:match("^release/[^/]+/[^/]+/(.+)$") or ""]
      or target:gsub("::", "/")
    if pages[key] then
      return 'href="' .. links.relative(dir, key) .. anchor_in(key, anchor) .. '"'
    end
    return nil
  end)
  return links.rewrite_html(html, { dir = dir, known = known, base = site })
end

-- What each install read in index, kept for its db call.
local read = {}

--- The release's documented modules, fetched a page each, their headings named.
local function read_release(docset, system, report)
  local dist, version = split_docset(docset)
  local release = find_release(dist, version, system)
  local files = documented_files(release, system)
  if #files == 0 then
    error("MetaCPAN holds no documentation for " .. release.name, 0)
  end
  local requests = {}
  for _, file in ipairs(files) do
    requests[#requests + 1] = {
      key = file.key,
      url = api .. "pod/" .. release.author .. "/" .. release.name .. "/" .. file.path .. "?content-type=text/html",
    }
  end
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local fetched = fetching.pages(requests, dir, system, report)
  local pages = {}
  for _, file in ipairs(files) do
    local path = fetched[file.key]
    if path then
      local handle = assert(io.open(path, "r"))
      local body, headings, renamed = name_the_headings(handle:read("*a"))
      handle:close()
      pages[#pages + 1] = { key = file.key, module = file.module, path = file.path, html = body, headings = headings, renamed = renamed }
    end
  end
  vim.fn.delete(dir, "rf")
  return pages
end

function M.index(docset, _, system, report)
  read[docset] = read_release(docset, system, report)
  local entries = {}
  for _, page in ipairs(read[docset]) do
    entries[#entries + 1] = { name = page.module, path = page.key, type = "Modules" }
    for _, heading in ipairs(page.headings) do
      entries[#entries + 1] = {
        name = page.module .. " " .. heading.text,
        path = page.key .. "#" .. heading.id,
        type = heading.section,
      }
    end
  end
  return { entries = entries }
end

function M.db(docset, _, system, report)
  local pages = read[docset] or read_release(docset, system, report)
  read[docset] = nil
  local by_key, key_of_path, known = {}, {}, {}
  for _, page in ipairs(pages) do
    by_key[page.key] = page
    key_of_path[page.path] = page.key
    known[page.key] = true
  end
  local db = {}
  for _, page in ipairs(pages) do
    db[page.key] = rewrite_links(page, by_key, key_of_path, known)
  end
  return db
end

M._internal = { name_the_headings = name_the_headings }

return M
