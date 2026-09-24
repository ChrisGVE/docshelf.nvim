-- Tests for lua/docshelf/sources/pkggodev.lua, offline: a fake command runner
-- serves tests/fixtures/pkggodev/site as pkg.go.dev, so the whole path -- the
-- package page fetch, the version and the subpackage list read off it, the
-- symbol index, the page cleaning and the link rewriting -- runs for real
-- against a site that is only on disk.
--
-- Run from the repository root: nvim --headless -l tests/sources_pkggodev_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local pkggodev = require("docshelf.sources.pkggodev")

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

local fixtures = vim.fn.fnamemodify("tests/fixtures/pkggodev/site", ":p"):gsub("/$", "")

-- The install remembers which module a docset came from beside the installed
-- docsets, so the specs point the data folder at a scratch directory.
local scratch = vim.fn.tempname()
vim.fn.mkdir(scratch, "p")
vim.env.XDG_DATA_HOME = scratch

-- Which fixture file answers which package page.
local pages = {
  ["/example.com/widget"] = "widget.html",
  ["/example.com/widget@v1.2.3"] = "widget.html",
  -- The standard library's shape: the version rides on the package path, not
  -- the module's, so a subpackage address is only ever the site's own href.
  ["/example.com/widget/render@v1.2.3"] = "render.html",
}

--- Answers like pkg.go.dev: a known package path is served from the fixture,
--- anything else is a 404 (curl exit 22, as `curl -f` reports one).
local function runner()
  local seen = { urls = {} }
  local system = function(cmd)
    local url, out
    for i, arg in ipairs(cmd) do
      if arg == "-o" then
        out = cmd[i + 1]
      end
      if arg:match("^https?://") then
        url = arg
      end
    end
    if not url then
      return { code = 0, stdout = "", stderr = "" }
    end
    seen.urls[#seen.urls + 1] = url
    local path = url:gsub("^https://pkg%.go%.dev", ""):gsub("%?.*$", "")
    local file = pages[path] and (fixtures .. "/" .. pages[path])
    if not file or vim.fn.filereadable(file) ~= 1 then
      return { code = 22, stdout = "", stderr = "404" }
    end
    local body = table.concat(vim.fn.readfile(file), "\n")
    if out then
      vim.fn.writefile(vim.split(body, "\n"), out)
      return { code = 0, stdout = "", stderr = "" }
    end
    return { code = 0, stdout = body, stderr = "" }
  end
  return system, seen
end

test("the adapter names its origin and its language", function()
  eq(pkggodev.origin, "pkg.go.dev")
  eq(pkggodev.language, "Go")
end)

test("only a pkg.go.dev address is one of ours", function()
  eq(pkggodev.is_url("https://pkg.go.dev/example.com/widget"), true)
  eq(pkggodev.is_url("https://numpy.org/doc/stable/"), false)
  eq(pkggodev.is_url("example.com/widget"), false)
end)

test("a package URL names the package, its version and how many pages it is", function()
  local system = runner()
  eq(pkggodev.from_url("https://pkg.go.dev/example.com/widget", system), {
    {
      name = "example.com/widget",
      version = "1.2.3",
      pages = 2,
      url = "https://pkg.go.dev/example.com/widget@v1.2.3",
    },
  })
end)

test("a URL that is not pkg.go.dev's is left to whoever owns it", function()
  local system, seen = runner()
  eq(pkggodev.from_url("https://numpy.org/doc/stable/", system), {})
  eq(#seen.urls, 0)
end)

test("latest reads the package page again and names what it offers now", function()
  local system = runner()
  pkggodev.from_url("https://pkg.go.dev/example.com/widget", system)
  eq(pkggodev.latest("example.com_widget~1.2.3", system), "example.com_widget~1.2.3")
end)

test("latest says nothing for a docset whose package is not remembered", function()
  eq(pkggodev.latest("example.com_never~0.1.0", runner()), nil)
end)

test("the release is the version the docset is named for", function()
  eq(pkggodev.release("example.com_widget~1.2.3"), "1.2.3")
end)

local docset = "example.com_widget~1.2.3"

test("the index carries every documented symbol, under its Go kind", function()
  local system = runner()
  pkggodev.from_url("https://pkg.go.dev/example.com/widget", system)
  local index = pkggodev.index(docset, nil, system)
  local by_name = {}
  for _, entry in ipairs(index.entries) do
    by_name[entry.name] = entry
  end
  eq(by_name["example.com/widget"], { name = "example.com/widget", path = "widget", type = "Packages" })
  eq(by_name["widget.MaxWidgets"], { name = "widget.MaxWidgets", path = "widget#MaxWidgets", type = "Constants" })
  eq(by_name["widget.ErrNoWidget"], { name = "widget.ErrNoWidget", path = "widget#ErrNoWidget", type = "Variables" })
  eq(by_name["widget.New"], { name = "widget.New", path = "widget#New", type = "Functions" })
  eq(by_name["widget.Widget"], { name = "widget.Widget", path = "widget#Widget", type = "Types" })
  eq(by_name["widget.Widget.Name"], { name = "widget.Widget.Name", path = "widget#Widget.Name", type = "Fields" })
  eq(by_name["widget.Widget.Draw"], { name = "widget.Widget.Draw", path = "widget#Widget.Draw", type = "Methods" })
  eq(by_name["example.com/widget/render"], {
    name = "example.com/widget/render",
    path = "widget/render",
    type = "Packages",
  })
  eq(by_name["render.Draw"], { name = "render.Draw", path = "widget/render#Draw", type = "Functions" })
end)

test("an internal package is not offered, and is never fetched", function()
  local system, seen = runner()
  pkggodev.from_url("https://pkg.go.dev/example.com/widget", system)
  local index = pkggodev.index(docset, nil, system)
  for _, entry in ipairs(index.entries) do
    has_not(entry.path, "stash")
  end
  for _, url in ipairs(seen.urls) do
    has_not(url, "internal")
  end
end)

test("the db holds one page per package, and only the documentation", function()
  local system = runner()
  pkggodev.from_url("https://pkg.go.dev/example.com/widget", system)
  local db = pkggodev.db(docset, nil, system)
  eq(vim.tbl_count(db), 2)
  has(db["widget"], "Package widget draws widgets")
  has_not(db["widget"], "site chrome that is not documentation")
  has_not(db["widget"], "loadScript")
  has(db["widget/render"], "Package render draws")
end)

test("a link to another package of the docset becomes that page", function()
  local system = runner()
  pkggodev.from_url("https://pkg.go.dev/example.com/widget", system)
  local db = pkggodev.db(docset, nil, system)
  -- From the root package, whose key has no directory of its own.
  has(db["widget"], 'href="widget/render"')
  -- And back the other way, against the page key holding the link.
  has(db["widget/render"], 'href="../widget#Widget"')
end)

test("the page's own index and its pilcrows are left out", function()
  local system = runner()
  pkggodev.from_url("https://pkg.go.dev/example.com/widget", system)
  local db = pkggodev.db(docset, nil, system)
  -- The index lists every symbol of the page, which is what the picker is.
  has_not(db["widget"], "Documentation-indexList")
  -- Nothing links to a heading of the page any more: a split page has none.
  for href in db["widget"]:gmatch('href="([^"]*)"') do
    if href:match("^#pkg%-") or href:match("^#section%-") then
      error("a link to the page's own heading survived: " .. href, 0)
    end
  end
  -- The source link is unwrapped, so the symbol keeps its name.
  has(db["widget"], ">func New")
end)

test("a link out of the docset keeps working, as an address", function()
  local system = runner()
  pkggodev.from_url("https://pkg.go.dev/example.com/widget", system)
  local db = pkggodev.db(docset, nil, system)
  -- The standard library, which pkg.go.dev serves at the site root.
  has(db["widget"], 'href="https://pkg.go.dev/builtin#string"')
  -- Somebody else's site, untouched.
  has(db["widget"], 'href="https://example.com/handbook"')
end)

test("an image of the site keeps pointing at the site", function()
  local system = runner()
  pkggodev.from_url("https://pkg.go.dev/example.com/widget", system)
  local db = pkggodev.db(docset, nil, system)
  -- Left site-relative, an <img> is a link to nowhere once the page is a file.
  has(db["widget"], 'src="https://pkg.go.dev/static/shared/icon/folder.svg"')
end)

test("another view of the same package stays a view, not the documentation", function()
  local system = runner()
  pkggodev.from_url("https://pkg.go.dev/example.com/widget", system)
  local db = pkggodev.db(docset, nil, system)
  has(db["widget"], 'href="https://pkg.go.dev/example.com/widget@v1.2.3?tab=versions"')
  -- Written the short way, it is relative to the page's own address -- and
  -- relative to a file on disk it is a file that does not exist.
  has(db["widget"], 'href="https://pkg.go.dev/example.com/widget@v1.2.3?tab=imports"')
  -- The site's own search form is not documentation, and its options are site
  -- paths that nothing would rewrite.
  has_not(db["widget"], 'action="/search"')
  has_not(db["widget"], "tab=licenses")
end)

test("each page is asked for once, however many times it is read", function()
  local system, seen = runner()
  pkggodev.from_url("https://pkg.go.dev/example.com/widget", system)
  pkggodev.index(docset, nil, system)
  pkggodev.db(docset, nil, system)
  -- The probe reads the root package page and that page is kept, so the
  -- install asks only for the one page the probe did not already read.
  eq(#seen.urls, 2)
end)

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
