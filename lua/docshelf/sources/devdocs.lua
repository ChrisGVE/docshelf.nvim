-- The devdocs.io source adapter.
--
-- An adapter hands the installer two tables in devdocs' own shape:
--   index(slug, version_key, system) -> { entries = { { name, path, type } } }
--     where `path` is "page" or "page#anchor"
--   db(slug, version_key, system)    -> { [page] = html }
-- `system(cmd)` runs a command and returns vim.system's result; the installer
-- passes one that yields its coroutine, tests pass a fake. Everything after
-- these two tables (splitting, conversion, link fixing) is source-agnostic.
local M = {}

local links = require("docshelf.links")

M.origin = require("docshelf.metadata").devdocs_origin

local base = "https://documents.devdocs.io/"

local function fetch_json(url, system)
  local res = system({ "curl", "-sfL", url })
  if res.code ~= 0 then
    error("download failed (curl exit " .. tostring(res.code) .. "): " .. url, 0)
  end
  return vim.fn.json_decode(res.stdout)
end

-- `mtime` only busts devdocs' CDN cache; the content is the current build.
function M.index(slug, mtime, system)
  return fetch_json(base .. slug .. "/index.json?" .. mtime, system)
end

-- Where a page of a docset is read on the web.
local site = "https://devdocs.io/"

-- devdocs leaves some pages of a site out (python's genindex), and a link to
-- one, left relative, became elinks' absolute file:// path to nothing. Every
-- link goes through docshelf.links: one to a page the docset holds stays
-- relative, one to a page it does not goes to that page on devdocs.io.
function M.db(slug, mtime, system)
  local db = fetch_json(base .. slug .. "/db.json?" .. mtime, system)
  local known = {}
  for key in pairs(db) do
    known[key] = true
  end
  for key, html in pairs(db) do
    db[key] = links.rewrite_html(html, {
      dir = key:match("^(.*)/[^/]*$") or "",
      known = known,
      base = site .. slug .. "/",
    })
  end
  return db
end

return M
