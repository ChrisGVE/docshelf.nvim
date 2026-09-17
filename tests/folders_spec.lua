-- Tests for lua/apidocs/folders.lua.
-- Run from the repository root: nvim --headless -l tests/folders_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local folders = require("apidocs.folders")

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

test("a devdocs source keeps its plain folder name", function()
  eq(folders.name("python~3.14", "devdocs.io"), "python~3.14")
  eq(folders.name("python~3.14", nil), "python~3.14")
end)

test("another origin is appended after ~~", function()
  eq(folders.name("text~2.1", "hackage.haskell.org"), "text~2.1~~hackage.haskell.org")
end)

test("split returns the docset name and origin", function()
  eq({ folders.split("text~2.1~~hackage.haskell.org") }, { "text~2.1", "hackage.haskell.org" })
  eq({ folders.split("python~3.14") }, { "python~3.14", "devdocs.io" })
end)

test("name and split round-trip", function()
  for _, case in ipairs({ { "serde~1.0.219", "docs.rs" }, { "lua~5.4", "devdocs.io" } }) do
    eq({ folders.split(folders.name(case[1], case[2])) }, case)
  end
end)

test("display is the docset name alone", function()
  eq(folders.display("text~2.1~~hackage.haskell.org"), "text~2.1")
  eq(folders.display("python~3.14"), "python~3.14")
end)

test("display_path shows a page path under its docset name", function()
  eq(folders.display_path("text~2.1~~hackage.haskell.org/Data.Text"), "text~2.1/Data.Text")
  eq(folders.display_path("python~3.14/library/os"), "python~3.14/library/os")
  eq(folders.display_path("lua~5.4"), "lua~5.4")
end)

test("folder names only use characters elinks leaves unencoded in links", function()
  -- elinks percent-encodes anything else, and the link fixer then cannot
  -- recognise the folder's own pages.
  local folder = folders.name("aeson-pretty~0.8.10", "hackage.haskell.org")
  assert(folder:match("^[%w%-%._~]+$"), folder)
end)

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
