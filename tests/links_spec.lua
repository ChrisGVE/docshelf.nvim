-- Tests for lua/apidocs/links.lua.
-- Run from the repository root: nvim --headless -l tests/links_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local links = require("apidocs.links")

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

test("resolve walks . and .. like a browser", function()
  eq(links.resolve("a/b", "../c/d.html"), "a/c/d.html")
  eq(links.resolve("a/b", "./e.html"), "a/b/e.html")
  eq(links.resolve("", "x.html"), "x.html")
  eq(links.resolve("a", "../../x.html"), "x.html")
end)

test("relative climbs no further than it has to", function()
  eq(links.relative("a/b", "a/c"), "../c")
  eq(links.relative("a", "a/b"), "b")
  eq(links.relative("", "x"), "x")
end)

test("a link to a page's own parent always names one segment", function()
  -- from wheel/spin (dir "wheel") to the page "wheel": the empty string would
  -- read as the docset folder itself
  eq(links.relative("wheel", "wheel"), "../wheel")
  eq(links.relative("a/b", "a/b"), "../b")
end)

local site = { dir = "guide", base = "https://example.org/docs/", known = { ["guide/intro"] = true, api = true } }

test("a link to a page of the docset becomes its key, anchor kept", function()
  eq(links.rewrite("intro.html#setup", site), "intro#setup")
  eq(links.rewrite("../api.html", site), "../api")
end)

test("a link outside the docset becomes an address on the site", function()
  eq(links.rewrite("../_static/logo.png", site), "https://example.org/docs/_static/logo.png")
  eq(links.rewrite("/search.html", site), "https://example.org/search.html")
  eq(links.rewrite("//cdn.example.org/x.js", site), "https://cdn.example.org/x.js")
end)

test("absolute addresses, same-page anchors and empty links are left alone", function()
  eq(links.rewrite("https://other.org/x", site), "https://other.org/x")
  eq(links.rewrite("mailto:a@b.c", site), "mailto:a@b.c")
  eq(links.rewrite("#top", site), "#top")
  eq(links.rewrite("", site), "")
end)

test("a source can name its own page keys", function()
  local opts = vim.tbl_extend("force", site, {
    known = { ["guide/intro/"] = true },
    key_of = function(path)
      return (path:gsub("%.html$", "/"))
    end,
  })
  eq(links.rewrite("intro.html", opts), "intro/")
end)

test("with no base, a link outside the docset is dropped to plain text", function()
  local opts = { dir = "", known = {} }
  eq(links.rewrite("missing.html", opts), nil)
end)

test("rewrite_html rewrites href AND src, and nothing else", function()
  local html = '<a href="intro.html">i</a><img src="../_static/p.png" alt="intro.html"><div title="intro.html">'
  eq(
    links.rewrite_html(html, site),
    '<a href="intro">i</a><img src="https://example.org/docs/_static/p.png" alt="intro.html"><div title="intro.html">'
  )
end)

test("rewrite_html turns a dropped link into plain text", function()
  eq(links.rewrite_html('<p><a href="gone.html">gone</a></p>', { dir = "", known = {} }), "<p>gone</p>")
end)

if failures > 0 then
  print(failures .. " failure(s)")
  os.exit(1)
end
