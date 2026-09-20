-- Tests for lua/apidocs/sources/sphinx.lua, offline: a fake command runner
-- serves tests/fixtures/sphinx/site as the documentation site, so the whole
-- path -- inventory fetch, zlib inflate, entry building, page fetch, link
-- rewriting -- runs for real against a site that is only on disk.
--
-- The inflate is NOT faked: the fixture's objects.inv is a real zlib stream
-- and the adapter decompresses it the way it would any other, which is the
-- half of this source that has no equivalent anywhere else in the plugin.
-- Run from the repository root: nvim --headless -l tests/sources_sphinx_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local sphinx = require("apidocs.sources.sphinx")
local internal = sphinx._internal

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

local fixtures = vim.fn.fnamemodify("tests/fixtures/sphinx/site", ":p"):gsub("/$", "")
local site = "https://widget.example/doc/"

-- The install writes the remembered sites beside the installed docsets, so the
-- specs point the data folder at a scratch directory of their own.
local scratch = vim.fn.tempname()
vim.fn.mkdir(scratch, "p")
vim.env.XDG_DATA_HOME = scratch

--- Answers like the site: anything under `site` is served from the fixture,
--- and everything else -- python3, sh, gzip -- is really run, because that is
--- the code being tested.
local function runner(opts)
  opts = opts or {}
  local seen = { urls = {}, cmds = {} }
  local function serve(url, out)
    seen.urls[#seen.urls + 1] = url
    if url:sub(1, #site) ~= site then
      return false
    end
    local path = url:sub(#site + 1)
    if path == "" or path:sub(-1) == "/" then
      path = path .. "index.html"
    end
    local file = fixtures .. "/" .. path
    if vim.fn.filereadable(file) ~= 1 then
      return false
    end
    vim.fn.mkdir(vim.fn.fnamemodify(out, ":h"), "p")
    vim.fn.writefile(vim.fn.readfile(file, "b"), out, "b")
    return true
  end
  return function(cmd, cmd_opts)
    seen.cmds[#seen.cmds + 1] = cmd
    if cmd[1] ~= "curl" then
      return vim.system(cmd, cmd_opts):wait()
    end
    if cmd[2] == "--help" then
      return { code = 0, stdout = opts.parallel and "--parallel-max <num>" or "", stderr = "" }
    end
    -- One URL and one -o, or a config file of url/output pairs.
    local config
    for i, arg in ipairs(cmd) do
      if arg == "-K" then
        config = cmd[i + 1]
      end
    end
    if config then
      local url
      local ok = true
      for _, line in ipairs(vim.fn.readfile(config)) do
        local value = line:match('"(.*)"')
        if line:match("^url") then
          url = value
        elseif line:match("^output") then
          ok = serve(url, value) and ok
        end
      end
      return { code = ok and 0 or 22, stdout = "", stderr = "" }
    end
    local out
    for i, arg in ipairs(cmd) do
      if arg == "-o" then
        out = cmd[i + 1]
      end
    end
    local found = serve(cmd[#cmd], out)
    return { code = found and 0 or 22, stdout = "", stderr = "" }
  end,
    seen
end

-- ------------------------------------------------------------ the contract

test("the origin is sphinx", function()
  eq(sphinx.origin, "sphinx")
end)

test("the fallback language is Sphinx's own default domain", function()
  eq(sphinx.language, "Python")
end)

test("a docset's release is the version it is named for", function()
  eq(sphinx.release("widget~3.1"), "3.1")
  eq(sphinx.release("widget"), nil)
end)

test("a Sphinx source declares no search: there is no registry to ask", function()
  eq(sphinx.search, nil)
end)

-- ------------------------------------------------------- reading a URL

test("a documentation URL is recognised, a package name is not", function()
  eq(sphinx.is_url("https://numpy.org/doc/stable"), true)
  eq(sphinx.is_url("http://localhost:8000/docs/"), true)
  eq(sphinx.is_url("numpy"), false)
  eq(sphinx.is_url("aeson-pretty"), false)
end)

test("a URL is normalised to one trailing slash, with objects.inv dropped", function()
  eq(internal.base_url("https://numpy.org/doc/stable"), "https://numpy.org/doc/stable/")
  eq(internal.base_url("https://numpy.org/doc/stable/"), "https://numpy.org/doc/stable/")
  eq(internal.base_url("https://numpy.org/doc/stable/objects.inv"), "https://numpy.org/doc/stable/")
  eq(internal.base_url("  https://numpy.org/doc/stable/#anchor "), "https://numpy.org/doc/stable/")
end)

test("an inventory line's name may hold spaces", function()
  local item = internal.parse_line("C order std:term -1 index.html#term-C-order -")
  eq(item.name, "C order")
  eq(item.role, "std:term")
  eq(item.uri, "index.html#term-C-order")
end)

test("a site answers with its project, version and page count", function()
  local system = runner()
  eq(sphinx.from_url(site, system), {
    { name = "widget", version = "3.1", pages = 4, url = site },
  })
end)

test("reading a site is one request -- the inventory", function()
  local system, seen = runner()
  sphinx.from_url(site, system)
  eq(seen.urls, { site .. "objects.inv" })
end)

test("a name that is not a URL is not asked about", function()
  eq(sphinx.from_url("numpy", runner()), {})
end)

test("a site with no inventory says so rather than installing nothing", function()
  local ok, err = pcall(sphinx.from_url, "https://widget.example/nope/", runner())
  eq(ok, false)
  has(err, "no Sphinx inventory")
end)

test("the site a docset came from is remembered, so it can be installed again", function()
  sphinx.from_url(site, runner())
  eq(sphinx.site("widget~3.1"), { url = site, language = "Python" })
end)

test("latest reads the site again and names what it offers now", function()
  sphinx.from_url(site, runner())
  eq(sphinx.latest("widget~3.1", runner()), "widget~3.1")
end)

test("latest says nothing for a docset whose site is not remembered", function()
  eq(sphinx.latest("never-seen~1.0", runner()), nil)
end)

test("a docset whose site is not remembered says how to name it again", function()
  local ok, err = pcall(sphinx.index, "never-seen~1.0", "", runner())
  eq(ok, false)
  has(err, "does not know which site")
end)

test("the language is the domain the inventory is mostly written in", function()
  sphinx.from_url(site, runner())
  eq(sphinx.language_of("widget~3.1"), "Python")
end)

-- --------------------------------------------------------------- the index

local function index_of(system)
  sphinx.from_url(site, system)
  return sphinx.index("widget~3.1", "", system)
end

local function entry_named(entries, name)
  for _, entry in ipairs(entries) do
    if entry.name == name then
      return entry
    end
  end
end

test("every documented item becomes an entry under its own page", function()
  local entries = index_of(runner()).entries
  eq(entry_named(entries, "widget.spin"), { name = "widget.spin", path = "api#widget.spin", type = "Functions" })
  eq(entry_named(entries, "widget.Widget"), { name = "widget.Widget", path = "api#widget.Widget", type = "Classes" })
end)

test("a page is an entry of its own, named as the site displays it", function()
  local entries = index_of(runner()).entries
  eq(entry_named(entries, "Getting started") ~= nil, true)
  eq(entry_named(entries, "API"), { name = "API", path = "api", type = "Pages" })
end)

test("$ in a uri stands for the entry's own name", function()
  local entries = index_of(runner()).entries
  eq(entry_named(entries, "widget.spin").path, "api#widget.spin")
end)

test("a C function's parameters are not entries of their own", function()
  local entries = index_of(runner()).entries
  eq(entry_named(entries, "widget.Widget.spin"), nil)
end)

test("a dirhtml page keeps a key without its trailing slash", function()
  local entries = index_of(runner()).entries
  eq(entry_named(entries, "Notes").path, "guide/dirhtml")
end)

-- ------------------------------------------------------------------ the db

local function db_of(opts)
  local system, seen = runner(opts)
  sphinx.from_url(site, system)
  sphinx.index("widget~3.1", "", system)
  return sphinx.db("widget~3.1", "", system), seen
end

test("every page in the inventory is fetched and kept", function()
  local db = db_of()
  eq(vim.tbl_count(db), 4)
  eq(db["index"] ~= nil, true)
  eq(db["guide/intro"] ~= nil, true)
  eq(db["guide/dirhtml"] ~= nil, true)
end)

test("pages are fetched in parallel when curl can, and sequentially when not", function()
  local _, parallel = db_of({ parallel = true })
  local found = false
  for _, cmd in ipairs(parallel.cmds) do
    if vim.tbl_contains(cmd, "--parallel") then
      found = true
    end
  end
  eq(found, true)
  local _, plain = db_of({ parallel = false })
  for _, cmd in ipairs(plain.cmds) do
    eq(vim.tbl_contains(cmd, "--parallel"), false)
  end
end)

test("only the page itself is kept, whatever theme wrote it", function()
  local db = db_of()
  has_not(db["index"], "sphinxsidebar")
  has_not(db["api"], "bd-sidebar-secondary")
  has_not(db["api"], "var tracking")
  has(db["index"], "<h1>Widget")
  has(db["api"], "widget.spin")
  has(db["guide/intro"], "Getting started")
end)

test("the paragraph mark beside a heading is not a link to resolve", function()
  local db = db_of()
  has_not(db["index"], "headerlink")
end)

test("a link between two pages keeps the shape the installer reads", function()
  local db = db_of()
  -- The installer resolves a link against the page key holding it, so a link
  -- from api to guide/intro stays relative, never the whole key.
  has(db["api"], 'href="guide/intro"')
  has(db["api"], 'href="index"')
  has(db["guide/intro"], 'href="../api#widget.spin"')
  has(db["guide/intro"], 'href="../index"')
end)

test("a link to something the docset does not hold goes back to the site", function()
  local db = db_of()
  has(db["index"], 'href="' .. site .. '_static/theme.css"')
  has(db["index"], 'href="https://widget.example/doc/other.html"')
  has(db["guide/intro"], 'href="' .. site .. 'missing.html"')
end)

test("an address that is already absolute is left alone", function()
  local db = db_of()
  has(db["index"], 'href="https://example.com/"')
end)

test("no page holds a link that leaves the docset by accident", function()
  local db = db_of()
  local known = {}
  for key in pairs(db) do
    known[key] = true
  end
  for key, html in pairs(db) do
    for href in html:gmatch('href="([^"]*)"') do
      if not href:match("^%a[%w+.-]*:") and not href:match("^#") then
        local dir = key:match("^(.*)/[^/]*$") or ""
        local segments = vim.split(dir, "/", { trimempty = true })
        for _, part in ipairs(vim.split(href:gsub("#.*$", ""), "/", { trimempty = true })) do
          if part == ".." then
            table.remove(segments)
          elseif part ~= "." then
            segments[#segments + 1] = part
          end
        end
        local target = table.concat(segments, "/")
        if not known[target] then
          error("link " .. href .. " on page " .. key .. " resolves to " .. target .. ", which is not a page", 0)
        end
      end
    end
  end
end)

-- ------------------------------------------------------- naming a docset

test("a docset is named for the project and version the site publishes", function()
  eq(internal.docset_name("NumPy", "2.5"), "numpy~2.5")
  eq(internal.docset_name("Read the Docs", "9.1"), "read_the_docs~9.1")
  eq(internal.docset_name("Widget", ""), "widget")
  eq(internal.docset_name("Widget", nil), "widget")
end)

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
