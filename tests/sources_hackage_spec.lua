-- Tests for lua/apidocs/sources/hackage.lua, offline: a fake command runner
-- answers the Hackage requests and serves tests/fixtures/hackage as docs.tar.
-- Run from the repository root: nvim --headless -l tests/sources_hackage_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local hackage = require("apidocs.sources.hackage")

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

local fixtures = vim.fn.fnamemodify("tests/fixtures/hackage", ":p")

-- Answers like hackage.haskell.org: `preferred` lists versions newest first,
-- `built` names the versions whose docs.tar exists.
local function hackage_runner(preferred, built)
  local seen = {}
  return function(cmd)
    seen[#seen + 1] = cmd
    local url = cmd[#cmd]
    if cmd[1] == "tar" then
      return vim.system(cmd):wait()
    end
    if url:match("/preferred$") then
      return { code = 0, stdout = vim.json.encode({ ["normal-version"] = preferred }) }
    end
    local version = url:match("/package/[%w%-]-%-([%d%.]+)/docs%.tar$")
    if not (version and vim.tbl_contains(built, version)) then
      return { code = 22, stdout = "" }
    end
    local out
    for i, arg in ipairs(cmd) do
      if arg == "-o" then
        out = cmd[i + 1]
      end
    end
    if out then
      -- serve the fixture folder as the package's docs.tar
      vim.system({ "tar", "-cf", out, "-C", fixtures, "tiny-1.0-docs" }):wait()
    end
    return { code = 0, stdout = "" }
  end,
    seen
end

test("the origin is hackage.haskell.org", function()
  eq(hackage.origin, "hackage.haskell.org")
end)

test("resolve picks the newest version with built docs", function()
  local system = hackage_runner({ "1.2", "1.1", "1.0" }, { "1.1", "1.0" })
  eq(hackage.resolve("tiny", system), "tiny~1.1")
end)

test("resolve fails when no version has docs", function()
  local system = hackage_runner({ "1.0" }, {})
  local ok, err = pcall(hackage.resolve, "tiny", system)
  eq(ok, false)
  assert(tostring(err):find("no documentation on Hackage for tiny", 1, true), err)
end)

test("index lists each module and each documented name", function()
  local system = hackage_runner({ "1.0" }, { "1.0" })
  local index = hackage.index("tiny~1.0", "", system)
  table.sort(index.entries, function(a, b)
    return a.path < b.path
  end)
  eq(index.entries, {
    { name = "Data.Tiny", path = "Data-Tiny", type = "Modules" },
    { name = "Data.Tiny.Tiny", path = "Data-Tiny#t:Tiny", type = "Types" },
    { name = "Data.Tiny.shrink", path = "Data-Tiny#v:shrink", type = "Values" },
    { name = "Data.Tiny.Extra", path = "Data-Tiny-Extra", type = "Modules" },
    { name = "Data.Tiny.Extra.grow", path = "Data-Tiny-Extra#v:grow", type = "Values" },
  })
end)

test("db has one page per module and no index page", function()
  local system = hackage_runner({ "1.0" }, { "1.0" })
  local db = hackage.db("tiny~1.0", "", system)
  local pages = vim.tbl_keys(db)
  table.sort(pages)
  eq(pages, { "Data-Tiny", "Data-Tiny-Extra" })
end)

test("db keeps the module text and drops the page chrome", function()
  local system = hackage_runner({ "1.0" }, { "1.0" })
  local page = hackage.db("tiny~1.0", "", system)["Data-Tiny"]
  assert(page:find("Tiny things.", 1, true), page)
  assert(page:find('id="t:Tiny"', 1, true), page)
  for _, gone in ipairs({
    "package-header",
    "table-of-contents",
    "SYNOPSIS-COPY",
    "Produced by Haddock",
    "<script",
    ">Source<",
    "selflink",
  }) do
    assert(not page:find(gone, 1, true), gone .. " still in page")
  end
end)

test("db rewrites links to page keys or to hackage.haskell.org", function()
  local system = hackage_runner({ "1.0" }, { "1.0" })
  local page = hackage.db("tiny~1.0", "", system)["Data-Tiny"]
  assert(page:find('href="Data-Tiny-Extra#v:grow"', 1, true), page)
  assert(page:find('href="Data-Tiny#t:Tiny"', 1, true), page)
  assert(page:find('href="Data-Tiny"', 1, true), page)
  assert(page:find('href="https://hackage.haskell.org/package/base-4.19.2.0/docs/Prelude.html#t:Int"', 1, true), page)
  -- no relative link still points at a .html file
  assert(not page:find('href="[%w%-]+%.html'), page)
end)

test("a link to a module the archive lacks keeps its text, not the link", function()
  -- Haddock writes links to qualified-import aliases (T.html) that do not exist
  local system = hackage_runner({ "1.0" }, { "1.0" })
  local page = hackage.db("tiny~1.0", "", system)["Data-Tiny-Extra"]
  assert(page:find("<a>T.shrink</a>", 1, true), page)
end)

test("index and db download the tar only once per install", function()
  local system, seen = hackage_runner({ "1.0" }, { "1.0" })
  hackage.index("tiny~1.0", "", system)
  hackage.db("tiny~1.0", "", system)
  local downloads = vim.tbl_filter(function(cmd)
    return cmd[1] == "curl" and vim.tbl_contains(cmd, "-o")
  end, seen)
  eq(#downloads, 1)
end)

test("a missing docs.tar is an error naming the package", function()
  local system = hackage_runner({ "1.0" }, {})
  local ok, err = pcall(hackage.index, "tiny~9.9", "", system)
  eq(ok, false)
  assert(tostring(err):find("no documentation on Hackage for tiny-9.9", 1, true), err)
end)

test("a name without a version is an error", function()
  local ok, err = pcall(hackage.index, "tiny", "", hackage_runner({}, {}))
  eq(ok, false)
  assert(tostring(err):find("tiny", 1, true), err)
end)

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
