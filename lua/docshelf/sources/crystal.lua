-- The crystal-lang.org source adapter (Crystal's standard library).
--
-- Crystal has no central package registry (a shard is a git URL), but its
-- standard library is documented at crystal-lang.org/api, and the generator
-- writes the whole API as one file beside the pages (measured 2026-09-26,
-- Crystal 1.21.0):
--   * api/                  a 302 to api/<version>/, the newest release;
--   * api/<v>/index.json    every type, method, macro and constant (11.8 MB,
--                           served gzipped whatever the request asks), each
--                           member with the id its page gives it;
--   * api/<v>/<Type>.html   a page per type (Array.html, Atomic/Flag.html),
--                           and toplevel.html for the top-level methods and
--                           macros (puts, record).
--
-- This adapter turns that into the index/db pair the installer expects (see
-- sources/devdocs.lua):
--   * one docset, "crystal~<version>": named for the language, so it is
--     Crystal's reference;
--   * a page per type, keyed by its path without ".html" (Atomic/Flag);
--   * entries: every type ("Array"), every constructor, class method and
--     macro ("Array.new(initial_capacity : Int)"), every instance method
--     ("Array#&(other : Array(U))") -- overloads each their own -- and every
--     constant ("Signal::INT");
--   * links to a page of the docset name it; any other link is an address on
--     crystal-lang.org.
--
-- A member's id is its whole signature ("&(other:Array(U)):Array(T)forallU-
-- instance-method"), written escaped on the page and url-encoded in links;
-- `anchors.hex_id` makes each plain text that a link and its id agree on.
local anchors = require("docshelf.anchors")
local fetching = require("docshelf.fetch")
local links = require("docshelf.links")

local M = {}

M.origin = "crystal-lang.org"

M.language = "Crystal"

local site = "https://crystal-lang.org/api/"

local user_agent = "docshelf.nvim (https://github.com/ChrisGVE/docshelf.nvim)"

local docset_name = "crystal"

--- The one docset, when what was typed is part of its name. No request.
---@param query string
---@return { name: string }[]
function M.search(query, _)
  if docset_name:find(query:lower(), 1, true) then
    return { { name = docset_name } }
  end
  return {}
end

--- The docset for the newest Crystal release: the site's api/ answers with a
--- redirect naming it.
---@param name string
---@param system fun(cmd: string[]): vim.SystemCompleted
---@return string docset e.g. "crystal~1.21.0"
function M.resolve(name, system)
  if name ~= docset_name then
    error("crystal-lang.org has no docset " .. name .. " (it offers " .. docset_name .. ")", 0)
  end
  local res = system({ "curl", "-s", "-A", user_agent, "-o", "/dev/null", "-w", "%{redirect_url}", site })
  local version = res.code == 0 and (res.stdout or ""):match("/api/([%d%.]+)/?$")
  if not version then
    error("could not find the newest Crystal release on crystal-lang.org", 0)
  end
  return docset_name .. "~" .. version
end

local function split_docset(docset)
  local name, version = docset:match("^(.+)~([%d%.]+)$")
  if name ~= docset_name then
    error("a crystal-lang.org docset is crystal~<version>, got " .. docset, 0)
  end
  return name, version
end

--- The release a docset holds: it is named for the exact version it came from.
---@param docset string e.g. "crystal~1.21.0"
function M.release(docset)
  local _, version = split_docset(docset)
  return version
end

--- The docset crystal-lang.org offers today; comparing it with the docset's
--- own name is how an update is noticed.
---@param docset string
---@param system fun(cmd: string[]): vim.SystemCompleted
function M.latest(docset, system)
  return M.resolve((split_docset(docset)), system)
end

-- ------------------------------------------------------------- the index

-- A type's kind in the pickers' words.
local type_kinds = {
  class = "Classes",
  struct = "Structs",
  module = "Modules",
  enum = "Enums",
  alias = "Aliases",
  annotation = "Annotations",
}

-- Each list of members a type holds: its picker type, and how a member is
-- joined to the type's name.
local member_lists = {
  { field = "constructors", type = "Constructors", join = "." },
  { field = "class_methods", type = "Class Methods", join = "." },
  { field = "macros", type = "Macros", join = "." },
  { field = "instance_methods", type = "Instance Methods", join = "#" },
}

--- A member's parameters as its signature writes them, without the return
--- type: "(other : Array(U))" of "(other : Array(U)) : Array(T) forall U".
local function parameters(member)
  return type(member.args_string) == "string" and member.args_string:match("^%b()") or ""
end

--- The entries of one type, and the name each of its anchors lands on.
local function read_type(t, key, entries, names)
  local program = t.program == true
  -- "Array(T)" is typed "Array"; the top level has no name of its own
  local name = program and "" or t.full_name:gsub("%b()", "")
  if not program then
    entries[#entries + 1] = { name = name, path = key, type = type_kinds[t.kind] or "Types" }
  end
  local function add(entry_name, id, entry_type)
    local anchor = anchors.hex_id(id)
    names[key][anchor] = names[key][anchor] or entry_name
    entries[#entries + 1] = { name = entry_name, path = key .. "#" .. anchor, type = entry_type }
  end
  for _, list in ipairs(member_lists) do
    for _, member in ipairs(t[list.field] or {}) do
      if type(member.name) == "string" and type(member.html_id) == "string" then
        local prefix = program and "" or name .. list.join
        add(prefix .. member.name .. parameters(member), member.html_id, list.type)
      end
    end
  end
  for _, constant in ipairs(t.constants or {}) do
    if type(constant.name) == "string" and type(constant.id) == "string" then
      add((program and "" or name .. "::") .. constant.name, constant.id, "Constants")
    end
  end
end

-- What each install read in index, kept for its db call.
local read = {}

local function read_api(docset, system)
  local _, version = split_docset(docset)
  local base = site .. version .. "/"
  -- stored gzipped: without --compressed curl hands back the gzip bytes
  local res = system({ "curl", "-sfL", "--compressed", "-A", user_agent, base .. "index.json" })
  if res.code ~= 0 then
    error("crystal-lang.org has no API index for Crystal " .. version, 0)
  end
  local ok, index = pcall(vim.json.decode, res.stdout)
  if not (ok and type(index) == "table" and type(index.program) == "table") then
    error("crystal-lang.org's API index for Crystal " .. version .. " is not the JSON expected", 0)
  end
  local entries, names, pages = {}, {}, {}
  local function walk(t)
    if type(t.path) == "string" then
      local key = t.path:gsub("%.html$", "")
      pages[#pages + 1] = key
      names[key] = {}
      read_type(t, key, entries, names)
    end
    for _, inner in ipairs(t.types or {}) do
      walk(inner)
    end
  end
  walk(index.program)
  return { base = base, pages = pages, names = names, entries = entries }
end

function M.index(docset, _, system)
  read[docset] = read_api(docset, system)
  return { entries = read[docset].entries }
end

-- ------------------------------------------------------------ the pages

local function clean_page(html, names)
  local start = html:find('<div class="main-content">', 1, true)
  local body = start and html:sub(start) or html
  body = body
    :gsub("</body>.*$", "")
    :gsub("<script.-</script>", "")
    :gsub("<svg.-</svg>", "")
    -- the "#" beside every signature, a link to itself
    :gsub('<a class="method%-permalink"[^>]*>.-</a>', "")
    -- a link to the source of every member on GitHub
    :gsub(
      '%[<a href="https://github%.com/[^"]*"[^>]*>View source</a>%]',
      ""
    )
  return anchors.plain_fragments(anchors.name_the_anchors(body, names, anchors.hex_id), anchors.hex_id)
end

function M.db(docset, _, system, report)
  local api = read[docset] or read_api(docset, system)
  read[docset] = nil
  local requests = {}
  for _, key in ipairs(api.pages) do
    requests[#requests + 1] = { key = key, url = api.base .. key .. ".html" }
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
    db[key] = links.rewrite_html(clean_page(html, api.names[key]), {
      dir = key:match("^(.*)/[^/]*$") or "",
      known = known,
      base = api.base,
    })
  end
  vim.fn.delete(dir, "rf")
  return db
end

return M
