-- The docs.rs source adapter (Rust crates).
--
-- docs.rs builds rustdoc for every crate on crates.io and offers the whole
-- build as one zip, /crate/<name>/<version>/download. Inside it, a page per
-- documented item under the crate's own folder, named for what it documents
-- (serde/de/trait.Error.html), plus rustdoc's own machinery -- the search
-- index, trait implementation lists, source listings -- which a reader in a
-- buffer has no use for.
--
-- This adapter turns that into the index/db pair the installer expects (see
-- sources/devdocs.lua):
--   * a docset is "<crate>~<version>" (serde~1.0.229);
--   * every page is an entry named by its Rust path (serde::de::Error), typed
--     from the file name's own prefix (trait., struct., fn.);
--   * pages keep only <section id="main-content">, links between pages become
--     page keys, and links to rustdoc's static files or to another crate
--     become absolute addresses on docs.rs.
--
-- Versions come from crates.io, not from docs.rs: its API answers a search
-- with each crate's newest stable release, so a row picked in the install
-- picker already knows which version to fetch.
local M = {}

M.origin = "docs.rs"

-- docs.rs documents one language, so a picker narrowed to Rust asks it and a
-- picker narrowed to anything else leaves it alone.
M.language = "Rust"

local base = "https://docs.rs"
local registry = "https://crates.io/api/v1/crates"

-- crates.io asks for a real user agent and refuses anonymous ones.
local user_agent = "apidocs.nvim (https://github.com/emmanueltouzery/apidocs.nvim)"

local function fetch_json(url, system)
  local res = system({ "curl", "-sfL", "-A", user_agent, url })
  if res.code ~= 0 then
    error("request failed (curl exit " .. tostring(res.code) .. "): " .. url, 0)
  end
  local ok, body = pcall(vim.json.decode, res.stdout)
  if not ok then
    error("crates.io answered " .. url .. " with something that is not JSON", 0)
  end
  return body
end

--- The crates whose name or description matches `query`, in crates.io's own
--- order of relevance. Each row carries the newest stable release, so nothing
--- has to be resolved when one is picked.
---@param query string
---@param system fun(cmd: string[]): vim.SystemCompleted
---@return { name: string, version: string }[]
function M.search(query, system)
  local body = fetch_json(registry .. "?per_page=30&q=" .. vim.uri_encode(query), system)
  if type(body) ~= "table" or not vim.islist(body.crates) then
    error("crates.io answered a search with something other than a list of crates", 0)
  end
  local rows = {}
  for _, crate in ipairs(body.crates) do
    local version = crate.max_stable_version or crate.max_version
    if type(crate.name) == "string" and type(version) == "string" then
      rows[#rows + 1] = { name = crate.name, version = version }
    end
  end
  return rows
end

--- The docset for a crate's newest stable release.
---@param name string
---@param system fun(cmd: string[]): vim.SystemCompleted
---@return string docset e.g. "serde~1.0.229"
function M.resolve(name, system)
  local body = fetch_json(registry .. "/" .. name, system)
  local crate = type(body) == "table" and body.crate
  local version = type(crate) == "table" and (crate.max_stable_version or crate.max_version)
  if type(version) ~= "string" then
    error("no crate named " .. name .. " on crates.io", 0)
  end
  return name .. "~" .. version
end

local function split_docset(docset)
  local name, version = docset:match("^(.+)~([%w%.%-%+]+)$")
  if not name then
    error("a docs.rs docset is <crate>~<version>, got " .. docset, 0)
  end
  return name, version
end

--- The release a docset holds: it is named for the exact version it was built
--- from, so there is nothing to look up.
---@param docset string e.g. "serde~1.0.229"
function M.release(docset)
  local _, version = split_docset(docset)
  return version
end

-- The rustdoc file-name prefixes, and what the installer should call them.
-- A page whose prefix is not here is still offered, under its own prefix.
local kinds = {
  struct = "Structs",
  trait = "Traits",
  enum = "Enums",
  fn = "Functions",
  macro = "Macros",
  derive = "Derive Macros",
  attr = "Attribute Macros",
  type = "Type Aliases",
  constant = "Constants",
  static = "Statics",
  union = "Unions",
  primitive = "Primitives",
}

-- rustdoc's own machinery, which is of no use to a reader in a buffer.
local not_documentation = {
  ["all.html"] = true,
  ["help.html"] = true,
  ["settings.html"] = true,
}

-- The extracted build of the last download, kept between the index and db
-- calls of one install.
local downloaded = {}

local function read_file(path)
  local file = assert(io.open(path, "r"))
  local contents = file:read("*a")
  file:close()
  return contents
end

--- A crate's pages live under a folder named after it, with dashes turned into
--- underscores -- the crate's own Rust path root (serde_json, not serde-json).
local function crate_root(folder, name)
  local underscored = name:gsub("%-", "_")
  if vim.fn.isdirectory(folder .. "/" .. underscored) == 1 then
    return underscored
  end
  -- A crate whose lib is named something else entirely: take the only folder
  -- that is not rustdoc's machinery.
  for entry, kind in vim.fs.dir(folder) do
    if kind == "directory" and not entry:match("^src$") and not entry:match("%.") then
      return entry
    end
  end
  error("no documentation folder in the docs.rs build of " .. name, 0)
end

local function download(docset, system)
  local name, version = split_docset(docset)
  local url = base .. "/crate/" .. name .. "/" .. version .. "/download"
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local zip = dir .. "/docs.zip"
  if system({ "curl", "-sfL", "-A", user_agent, "-o", zip, url }).code ~= 0 then
    error("no documentation on docs.rs for " .. name .. " " .. version, 0)
  end
  if system({ "unzip", "-qq", "-o", zip, "-d", dir }).code ~= 0 then
    error("could not unpack " .. url, 0)
  end
  return { folder = dir, root = crate_root(dir, name), name = name, version = version }
end

--- Every documented page, as { path = "de/trait.Error", file = <absolute>,
--- name = "serde::de::Error", type = "Traits" }. `path` comes from the file
--- name, never from the Rust path: rustdoc writes both
--- macro.forward_to_deserialize_any.html and macro.…!.html, which document the
--- same item and would otherwise collide.
local function pages(docs)
  local root = docs.folder .. "/" .. docs.root
  local found = {}
  local function walk(dir, prefix)
    for entry, kind in vim.fs.dir(dir) do
      if kind == "directory" then
        walk(dir .. "/" .. entry, prefix .. entry .. "/")
      elseif entry:match("%.html$") and not not_documentation[entry] then
        local segments = vim.split(docs.root .. "/" .. prefix, "/", { trimempty = true })
        local item, label
        if entry == "index.html" then
          item, label = nil, "Modules"
        else
          local kind_name, name = entry:match("^([%a_]+)%.(.*)%.html$")
          item = name or entry:gsub("%.html$", "")
          label = kinds[kind_name] or kind_name or "Pages"
        end
        if item then
          segments[#segments + 1] = item
        end
        found[#found + 1] = {
          path = prefix .. entry:gsub("%.html$", ""),
          file = dir .. "/" .. entry,
          name = table.concat(segments, "::"),
          type = label,
        }
      end
    end
  end
  walk(root, "")
  table.sort(found, function(a, b)
    return a.path < b.path
  end)
  return found
end

function M.index(docset, _, system)
  local docs = downloaded[docset] or download(docset, system)
  downloaded[docset] = docs
  local entries = {}
  for _, page in ipairs(pages(docs)) do
    entries[#entries + 1] = { name = page.name, path = page.path, type = page.type }
  end
  return { entries = entries }
end

--- Resolve `href` against the directory of the page holding it, the way a
--- browser would: "../de/trait.Error.html" seen from "ser/trait.Serialize"
--- is "de/trait.Error.html".
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

--- Where a link should point once the page is a buffer. A link to another page
--- of this crate becomes that page's key; anything else -- rustdoc's static
--- files, the source listings, another crate -- becomes an address on docs.rs.
local function rewrite_href(href, dir, docs, known)
  if href:match("^%a[%w+.-]*:") or href:match("^#") then
    return href
  end
  local crate_base = base .. "/" .. docs.name .. "/" .. docs.version .. "/"
  if href:match("^/") then
    return base .. href
  end
  local target, anchor = href:match("^([^#]*)(#?.*)$")
  local resolved = resolve_path(dir, target)
  local page = resolved:match("^(.*)%.html$")
  if page and known[page] then
    -- Page keys are relative to the crate folder, a resolved link is not.
    return page:sub(#docs.root + 2) .. anchor
  end
  return crate_base .. docs.root .. "/" .. resolved .. anchor
end

local function clean_page(html, dir, docs, known)
  -- Everything a reader wants is inside <section id="main-content">; the
  -- sidebar, the top bar and the search machinery come before it.
  local start = html:find('<section id="main%-content"')
  local body = start and html:sub(start) or html
  body = body:match("^(.*)</main>") or body
  body = body
    :gsub("<script.-</script>", "")
    :gsub('<a class="src rightside" href="[^"]*">Source</a>', "")
    :gsub('<a href="[^"]*" class="anchor">§</a>', "")
    :gsub('<a class="anchor" href="[^"]*">§</a>', "")
  return (
    body:gsub(' ?href="([^"]*)"', function(href)
      return ' href="' .. rewrite_href(href, dir, docs, known) .. '"'
    end)
  )
end

function M.db(docset, _, system)
  local docs = downloaded[docset] or download(docset, system)
  downloaded[docset] = nil
  local found = pages(docs)
  local known = {}
  for _, page in ipairs(found) do
    known[docs.root .. "/" .. page.path] = true
  end
  -- known keys are rooted at the crate folder, the way a resolved link is
  local db = {}
  for _, page in ipairs(found) do
    local dir = docs.root .. "/" .. (page.path:match("^(.*)/[^/]*$") or "")
    db[page.path] = clean_page(read_file(page.file), dir, docs, known)
  end
  return db
end

return M
