-- Tests for lua/docshelf/sources/cljdoc.lua, offline: a fake command runner
-- answers as cljdoc.org -- its search API, the redirect naming a library's
-- current version, the search set, and the offline bundle, which a fake unzip
-- unpacks from tests/fixtures/cljdoc/demo-1.0.0.
--
-- search.json is cut from cljdoc.org/api/search?q=ring (2026-09-26); the demo
-- library is written in the markup of ring-core 1.15.5's offline bundle and
-- core.async's search set: var names holding "!" and ">" (ids written
-- "&gt;!" in the page and "%3E!" in a link), a def on two platforms listed
-- twice, a protocol with a member, raw docstrings beside the rendered ones.
-- Run from the repository root: nvim --headless -l tests/sources_cljdoc_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local cljdoc = require("docshelf.sources.cljdoc")

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

local function has(haystack, needle)
  if not tostring(haystack):find(needle, 1, true) then
    error("expected to find " .. vim.inspect(needle) .. " in " .. vim.inspect(haystack), 2)
  end
end

local function has_not(haystack, needle)
  if tostring(haystack):find(needle, 1, true) then
    error("expected NOT to find " .. vim.inspect(needle) .. " in " .. vim.inspect(haystack), 2)
  end
end

local fixtures = vim.fn.fnamemodify("tests/fixtures/cljdoc", ":p")
local site = "https://cljdoc.org/"

local function read(file)
  return table.concat(vim.fn.readfile(fixtures .. file, "b"), "\n")
end

--- Answers like cljdoc.org, which knows one library, demo/demo 1.0.0. An
--- offline bundle is a file naming its fixture folder, which the fake unzip
--- copies.
local function runner()
  local seen = {}
  return function(cmd)
    seen[#seen + 1] = cmd
    if cmd[1] == "unzip" then
      local bundle, into = cmd[vim.fn.index(cmd, "-o") + 2], cmd[#cmd]
      local file = assert(io.open(bundle))
      local folder = file:read("*a")
      file:close()
      vim.fn.mkdir(into, "p")
      return vim.system({ "cp", "-R", fixtures .. folder, into }):wait()
    end
    local url = cmd[#cmd]
    if url:sub(1, #site) ~= site then
      error("unexpected request " .. url)
    end
    local path = url:sub(#site + 1)
    if path:match("^api/search%?q=") then
      return { code = 0, stdout = read("search.json") }
    end
    if path:match("^d/") then
      -- curl without -f: a 404 still exits 0, with no redirect to write
      return { code = 0, stdout = path == "d/demo/demo" and site .. "d/demo/demo/1.0.0" or "" }
    end
    if path == "api/searchset/demo/demo/1.0.0" then
      return { code = 0, stdout = read("searchset.json") }
    end
    if path == "download/demo/demo/1.0.0" then
      local out = assert(io.open(cmd[vim.fn.index(cmd, "-o") + 2], "w"))
      out:write("demo-1.0.0")
      out:close()
      return { code = 0, stdout = "" }
    end
    return { code = 22, stdout = "" }
  end,
    seen
end

local docset = "demo@demo~1.0.0"

local function entries_of()
  local by_path = {}
  local all = cljdoc.index(docset, "", runner()).entries
  for _, entry in ipairs(all) do
    by_path[entry.path] = entry
  end
  return by_path, all
end

local function db()
  local system = runner()
  cljdoc.index(docset, "", system)
  return cljdoc.db(docset, "", system)
end

-- ------------------------------------------------------------ the contract

test("the adapter is cljdoc.org, for Clojure", function()
  eq(cljdoc.origin, "cljdoc.org")
  eq(cljdoc.language, "Clojure")
end)

test("search lists libraries as artifact@group, without a version", function()
  local system, seen = runner()
  eq(cljdoc.search("ring", system), {
    { name = "ring@ring" },
    { name = "ring-codec@ring" },
    { name = "ring-core@ring" },
  })
  has(seen[1][#seen[1]], "https://cljdoc.org/api/search?q=ring")
end)

test("search sends the query encoded, and says so when cljdoc does not answer", function()
  local system, seen = runner()
  cljdoc.search("a&b c", system)
  has(seen[1][#seen[1]], "q=a%26b%20c")
  local ok, err = pcall(cljdoc.search, "ring", function()
    return { code = 6, stdout = "" }
  end)
  eq(ok, false)
  has(err, "could not search cljdoc.org")
end)

test("resolve takes the version cljdoc.org redirects a library to", function()
  eq(cljdoc.resolve("demo@demo", runner()), "demo@demo~1.0.0")
  local ok, err = pcall(cljdoc.resolve, "nosuch@nowhere", runner())
  eq(ok, false)
  has(err, "cljdoc.org has no documentation for nosuch@nowhere")
end)

test("release is the docset's version and latest asks cljdoc.org", function()
  eq(cljdoc.release(docset), "1.0.0")
  eq(cljdoc.latest("demo@demo~0.9", runner()), docset)
  local ok, err = pcall(cljdoc.release, "demo~1.0.0")
  eq(ok, false)
  has(err, "artifact@group~version")
end)

-- ------------------------------------------------------------ the index

test("namespaces and defs are entries, named the Clojure way", function()
  local entries = entries_of()
  eq(entries["api/demo.core"], { name = "demo.core", path = "api/demo.core", type = "Namespaces" })
  eq(entries["api/demo.core#respond"], { name = "demo.core/respond", path = "api/demo.core#respond", type = "Vars" })
  eq(entries["api/demo.async#go"], { name = "demo.async/go", path = "api/demo.async#go", type = "Macros" })
  eq(
    entries["api/demo.async#dispatch"],
    { name = "demo.async/dispatch", path = "api/demo.async#dispatch", type = "Multimethods" }
  )
  eq(entries["api/demo.core#Sized"], { name = "demo.core/Sized", path = "api/demo.core#Sized", type = "Protocols" })
  eq(
    entries["api/demo.core#size-of"],
    { name = "demo.core/size-of", path = "api/demo.core#size-of", type = "Protocol Methods" }
  )
end)

test("an id holding punctuation is made plain, the entry keeps its name", function()
  eq(entries_of()["api/demo.async#.3E.21"], { name = "demo.async/>!", path = "api/demo.async#.3E.21", type = "Vars" })
end)

test("a def on two platforms is one entry", function()
  local _, all = entries_of()
  local count = 0
  for _, entry in ipairs(all) do
    count = count + (entry.path == "api/demo.core#respond" and 1 or 0)
  end
  eq(count, 1)
  eq(#all, 12)
end)

test("the library, each article and each section are entries", function()
  local entries = entries_of()
  eq(entries["index"], { name = "demo/demo", path = "index", type = "Guides" })
  eq(entries["doc/readme"], { name = "Readme", path = "doc/readme", type = "Guides" })
  eq(
    entries["doc/readme#installation"],
    { name = "Readme - Installation", path = "doc/readme#installation", type = "Sections" }
  )
end)

test("a version cljdoc.org has not built says so", function()
  local ok, err = pcall(cljdoc.index, "demo@demo~0.1", "", runner())
  eq(ok, false)
  has(err, "cljdoc.org has not built the documentation of demo@demo 0.1")
end)

-- ------------------------------------------------------------ the pages

test("every page of the bundle is a page, the stylesheets are not", function()
  local keys = vim.tbl_keys(db())
  table.sort(keys)
  eq(keys, { "api/demo.async", "api/demo.core", "doc/readme", "index" })
end)

test("a page is its documentation, without the bar above it", function()
  local page = db()["api/demo.core"]
  has(page, "Core things.")
  has_not(page, "<nav")
  has_not(page, "Namespaces</a>")
  has_not(page, "<svg")
end)

test("the raw docstrings and their switches are dropped", function()
  local page = db()["api/demo.core"]
  has_not(page, "raw docstring")
  has_not(page, "raw dn")
end)

test("each def's id is plain and named by a heading", function()
  local pages = db()
  has(pages["api/demo.core"], '<h4 id="respond">demo.core/respond</h4>')
  has(pages["api/demo.async"], '<h4 id=".3E.21">demo.async/&gt;!</h4>')
end)

test("links inside the library name their page and a plain anchor", function()
  local pages = db()
  has(pages["api/demo.core"], 'href="demo.async#.3E.21"')
  has(pages["api/demo.core"], 'href="../doc/readme#installation"')
  has(pages["doc/readme"], 'href="../api/demo.core#respond"')
  has(pages["index"], 'href="api/demo.async#.3E.21"')
end)

test("a link to a page the bundle lacks goes to cljdoc.org", function()
  has(db()["api/demo.async"], 'href="https://cljdoc.org/d/demo/demo/1.0.0/api/demo.other.html"')
end)

if failures > 0 then
  print(failures .. " failure(s)")
  os.exit(1)
end
print("all passed")
