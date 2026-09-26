-- Tests for lua/docshelf/sources/nimdoc.lua, offline: a fake command runner
-- serves tests/fixtures/nimdoc as Nim's package list and two nimdoc sites, so
-- the whole path -- search, resolving a package to its site, reading the
-- site's index, page fetch, entry kinds, anchor naming, link rewriting --
-- runs for real against sites that are only on disk.
--
-- The package list is cut from nim-lang/packages' packages.json
-- (2026-09-26). The two sites are written in the markup of real ones, one
-- per nimdoc generation: pixie (treeform.github.io/pixie, Nim 2.2, 2026),
-- reached where GitHub Pages puts a repository's site, with its procs
-- grouped in "-procs-all" wrappers; and argparse (iffycan.com/nim-argparse,
-- 2023), reached by the "doc" address its package declares, whose index names
-- no kinds; a third, leveldb (zielmicha.github.io/leveldb.nim, 2021), is
-- reached by its URL and marks its symbols "<a id>" rather than "<div id>".
-- Operators ("$", "[]="), a template ("[].t"), a converter
-- ("parseSomePaint.c") and a generic whose id spells its constraint in full
-- ("applyOpacity,seq[T: int or int8 or ...]") are in the ids; pixie's index
-- names a page (fonts) the site does not serve.
-- Run from the repository root: nvim --headless -l tests/sources_nimdoc_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local nimdoc = require("docshelf.sources.nimdoc")

local failures = 0
local function test(name, fn)
  nimdoc.reset()
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

local function fails_with(fn, needle)
  local ok, err = pcall(fn)
  if ok then
    error("expected an error holding " .. vim.inspect(needle), 2)
  end
  has(err, needle)
end

-- the remembered sites go to a scratch data folder
local data = vim.fn.tempname() .. "/"
vim.fn.mkdir(data, "p")
package.loaded["docshelf.common"] = {
  data_folder = function()
    return data
  end,
}

local fixtures = vim.fn.fnamemodify("tests/fixtures/nimdoc", ":p"):gsub("/$", "")
local registry = "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json"
local pixie = "https://treeform.github.io/pixie/"
local argparse = "https://www.iffycan.com/nim-argparse/"
local leveldb = "https://zielmicha.github.io/leveldb.nim/"

--- The fixture file answering `url`, or nil for a 404.
local function file_for(url)
  local file
  if url == registry then
    file = fixtures .. "/registry/packages.json"
  elseif url:sub(1, #pixie) == pixie then
    local path = url:sub(#pixie + 1)
    file = fixtures .. "/pixie/" .. (path == "" and "index.html" or path)
  elseif url:sub(1, #argparse) == argparse then
    file = fixtures .. "/argparse/" .. url:sub(#argparse + 1)
  elseif url:sub(1, #leveldb) == leveldb then
    local path = url:sub(#leveldb + 1)
    file = fixtures .. "/leveldb/" .. (path == "" and "index.html" or path)
  end
  return (file and vim.fn.filereadable(file) == 1) and file or nil
end

--- Answers like the package list and the two sites; every request is
--- recorded.
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
    local config, write_out
    for i, arg in ipairs(cmd) do
      if arg == "-K" then
        config = cmd[i + 1]
      elseif arg == "-w" then
        write_out = cmd[i + 1]
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
    local url = cmd[#cmd]
    local text = body(url)
    if not text then
      return { code = 22, stdout = "", stderr = "" }
    end
    if write_out == "\n%{url_effective}" then
      return { code = 0, stdout = text .. "\n" .. url, stderr = "" }
    end
    return { code = 0, stdout = text, stderr = "" }
  end,
    seen
end

local docset = "pixie~2026-09-13"

local function installed(name, system)
  system = system or runner()
  vim.fn.delete(nimdoc.sites_path())
  return nimdoc.resolve(name, system), system
end

local function entries_of(name)
  local resolved, system = installed(name or "pixie")
  local by_path = {}
  for _, entry in ipairs(nimdoc.index(resolved, "", system).entries) do
    by_path[entry.path] = entry
  end
  return by_path
end

local function db_of(name)
  local resolved, system = installed(name or "pixie")
  nimdoc.index(resolved, "", system)
  return nimdoc.db(resolved, "", system)
end

-- ------------------------------------------------------------ the contract

test("the origin is the tool the sites are built with", function()
  eq(nimdoc.origin, "nimdoc")
end)

test("every docset documents Nim", function()
  eq(nimdoc.language, "Nim")
end)

test("a docset's release is the day its site was generated", function()
  eq(nimdoc.release(docset), "2026-09-13")
end)

-- ------------------------------------------------------------ the package list

test("a search offers the listed packages whose name holds what was typed", function()
  local system, seen = runner()
  eq(nimdoc.search("PIX", system), { { name = "pixel" }, { name = "pixie" } })
  eq(nimdoc.search("jest", system), { { name = "jester" } })
  -- the list is fetched once for the session
  eq(seen.urls, { registry })
end)

test("a search says so when the package list does not answer", function()
  fails_with(function()
    nimdoc.search("pix", function()
      return { code = 6, stdout = "", stderr = "" }
    end)
  end, "could not fetch Nim's package list")
end)

-- ------------------------------------------------------------ resolving a pick

test("a package is resolved to the site GitHub Pages serves for its repository", function()
  local resolved = installed("pixie")
  eq(resolved, docset)
  eq(nimdoc.site(docset), { url = pixie, name = "pixie" })
end)

test("an alias is resolved to the package it names", function()
  eq((installed("pixel")), docset)
end)

test("a package's declared documentation address is read first", function()
  local resolved = installed("argparse")
  eq(resolved, "argparse~2023-03-15")
  eq(nimdoc.site(resolved), { url = argparse, name = "argparse" })
end)

test("a package with no nimdoc site asks for its URL", function()
  fails_with(function()
    installed("jester")
  end, "type its documentation URL")
  -- a declared address that is not a nimdoc page, on a host with no Pages
  fails_with(function()
    installed("nim0")
  end, "type its documentation URL")
end)

test("a name the package list does not hold is refused", function()
  fails_with(function()
    installed("nope")
  end, "Nim's package list has no package nope")
end)

-- ------------------------------------------------------------ any site by URL

test("any page of a site gives the site's docset, its day and its page count", function()
  local system = runner()
  eq(nimdoc.from_url(pixie .. "pixie/paints.html#Paint", system), {
    { name = "pixie", version = "2026-09-13", pages = 4, url = pixie },
  })
  eq(nimdoc.site(docset), { url = pixie, name = "pixie" })
end)

test("the site's own index page is a page of it too", function()
  eq(nimdoc.from_url(argparse .. "theindex.html", runner()), {
    { name = "argparse", version = "2023-03-15", pages = 4, url = argparse },
  })
end)

test("a URL that is not a nimdoc page is refused, and text that is no URL ignored", function()
  fails_with(function()
    nimdoc.from_url(registry, runner())
  end, "is not a page of a nimdoc site")
  eq(nimdoc.from_url("pixie", runner()), {})
end)

test("latest is the docset named for the day the site was generated again", function()
  local system = runner()
  eq(nimdoc.latest("pixie~2026-01-01", system), nil)
  installed("pixie", system)
  local sites = vim.json.decode(table.concat(vim.fn.readfile(nimdoc.sites_path()), "\n"))
  sites["pixie~2026-01-01"] = sites[docset]
  vim.fn.writefile({ vim.json.encode(sites) }, nimdoc.sites_path())
  eq(nimdoc.latest("pixie~2026-01-01", system), docset)
end)

-- ------------------------------------------------------------ the entries

test("every module page is an entry, named by its path", function()
  local entries = entries_of()
  eq(entries["pixie"], { name = "pixie", path = "pixie", type = "Modules" })
  eq(entries["pixie/paints"], { name = "pixie/paints", path = "pixie/paints", type = "Modules" })
  eq(entries["pixie/images"], { name = "pixie/images", path = "pixie/images", type = "Modules" })
end)

test("every documented symbol is an entry, typed by the section it is in", function()
  local entries = entries_of()
  eq(entries["pixie/paints#Paint"], { name = "paints.Paint", path = "pixie/paints#Paint", type = "Types" })
  eq(entries["pixie/paints#colorStop.2CColor.2Cfloat32"], {
    name = "paints.colorStop(Color, float32)",
    path = "pixie/paints#colorStop.2CColor.2Cfloat32",
    type = "Procs",
  })
  eq(entries["pixie/paints#parseSomePaint.2Ec.2CSomePaint"].name, "paints.parseSomePaint(SomePaint)")
  eq(entries["pixie/paints#parseSomePaint.2Ec.2CSomePaint"].type, "Converters")
  eq(entries["pixie#decodeImage.2Cstring"].name, "pixie.decodeImage(string)")
end)

test("an operator and a template keep their name, without the kind nimdoc adds", function()
  local entries = entries_of()
  eq(entries["pixie/images#.24.2CImage"].name, "images.$(Image)")
  eq(entries["pixie/images#.5B.5D.3D.2CImage.2Cint.2Cint.2CSomeColor"].name, "images.[]=(Image, int, int, SomeColor)")
  eq(entries["pixie/images#.5B.5D.2Et.2CUnsafeImage.2Cint.2Cint"], {
    name = "images.[](UnsafeImage, int, int)",
    path = "pixie/images#.5B.5D.2Et.2CUnsafeImage.2Cint.2Cint",
    type = "Templates",
  })
end)

test("imports and nimdoc's grouping wrappers are no entries", function()
  for path in pairs(entries_of()) do
    has_not(path, "procs-all")
    has_not(path, "templates-all")
    has_not(path, "converters-all")
  end
end)

test("a page the site does not serve gives no entries", function()
  for path in pairs(entries_of()) do
    has_not(path, "fonts")
  end
end)

test("an older site's symbols are typed the same way, though its index names no kinds", function()
  local entries = entries_of("argparse")
  eq(entries["argparse/backend#.24.2Cref.2EParseState"], {
    name = "backend.$(ref.ParseState)",
    path = "argparse/backend#.24.2Cref.2EParseState",
    type = "Procs",
  })
  eq(entries["argparse/backend#ARGPARSE_STDOUT"].type, "Vars")
  eq(entries["argparse/backend#Builder"].type, "Types")
  eq(entries["argparse#newParser.2Cstring.2Cuntyped"].name, "argparse.newParser(string, untyped)")
end)

test("a symbol whose id spells a long signature gets a short plain id", function()
  local entry
  for _, candidate in pairs(entries_of()) do
    if candidate.name:match("applyOpacity") then
      entry = candidate
    end
  end
  -- the constraint is left out of the name, as Nim's own index leaves it
  eq(entry.name, "images.applyOpacity(seq[T])")
  eq(entry.type, "Procs")
  local id = entry.path:match("#(.*)$")
  assert(#id <= 57, "id is " .. #id .. " bytes: " .. id)
  local page = db_of()["pixie/images"]
  has(page, '<h4 id="' .. id .. '">images.applyOpacity(seq[T])</h4>')
  has(page, 'href="#' .. id .. '"')
end)

test("a site built in 2021 marks its symbols with <a id>, and they are entries too", function()
  local system = runner()
  eq(nimdoc.from_url(leveldb, system), {
    { name = "leveldb", version = "2021-02-08", pages = 2, url = leveldb },
  })
  local by_path = {}
  for _, entry in ipairs(nimdoc.index("leveldb~2021-02-08", "", system).entries) do
    by_path[entry.path] = entry
  end
  eq(by_path["leveldb#close.2CLevelDb"], { name = "leveldb.close(LevelDb)", path = "leveldb#close.2CLevelDb", type = "Procs" })
  eq(by_path["leveldb#LevelDb"].type, "Types")
  local page = nimdoc.db("leveldb~2021-02-08", "", system)["leveldb"]
  has(page, "Closes the database.")
  has(page, '<h4 id="close.2CLevelDb">leveldb.close(LevelDb)</h4>')
  -- its source link runs over three lines, and its pragmas hide behind "{...}"
  has_not(page, "link-seesrc")
  has_not(page, ">Source<")
  has_not(page, '<span class="Other">{</span>')
end)

-- ------------------------------------------------------------ the pages

test("every page the site serves is kept, a missing one skipped", function()
  local keys = vim.tbl_keys(db_of())
  table.sort(keys)
  eq(keys, { "pixie", "pixie/images", "pixie/paints" })
end)

test("the sidebar, the footer, and the source and edit links go", function()
  local page = db_of()["pixie/paints"]
  has_not(page, "theme-select")
  has_not(page, "searchInput")
  has_not(page, "global-links")
  has_not(page, "link-seesrc")
  has_not(page, ">Source<")
  has_not(page, ">Edit<")
  has_not(page, "Made with Nim")
  has_not(page, "pragmadots")
  has(page, "Given SomePaint, parse it in different ways.")
end)

test("a page opens with its module's name, and each section is a heading", function()
  local page = db_of()["pixie/paints"]
  has(page, "<h1>pixie/paints</h1>")
  has(page, "<h2>Types</h2>")
  has(page, "<h2>Converters</h2>")
  has_not(page, "toc-backref")
end)

test("each symbol gets a heading holding its plain id and its name", function()
  local page = db_of()["pixie/paints"]
  has(page, '<h4 id="colorStop.2CColor.2Cfloat32">paints.colorStop(Color, float32)</h4>')
  has(db_of()["pixie/images"], '<h4 id=".24.2CImage">images.$(Image)</h4>')
end)

test("a link within the page follows the plain ids", function()
  has(db_of()["pixie/images"], 'href="#.5B.5D.3D.2CImage.2Cint.2Cint.2CSomeColor"')
end)

test("a link to a page of the docset names that page", function()
  local db = db_of()
  has(db["pixie/paints"], 'href="../pixie#decodeImage.2Cstring"')
  has(db["pixie/paints"], 'href="images#Image"')
  has(db["pixie"], 'href="pixie/paints#Paint"')
end)

test("a link to another site stays, one to a page the docset lacks goes back to the site", function()
  has(db_of()["pixie"], 'href="https://nim-lang.org/docs/system.html#string"')
  has(db_of("argparse")["argparse/backend"], 'href="' .. argparse .. 'argparse/macrohelp.html"')
end)

if failures > 0 then
  print(failures .. " failed")
  os.exit(1)
end
print("all passed")
