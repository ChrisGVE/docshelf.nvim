-- Tests for lua/docshelf/sources/devdocs.lua.
-- Run from the repository root: nvim --headless -l tests/sources_devdocs_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local devdocs = require("docshelf.sources.devdocs")

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

-- A fake command runner: records the command, answers with canned output.
local function runner(stdout, code)
  local seen = {}
  return function(cmd)
    seen[#seen + 1] = cmd
    return { code = code or 0, stdout = stdout }
  end, seen
end

test("the origin is devdocs.io", function()
  eq(devdocs.origin, "devdocs.io")
end)

test("index downloads the source's index.json, cache-busted by mtime", function()
  local system, seen = runner('{"entries":[{"name":"print","path":"library/functions#print","type":"Built-in"}]}')
  local index = devdocs.index("python~3.14", 123, system)
  eq(seen[1][#seen[1]], "https://documents.devdocs.io/python~3.14/index.json?123")
  eq(index.entries[1].path, "library/functions#print")
end)

test("db downloads the source's db.json", function()
  local system, seen = runner('{"library/functions":"<h1>Functions</h1>"}')
  local db = devdocs.db("python~3.14", 123, system)
  eq(seen[1][#seen[1]], "https://documents.devdocs.io/python~3.14/db.json?123")
  eq(db["library/functions"], "<h1>Functions</h1>")
end)

test("a failed download is an error naming the address", function()
  local system = runner("", 22)
  local ok, err = pcall(devdocs.index, "nosuch~1", "", system)
  eq(ok, false)
  assert(tostring(err):find("https://documents.devdocs.io/nosuch~1/index.json", 1, true), err)
end)

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
