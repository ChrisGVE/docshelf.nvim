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

--- Every page under Documents, by key: its path without ".html".
local function page_files(documents)
  local found = {}
  local function walk(dir, prefix)
    for entry, kind in vim.fs.dir(dir) do
      if kind == "directory" then
        walk(dir .. "/" .. entry, prefix .. entry .. "/")
      elseif entry:match("%.html?$") then
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

--- The index/db pair's first half (see sources/devdocs.lua) for the archive
--- at `url`, installed as `docset`.
function M.index(docset, url, system)
  local docs = held(docset, url, system)
  local known = page_files(docs.documents)
  local entries = {}
  for _, row in ipairs(index_rows(docs.dsidx, system)) do
    local path = entry_path(row, known)
    if path and type(row.name) == "string" then
      entries[#entries + 1] = { name = row.name, path = path, type = row.type ~= vim.NIL and row.type or "Entries" }
    end
  end
  return { entries = entries }
end

--- Dash's entry marks, and any older named anchor, as ids.
local function anchors_as_ids(html)
  return (
    html:gsub("<a(%s[^>]*)>", function(attributes)
      local name = attributes:match('%sname="([^"]*)"')
      if not name or attributes:match('%sid="') then
        return nil
      end
      if attributes:match('class="dashAnchor"') then
        return '<a id="' .. name .. '">'
      end
      return "<a" .. attributes:gsub('(%s)name="', '%1id="', 1) .. ">"
    end)
  )
end

local function clean_page(html, key, known)
  local body = html:match("<body[^>]*>(.*)</body>") or html
  body = anchors_as_ids(body:gsub("<script.-</script>", ""):gsub("<style.-</style>", ""))
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

return M
