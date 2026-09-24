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

function M.db(slug, mtime, system)
  return fetch_json(base .. slug .. "/db.json?" .. mtime, system)
end

return M
