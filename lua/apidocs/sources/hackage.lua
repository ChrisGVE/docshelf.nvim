-- The Hackage source adapter (Haskell packages, hackage.haskell.org).
--
-- Hackage publishes each package version's Haddock output as one archive,
-- /package/<name>-<version>/docs.tar: a page per module plus doc-index.json,
-- which lists every documented name with its module and `Page.html#anchor`.
-- This adapter turns that into the index/db pair the installer expects (see
-- sources/devdocs.lua):
--   * a docset is "<name>~<version>" (text~2.1.2);
--   * each module page is an entry named after the module (Data.Text), and
--     each documented name an entry qualified by it (Data.Text.pack), typed
--     "Types" (t: anchors) or "Values" (v: anchors);
--   * pages lose Haddock's chrome (package header, contents list, synopsis,
--     footer, scripts, Source and # links), links between modules become page
--     keys, and links elsewhere on Hackage become absolute addresses.
local M = {}

M.origin = "hackage.haskell.org"

local base = "https://hackage.haskell.org"

local function docs_url(package_version)
  return base .. "/package/" .. package_version .. "/docs.tar"
end

--- The docset for a package's newest version that has documentation built.
--- Hackage lists versions newest first; recent uploads may not be built yet.
---@param name string package name, e.g. "text"
---@param system fun(cmd: string[]): vim.SystemCompleted
---@return string docset e.g. "text~2.1.2"
function M.resolve(name, system)
  local res = system({ "curl", "-sfL", "-H", "Accept: application/json", base .. "/package/" .. name .. "/preferred" })
  if res.code == 0 then
    for _, version in ipairs(vim.json.decode(res.stdout)["normal-version"] or {}) do
      if system({ "curl", "-sfIL", docs_url(name .. "-" .. version) }).code == 0 then
        return name .. "~" .. version
      end
    end
  end
  error("no documentation on Hackage for " .. name, 0)
end

local function split_docset(docset)
  local name, version = docset:match("^(.+)~([%d%.]+)$")
  if not name then
    error("a Hackage docset is <package>~<version>, got " .. docset, 0)
  end
  return name, version
end

local function read_file(path)
  local file = assert(io.open(path, "r"))
  local contents = file:read("*a")
  file:close()
  return contents
end

-- The extracted docs folder of the last download, kept between the index and
-- db calls of one install.
local downloaded = {}

local function download(docset, system)
  local name, version = split_docset(docset)
  local package_version = name .. "-" .. version
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local tar = dir .. "/docs.tar"
  if system({ "curl", "-sfL", "-o", tar, docs_url(package_version) }).code ~= 0 then
    error("no documentation on Hackage for " .. package_version, 0)
  end
  if system({ "tar", "-xf", tar, "-C", dir }).code ~= 0 then
    error("could not unpack " .. docs_url(package_version), 0)
  end
  -- the archive holds one folder, <package>-<version>-docs
  local folder = vim.fn.glob(dir .. "/*-docs", false, true)[1]
  if not folder then
    error("unexpected archive layout in " .. docs_url(package_version), 0)
  end
  return { folder = folder, package_version = package_version }
end

--- Module pages: every top-level .html page but the name index.
local function module_pages(folder)
  local pages = {}
  for file, kind in vim.fs.dir(folder) do
    if kind == "file" and file:match("%.html$") and not file:match("^doc%-index") then
      pages[#pages + 1] = file:gsub("%.html$", "")
    end
  end
  table.sort(pages)
  return pages
end

local function module_name(page)
  return (page:gsub("%-", "."))
end

function M.index(docset, _, system)
  local docs = download(docset, system)
  downloaded[docset] = docs
  local entries = {}
  for _, page in ipairs(module_pages(docs.folder)) do
    entries[#entries + 1] = { name = module_name(page), path = page, type = "Modules" }
  end
  local names = vim.json.decode(read_file(docs.folder .. "/doc-index.json"))
  for _, item in ipairs(names) do
    local page, anchor = item.link:match("^(.-)%.html#(.+)$")
    if page then
      entries[#entries + 1] = {
        name = item.module .. "." .. item.name,
        path = page .. "#" .. anchor,
        type = anchor:match("^t:") and "Types" or "Values",
      }
    end
  end
  return { entries = entries }
end

-- Remove every <div id="<id>">...</div> block, nesting included.
local function drop_div(html, id)
  local start = html:find('<div id="' .. id .. '"', 1, true)
  if not start then
    return html
  end
  local depth, pos = 0, start
  while true do
    local open_at = html:find("<div[ >]", pos)
    local close_at, close_end = html:find("</div>", pos, true)
    if not close_at then
      return html
    end
    if open_at and open_at < close_at then
      depth = depth + 1
      pos = open_at + 1
    else
      depth = depth - 1
      pos = close_end + 1
      if depth == 0 then
        return html:sub(1, start - 1) .. html:sub(close_end + 1)
      end
    end
  end
end

-- The rewritten address of a link, or nil when it points at a module page the
-- archive does not have (Haddock links qualified-import aliases such as T.html).
local function rewrite_href(href, package_version, modules)
  if href:match("^%a[%w+.-]*:") or href:match("^#") then
    return href
  end
  if href:match("^/") then
    return base .. href
  end
  if href:match("^src/") then
    return base .. "/package/" .. package_version .. "/docs/" .. href
  end
  -- another module of this package: Page.html[#anchor] -> Page[#anchor]
  local page, rest = href:match("^([^/#]+)%.html(.*)$")
  if not page then
    return href
  end
  return modules[page] and (page .. rest) or nil
end

local function clean_page(html, package_version, modules)
  local body = html:match("<body[^>]*>(.*)</body>") or html
  for _, id in ipairs({ "package-header", "table-of-contents", "synopsis", "footer" }) do
    body = drop_div(body, id)
  end
  body = body
    :gsub("<script.-</script>", "")
    :gsub('<a href="[^"]*" class="link">Source</a>', "")
    :gsub('<a href="[^"]*" class="selflink">#</a>', "")
  return (
    body:gsub(' ?href="([^"]*)"', function(href)
      local target = rewrite_href(href, package_version, modules)
      return target and (' href="' .. target .. '"') or ""
    end)
  )
end

function M.db(docset, _, system)
  local docs = downloaded[docset] or download(docset, system)
  downloaded[docset] = nil
  local db = {}
  local pages = module_pages(docs.folder)
  local modules = {}
  for _, page in ipairs(pages) do
    modules[page] = true
  end
  for _, page in ipairs(pages) do
    db[page] = clean_page(read_file(docs.folder .. "/" .. page .. ".html"), docs.package_version, modules)
  end
  vim.fn.delete(vim.fs.dirname(docs.folder), "rf")
  return db
end

return M
