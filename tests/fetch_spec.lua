-- Tests for lua/docshelf/fetch.lua.
-- Run from the repository root: nvim --headless -l tests/fetch_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local fetch = require("docshelf.fetch")

local failures = 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. "\n     " .. tostring(err))
  end
end

local function eq(actual, expected)
  if not vim.deep_equal(actual, expected) then
    error("expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual), 2)
  end
end

--- A stand-in for vim.system that serves `site` (url -> body) through curl's
--- `-K` config files, and records every command it was handed.
local function fake_system(site, opts)
  local seen = { cmds = {}, configs = {} }
  local system = function(cmd)
    seen.cmds[#seen.cmds + 1] = cmd
    if cmd[2] == "--help" then
      return { code = 0, stdout = opts.parallel and "--parallel-max <num>" or "", stderr = "" }
    end
    local config
    for i, arg in ipairs(cmd) do
      if arg == "-K" then
        config = cmd[i + 1]
      end
    end
    local lines = vim.fn.readfile(config)
    seen.configs[#seen.configs + 1] = lines
    local url, ok = nil, true
    for _, line in ipairs(lines) do
      local value = line:match('"(.*)"')
      if line:match("^url") then
        url = value
      elseif line:match("^output") then
        if site[url] then
          vim.fn.writefile({ site[url] }, value)
        else
          ok = false
        end
      end
    end
    return { code = ok and 0 or 22, stdout = "", stderr = "" }
  end
  return system, seen
end

local function requests(n)
  local list, site = {}, {}
  for i = 1, n do
    local url = "https://example.org/p" .. i .. ".html"
    list[i] = { key = "dir/p" .. i, url = url }
    site[url] = "page " .. i
  end
  return list, site
end

test("every page lands in its own file, keyed as asked", function()
  local list, site = requests(3)
  local system = fake_system(site, { parallel = true })
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local files = fetch.pages(list, dir, system)
  eq(vim.tbl_count(files), 3)
  eq(files["dir/p2"], dir .. "/dir%2Fp2")
  eq(vim.fn.readfile(files["dir/p2"]), { "page 2" })
end)

test("a page the site does not serve is left out, not fatal", function()
  local list, site = requests(3)
  site[list[2].url] = nil
  local system = fake_system(site, { parallel = true })
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local files = fetch.pages(list, dir, system)
  eq(files["dir/p1"] ~= nil, true)
  eq(files["dir/p2"], nil)
  eq(files["dir/p3"] ~= nil, true)
end)

test("pages come in batches of 200, each reported as it lands", function()
  local list, site = requests(450)
  local system, seen = fake_system(site, { parallel = true })
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local reports = {}
  fetch.pages(list, dir, system, function(message)
    reports[#reports + 1] = message
  end)
  eq(#seen.configs, 3)
  eq(#seen.configs[1], 400)
  eq(#seen.configs[3], 100)
  eq(reports, {
    "fetching pages 200/450",
    "fetching pages 400/450",
    "fetching pages 450/450",
  })
end)

test("curl is asked to fetch in parallel only when it can", function()
  local list, site = requests(2)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local system, seen = fake_system(site, { parallel = true })
  fetch.pages(list, dir, system)
  local last = seen.cmds[#seen.cmds]
  eq(vim.tbl_contains(last, "--parallel"), true)
  eq(last[vim.fn.index(last, "--parallel-max") + 2], tostring(require("docshelf.sources").workers()))

  system, seen = fake_system(site, { parallel = false })
  fetch.pages(list, dir, system)
  for _, cmd in ipairs(seen.cmds) do
    eq(vim.tbl_contains(cmd, "--parallel"), false)
  end
end)

test("no request, no call to curl at all", function()
  local system, seen = fake_system({}, { parallel = true })
  eq(fetch.pages({}, vim.fn.tempname(), system), {})
  eq(#seen.cmds, 0)
end)

if failures > 0 then
  print(failures .. " failure(s)")
  os.exit(1)
end
