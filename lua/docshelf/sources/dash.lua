-- The Dash source adapter for Kapeli's own docsets (kapeli.com).
--
-- Kapeli publishes one feed per docset in the GitHub repository Kapeli/feeds:
-- <Feed>.xml names the current version, the archive (<Feed>.tgz on
-- kapeli.com) and the older versions still offered. This adapter
--   * searches the list of feeds (one request, kept for the session);
--   * names a docset "<Feed>~<version>" (Lua~5.5), the version read from the
--     feed when a row is picked;
--   * downloads the current version from kapeli.com/feeds/<Feed>.tgz and an
--     older one from kapeli.com/feeds/zzz/versions/<Feed>/<version>/;
--   * leaves reading the archive to docshelf.dash.
-- The user-contributed docsets are a separate source (dash_contrib.lua): the
-- two catalogues share names (Swift, Xojo), and the origin keeps them apart.
local dash = require("docshelf.dash")

local M = {}

M.origin = "kapeli.com"

-- Dash documents many languages, so there is no one language to declare: a
-- docset's language comes from its name (Lua~5.5 is Lua), as devdocs' does.
M.catalogue = true

local feeds_listing = "https://api.github.com/repos/Kapeli/feeds/contents/"
local feed_file = "https://raw.githubusercontent.com/Kapeli/feeds/master/"
local archives = "https://kapeli.com/feeds/"

local function fetch(url, system)
  local res = system({ "curl", "-sfL", url })
  if res.code ~= 0 then
    error("could not fetch " .. url .. " (curl exit " .. tostring(res.code) .. ")", 0)
  end
  return res.stdout
end

-- The feed names, fetched once per session: GitHub allows 60 unauthenticated
-- requests an hour, and a search runs at every keystroke.
local feeds

--- Forget the fetched feed list (for the specs).
function M.reset()
  feeds = nil
end

local function feed_names(system)
  if not feeds then
    local names = {}
    for _, file in ipairs(vim.json.decode(fetch(feeds_listing, system))) do
      local name = type(file) == "table" and type(file.name) == "string" and file.name:match("^(.+)%.xml$")
      if name then
        names[#names + 1] = name
      end
    end
    table.sort(names)
    feeds = names
  end
  return feeds
end

--- The feeds whose name holds `query`, whatever the case. The version is left
--- for `resolve`: it is one request per feed.
---@param query string
---@param system fun(cmd: string[]): vim.SystemCompleted
---@return { name: string }[]
function M.search(query, system)
  local needle = query:lower()
  local rows = {}
  for _, name in ipairs(feed_names(system)) do
    if name:lower():find(needle, 1, true) then
      rows[#rows + 1] = { name = name }
    end
  end
  return rows
end

--- A feed's current version and the older ones it still offers.
local function read_feed(name, system)
  local ok, xml = pcall(fetch, feed_file .. name .. ".xml", system)
  if not ok then
    error("no Dash feed named " .. name, 0)
  end
  local older = {}
  for version in (xml:match("<other%-versions>(.-)</other%-versions>") or ""):gmatch("<name>(.-)</name>") do
    older[#older + 1] = version
  end
  local current = xml:gsub("<other%-versions>.-</other%-versions>", ""):match("<version>(.-)</version>")
  return { current = current, older = older }
end

local function split_docset(docset)
  return dash.split(docset, "Dash")
end

--- The docset for a feed's current version.
---@param name string feed name, e.g. "Lua"
---@return string docset e.g. "Lua~5.5"
function M.resolve(name, system)
  return name .. "~" .. dash.release(read_feed(name, system).current)
end

---@param docset string e.g. "Lua~5.5"
---@return string release
function M.release(docset)
  local _, release = split_docset(docset)
  return release
end

--- The docset the feed offers today; a different name means an update.
function M.latest(docset, system)
  return M.resolve((split_docset(docset)), system)
end

--- Where the archive for a docset's version is downloaded from.
local function archive_url(docset, system)
  local name, release = split_docset(docset)
  local feed = read_feed(name, system)
  if dash.release(feed.current) == release then
    return archives .. name .. ".tgz"
  end
  for _, version in ipairs(feed.older) do
    if dash.release(version) == release then
      return archives .. "zzz/versions/" .. name .. "/" .. version .. "/" .. name .. ".tgz"
    end
  end
  error("the Dash feed " .. name .. " offers no version " .. release, 0)
end

--- How many bytes a feed's current archive is, shown in the install picker
--- before the pick: Lua is a few hundred kilobytes, C++ 173 MB. The current
--- archive's address needs no feed, so this is one HEAD request.
---@param name string feed name, e.g. "Lua"
---@return integer?
function M.size(name, system)
  return dash.archive_size(archives .. name .. ".tgz", system)
end

M.index, M.db = dash.installer(archive_url)

return M
