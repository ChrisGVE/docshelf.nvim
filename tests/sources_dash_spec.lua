-- Tests for the two Dash sources, offline: lua/docshelf/sources/dash.lua
-- (Kapeli's own feeds) and lua/docshelf/sources/dash_contrib.lua (the
-- user-contributed ones). A fake command runner answers the catalogue
-- requests and serves a fixture docset from tests/fixtures/dash, packed on the
-- spot; tar and sqlite3 run for real.
-- Run from the repository root: nvim --headless -l tests/sources_dash_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local dash = require("docshelf.sources.dash")
local contrib = require("docshelf.sources.dash_contrib")

local failures = 0
local function test(name, fn)
  dash.reset()
  contrib.reset()
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

local function pack(layout)
  local work = vim.fn.tempname()
  vim.fn.mkdir(work, "p")
  vim.system({ "cp", "-R", vim.fn.fnamemodify("tests/fixtures/dash/" .. layout, ":p"), work .. "/src" }):wait()
  local resources = vim.fn.glob(work .. "/src/*.docset/Contents/Resources", false, true)[1]
  vim.system({ "sqlite3", resources .. "/docSet.dsidx", ".read " .. resources .. "/tokens.sql" }):wait()
  vim.fn.delete(resources .. "/tokens.sql")
  local archive = work .. "/docset.tgz"
  vim.system({ "tar", "-czf", archive, "-C", work .. "/src", "." }):wait()
  return archive
end

local archive = pack("coredata")

-- What GitHub answers for the Kapeli/feeds repository's contents.
local listing = vim.json.encode({
  { name = "Lua.xml", type = "file" },
  { name = "C++.xml", type = "file" },
  { name = "LuaJIT.xml", type = "file" },
  { name = "README.md", type = "file" },
})

local lua_feed = [[
<entry>
    <version>5.5</version>
    <url>http://sanfrancisco.kapeli.com/feeds/Lua.tgz</url>
    <url>http://london.kapeli.com/feeds/Lua.tgz</url>
    <other-versions>
        <version><name>5.5</name></version>
        <version><name>5.1</name></version>
    </other-versions>
</entry>
]]

-- The user-contributed catalogue: Kapeli's own index.json, trimmed.
local contributed = vim.json.encode({
  docsets = {
    HAProxy_Lua = {
      name = "HAProxy Lua",
      archive = "HAProxyLua.tgz",
      version = "1.0/1",
      specific_versions = {},
    },
    Jest = {
      name = "Jest",
      archive = "Jest.tgz",
      version = "24.1.1",
      specific_versions = {
        { version = "24.1.1", archive = "versions/24.1.1/Jest.tgz" },
        { version = "23.1.0", archive = "versions/23.1.0/Jest.tgz" },
      },
    },
    Swift = { name = "Swift", archive = "Swift.tgz", version = "5.1" },
  },
})

--- Answers the way GitHub and kapeli.com would; any archive URL gets the
--- fixture docset. `seen` records every command, `urls` every address.
local function runner(opts)
  opts = opts or {}
  local seen, urls = {}, {}
  return function(cmd)
    seen[#seen + 1] = cmd
    if cmd[1] ~= "curl" then
      return vim.system(cmd, { text = true }):wait()
    end
    local url = cmd[#cmd]
    urls[#urls + 1] = url
    if opts.down then
      return { code = 22, stdout = "" }
    end
    if url == "https://api.github.com/repos/Kapeli/feeds/contents/" then
      return { code = 0, stdout = listing }
    elseif url == "https://raw.githubusercontent.com/Kapeli/feeds/master/Lua.xml" then
      return { code = 0, stdout = lua_feed }
    elseif url == "https://kapeli.com/feeds/zzz/user_contributed/build/index.json" then
      return { code = 0, stdout = contributed }
    elseif url:match("%.tgz$") then
      local out = cmd[vim.fn.index(cmd, "-o") + 2]
      vim.system({ "cp", archive, out }):wait()
      return { code = 0, stdout = "" }
    end
    return { code = 22, stdout = "" }
  end,
    seen,
    urls
end

-- Kapeli's own feeds ---------------------------------------------------------

test("Kapeli's feeds install under kapeli.com", function()
  eq(dash.origin, "kapeli.com")
end)

test("a feed search matches the feed names, ignoring case", function()
  local rows = dash.search("lua", runner())
  table.sort(rows, function(a, b)
    return a.name < b.name
  end)
  eq(rows, { { name = "Lua" }, { name = "LuaJIT" } })
end)

test("the feed list is fetched once, however often it is searched", function()
  local system, _, urls = runner()
  dash.search("lua", system)
  dash.search("c++", system)
  eq(#urls, 1)
end)

test("a file that is not a feed is not offered", function()
  eq(dash.search("readme", runner()), {})
end)

test("resolve names the docset for the feed's current version", function()
  eq(dash.resolve("Lua", runner()), "Lua~5.5")
end)

test("a feed that does not exist is an error naming it", function()
  local ok, err = pcall(dash.resolve, "Nope", runner())
  eq(ok, false)
  assert(tostring(err):find("Nope", 1, true), err)
end)

test("a docset's release is the version it is named for", function()
  eq(dash.release("Lua~5.5"), "5.5")
  eq(dash.release("C++~20"), "20")
end)

test("latest asks the feed the docset names", function()
  eq(dash.latest("Lua~5.1", runner()), "Lua~5.5")
end)

test("the current version downloads from the feed's own address", function()
  local system, _, urls = runner()
  dash.index("Lua~5.5", "", system)
  dash.db("Lua~5.5", "", system)
  eq(urls[#urls], "https://kapeli.com/feeds/Lua.tgz")
end)

test("an older version downloads from Kapeli's versions folder", function()
  local system, _, urls = runner()
  dash.index("Lua~5.1", "", system)
  dash.db("Lua~5.1", "", system)
  eq(urls[#urls], "https://kapeli.com/feeds/zzz/versions/Lua/5.1/Lua.tgz")
end)

test("a version the feed does not offer is an error naming it", function()
  local ok, err = pcall(dash.index, "Lua~4.0", "", runner())
  eq(ok, false)
  assert(tostring(err):find("4.0", 1, true), err)
end)

test("index and db come from the docset archive", function()
  local system = runner()
  local index = dash.index("Lua~5.5", "", system)
  local db = dash.db("Lua~5.5", "", system)
  assert(#index.entries > 0, "no entries")
  assert(db["site/guide/manual"], vim.inspect(vim.tbl_keys(db)))
end)

test("a catalogue that cannot be fetched is an error", function()
  local ok = pcall(dash.search, "lua", runner({ down = true }))
  eq(ok, false)
end)

-- The user-contributed feeds ----------------------------------------------------

test("user-contributed docsets install under contrib.kapeli.com", function()
  eq(contrib.origin, "contrib.kapeli.com")
end)

test("a contributed search matches the folder or the display name, with its release", function()
  eq(contrib.search("haproxy lua", runner()), { { name = "HAProxy_Lua", version = "1.0" } })
  eq(contrib.search("jest", runner()), { { name = "Jest", version = "24.1.1" } })
end)

test("the contributed catalogue is fetched once, however often it is searched", function()
  local system, _, urls = runner()
  contrib.search("jest", system)
  contrib.search("swift", system)
  eq(#urls, 1)
end)

test("resolve names the contributed docset's current release", function()
  eq(contrib.resolve("Jest", runner()), "Jest~24.1.1")
end)

test("a contributed docset that does not exist is an error naming it", function()
  local ok, err = pcall(contrib.resolve, "Nope", runner())
  eq(ok, false)
  assert(tostring(err):find("Nope", 1, true), err)
end)

test("the current contributed version downloads from its build folder", function()
  local system, _, urls = runner()
  contrib.index("HAProxy_Lua~1.0", "", system)
  contrib.db("HAProxy_Lua~1.0", "", system)
  eq(urls[#urls], "https://kapeli.com/feeds/zzz/user_contributed/build/HAProxy_Lua/HAProxyLua.tgz")
end)

test("an older contributed version downloads its own archive", function()
  local system, _, urls = runner()
  contrib.index("Jest~23.1.0", "", system)
  contrib.db("Jest~23.1.0", "", system)
  eq(urls[#urls], "https://kapeli.com/feeds/zzz/user_contributed/build/Jest/versions/23.1.0/Jest.tgz")
end)

test("latest asks the contributed catalogue", function()
  eq(contrib.latest("Jest~23.1.0", runner()), "Jest~24.1.1")
end)

test("the same name in both feeds stays two docsets", function()
  -- Swift and Xojo are in both; the origin keeps them apart
  eq(dash.origin ~= contrib.origin, true)
  eq(contrib.resolve("Swift", runner()), "Swift~5.1")
end)

-- Both ----------------------------------------------------------------------------

test("both are whole catalogues: a docset's language comes from its name", function()
  eq(dash.catalogue, true)
  eq(contrib.catalogue, true)
  eq(dash.language, nil)
  eq(contrib.language, nil)
end)

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
