-- Tests for lua/docshelf/dash.lua, offline: the fixture docsets under
-- tests/fixtures/dash are packed into .tgz archives on the spot, their
-- docSet.dsidx built from tokens.sql, and a fake command runner hands them
-- over as a download would. tar and sqlite3 run for real.
-- Run from the repository root: nvim --headless -l tests/dash_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local dash = require("docshelf.dash")

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

--- Pack tests/fixtures/dash/<layout> into a .tgz the way Kapeli ships one:
--- a single <Name>.docset folder, its index already built.
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

local archives = { coredata = pack("coredata"), searchindex = pack("searchindex") }

--- A runner that serves `archive` for any curl download and runs the rest.
local function serving(archive)
  local seen = {}
  return function(cmd)
    seen[#seen + 1] = cmd
    if cmd[1] ~= "curl" then
      return vim.system(cmd, { text = true }):wait()
    end
    local out
    for i, arg in ipairs(cmd) do
      if arg == "-o" then
        out = cmd[i + 1]
      end
    end
    if not archive then
      return { code = 22, stdout = "" }
    end
    vim.system({ "cp", archive, out }):wait()
    return { code = 0, stdout = "" }
  end,
    seen
end

local function sorted_keys(t)
  local keys = vim.tbl_keys(t)
  table.sort(keys)
  return keys
end

test("a plain version is its own release", function()
  eq(dash.release("5.4"), "5.4")
  eq(dash.release("1.0.0b1"), "1.0.0b1")
end)

test("a version with a build after a slash keeps the version", function()
  -- Kapeli writes <version>/<build> when a docset is rebuilt
  eq(dash.release("1.0.1/0"), "1.0.1")
  eq(dash.release("4.5.4/2026-01-14"), "4.5.4")
end)

test("a version that is only a build uses the build", function()
  eq(dash.release("/8.5_bf6e24"), "8.5_bf6e24")
end)

test("a release is safe in a folder name", function()
  eq(dash.release("4.0 (Hogfather)"), "4.0_Hogfather")
  eq(dash.release("(2020, Jun 28)/2020-06-28"), "2020_Jun_28")
  eq(dash.release("0.8.2@dev"), "0.8.2_dev")
end)

test("a docset with no version at all is released as 'latest'", function()
  eq(dash.release(""), "latest")
  eq(dash.release(nil), "latest")
end)

test("the Core Data index names each token with its page and anchor", function()
  local system = serving(archives.coredata)
  local index = dash.index("tiny~1.2", "https://example.org/Tiny.tgz", system)
  dash.forget("tiny~1.2")
  table.sort(index.entries, function(a, b)
    return a.name < b.name
  end)
  eq(index.entries, {
    { name = "Tiny index", path = "site/guide/index", type = "Pages" },
    { name = "Tiny manual", path = "site/guide/manual", type = "Guide" },
    { name = "tiny.close", path = "site/guide/manual#//apple_ref/func/tiny%2Eclose", type = "func" },
    { name = "tiny.open", path = "site/guide/manual#//apple_ref/func/tiny%2Eopen", type = "func" },
  })
end)

test("every page is an entry of its own, named by its title or its path", function()
  -- the installer only resolves a link to a page that is an entry, and Dash
  -- indexes anchors: without this, "index#core.emerg" leads nowhere
  local system = serving(archives.searchindex)
  local index = dash.index("small~1.0", "https://example.org/Small.tgz", system)
  dash.forget("small~1.0")
  local pages = vim.tbl_filter(function(entry)
    return not entry.path:find("#", 1, true)
  end, index.entries)
  eq(#pages, 2)
end)

test("an entry on a page the archive does not hold is left out", function()
  -- 'Online only' points at a web address, which no buffer can show
  local system = serving(archives.coredata)
  local index = dash.index("tiny~1.2", "https://example.org/Tiny.tgz", system)
  dash.forget("tiny~1.2")
  for _, entry in ipairs(index.entries) do
    assert(entry.name ~= "Online only", "an online page is in the index")
  end
end)

test("the searchIndex layout drops Dash's entry markup from a path", function()
  local system = serving(archives.searchindex)
  local index = dash.index("small~1.0", "https://example.org/Small.tgz", system)
  dash.forget("small~1.0")
  table.sort(index.entries, function(a, b)
    return a.name < b.name
  end)
  eq(index.entries, {
    { name = "Extra", path = "_static/extra", type = "Guide" },
    { name = "core.alert", path = "index#core.alert", type = "Directive" },
    { name = "core.emerg", path = "index#core.emerg", type = "Directive" },
    { name = "index", path = "index", type = "Pages" },
  })
end)

test("db holds every page of the archive, keyed without .html", function()
  local system = serving(archives.coredata)
  dash.index("tiny~1.2", "https://example.org/Tiny.tgz", system)
  local db = dash.db("tiny~1.2", "https://example.org/Tiny.tgz", system)
  eq(sorted_keys(db), { "site/guide/index", "site/guide/manual" })
end)

test("a page that only redirects elsewhere is not a page", function()
  -- Kapeli's archives open on a mirroring tool's refresh stub
  local system = serving(archives.coredata)
  local index = dash.index("tiny~1.2", "https://example.org/Tiny.tgz", system)
  local db = dash.db("tiny~1.2", "https://example.org/Tiny.tgz", system)
  eq(db["index"], nil)
  for _, entry in ipairs(index.entries) do
    assert(entry.path ~= "index", "the refresh stub is in the index")
  end
end)

test("index and db download the archive only once per install", function()
  local system, seen = serving(archives.coredata)
  dash.index("tiny~1.2", "https://example.org/Tiny.tgz", system)
  dash.db("tiny~1.2", "https://example.org/Tiny.tgz", system)
  local downloads = vim.tbl_filter(function(cmd)
    return cmd[1] == "curl"
  end, seen)
  eq(#downloads, 1)
end)

test("a Dash anchor becomes an id the installer can find", function()
  local system = serving(archives.coredata)
  local page = dash.db("tiny~1.2", "https://example.org/Tiny.tgz", system)["site/guide/manual"]
  assert(page:find('<a id="//apple_ref/func/tiny%2Eopen"></a>', 1, true), page)
  -- the attributes come in either order in real docsets
  assert(page:find('<a id="//apple_ref/func/tiny%2Eclose"></a>', 1, true), page)
  assert(not page:find("dashAnchor", 1, true), page)
end)

test("an anchor written as a name is an id too, so a link to it lands", function()
  -- older HTML, the Lua manual among it, names its anchors this way
  local system = serving(archives.coredata)
  local page = dash.db("tiny~1.2", "https://example.org/Tiny.tgz", system)["site/guide/manual"]
  assert(page:find('<a id="pdf-tiny.open">', 1, true), page)
  assert(page:find('<A id="shouted">', 1, true), page)
end)

test("a page keeps its body and loses scripts and styles", function()
  local system = serving(archives.coredata)
  local page = dash.db("tiny~1.2", "https://example.org/Tiny.tgz", system)["site/guide/manual"]
  assert(page:find("<h1>Tiny manual</h1>", 1, true), page)
  for _, gone in ipairs({ "<script", "<SCRIPT", "<style", "<title>", "<head>" }) do
    assert(not page:find(gone, 1, true), gone .. " still in page")
  end
end)

test("a link to another page of the docset becomes its relative key", function()
  local system = serving(archives.coredata)
  local db = dash.db("tiny~1.2", "https://example.org/Tiny.tgz", system)
  assert(db["site/guide/manual"]:find('href="index"', 1, true), db["site/guide/manual"])
  assert(db["site/guide/index"]:find('href="manual#pdf-tiny.open"', 1, true), db["site/guide/index"])
end)

test("a link the archive cannot answer keeps its text and loses the link", function()
  -- an archive has no site behind it to send the link to
  local system = serving(archives.coredata)
  local page = dash.db("tiny~1.2", "https://example.org/Tiny.tgz", system)["site/guide/manual"]
  assert(page:find("a page not in the docset", 1, true), page)
  assert(not page:find("other.html", 1, true), page)
  assert(not page:find('src="logo.png"', 1, true), page)
end)

test("links to the web and within the page are kept", function()
  local system = serving(archives.coredata)
  local page = dash.db("tiny~1.2", "https://example.org/Tiny.tgz", system)["site/guide/manual"]
  assert(page:find('href="https://example.org/tiny"', 1, true), page)
  assert(page:find('href="#pdf-tiny.open"', 1, true), page)
end)

test("a link climbing out of a subfolder reaches its page", function()
  local system = serving(archives.searchindex)
  local db = dash.db("small~1.0", "https://example.org/Small.tgz", system)
  assert(db["_static/extra"]:find('href="../index#core.emerg"', 1, true), db["_static/extra"])
  assert(db["index"]:find('href="_static/extra"', 1, true), db["index"])
end)

test("a failed download is an error naming the address", function()
  local system = serving(nil)
  local ok, err = pcall(dash.index, "gone~1.0", "https://example.org/Gone.tgz", system)
  eq(ok, false)
  assert(tostring(err):find("https://example.org/Gone.tgz", 1, true), err)
end)

test("the unpacked archive is removed once db has read it", function()
  local system, seen = serving(archives.coredata)
  dash.index("tiny~1.2", "https://example.org/Tiny.tgz", system)
  dash.db("tiny~1.2", "https://example.org/Tiny.tgz", system)
  local archive = seen[1][vim.fn.index(seen[1], "-o") + 2]
  eq(vim.fn.isdirectory(vim.fs.dirname(archive)), 0)
end)

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
