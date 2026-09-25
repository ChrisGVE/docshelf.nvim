-- Tests for lua/docshelf/sources/hexdocs.lua, offline: a fake command runner
-- answers the hex.pm requests and serves a folder of tests/fixtures/hexdocs as
-- the package's docs tarball. Each folder is one generator's output:
--   tiny        current ExDoc (dist/search_data-*.js), an Elixir package
--   tiny_items  ExDoc 0.2x (dist/search_items-*.js, not strict JSON), Erlang
--   tiny_old    ExDoc before 0.20 (only dist/sidebar_items-*.js)
--   tiny_gleam  Gleam's own generator (search_data.json)
-- Run from the repository root: nvim --headless -l tests/sources_hexdocs_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local hexdocs = require("docshelf.sources.hexdocs")

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

local fixtures = vim.fn.fnamemodify("tests/fixtures/hexdocs", ":p")

local function release(version, has_docs)
  return { version = version, has_docs = has_docs }
end

-- A package as hex.pm describes it: releases newest first.
local function package(name, latest_stable, releases)
  return {
    name = name,
    latest_stable_version = latest_stable,
    latest_version = releases[1].version,
    releases = releases,
  }
end

-- Answers like hex.pm and repo.hex.pm. `packages` maps a name to its package;
-- `found` is what a search answers. A docs tarball is built from the fixture
-- folder named like the package. Unpacking a real Gleam tarball leaves its
-- top-level files with no permissions at all (mode 000); the fake unpack does
-- the same to tiny_gleam, since a fixture with such files could not be
-- archived in the first place.
local function hex_runner(packages, found)
  local seen = {}
  return function(cmd)
    seen[#seen + 1] = cmd
    if cmd[1] == "tar" and cmd[2] == "-xzf" then
      local res = vim.system(cmd):wait()
      local into = cmd[#cmd]
      if vim.fn.filereadable(into .. "/search_data.json") == 1 then
        vim.system({ "chmod", "000", into .. "/search_data.json", into .. "/index.html" }):wait()
      end
      return res
    end
    if cmd[1] ~= "curl" then
      return vim.system(cmd):wait()
    end
    local url = cmd[#cmd]
    if url:match("/api/packages%?search=") then
      return { code = 0, stdout = vim.json.encode(found or {}) }
    end
    local name = url:match("/api/packages/([%w_]+)$")
    if name then
      if not packages[name] then
        return { code = 22, stdout = "" }
      end
      return { code = 0, stdout = vim.json.encode(packages[name]) }
    end
    local tarball = url:match("^https://repo%.hex%.pm/docs/(.+)%.tar%.gz$")
    local folder = tarball and tarball:match("^(.-)%-%d")
    if not (folder and vim.fn.isdirectory(fixtures .. folder) == 1) then
      return { code = 22, stdout = "" }
    end
    local out
    for i, arg in ipairs(cmd) do
      if arg == "-o" then
        out = cmd[i + 1]
      end
    end
    vim.system({ "tar", "-czf", out, "-C", fixtures .. folder, "." }):wait()
    return { code = 0, stdout = "" }
  end,
    seen
end

local function by_path(index)
  local found = {}
  for _, entry in ipairs(index.entries) do
    found[entry.path] = entry
  end
  return found
end

test("the origin is hexdocs.pm", function()
  eq(hexdocs.origin, "hexdocs.pm")
end)

test("it documents the languages hex.pm packages are written in", function()
  eq(hexdocs.language, nil)
  eq(hexdocs.languages, { "Elixir", "Erlang", "Gleam" })
end)

test("search keeps packages with documentation, at the release to fetch", function()
  local system = hex_runner({}, {
    package("tiny", "1.0.0", { release("1.1.0-rc.1", true), release("1.0.0", true) }),
    package("undocumented", "2.0.0", { release("2.0.0", false) }),
    package("stable_undocumented", "3.0.0", { release("3.0.0", false), release("2.9.0", true) }),
  })
  eq(hexdocs.search("tiny", system), {
    { name = "tiny", version = "1.0.0" },
    { name = "stable_undocumented", version = "2.9.0" },
  })
end)

test("search asks hex.pm by recent downloads, not by name", function()
  local system, seen = hex_runner({}, {})
  hexdocs.search("json parser", system)
  local url = seen[1][#seen[1]]
  assert(url:find("search=json%20parser", 1, true), url)
  assert(url:find("sort=recent_downloads", 1, true), url)
end)

test("a query's own & and + stay inside the search term", function()
  local system, seen = hex_runner({}, {})
  hexdocs.search("a&b+c", system)
  local url = seen[1][#seen[1]]
  assert(url:find("search=a%26b%2bc&sort=", 1, true), url)
end)

test("a package with only prereleases documented offers the newest one", function()
  local system = hex_runner({}, {
    package("fresh", nil, { release("0.2.0-dev", true), release("0.1.0-dev", true) }),
  })
  eq(hexdocs.search("fresh", system), { { name = "fresh", version = "0.2.0-dev" } })
end)

test("resolve picks the newest stable release with documentation", function()
  local system = hex_runner({
    tiny = package("tiny", "1.0.0", { release("1.1.0-rc.1", true), release("1.0.0", false), release("0.9.0", true) }),
  })
  eq(hexdocs.resolve("tiny", system), "tiny~0.9.0")
end)

test("resolve says so when nothing is documented", function()
  local system = hex_runner({ bare = package("bare", "1.0.0", { release("1.0.0", false) }) })
  local ok, err = pcall(hexdocs.resolve, "bare", system)
  eq(ok, false)
  assert(tostring(err):find("no documentation on hexdocs.pm for bare", 1, true), err)
end)

test("release reads the version out of the docset, prereleases included", function()
  eq(hexdocs.release("tiny~1.0.0"), "1.0.0")
  eq(hexdocs.release("phoenix_live_view~1.2.0-rc.1"), "1.2.0-rc.1")
end)

test("latest asks about the package a docset names", function()
  local system = hex_runner({ tiny = package("tiny", "1.1.0", { release("1.1.0", true), release("1.0.0", true) }) })
  eq(hexdocs.latest("tiny~1.0.0", system), "tiny~1.1.0")
end)

test("index lists what current ExDoc's search data lists, on pages the docs hold", function()
  local found = by_path(hexdocs.index("tiny~1.0.0", nil, hex_runner({})))
  eq(found["Tiny"], { name = "Tiny", path = "Tiny", type = "Modules" })
  eq(found["Tiny#greet/1"], { name = "Tiny.greet/1", path = "Tiny#greet/1", type = "Functions" })
  eq(found["Tiny#greet/1-examples"].name, "Examples - Tiny.greet/1")
  eq(found["Tiny.Helper#t:t/0"], { name = "Tiny.Helper.t/0", path = "Tiny.Helper#t:t/0", type = "Types" })
  eq(found["readme"], { name = "Tiny", path = "readme", type = "Guides" })
  eq(found["readme#usage"].type, "Guides")
  -- listed by the search data, but no page was built for it
  eq(found["Tiny.Gone"], nil)
  -- a page no index lists is still an entry, named by its title, so that a
  -- link to it can be followed
  eq(found["api-reference"], { name = "API Reference", path = "api-reference", type = "Guides" })
  -- the redirect, the 404 page and the search page are not documentation
  eq(found["index"], nil)
  eq(found["404"], nil)
  eq(found["search"], nil)
  hexdocs.db("tiny~1.0.0", nil, hex_runner({}))
end)

test("an ExDoc package's language comes from its stylesheet", function()
  hexdocs.index("tiny~1.0.0", nil, hex_runner({}))
  hexdocs.db("tiny~1.0.0", nil, hex_runner({}))
  eq(hexdocs.language_of("tiny~1.0.0"), "Elixir")
  hexdocs.index("tiny_items~0.1.0", nil, hex_runner({}))
  hexdocs.db("tiny_items~0.1.0", nil, hex_runner({}))
  eq(hexdocs.language_of("tiny_items~0.1.0"), "Erlang")
end)

test("index reads ExDoc 0.2x search items, which are JavaScript rather than JSON", function()
  local found = by_path(hexdocs.index("tiny_items~0.1.0", nil, hex_runner({})))
  eq(found["tiny_erl#hello-1"], { name = "tiny_erl.hello/1", path = "tiny_erl#hello-1", type = "Functions" })
  eq(found["tiny_erl"].type, "Modules")
  hexdocs.db("tiny_items~0.1.0", nil, hex_runner({}))
end)

test("index builds the entries of an old ExDoc from its sidebar", function()
  local found = by_path(hexdocs.index("tiny_old~1.0.0", nil, hex_runner({})))
  eq(found["Old"], { name = "Old", path = "Old", type = "Modules" })
  eq(found["Old#run/0"], { name = "Old.run/0", path = "Old#run/0", type = "Functions" })
  eq(found["Old#t:t/0"], { name = "Old.t/0", path = "Old#t:t/0", type = "Types" })
  -- no page for these in the fixture
  eq(found["Old.Error"], nil)
  eq(found["api-reference"], nil)
  hexdocs.db("tiny_old~1.0.0", nil, hex_runner({}))
  eq(hexdocs.language_of("tiny_old~1.0.0"), "Elixir")
end)

test("a Gleam package is read through its own search data, unlocked first", function()
  local found = by_path(hexdocs.index("tiny_gleam~1.0.0", nil, hex_runner({})))
  eq(found["index"], { name = "tiny_gleam", path = "index", type = "Guides" })
  eq(found["gleam/tiny"], { name = "gleam/tiny", path = "gleam/tiny", type = "Modules" })
  eq(found["gleam/tiny#greet"], { name = "gleam/tiny.greet", path = "gleam/tiny#greet", type = "Values" })
  local db = hexdocs.db("tiny_gleam~1.0.0", nil, hex_runner({}))
  eq(hexdocs.language_of("tiny_gleam~1.0.0"), "Gleam")
  assert(db["index"]:find("A Gleam package", 1, true), db["index"])
end)

test("db keeps the documentation and drops ExDoc's chrome", function()
  hexdocs.index("tiny~1.0.0", nil, hex_runner({}))
  local db = hexdocs.db("tiny~1.0.0", nil, hex_runner({}))
  eq(vim.tbl_keys(db) ~= nil, true)
  local keys = vim.tbl_keys(db)
  table.sort(keys)
  eq(keys, { "Tiny", "Tiny.Helper", "api-reference", "readme" })
  local page = db["Tiny"]
  for _, gone in ipairs({
    "sidebar",
    "search-bar",
    "View Source",
    "Link to this function",
    "footer",
    "<script",
    "<button",
    "ri-link-m",
  }) do
    assert(not page:find(gone, 1, true), gone .. " left in:\n" .. page)
  end
  assert(page:find("Tiny greets people", 1, true), page)
end)

test("db puts each detail's id on its signature, where its text begins", function()
  local db = hexdocs.db("tiny~1.0.0", nil, hex_runner({}))
  local page = db["Tiny"]
  assert(page:find('<h1 id="greet/1" class="signature" translate="no">greet(', 1, true), page)
  assert(not page:find('class="detail" id=', 1, true), page)
  -- an alias id with no text of its own is dropped
  assert(not page:find('id="greet/0"', 1, true), page)
  -- a section heading starts with its text once its link icon is gone
  assert(page:find('<h2 id="greet/1%-examples" class="section%-heading">%s*<span class="text">Examples'), page)
  local old = hexdocs.db("tiny_old~1.0.0", nil, hex_runner({}))
  assert(old["Old"]:find('<span id="run/0" class="signature">run()</span>', 1, true), old["Old"])
end)

test("db rewrites links: pages of the docs stay pages, the rest go to hexdocs.pm", function()
  local db = hexdocs.db("tiny~1.0.0", nil, hex_runner({}))
  local page = db["Tiny"]
  assert(page:find('href="readme#usage"', 1, true), page)
  assert(page:find('href="Tiny.Helper#t:t/0"', 1, true), page)
  assert(page:find('href="https://hexdocs.pm/elixir/Kernel.html#to_string/1"', 1, true), page)
  -- a link to the page itself is its text (elinks would make it the folder)
  assert(db["Tiny.Helper"]:find("on this page", 1, true), db["Tiny.Helper"])
  -- a page the tarball lacks is still on the site
  assert(page:find('href="https://hexdocs.pm/tiny/1.0.0/Tiny.Old.html"', 1, true), page)
end)

test("db unwraps a Gleam heading's link to itself and drops the source link", function()
  local db = hexdocs.db("tiny_gleam~1.0.0", nil, hex_runner({}))
  local page = db["gleam/tiny"]
  assert(page:find('<h2 id="greet">%s*greet%s*</h2>'), page)
  assert(not page:find("member-source", 1, true), page)
  assert(not page:find("<svg", 1, true), page)
  assert(not page:find("sidebar", 1, true), page)
  assert(page:find('href="../index"', 1, true), page)
end)

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
