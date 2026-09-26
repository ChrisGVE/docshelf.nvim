--- Reading a Dash docset: the archive format Kapeli's feeds and the
--- user-contributed feeds both ship (sources/dash.lua and
--- sources/dash_contrib.lua say where each is downloaded from).
---
--- A docset archive (.tgz) holds one <Name>.docset folder:
---   Contents/Info.plist                 the docset's display name
---   Contents/Resources/docSet.dsidx     SQLite: what is documented, and where
---   Contents/Resources/Documents/**     the pages, as the site wrote them
---
--- The index comes in two layouts, told apart by its tables, and both are read
--- with the sqlite3 program:
---   * searchIndex(name, type, path), path = "page.html#anchor" -- what
---     user-contributed docsets and most generated ones use;
---   * Core Data (ZTOKEN and its tables), anchor held apart from the path --
---     what Kapeli's own docsets use.
---
--- Dash marks an entry's place with <a class="dashAnchor"
--- name="//apple_ref/<type>/<name>"></a>. The installer finds an anchor by its
--- `id`, so every such mark -- and every older <a name="..."> an in-page link
--- may point at -- becomes an id. Links go through docshelf.links with no base:
--- an archive has no site behind it, so a link to a page it does not hold
--- keeps its text and loses the link.
local M = {}

local html_text = require("docshelf.html")
local links = require("docshelf.links")

--- A Dash version as a docset folder can carry it. Kapeli writes
--- "<version>/<build>" when a docset is rebuilt ("1.0.1/0"), and sometimes
--- the build alone ("/8.5_bf6e24"); the version is what a reader asks for, so
--- it wins, and anything a folder name should not hold becomes "_".
---@param version string?
---@return string
function M.release(version)
  version = version or ""
  local before, after = version:match("^([^/]*)/(.*)$")
  if before then
    version = before ~= "" and before or after
  end
  version = version:gsub("[^%w._+-]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  return version ~= "" and version or "latest"
end

-- The unpacked archive of the last download, kept between the index and db
-- calls of one install.
local downloaded = {}

local function download(url, system)
  if vim.fn.executable("sqlite3") ~= 1 then
    error("the 'sqlite3' program must be installed to read Dash docsets", 0)
  end
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local archive = dir .. "/docset.tgz"
  if system({ "curl", "-sfL", "-o", archive, url }).code ~= 0 then
    vim.fn.delete(dir, "rf")
    error("could not download " .. url, 0)
  end
  if system({ "tar", "-xzf", archive, "-C", dir }).code ~= 0 then
    vim.fn.delete(dir, "rf")
    error("could not unpack " .. url, 0)
  end
  local docset = vim.fn.glob(dir .. "/*.docset", false, true)[1] or vim.fn.glob(dir .. "/*/*.docset", false, true)[1]
  if not docset then
    vim.fn.delete(dir, "rf")
    error("no .docset folder in " .. url, 0)
  end
  return {
    dir = dir,
    documents = docset .. "/Contents/Resources/Documents",
    dsidx = docset .. "/Contents/Resources/docSet.dsidx",
  }
end

local function held(docset, url, system)
  downloaded[docset] = downloaded[docset] or download(url, system)
  return downloaded[docset]
end

--- Drop what an index call downloaded, when no db call will follow.
function M.forget(docset)
  local docs = downloaded[docset]
  downloaded[docset] = nil
  if docs then
    vim.fn.delete(docs.dir, "rf")
  end
end

local function page_key(path)
  return (path:gsub("%.html?$", ""))
end

--- A stub whose only job is to send the browser on -- Kapeli's archives open
--- on a mirroring tool's -- documents nothing, and its link would point at
--- whatever it refreshes to. HTTrack writes the refresh in the body, 5 KB in,
--- so the scan reads a stub's worth rather than the head alone.
local function is_redirect(file)
  local handle = io.open(file, "r")
  if not handle then
    return false
  end
  local start = (handle:read(16384) or ""):lower()
  handle:close()
  return start:find('<meta[^>]*http%-equiv="refresh"') ~= nil
end

--- Every page under Documents, by key: its path without ".html".
local function page_files(documents)
  local found = {}
  local function walk(dir, prefix)
    for entry, kind in vim.fs.dir(dir) do
      if kind == "directory" then
        walk(dir .. "/" .. entry, prefix .. entry .. "/")
      elseif entry:match("%.html?$") and not is_redirect(dir .. "/" .. entry) then
        found[page_key(prefix .. entry)] = dir .. "/" .. entry
      end
    end
  end
  walk(documents, "")
  return found
end

local function query(dsidx, sql, system)
  local res = system({ "sqlite3", "-json", dsidx, sql })
  if res.code ~= 0 then
    error("could not read the docset index: " .. (res.stderr or ""), 0)
  end
  if not res.stdout or res.stdout:match("^%s*$") then
    return {}
  end
  return vim.json.decode(res.stdout)
end

local core_data_rows = [[
SELECT ztokenname AS name, ztypename AS type, zpath AS path, zanchor AS anchor
FROM ztoken
JOIN ztokenmetainformation m ON ztoken.zmetainformation = m.z_pk
JOIN zfilepath f ON m.zfile = f.z_pk
JOIN ztokentype t ON ztoken.ztokentype = t.z_pk]]

--- The rows of either index layout, as { name, type, path, anchor? }.
local function index_rows(dsidx, system)
  local tables = query(dsidx, "SELECT name FROM sqlite_master WHERE type = 'table'", system)
  for _, t in ipairs(tables) do
    if t.name == "searchIndex" then
      return query(dsidx, "SELECT name, type, path FROM searchIndex", system)
    end
  end
  return query(dsidx, core_data_rows, system)
end

--- The installer's path for an index row -- "key" or "key#anchor" -- or nil
--- when the row points at nothing the archive holds (a web address, a page
--- left out of the build).
local function entry_path(row, known)
  local path = (row.path or ""):gsub("<dash_entry_[^>]*>", "")
  if row.anchor and row.anchor ~= vim.NIL and row.anchor ~= "" then
    path = path .. "#" .. row.anchor
  end
  if path:match("^%a[%w+.-]*:") then
    return nil
  end
  local page, anchor = path:match("^([^#]*)(#?.*)$")
  local key = page_key(links.resolve("", vim.uri_decode((page:gsub("%?.*$", "")))))
  if not known[key] then
    return nil
  end
  return key .. anchor
end

--- Whether `text` is valid UTF-8. vim.iconv cannot tell: it substitutes
--- rather than failing.
local function is_utf8(text)
  local i = 1
  while i <= #text do
    local byte = text:byte(i)
    local length = byte < 0x80 and 1
      or (byte >= 0xC2 and byte <= 0xDF) and 2
      or (byte >= 0xE0 and byte <= 0xEF) and 3
      or (byte >= 0xF0 and byte <= 0xF4) and 4
    if not length then
      return false
    end
    for j = i + 1, i + length - 1 do
      local continuation = text:byte(j)
      if not continuation or continuation < 0x80 or continuation > 0xBF then
        return false
      end
    end
    i = i + length
  end
  return true
end

--- A page's own title, or its key when it has none. Older pages are written
--- in Latin-1 (Lua 5.1's Portuguese manual): a title that is not UTF-8 is
--- read as that, since it becomes a name in the pickers and a file name.
local function page_title(file, key)
  local handle = io.open(file, "r")
  local head = handle and handle:read(4096) or ""
  if handle then
    handle:close()
  end
  local title = head:match("<[tT][iI][tT][lL][eE][^>]*>(.-)</[tT][iI][tT][lL][eE]>")
  title = title and vim.trim(title:gsub("%s+", " ")) or ""
  if not is_utf8(title) then
    title = vim.iconv(title, "latin1", "utf-8") or ""
  end
  title = html_text.decode_entities(title)
  return title ~= "" and title or key
end

--- The index/db pair's first half (see sources/devdocs.lua) for the archive
--- at `url`, installed as `docset`. Every page is an entry too: the installer
--- only resolves a link to a page that is one, and Dash indexes anchors, so a
--- link to "index#core.emerg" would otherwise lead nowhere.
function M.index(docset, url, system)
  local docs = held(docset, url, system)
  local known = page_files(docs.documents)
  local entries, listed = {}, {}
  for _, row in ipairs(index_rows(docs.dsidx, system)) do
    local path = entry_path(row, known)
    if path and type(row.name) == "string" then
      entries[#entries + 1] = { name = row.name, path = path, type = row.type ~= vim.NIL and row.type or "Entries" }
      listed[path] = true
    end
  end
  for key, file in pairs(known) do
    if not listed[key] then
      entries[#entries + 1] = { name = page_title(file, key), path = key, type = "Pages" }
    end
  end
  return { entries = entries }
end

--- Dash's entry marks, and any older named anchor, as ids.
local function anchors_as_ids(html)
  return (
    html:gsub("<([aA])(%s[^>]*)>", function(tag, attributes)
      local name = attributes:match('%s[nN][aA][mM][eE]="([^"]*)"')
      if not name or attributes:match('%s[iI][dD]="') then
        return nil
      end
      if attributes:match('class="dashAnchor"') then
        return "<" .. tag .. ' id="' .. name .. '">'
      end
      return "<" .. tag .. attributes:gsub('(%s)[nN][aA][mM][eE]="', '%1id="', 1) .. ">"
    end)
  )
end

local function clean_page(html, key, known)
  -- tag names in any case, as for links
  local body = html:match("<[bB][oO][dD][yY][^>]*>(.*)</[bB][oO][dD][yY]>") or html
  body = body
    :gsub("<[sS][cC][rR][iI][pP][tT].-</[sS][cC][rR][iI][pP][tT]>", "")
    :gsub("<[sS][tT][yY][lL][eE].-</[sS][tT][yY][lL][eE]>", "")
    -- the "¶" a Sphinx theme puts beside every heading links to the heading
    -- itself; doc2dash builds many contributed docsets from Sphinx sites
    :gsub('<a class="headerlink"[^>]*>.-</a>', "")
  body = anchors_as_ids(body)
  return links.rewrite_html(body, {
    dir = key:match("^(.*)/[^/]*$") or "",
    known = known,
    key_of = function(path)
      local key_ = page_key(vim.uri_decode(path)):gsub("/$", "")
      if not known[key_] and known[key_ .. "/index"] then
        return key_ .. "/index"
      end
      return key_
    end,
  })
end

--- The index/db pair's second half: every page of the archive, cleaned. The
--- unpacked archive is removed once read.
function M.db(docset, url, system)
  local docs = held(docset, url, system)
  downloaded[docset] = nil
  local files = page_files(docs.documents)
  local known = {}
  for key in pairs(files) do
    known[key] = true
  end
  local db = {}
  for key, path in pairs(files) do
    local file = io.open(path, "r")
    if file then
      db[key] = clean_page(file:read("*a"), key, known)
      file:close()
    end
  end
  vim.fn.delete(docs.dir, "rf")
  return db
end

--- A docset's name and release: "<name>~<release>" (Lua~5.5).
---@param docset string
---@param source string what to call the source in an error
---@return string name, string release
function M.split(docset, source)
  local name, release = docset:match("^(.+)~([^~]+)$")
  if not name then
    error("a " .. source .. " docset is <name>~<version>, got " .. docset, 0)
  end
  return name, release
end

--- How many bytes the archive at `url` is, from the headers a HEAD request
--- answers with; nil when the server does not answer or names no length. A
--- redirect answers twice, so the last length named is the archive's own.
---@param url string
---@param system fun(cmd: string[]): vim.SystemCompleted
---@return integer?
function M.archive_size(url, system)
  local res = system({ "curl", "-sfIL", url })
  if res.code ~= 0 then
    return nil
  end
  local size
  for length in (res.stdout or ""):lower():gmatch("content%-length:%s*(%d+)") do
    size = tonumber(length)
  end
  return size
end

--- The index/db pair of a source whose docsets are Dash archives.
--- `archive_url(docset, system)` says where a docset's archive is; it is
--- asked once per install, by index, and its answer reused by db.
---@param archive_url fun(docset: string, system: function): string
---@return function index, function db
function M.installer(archive_url)
  local urls = {}
  local function index(docset, _, system)
    urls[docset] = archive_url(docset, system)
    return M.index(docset, urls[docset], system)
  end
  local function db(docset, _, system)
    local url = urls[docset] or archive_url(docset, system)
    urls[docset] = nil
    return M.db(docset, url, system)
  end
  return index, db
end

return M
