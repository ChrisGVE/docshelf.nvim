-- Tests for lua/docshelf/sources/docsrs.lua, offline: a fake command runner
-- answers the crates.io requests and serves tests/fixtures/docsrs as the zip
-- docs.rs would have handed over.
-- Run from the repository root: nvim --headless -l tests/sources_docsrs_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local docsrs = require("docshelf.sources.docsrs")

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

local fixtures = vim.fn.fnamemodify("tests/fixtures/docsrs", ":p")

--- Answers like docs.rs: `built` names the versions whose zip exists; the zip
--- is the fixture build, packed on the spot so the adapter unpacks a real one.
local function docsrs_runner(built)
  local seen = {}
  return function(cmd)
    seen[#seen + 1] = cmd
    if cmd[1] == "unzip" then
      return vim.system(cmd):wait()
    end
    local url = cmd[#cmd]
    local version = url:match("^https://docs%.rs/crate/[%w%-_]+/([%w%.%-]+)/download$")
    if not version then
      error("unexpected request: " .. url, 0)
    end
    if not vim.tbl_contains(built, version) then
      return { code = 22, stdout = "" }
    end
    local out
    for i, arg in ipairs(cmd) do
      if arg == "-o" then
        out = cmd[i + 1]
      end
    end
    if out then
      vim.system({ "zip", "-q", "-r", out, "." }, { cwd = fixtures }):wait()
    end
    return { code = 0, stdout = "" }
  end,
    seen
end

test("the origin is docs.rs", function()
  eq(docsrs.origin, "docs.rs")
end)

test("docs.rs declares the one language it documents", function()
  eq(docsrs.language, "Rust")
end)

test("a docset's release is the version it is named for", function()
  eq(docsrs.release("serde~1.0.229"), "1.0.229")
end)

test("a name without a version is an error", function()
  local ok, err = pcall(docsrs.release, "serde")
  eq(ok, false)
  assert(tostring(err):find("serde", 1, true), err)
end)

test("index names every documented page, typed by its file name", function()
  local index = docsrs.index("tiny~1.0.0", "", docsrs_runner({ "1.0.0" }))
  eq(index.entries, {
    { name = "tiny::de::ignored::Any", path = "de/ignored/struct.Any", type = "Structs" },
    { name = "tiny::de", path = "de/index", type = "Modules" },
    { name = "tiny::de::Error", path = "de/trait.Error", type = "Traits" },
    { name = "tiny", path = "index", type = "Modules" },
    { name = "tiny::shout", path = "macro.shout", type = "Macros" },
    { name = "tiny::Thing", path = "struct.Thing", type = "Structs" },
  })
end)

test("a redirect stub is not offered as a page of its own", function()
  -- rustdoc writes one where an item is re-exported or a macro has a second
  -- name; it documents nothing and points at the page that does.
  local db = docsrs.db("tiny~1.0.0", "", docsrs_runner({ "1.0.0" }))
  eq(db["macro.shout!"], nil)
  assert(db["macro.shout"], "the page the stub redirects to is still there")
end)

test("rustdoc's own machinery is not offered as documentation", function()
  local index = docsrs.index("tiny~1.0.0", "", docsrs_runner({ "1.0.0" }))
  for _, entry in ipairs(index.entries) do
    assert(not entry.path:match("^all$"), "all.html is in the index")
    assert(not entry.path:match("^src/"), "a source listing is in the index")
  end
end)

test("db has a page per index entry and nothing else", function()
  local system = docsrs_runner({ "1.0.0" })
  local db = docsrs.db("tiny~1.0.0", "", system)
  local pages = vim.tbl_keys(db)
  table.sort(pages)
  eq(pages, {
    "de/ignored/struct.Any",
    "de/index",
    "de/trait.Error",
    "index",
    "macro.shout",
    "struct.Thing",
  })
end)

test("db keeps the item's text and drops the page chrome", function()
  local page = docsrs.db("tiny~1.0.0", "", docsrs_runner({ "1.0.0" }))["struct.Thing"]
  assert(page:find("A thing with a size", 1, true), page)
  assert(page:find("pub struct Thing", 1, true), page)
  for _, gone in ipairs({ '<nav class="sidebar"', "<script", ">Source</a>", ">§</a>", "</main>" }) do
    assert(not page:find(gone, 1, true), gone .. " still in page")
  end
end)

test("a link to another page of the crate keeps its relative shape, without the .html", function()
  -- the installer resolves a link against the page key of the page holding it,
  -- so a whole key here would be read as a key below that page's own folder.
  local db = docsrs.db("tiny~1.0.0", "", docsrs_runner({ "1.0.0" }))
  assert(db["index"]:find('href="struct.Thing"', 1, true), db["index"])
  assert(db["index"]:find('href="de/index"', 1, true), db["index"])
  assert(db["de/trait.Error"]:find('href="../struct.Thing"', 1, true), db["de/trait.Error"])
  assert(db["de/index"]:find('href="../index"', 1, true), db["de/index"])
  assert(db["de/index"]:find('href="trait.Error"', 1, true), db["de/index"])
end)

test("a link that climbs to the crate root and back is written the short way", function()
  -- the page keys the installer resolves a link against cannot climb above the
  -- crate, so a link that does lands outside the docset and stays unread.
  local page = docsrs.db("tiny~1.0.0", "", docsrs_runner({ "1.0.0" }))["de/ignored/struct.Any"]
  assert(page:find('href="../trait.Error"', 1, true), page)
  assert(page:find('href="../../index"', 1, true), page)
end)

test("an anchor on a link to another page is kept", function()
  local page = docsrs.db("tiny~1.0.0", "", docsrs_runner({ "1.0.0" }))["de/trait.Error"]
  assert(page:find('href="../struct.Thing#method.size"', 1, true), page)
end)

test("a link to another crate or to the standard library is left alone", function()
  local db = docsrs.db("tiny~1.0.0", "", docsrs_runner({ "1.0.0" }))
  assert(db["index"]:find('href="https://docs.rs/serde/1.0.229/serde/trait.Serialize.html"', 1, true), db["index"])
  assert(db["de/trait.Error"]:find("https://doc.rust-lang.org/nightly/alloc/string/struct.String.html", 1, true))
end)

test("a link to a file the docset does not hold becomes its address on docs.rs", function()
  local db = docsrs.db("tiny~1.0.0", "", docsrs_runner({ "1.0.0" }))
  -- the source listing is in the build but is not a page: it stays reachable
  assert(db["index"]:find('href="https://docs.rs/tiny/1.0.0/src/tiny/lib.rs.html#3"', 1, true), db["index"])
end)

test("no rewritten link still points at a .html file inside the docset", function()
  local db = docsrs.db("tiny~1.0.0", "", docsrs_runner({ "1.0.0" }))
  for page, html in pairs(db) do
    for href in html:gmatch('href="([^"]*)"') do
      if not href:match("^%a[%w+.-]*:") and not href:match("^#") then
        assert(not href:match("%.html"), page .. " keeps a raw link: " .. href)
      end
    end
  end
end)

test("index and db download the zip only once per install", function()
  local system, seen = docsrs_runner({ "1.0.0" })
  docsrs.index("tiny~1.0.0", "", system)
  docsrs.db("tiny~1.0.0", "", system)
  local downloads = vim.tbl_filter(function(cmd)
    return cmd[1] == "curl" and vim.tbl_contains(cmd, "-o")
  end, seen)
  eq(#downloads, 1)
end)

test("a crate version docs.rs never built is an error naming it", function()
  local ok, err = pcall(docsrs.index, "tiny~9.9.9", "", docsrs_runner({ "1.0.0" }))
  eq(ok, false)
  assert(tostring(err):find("no documentation on docs.rs for tiny 9.9.9", 1, true), err)
end)

-- Searching: the fake runner answers crates.io with a body of the test's
-- choosing, so the shape it returns is pinned without a network.
local function search_runner(body, code)
  local seen = {}
  return function(cmd)
    seen[#seen + 1] = cmd
    return { code = code or 0, stdout = body }
  end, seen
end

test("a search returns each crate with the version a row can install", function()
  local system = search_runner('{"crates":[{"name":"serde","max_stable_version":"1.0.229","max_version":"1.0.230"}]}')
  eq(docsrs.search("serde", system), { { name = "serde", version = "1.0.229" } })
end)

test("a crate with no stable release falls back to its newest version", function()
  local system = search_runner('{"crates":[{"name":"early","max_version":"0.1.0-beta.1"}]}')
  eq(docsrs.search("early", system), { { name = "early", version = "0.1.0-beta.1" } })
end)

test("a link written from the site root keeps its place on docs.rs", function()
  local page = docsrs.db("tiny~1.0.0", "", docsrs_runner({ "1.0.0" }))["de/trait.Error"]
  assert(page:find('href="https://docs.rs/crate/tiny/latest"', 1, true), page)
end)

test("a search sends the query encoded for a URL, with a real user agent", function()
  local system, seen = search_runner('{"crates":[]}')
  docsrs.search("async runtime", system)
  assert(seen[1][#seen[1]]:find("q=async%20runtime", 1, true), vim.inspect(seen[1]))
  assert(vim.tbl_contains(seen[1], "-A"), "crates.io refuses a request with no user agent")
end)

test("a search that finds nothing returns no rows", function()
  eq(docsrs.search("nothinglikethis", search_runner('{"crates":[]}')), {})
end)

test("a failed request is an error, so the picker can report the source as silent", function()
  eq(pcall(docsrs.search, "serde", search_runner("", 22)), false)
end)

test("an answer that is not a list of crates is an error", function()
  eq(pcall(docsrs.search, "serde", search_runner('{"errors":[{"detail":"nope"}]}')), false)
end)

test("resolve names the docset for a crate's newest stable release", function()
  local system = search_runner('{"crate":{"name":"serde","max_stable_version":"1.0.229"}}')
  eq(docsrs.resolve("serde", system), "serde~1.0.229")
end)

test("resolving a crate that does not exist is an error naming it", function()
  local ok, err = pcall(docsrs.resolve, "nosuchcrate", search_runner('{"errors":[{"detail":"Not Found"}]}'))
  eq(ok, false)
  assert(tostring(err):find("nosuchcrate", 1, true), err)
end)

test("latest asks about the crate a docset names, not the docset", function()
  local system = search_runner('{"crate":{"name":"serde","max_stable_version":"1.0.230"}}')
  eq(docsrs.latest("serde~1.0.229", system), "serde~1.0.230")
end)

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
