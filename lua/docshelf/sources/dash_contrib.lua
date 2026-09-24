-- The Dash source adapter for user-contributed docsets (contrib.kapeli.com).
--
-- Kapeli builds the docsets contributed to Kapeli/Dash-User-Contributions and
-- publishes them with one catalogue, index.json: per build folder, a display
-- name, the current version and archive, and the older versions still offered.
-- This adapter
--   * searches that catalogue (one request, kept for the session) by folder
--     and display name;
--   * names a docset "<folder>~<release>" (HAProxy_Lua~1.0);
--   * downloads from kapeli.com/feeds/zzz/user_contributed/build/<folder>/;
--   * leaves reading the archive to docshelf.dash.
-- Kapeli's own feeds are a separate source (dash.lua).
local dash = require("docshelf.dash")

local M = {}

M.origin = "contrib.kapeli.com"

-- Contributed docsets document every sort of thing, so there is no one
-- language to declare: a docset's language comes from its name.
M.catalogue = true

local build = "https://kapeli.com/feeds/zzz/user_contributed/build/"

-- The catalogue, fetched once per session: it is 2.4 MB, and a search runs at
-- every keystroke.
local catalogue

--- Forget the fetched catalogue (for the specs).
function M.reset()
  catalogue = nil
end

local function docsets(system)
  if not catalogue then
    local res = system({ "curl", "-sfL", build .. "index.json" })
    if res.code ~= 0 then
      error("could not fetch the user-contributed Dash catalogue (curl exit " .. tostring(res.code) .. ")", 0)
    end
    local decoded = vim.json.decode(res.stdout)
    if type(decoded) ~= "table" or type(decoded.docsets) ~= "table" then
      error("the user-contributed Dash catalogue is not a list of docsets", 0)
    end
    catalogue = decoded.docsets
  end
  return catalogue
end

--- The docsets whose folder or display name holds `query`, whatever the case,
--- each with the release a row can install.
---@param query string
---@param system fun(cmd: string[]): vim.SystemCompleted
---@return { name: string, version: string }[]
function M.search(query, system)
  local needle = query:lower()
  local rows = {}
  for folder, docset in pairs(docsets(system)) do
    local shown = type(docset.name) == "string" and docset.name or ""
    if folder:lower():find(needle, 1, true) or shown:lower():find(needle, 1, true) then
      rows[#rows + 1] = { name = folder, version = dash.release(docset.version) }
    end
  end
  table.sort(rows, function(a, b)
    return a.name < b.name
  end)
  return rows
end

local function split_docset(docset)
  return dash.split(docset, "user-contributed Dash")
end

local function entry(folder, system)
  local docset = docsets(system)[folder]
  if not docset then
    error("no user-contributed Dash docset named " .. folder, 0)
  end
  return docset
end

---@param name string build folder, e.g. "HAProxy_Lua"
---@return string docset e.g. "HAProxy_Lua~1.0"
function M.resolve(name, system)
  return name .. "~" .. dash.release(entry(name, system).version)
end

function M.release(docset)
  local _, release = split_docset(docset)
  return release
end

function M.latest(docset, system)
  return M.resolve((split_docset(docset)), system)
end

local function archive_url(docset, system)
  local folder, release = split_docset(docset)
  local found = entry(folder, system)
  if dash.release(found.version) == release then
    return build .. folder .. "/" .. found.archive
  end
  for _, older in ipairs(found.specific_versions or {}) do
    if dash.release(older.version) == release then
      return build .. folder .. "/" .. older.archive
    end
  end
  error("the user-contributed Dash docset " .. folder .. " offers no version " .. release, 0)
end

M.index, M.db = dash.installer(archive_url)

return M
