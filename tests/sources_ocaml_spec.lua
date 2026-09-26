-- Tests for lua/docshelf/sources/ocaml.lua, offline: a fake command runner
-- serves tests/fixtures/ocaml/site as ocaml.org, so the whole path -- search,
-- the version read from the latest documentation page, odoc's search index,
-- page fetch, anchor naming, link rewriting -- runs for real against a site
-- that is only on disk.
--
-- The search page is cut from ocaml.org/packages/search?q=lwt (2026-09-26);
-- the "demo" package is written in the markup of lwt 6.1.2's pages: specs
-- whose ids hold OCaml's operators ("val-(=|&lt;)"), constructors keyed
-- "type-state.Return", a "Source" link on every spec, and a link to the
-- standard library climbing out of the package ("../../../../../../u/…").
-- Run from the repository root: nvim --headless -l tests/sources_ocaml_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local ocaml = require("docshelf.sources.ocaml")

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

local fixtures = vim.fn.fnamemodify("tests/fixtures/ocaml/site", ":p"):gsub("/$", "")
local site = "https://ocaml.org/"

--- The fixture file answering `url`, or nil for a 404. A search answers
--- whatever it is asked, and a search index whatever its cache-busting name.
local function file_for(url)
  if url:sub(1, #site) ~= site then
    return nil
  end
  local path = url:sub(#site + 1)
  path = path:gsub("^packages/search%?.*$", "packages/search"):gsub("/search%-index/.*$", "/search-index")
  local file = fixtures .. "/" .. path
  return vim.fn.filereadable(file) == 1 and file or nil
end

--- Answers like ocaml.org; every request is recorded.
local function runner()
  local seen = { urls = {}, cmds = {} }
  local function body(url)
    seen.urls[#seen.urls + 1] = url
    local file = file_for(url)
    return file and table.concat(vim.fn.readfile(file, "b"), "\n") or nil
  end
  return function(cmd)
    seen.cmds[#seen.cmds + 1] = cmd
    if cmd[2] == "--help" then
      return { code = 0, stdout = "", stderr = "" }
    end
    local config
    for i, arg in ipairs(cmd) do
      if arg == "-K" then
        config = cmd[i + 1]
      end
    end
    if config then
      local url, ok = nil, true
      for _, line in ipairs(vim.fn.readfile(config)) do
        local value = line:match('"(.*)"')
        if line:match("^url") then
          url = value
        elseif line:match("^output") then
          local text = body(url)
          if text then
            vim.fn.writefile(vim.split(text, "\n"), value, "b")
          end
          ok = text ~= nil and ok
        end
      end
      return { code = ok and 0 or 22, stdout = "", stderr = "" }
    end
    local text = body(cmd[#cmd])
    return { code = text and 0 or 22, stdout = text or "", stderr = "" }
  end,
    seen
end

local docset = "demo~1.0.0"

local function entries_of(system)
  local by_path = {}
  for _, entry in ipairs(ocaml.index(docset, "", system or runner()).entries) do
    by_path[entry.path] = entry
  end
  return by_path
end

local function db()
  local system = runner()
  ocaml.index(docset, "", system)
  return ocaml.db(docset, "", system)
end

-- ------------------------------------------------------------ the contract

test("the adapter is ocaml.org, for OCaml", function()
  eq(ocaml.origin, "ocaml.org")
  eq(ocaml.language, "OCaml")
end)

test("search lists the packages ocaml.org documents, with their version", function()
  local system, seen = runner()
  eq(ocaml.search("lwt", system), {
    { name = "lwt", version = "6.1.2" },
    { name = "cohttp-lwt", version = "6.3.0" },
  })
  has(seen.urls[1], "https://ocaml.org/packages/search?q=lwt")
end)

test("search sends the query encoded", function()
  local system, seen = runner()
  ocaml.search("a&b c", system)
  has(seen.urls[1], "q=a%26b%20c")
end)

test("search says so when ocaml.org does not answer", function()
  local ok, err = pcall(ocaml.search, "lwt", function()
    return { code = 6, stdout = "", stderr = "" }
  end)
  eq(ok, false)
  has(err, "could not search ocaml.org")
end)

test("resolve reads the version from the head of the latest documentation", function()
  local system, seen = runner()
  eq(ocaml.resolve("demo", system), "demo~1.0.0")
  has(seen.urls[1], "https://ocaml.org/p/demo/latest/doc/index.html")
  eq(vim.tbl_contains(seen.cmds[1], "-r"), true)
end)

test("resolve of a package ocaml.org does not know says so", function()
  local ok, err = pcall(ocaml.resolve, "nosuch", runner())
  eq(ok, false)
  has(err, "ocaml.org has no documentation for nosuch")
end)

test("release is the docset's version and latest asks ocaml.org", function()
  eq(ocaml.release("demo~1.0.0"), "1.0.0")
  eq(ocaml.latest("demo~0.9", runner()), "demo~1.0.0")
end)

test("a docset without a version is refused", function()
  local ok, err = pcall(ocaml.release, "demo")
  eq(ok, false)
  has(err, "<package>~<version>")
end)

-- ------------------------------------------------------------ the index

test("the index is odoc's own, named as odoc names each item", function()
  local system, seen = runner()
  local entries = entries_of(system)
  has(seen.urls[1], "https://ocaml.org/p/demo/1.0.0/search-index/")
  eq(entries["demo/Demo"], { name = "Demo", path = "demo/Demo", type = "Modules" })
  eq(entries["demo/Demo/Infix"], { name = "Demo.Infix", path = "demo/Demo/Infix", type = "Modules" })
  eq(entries["demo/Demo#type-t"], { name = "Demo.t", path = "demo/Demo#type-t", type = "Types" })
  eq(entries["demo/Demo#val-bind"], { name = "Demo.bind", path = "demo/Demo#val-bind", type = "Values" })
  eq(
    entries["demo/Demo#exception-Canceled"],
    { name = "Demo.Canceled", path = "demo/Demo#exception-Canceled", type = "Exceptions" }
  )
  eq(
    entries["demo/Demo#type-state.2EReturn"],
    { name = "Demo.state.Return", path = "demo/Demo#type-state.2EReturn", type = "Constructors" }
  )
end)

test("an operator's id is made plain, the entry keeps its name", function()
  local entries = entries_of()
  eq(entries["demo/Demo#val-.28.3D.7C.3C.29"].name, "Demo.(=|<)")
  eq(entries["demo/Demo/Infix#val-.28.3E.3E.3D.29"].name, "Demo.Infix.(>>=)")
end)

test("pages are entries: the package, its readme, its library", function()
  local entries = entries_of()
  eq(entries["index"], { name = "demo", path = "index", type = "Guides" })
  eq(entries["README"], { name = "demo README", path = "README", type = "Guides" })
  eq(entries["demo"], { name = "Library demo", path = "demo", type = "Libraries" })
end)

test("the source listings are left out", function()
  for path in pairs(entries_of()) do
    has_not(path, "src")
  end
end)

test("a version ocaml.org has no documentation for says so", function()
  local ok, err = pcall(ocaml.index, "demo~0.1", "", runner())
  eq(ok, false)
  has(err, "ocaml.org has no documentation for demo 0.1")
end)

-- ------------------------------------------------------------ the pages

test("every page the index names is fetched, and nothing else", function()
  local keys = vim.tbl_keys(db())
  table.sort(keys)
  eq(keys, { "README", "demo", "demo/Demo", "demo/Demo/Infix", "index" })
end)

test("a page is its odoc content, without the site around it", function()
  local page = db()["demo/Demo"]
  has(page, "Promises.")
  has_not(page, "Package index")
  has_not(page, "sidebar")
  has_not(page, "<script")
  has_not(page, "Community")
end)

test("the Source links and the empty anchors are dropped", function()
  local page = db()["demo/Demo"]
  has_not(page, "source_link")
  has_not(page, ">Source<")
  has_not(page, 'class="anchor"')
end)

test("each item's id is plain and named by a heading", function()
  local page = db()["demo/Demo"]
  has(page, '<h4 id="val-bind">Demo.bind</h4>')
  has(page, '<h4 id="val-.28.3D.7C.3C.29">Demo.(=|&lt;)</h4>')
  has(page, '<h4 id="type-state.2EReturn">Demo.state.Return</h4>')
end)

test("links inside the package name their page and a plain anchor", function()
  local pages = db()
  has(pages["demo/Demo"], 'href="#val-.28.3D.7C.3C.29"')
  has(pages["demo/Demo"], 'href="Demo/Infix#val-.28.3E.3E.3D.29"')
  has(pages["demo/Demo/Infix"], 'href="../Demo#val-bind"')
  has(pages["index"], 'href="demo/Demo"')
  has(pages["index"], 'href="demo/Demo/Infix#val-.28.3E.3E.3D.29"')
  has(pages["README"], 'href="index"')
end)

test("a link out of the package goes to ocaml.org", function()
  has(
    db()["demo/Demo"],
    'href="https://ocaml.org/u/ea9089df81180202d64c20ebcdfe5c35/ocaml-compiler/5.5.1/doc/stdlib/Stdlib/index.html#val-ignore"'
  )
end)

if failures > 0 then
  print(failures .. " failure(s)")
  os.exit(1)
end
print("all passed")
