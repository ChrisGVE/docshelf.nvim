-- The documentation sources apidocs can install from, and the settings that
-- govern them.
--
-- Each source is an adapter (see sources/devdocs.lua for the contract) known
-- by its origin, the short address shown beside its docsets ("devdocs.io").
-- Every source is on unless setup() switches it off by origin:
--
--   require("apidocs").setup({ sources = { ["devdocs.io"] = false } })
--
-- A switched-off source cannot be installed from; docsets already installed
-- from it stay readable and searchable.
--
-- `workers` is how many processes convert pages at once during an install
-- (default 8). Installs themselves never overlap: the install queue runs one
-- at a time whatever this is set to.
local M = {}

local adapters = {}
for _, adapter in ipairs({ require("apidocs.sources.devdocs") }) do
  adapters[adapter.origin] = adapter
end

local default_workers = 8
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
      error("apidocs: sources[" .. vim.inspect(origin) .. "] must be true or false, got " .. vim.inspect(on), 0)
    end
    disabled[origin] = not on or nil
  end
  local workers = opts.workers or default_workers
  if not is_positive_integer(workers) then
    error("apidocs: workers must be a whole number of at least 1, got " .. vim.inspect(workers), 0)
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

--- The adapter for an origin, or nil and the reason there is none.
---@param origin string
---@return table? adapter, string? why
function M.get(origin)
  if not adapters[origin] then
    return nil, "no source for " .. origin
  end
  if not M.is_enabled(origin) then
    return nil, origin .. " is switched off in setup()"
  end
  return adapters[origin]
end

--- Origins of the sources that are on, sorted.
---@return string[]
function M.origins()
  local origins = vim.tbl_filter(M.is_enabled, vim.tbl_keys(adapters))
  table.sort(origins)
  return origins
end

--- Conversion processes per install.
function M.workers()
  return settings.workers
end

return M
