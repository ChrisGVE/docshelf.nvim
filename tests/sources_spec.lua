-- Tests for lua/docshelf/sources/init.lua.
-- Run from the repository root: nvim --headless -l tests/sources_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local sources = require("docshelf.sources")

local failures = 0
local function test(name, fn)
  sources.configure({})
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

local example = { origin = "example.org", index = function() end, db = function() end }

test("devdocs is a known source and on by default", function()
  eq(sources.get("devdocs.io").origin, "devdocs.io")
  eq(sources.is_enabled("devdocs.io"), true)
end)

test("an unknown origin has no adapter and says why", function()
  local adapter, why = sources.get("nowhere.example")
  eq(adapter, nil)
  eq(why, "no source for nowhere.example")
end)

test("a registered adapter is found by its origin and listed", function()
  sources.register(example)
  eq(sources.get("example.org"), example)
  eq(vim.tbl_contains(sources.origins(), "example.org"), true)
end)

test("setup can switch a source off by its origin", function()
  sources.register(example)
  sources.configure({ sources = { ["example.org"] = false } })
  eq(sources.is_enabled("example.org"), false)
  eq(vim.tbl_contains(sources.origins(), "example.org"), false)
  eq(sources.is_enabled("devdocs.io"), true)
end)

test("a switched-off source still installs and updates what is stored", function()
  sources.register(example)
  sources.configure({ sources = { ["example.org"] = false } })
  eq(sources.get("example.org"), example)
end)

test("switching a source back on in a later setup works", function()
  sources.register(example)
  sources.configure({ sources = { ["example.org"] = false } })
  sources.configure({ sources = { ["example.org"] = true } })
  eq(sources.is_enabled("example.org"), true)
end)

test("origins are listed in a stable order, shipped sources included", function()
  sources.register(example)
  eq(sources.origins(), {
    "contrib.kapeli.com",
    "devdocs.io",
    "docc",
    "docs.rs",
    "example.org",
    "hackage.haskell.org",
    "hexdocs.pm",
    "kapeli.com",
    "pkg.go.dev",
    "sphinx",
  })
end)

test("workers defaults to 4 async jobs", function()
  eq(sources.workers(), 4)
end)

test("setup sets the number of workers", function()
  sources.configure({ workers = 3 })
  eq(sources.workers(), 3)
end)

test("an invalid workers value is refused and the default kept", function()
  for _, bad in ipairs({ 0, -1, 2.5, "4" }) do
    local ok = pcall(sources.configure, { workers = bad })
    eq(ok, false)
    eq(sources.workers(), 4)
  end
end)

test("a sources value other than true/false is refused", function()
  local ok = pcall(sources.configure, { sources = { ["example.org"] = "no" } })
  eq(ok, false)
end)

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
