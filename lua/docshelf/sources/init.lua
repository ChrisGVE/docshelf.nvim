-- The documentation sources docshelf can install from, and the settings that
-- govern them.
--
-- Each source is an adapter (see sources/devdocs.lua for the contract) known
-- by its origin, the short address shown beside its docsets ("devdocs.io").
-- Every source is on unless setup() switches it off by origin:
--
--   require("docshelf").setup({ sources = { ["devdocs.io"] = false } })
--
-- Switching a source off only narrows what the install picker searches and
-- lists. Docsets already installed from it are unaffected: they stay readable
-- and searchable, and can still be installed again or updated.
--
-- `workers` caps how much async work runs at once: page conversion during an
-- install, and registry searches (default 4, since registries are
-- community-run). Installs themselves never overlap: the install queue runs
-- one at a time whatever this is set to.
local M = {}

local adapters = {}
for _, adapter in ipairs({ require("docshelf.sources.dash"), require("docshelf.sources.dash_contrib"), require("docshelf.sources.devdocs"), require("docshelf.sources.docc"), require("docshelf.sources.docsrs"), require("docshelf.sources.gemdocs"), require("docshelf.sources.hackage"), require("docshelf.sources.hexdocs"), require("docshelf.sources.maven"), require("docshelf.sources.metacpan"), require("docshelf.sources.odin"), require("docshelf.sources.pkggodev"), require("docshelf.sources.sphinx") }) do
  adapters[adapter.origin] = adapter
end

local default_workers = 4
local settings = { disabled = {}, workers = default_workers }

local function is_positive_integer(n)
  return type(n) == "number" and n >= 1 and n == math.floor(n)
end

--- Apply the user's setup() options. Invalid values raise an error and leave
--- the settings unchanged.
---@param opts { sources?: table<string, boolean>, workers?: integer }
function M.configure(opts)
  local disabled = {}
  for origin, on in pairs(opts.sources or {}) do
    if type(on) ~= "boolean" then
      error("docshelf: sources[" .. vim.inspect(origin) .. "] must be true or false, got " .. vim.inspect(on), 0)
    end
    disabled[origin] = not on or nil
  end
  local workers = opts.workers or default_workers
  if not is_positive_integer(workers) then
    error("docshelf: workers must be a whole number of at least 1, got " .. vim.inspect(workers), 0)
  end
  settings = { disabled = disabled, workers = workers }
end

--- Add a source adapter; its docsets install into "<docset>~~<origin>".
function M.register(adapter)
  adapters[adapter.origin] = adapter
end

---@param origin string
function M.is_enabled(origin)
  return not settings.disabled[origin]
end

--- The adapter for an origin, or nil and the reason there is none. The on/off
--- switch does not apply here: an installed docset must stay installable and
--- updatable whatever setup() says.
---@param origin string
---@return table? adapter, string? why
function M.get(origin)
  if not adapters[origin] then
    return nil, "no source for " .. origin
  end
  return adapters[origin]
end

--- Origins of the sources that are on, sorted: the ones searches may use.
---@return string[]
function M.origins()
  local origins = vim.tbl_filter(M.is_enabled, vim.tbl_keys(adapters))
  table.sort(origins)
  return origins
end

--- How many async jobs (page conversions, registry searches) run at once.
function M.workers()
  return settings.workers
end

return M
