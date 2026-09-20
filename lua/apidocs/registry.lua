-- Searching the registries behind the sources.
--
-- devdocs ships one catalogue of everything it has, so its install picker can
-- be a list. A package registry cannot: Hackage alone holds ~18,000 packages
-- and offers no catalogue worth downloading, so the only way to offer one of
-- them is to ask the registry as the name is typed.
--
-- A source that can be asked declares:
--   search(query, system) -> { { name = "aeson", version? = "2.2.3" } }
--   language?             -- the one language it documents ("Haskell"), so a
--                            search can be narrowed to the sources that could
--                            answer it at all
-- `version` is optional: a registry that does not return one leaves the
-- version to be resolved when a row is picked.
--
-- Answers are kept in a cache file beside the installed docsets, so a name
-- searched once is offered again at the next keystroke with no network at all.
-- A registry is community-run and may be slow or down: a source that fails is
-- reported as having found nothing, never as an error that empties the picker.
local M = {}

local sources = require("apidocs.sources")
local async = require("apidocs.async")

local cache_file = ".registry_cache.json"

--- Where the cache lives by default: beside the installed docsets.
function M.cache_path()
  return require("apidocs.common").data_folder() .. cache_file
end

local Cache = {}
Cache.__index = Cache

local function read_rows(path)
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  local ok, rows = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
  end)
  -- A cache is a convenience, never a source of truth: an unreadable one is
  -- started again rather than reported.
  return (ok and type(rows) == "table") and rows or {}
end

--- The cache in a file. Rows are { name, version?, origin }.
---@param path string
function M.cache(path)
  return setmetatable({ path = path, _rows = nil }, Cache)
end

--- The default cache: the one in the data folder.
function M.default_cache()
  return M.cache(M.cache_path())
end

function Cache:rows()
  if not self._rows then
    self._rows = read_rows(self.path)
  end
  return self._rows
end

--- Add rows, newest wins, and write the file. A row is identified by its
--- origin and name: the same package from two registries is two rows.
---@param rows { name: string, version?: string, origin: string }[]
function Cache:remember(rows)
  if #rows == 0 then
    return
  end
  local kept, seen = {}, {}
  for _, row in ipairs(rows) do
    seen[row.origin .. "\0" .. row.name] = true
  end
  for _, row in ipairs(self:rows()) do
    if not seen[row.origin .. "\0" .. row.name] then
      kept[#kept + 1] = row
    end
  end
  vim.list_extend(kept, rows)
  table.sort(kept, function(a, b)
    if a.name == b.name then
      return a.origin < b.origin
    end
    return a.name < b.name
  end)
  self._rows = kept
  vim.fn.mkdir(vim.fn.fnamemodify(self.path, ":h"), "p")
  pcall(vim.fn.writefile, { vim.json.encode(kept) }, self.path)
end

--- The remembered rows whose name holds `query`, whatever the case. An empty
--- query matches nothing: the cache is what has been searched for before, not
--- a catalogue to page through.
---@param query string
function Cache:match(query)
  if query == "" then
    return {}
  end
  local needle = query:lower()
  return vim.tbl_filter(function(row)
    return row.name:lower():find(needle, 1, true) ~= nil
  end, self:rows())
end

--- The origins a search may ask: on, able to search, and -- when `languages`
--- is given -- documenting one of those languages. A source that declares no
--- language cannot be narrowed to one, so it is left out of a narrowed search.
---@param opts? { languages?: table<string, boolean> }
---@return string[]
function M.searchable(opts)
  local languages = opts and opts.languages
  return vim.tbl_filter(function(origin)
    local adapter = sources.get(origin)
    if not (adapter and adapter.search) then
      return false
    end
    if languages then
      return adapter.language ~= nil and languages[adapter.language] == true
    end
    return true
  end, sources.origins())
end

local Handle = {}
Handle.__index = Handle

function Handle:pending()
  return vim.deepcopy(self._pending)
end

function Handle:cancelled()
  return self._cancelled
end

--- Stop reporting: the answers still in flight are dropped. The requests
--- themselves cannot be recalled, but what they find is still remembered.
function Handle:cancel()
  self._cancelled = true
  self._pending = {}
end

--- Ask every named source for `query`, at most `sources.workers()` at once.
--- `on_batch(origin, rows)` runs per source that answers, `on_done()` once
--- none is left. `run` and `system` default to the coroutine helpers; tests
--- pass their own.
---@param query string
---@param opts { origins: string[], cache: table, on_batch: fun(origin: string, rows: table[]), on_done: fun(), run?: fun(fn: fun(), on_fail?: fun()), system?: fun(cmd: string[]): table }
function M.search(query, opts)
  local run = opts.run or async.run
  local system = opts.system or function(cmd)
    return async.system(cmd, { text = true })
  end
  local handle = setmetatable({ _pending = {}, _cancelled = false }, Handle)
  local queued = query == "" and {} or vim.deepcopy(opts.origins)
  for _, origin in ipairs(queued) do
    handle._pending[#handle._pending + 1] = origin
  end

  local function finished(origin)
    handle._pending = vim.tbl_filter(function(o)
      return o ~= origin
    end, handle._pending)
    if #handle._pending == 0 and #queued == 0 and not handle._cancelled then
      opts.on_done()
    end
  end

  local start_next
  local function ask(origin)
    local adapter = sources.get(origin)
    run(function()
      local rows = adapter.search(query, system)
      for _, row in ipairs(rows) do
        row.origin = origin
      end
      opts.cache:remember(rows)
      if not handle._cancelled and #rows > 0 then
        opts.on_batch(origin, rows)
      end
      finished(origin)
      start_next()
    end, function(err)
      -- A registry that is down or slow must not empty the picker.
      vim.notify(
        "apidocs: " .. origin .. " could not be searched: " .. tostring(err),
        vim.log.levels.DEBUG,
        { title = "apidocs" }
      )
      finished(origin)
      start_next()
    end)
  end

  local running = 0
  start_next = function()
    running = math.max(0, running - 1)
    while #queued > 0 and running < sources.workers() do
      running = running + 1
      ask(table.remove(queued, 1))
    end
    if #queued == 0 and #handle._pending == 0 and not handle._cancelled then
      opts.on_done()
    end
  end
  running = 1 -- start_next decrements once before its first round
  start_next()
  return handle
end

return M
