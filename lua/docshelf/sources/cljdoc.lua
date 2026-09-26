-- The cljdoc.org source adapter (Clojure and ClojureScript libraries).
--
-- cljdoc.org builds the documentation of the libraries on Clojars and Maven
-- Central, and hands each built version out whole (measured 2026-09-26,
-- ring-core 1.15.5 and core.async 1.10.874-alpha3):
--   * api/search?q=<query>              JSON, best match first:
--                                       { results = { { artifact-id, group-id,
--                                       version, … } } };
--   * d/<group>/<artifact>              a redirect to the version cljdoc shows
--                                       by default (not always the newest:
--                                       ring-core goes to 1.15.5 while search
--                                       names 2.0.0-alpha1);
--   * api/searchset/<g>/<a>/<v>         JSON naming every namespace, every def
--                                       (typed var, macro, protocol with its
--                                       members, multimethod) and every
--                                       section of every article;
--   * download/<g>/<a>/<v>              the offline bundle: a zip of the whole
--                                       documentation (ring-core 170 KB),
--                                       <artifact>-<version>/{index.html,
--                                       api/<namespace>.html, doc/<article>.html};
--   * a version not built yet answers 404 ("please request a build first").
-- robots.txt allows everything.
--
-- This adapter turns that into the index/db pair the installer expects (see
-- sources/devdocs.lua):
--   * a docset is "<artifact>@<group>~<version>" (ring-core@ring~1.15.5), as
--     for Maven Central: the artifact alone is ambiguous across groups;
--   * a page per HTML file of the bundle, keyed by its path without ".html"
--     (api/ring.util.response, doc/readme; the overview is "index");
--   * entries: each namespace, each def named "<namespace>/<name>" as Clojure
--     writes it, each protocol member, each article and each of its sections;
--   * links to a page of the docset name it; any other link is an address on
--     cljdoc.org.
--
-- Clojure names hold "!", "?", "<", ">" (core.async's ">!"), and cljdoc
-- writes them unescaped in ids ("&gt;!" in the page, "%3E!" in a link).
-- Every id is made plain by `anchors.hex_id`, as for gemdocs.org.
local anchors = require("docshelf.anchors")
local links = require("docshelf.links")

local M = {}

M.origin = "cljdoc.org"

M.language = "Clojure"

local site = "https://cljdoc.org/"

local user_agent = "docshelf.nvim (https://github.com/ChrisGVE/docshelf.nvim)"

local function curl(url, system)
  return system({ "curl", "-sfL", "-A", user_agent, url })
end

--- The libraries cljdoc.org finds for `query`, in its own order. A row has
--- no version: the one cljdoc shows by default is asked on pick.
---@param query string
---@param system fun(cmd: string[]): vim.SystemCompleted
---@return { name: string }[]
function M.search(query, system)
  local res = curl(site .. "api/search?q=" .. vim.uri_encode(query, "rfc2396"), system)
  if res.code ~= 0 then
    error("could not search cljdoc.org (curl exit " .. tostring(res.code) .. ")", 0)
  end
  local ok, found = pcall(vim.json.decode, res.stdout)
  if not ok or type(found) ~= "table" or not vim.islist(found.results or {}) then
    error("cljdoc.org answered a search with something other than a list of libraries", 0)
  end
  local rows, seen = {}, {}
  for _, library in ipairs(found.results or {}) do
    local artifact, group = library["artifact-id"], library["group-id"]
    if type(artifact) == "string" and type(group) == "string" and not seen[artifact .. "@" .. group] then
      seen[artifact .. "@" .. group] = true
      rows[#rows + 1] = { name = artifact .. "@" .. group }
    end
  end
  return rows
end

local function split_name(name)
  local artifact, group = name:match("^([^@~/]+)@([^@~/]+)$")
  if not artifact then
    error("a cljdoc.org docset is named artifact@group, got " .. name, 0)
  end
  return artifact, group
end

--- The docset for the version cljdoc.org shows `name` at: its address
--- answers with a redirect naming it.
---@param name string artifact@group
---@param system fun(cmd: string[]): vim.SystemCompleted
---@return string docset e.g. "ring-core@ring~1.15.5"
function M.resolve(name, system)
  local artifact, group = split_name(name)
  local library = site .. "d/" .. group .. "/" .. artifact
  local res = system({ "curl", "-s", "-A", user_agent, "-o", "/dev/null", "-w", "%{redirect_url}", library })
  local version = res.code == 0 and (res.stdout or ""):match("^" .. vim.pesc(library) .. "/([^/]+)/?$")
  if not version then
    error("cljdoc.org has no documentation for " .. name, 0)
  end
  return name .. "~" .. version
end

local function split_docset(docset)
  local name, version = docset:match("^(.+)~([^~]+)$")
  if not name or not name:find("@", 1, true) then
    error("a cljdoc.org docset is artifact@group~version, got " .. docset, 0)
  end
  local artifact, group = split_name(name)
  return artifact, group, version
end

--- The release a docset holds: it is named for the exact version it came from.
---@param docset string e.g. "ring-core@ring~1.15.5"
function M.release(docset)
  local _, _, version = split_docset(docset)
  return version
end

--- The docset cljdoc.org shows this library at today; comparing it with the
--- docset's own name is how an update is noticed.
---@param docset string
---@param system fun(cmd: string[]): vim.SystemCompleted
function M.latest(docset, system)
  local artifact, group = split_docset(docset)
  return M.resolve(artifact .. "@" .. group, system)
end

-- ------------------------------------------------------------ the index

local plain_id = anchors.hex_id

-- What cljdoc calls a def, in the pickers' words.
local def_types = {
  var = "Vars",
  macro = "Macros",
  protocol = "Protocols",
  multimethod = "Multimethods",
}

local function read_file(path)
  local handle = assert(io.open(path, "r"))
  local text = handle:read("*a")
  handle:close()
  return text
end

--- A page key and anchor from a search set path
--- ("/d/ring/ring-core/1.15.5/api/ring.util.response#redirect").
local function locate(path, prefix)
  if type(path) ~= "string" or path:sub(1, #prefix) ~= prefix then
    return nil
  end
  local key, anchor = path:sub(#prefix + 1):match("^([^#]+)#?(.*)$")
  return key, anchor
end

-- What each install read in index, kept for its db call.
local read = {}

local function read_library(docset, system)
  local artifact, group, version = split_docset(docset)
  local what = artifact .. "@" .. group .. " " .. version
  local release = group .. "/" .. artifact .. "/" .. version
  local res = curl(site .. "api/searchset/" .. release, system)
  local ok, set = pcall(vim.json.decode, res.code == 0 and res.stdout or "")
  if not ok or type(set) ~= "table" then
    error("cljdoc.org has not built the documentation of " .. what, 0)
  end

  if vim.fn.executable("unzip") ~= 1 then
    error("the 'unzip' program must be installed to read cljdoc.org documentation", 0)
  end
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local bundle = dir .. ".zip"
  if system({ "curl", "-sfL", "-A", user_agent, "-o", bundle, site .. "download/" .. release }).code ~= 0 then
    error("cljdoc.org has not built the documentation of " .. what, 0)
  end
  local unpacked = system({ "unzip", "-q", "-o", bundle, "*.html", "-d", dir }).code
  os.remove(bundle)
  if unpacked ~= 0 then
    vim.fn.delete(dir, "rf")
    error("could not unpack the cljdoc.org bundle of " .. what, 0)
  end
  -- the bundle holds one folder, <artifact>-<version>
  local root = vim.fn.glob(dir .. "/*/", false, true)[1] or dir .. "/"
  local pages = {}
  for _, file in ipairs(vim.fn.globpath(root, "**/*.html", false, true)) do
    pages[file:sub(#root + 1):gsub("%.html$", "")] = read_file(file)
  end
  vim.fn.delete(dir, "rf")

  local entries, names, seen = {}, {}, {}
  local function add(name, key, anchor, type)
    if not pages[key] or type == nil then
      return
    end
    local path = key
    if anchor and anchor ~= "" then
      local id = plain_id(anchor)
      names[key] = names[key] or {}
      names[key][id] = names[key][id] or name
      path = key .. "#" .. id
    end
    if not seen[path] then
      seen[path] = true
      entries[#entries + 1] = { name = name, path = path, type = type }
    end
  end

  local prefix = "/d/" .. release .. "/"
  for _, namespace in ipairs(set.namespaces or {}) do
    local key = locate(namespace.path, prefix)
    if key and type(namespace.name) == "string" then
      add(namespace.name, key, nil, "Namespaces")
    end
  end
  for _, def in ipairs(set.defs or {}) do
    local key, anchor = locate(def.path, prefix)
    if key and type(def.name) == "string" then
      local namespace = type(def.namespace) == "string" and def.namespace .. "/" or ""
      add(namespace .. def.name, key, anchor, def_types[def.type])
      for _, member in ipairs(type(def.members) == "table" and def.members or {}) do
        local member_key, member_anchor = locate(member.path, prefix)
        if member_key and type(member.name) == "string" then
          add(namespace .. member.name, member_key, member_anchor, "Protocol Methods")
        end
      end
    end
  end
  for _, section in ipairs(set.docs or {}) do
    local key, anchor = locate(section.path, prefix)
    if key and type(section.name) == "string" then
      add(section.name, key, anchor, "Sections")
    end
  end
  -- every page is an entry: the overview by the library's name, an article
  -- by its title ("Readme — ring/ring-core v1.15.5"), anything else by path
  for key, html in pairs(pages) do
    local title = (html:match("<title>(.-)</title>") or "")
    local name = key == "index" and group .. "/" .. artifact or title:match("^(.-) — ") or key
    add(name, key, nil, "Guides")
  end
  return { base = site .. "d/" .. release .. "/", pages = pages, names = names, entries = entries }
end

function M.index(docset, _, system)
  read[docset] = read_library(docset, system)
  return { entries = read[docset].entries }
end

-- ------------------------------------------------------------ the pages

--- The documentation of a page, without the bar above it, and without the
--- raw docstring cljdoc keeps hidden beside each rendered one.
local function clean_page(html)
  local start = html:find('<div class="mw7 center', 1, true)
  local body = start and html:sub(start) or html
  return (
    body
      :gsub("<pre [^>]*raw dn[^>]*>.-</pre>", "")
      :gsub("<a [^>]*js%-%-toggle%-raw[^>]*>.-</a>", "")
      :gsub("<svg.-</svg>", "")
  )
end

function M.db(docset, _, system)
  local library = read[docset] or read_library(docset, system)
  read[docset] = nil
  local known = {}
  for key in pairs(library.pages) do
    known[key] = true
  end
  local db = {}
  for key, html in pairs(library.pages) do
    local body = links.rewrite_html(clean_page(html), {
      dir = key:match("^(.*)/[^/]*$") or "",
      known = known,
      base = library.base,
    })
    db[key] = anchors.plain_fragments(anchors.name_the_anchors(body, library.names[key], plain_id), plain_id)
  end
  return db
end

M._internal = { plain_id = plain_id }

return M
