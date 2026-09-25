--- Page fetching shared by the sources whose site has no archive (Sphinx,
--- DocC, and every source after them), so each page is one request.
---
--- curl is handed a config file of url/output pairs a batch at a time: one
--- connection serves the whole batch, and the install can say how far along it
--- is as each batch lands. Where curl knows `--parallel-max` (7.66 onwards) the
--- batch is fetched `sources.workers()` pages at once. Sphinx and DocC each
--- carried their own copy of this; this module is the one copy.
local M = {}

-- How many pages one curl call fetches.
local batch_size = 200

local function curl_parallel(system)
  local res = system({ "curl", "--help", "all" }, { text = true })
  return res.code == 0 and (res.stdout or ""):find("--parallel-max", 1, true) ~= nil
end

--- Fetch every `{ key, url }` of `requests` into `dir`, reporting as each
--- batch lands. A page's file is its key with `/` escaped, so keys never need
--- subfolders. Returns the file each fetched page was written to, by key.
---@param requests { key: string, url: string }[]
---@param dir string
---@param system fun(cmd: string[], opts?: table): vim.SystemCompleted
---@param report? fun(message: string)
---@return table<string, string>
function M.pages(requests, dir, system, report)
  local files = {}
  if #requests == 0 then
    return files
  end
  local parallel = curl_parallel(system)
  local done = 0
  for start = 1, #requests, batch_size do
    local config, batch = {}, {}
    for i = start, math.min(start + batch_size - 1, #requests) do
      local request = requests[i]
      local out = dir .. "/" .. request.key:gsub("/", "%%2F")
      batch[#batch + 1] = { key = request.key, out = out }
      config[#config + 1] = 'url = "' .. request.url .. '"'
      config[#config + 1] = 'output = "' .. out .. '"'
    end
    local config_path = vim.fn.tempname()
    vim.fn.writefile(config, config_path)
    local cmd = { "curl", "-sfL", "--max-time", "120" }
    if parallel then
      -- required here, not at the top: sources/init.lua loads the adapters
      -- that load this module.
      local workers = require("docshelf.sources").workers()
      vim.list_extend(cmd, { "--parallel", "--parallel-max", tostring(workers) })
    end
    vim.list_extend(cmd, { "-K", config_path })
    -- A page that 404s is skipped, not fatal: an index can name a page the
    -- site no longer serves, and one missing page is no reason to lose the
    -- thousands of others.
    system(cmd)
    vim.fn.delete(config_path)
    for _, page in ipairs(batch) do
      if vim.fn.filereadable(page.out) == 1 then
        files[page.key] = page.out
      end
    end
    done = math.min(done + batch_size, #requests)
    if report then
      report("fetching pages " .. done .. "/" .. #requests)
    end
  end
  return files
end

return M
