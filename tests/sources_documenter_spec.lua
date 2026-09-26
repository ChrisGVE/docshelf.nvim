-- Tests for lua/docshelf/sources/documenter.lua, offline: a fake command runner
-- serves tests/fixtures/documenter/registry as Julia's General registry and
-- tests/fixtures/documenter/site as a Documenter site, so the whole path --
-- the registry search, the GitHub Pages redirect, the site's version and
-- index, page fetch, docstring headings, link rewriting -- runs for real
-- against sites that are only on disk.
--
-- The fixture site is cut down from DataFrames 1.8.2's: pages served as
-- folders, docstrings in <details>/<summary>, a method whose id holds a type
-- signature ("DataFrames.select-Tuple{AbstractDataFrame, Vararg{Any}}"), a
-- "\" written "\\" in a page's ids but "\" in the index (as Julia's own
-- base/math page does), and a page the index names but the site does not
-- serve.
-- Run from the repository root: nvim --headless -l tests/sources_documenter_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local documenter = require("docshelf.sources.documenter")
local plain = documenter._internal.plain

local failures = 0
local function test(name, fn)
  documenter.reset()
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

-- the remembered sites go to a scratch data folder
local data = vim.fn.tempname() .. "/"
vim.fn.mkdir(data, "p")
package.loaded["docshelf.common"] = {
  data_folder = function()
    return data
  end,
}

local fixtures = vim.fn.fnamemodify("tests/fixtures/documenter", ":p"):gsub("/$", "")
local registry = "https://raw.githubusercontent.com/JuliaRegistries/General/master/"
local site = "https://dataframes.juliadata.org/stable/"
local pages = "https://JuliaData.github.io/DataFrames.jl/stable/"

--- The address a request lands on, and the fixture file answering it (nil
--- for a 404). GitHub Pages redirects to the project's own domain.
local function answer(url)
  local landed, file = url, nil
  if url:sub(1, #pages) == pages then
    landed = site .. url:sub(#pages + 1)
  end
  if url:sub(1, #registry) == registry then
    file = fixtures .. "/registry/" .. url:sub(#registry + 1)
  elseif landed:sub(1, #site) == site then
    local path = landed:sub(#site + 1)
    if path == "" or path:match("/$") then
      path = path .. "index.html"
    end
    file = fixtures .. "/site/" .. path
  end
  return landed, (file and vim.fn.filereadable(file) == 1) and file or nil
end

--- Answers like the registry and the site; every request is recorded.
local function runner()
  local seen = { urls = {}, cmds = {} }
  local function body(url)
    seen.urls[#seen.urls + 1] = url
    local landed, file = answer(url)
    return landed, file and table.concat(vim.fn.readfile(file, "b"), "\n") or nil
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
          local _, text = body(url)
          if text then
            vim.fn.writefile(vim.split(text, "\n"), value, "b")
          end
          ok = text ~= nil and ok
        end
      end
      return { code = ok and 0 or 22, stdout = "", stderr = "" }
    end
    local landed, text = body(cmd[#cmd])
    if not text then
      return { code = 22, stdout = "", stderr = "" }
    end
    if write_out == "\n%{url_effective}" then
      return { code = 0, stdout = text .. "\n" .. landed, stderr = "" }
    end
    return { code = 0, stdout = text, stderr = "" }
  end,
    seen
end

local docset = "DataFrames~1.8.2"

local function installed(system)
  system = system or runner()
  vim.fn.delete(documenter.sites_path())
  eq(documenter.resolve("DataFrames", system), docset)
  return system
end

local function entries_of()
  local system = installed()
  local by_path = {}
  for _, entry in ipairs(documenter.index(docset, "", system).entries) do
    by_path[entry.path] = entry
  end
  return by_path
end

local function db_of()
  local system = installed()
  documenter.index(docset, "", system)
  return documenter.db(docset, "", system)
end

-- ------------------------------------------------------------ the contract

test("the origin is the tool the sites are built with", function()
  eq(documenter.origin, "documenter")
end)

test("every docset documents Julia", function()
  eq(documenter.language, "Julia")
end)

test("a docset's release is the version it is named for", function()
  eq(documenter.release("DataFrames~1.8.2"), "1.8.2")
  eq(documenter.release("docs"), nil)
end)

-- ------------------------------------------------------------- searching

test("a search offers the registered packages whose name holds what was typed", function()
  local system, seen = runner()
  eq(documenter.search("dataf", system), { { name = "DataFrames" }, { name = "DataFramesMeta" } })
  eq(documenter.search("csv", system), { { name = "CSV" } })
  eq(documenter.search("zzz", system), {})
  -- the registry is asked once for the session
  eq(#seen.urls, 1)
end)

test("a pick is resolved to the version its GitHub Pages site was built for", function()
  local system, seen = runner()
  eq(documenter.resolve("DataFrames", system), "DataFrames~1.8.2")
  has(table.concat(seen.urls, " "), pages)
  -- the redirect's target is what is remembered
  eq(documenter.site("DataFrames~1.8.2"), { url = site, name = "DataFrames" })
end)

test("a package with no site where Documenter puts one asks for its URL", function()
  local ok, err = pcall(documenter.resolve, "Plots", runner())
  eq(ok, false)
  has(err, "type its documentation URL")
end)

test("a name the registry does not hold is refused", function()
  local ok, err = pcall(documenter.resolve, "NoSuchPackage", runner())
  eq(ok, false)
  has(err, "NoSuchPackage")
end)

test("any page of a site gives the site's docset, its version and its page count", function()
  vim.fn.delete(documenter.sites_path())
  local rows = documenter.from_url(site .. "lib/functions/#DataFrames.innerjoin", runner())
  eq(rows, { { name = "DataFrames", version = "1.8.2", pages = 5, url = site } })
  eq(documenter.site(docset).url, site)
end)

test("a URL that is not a Documenter page is refused", function()
  eq(documenter.from_url("not a url", runner()), {})
  eq(pcall(documenter.from_url, "https://example.org/nothing/", runner()), false)
end)

test("latest is the docset named for the version the site holds today", function()
  local system = installed()
  eq(documenter.latest("DataFrames~1.7.0", system), nil)
  local sites = vim.json.decode(table.concat(vim.fn.readfile(documenter.sites_path()), "\n"))
  sites["DataFrames~1.7.0"] = { url = site, name = "DataFrames" }
  vim.fn.writefile({ vim.json.encode(sites) }, documenter.sites_path())
  eq(documenter.latest("DataFrames~1.7.0", system), "DataFrames~1.8.2")
end)

-- ---------------------------------------------------------------- entries

test("every page is an entry, the home page keyed index", function()
  local entries = entries_of()
  eq(entries["index"], { name = "Introduction", path = "index", type = "Pages" })
  eq(entries["lib/functions"], { name = "Functions", path = "lib/functions", type = "Pages" })
end)

test("every section and docstring is an entry, typed by its category", function()
  local entries = entries_of()
  eq(entries["lib/functions#Joining"], { name = "Joining", path = "lib/functions#Joining", type = "Sections" })
  eq(entries["lib/functions#" .. plain("DataFrames.innerjoin")].type, "Functions")
  eq(entries["lib/functions#" .. plain("DataFrames.@by")].type, "Macros")
  eq(entries["lib/types#" .. plain("DataFrames.GroupKey")].type, "Types")
end)

test("a method's id holding its signature is made plain", function()
  local id = plain("DataFrames.select-Tuple{AbstractDataFrame, Vararg{Any}}")
  eq(id:find("[^%w%._%-]"), nil)
  eq(entries_of()["lib/functions#" .. id], {
    name = "DataFrames.select",
    path = "lib/functions#" .. id,
    type = "Methods",
  })
end)

test('a "\\" the page writes "\\\\" meets the index\'s "\\"', function()
  eq(plain("Base.:\\\\-Tuple{Any, Any}"), plain("Base.:\\-Tuple{Any, Any}"))
  eq(plain("Base.:%5C%5C-Tuple"), plain("Base.:\\-Tuple"))
end)

-- ------------------------------------------------------------------ pages

test("every page the site serves is kept, a missing one skipped", function()
  local keys = vim.tbl_keys(db_of())
  table.sort(keys)
  eq(keys, { "index", "lib/functions", "lib/types", "man/joins" })
end)

test("the sidebar, the navbar, the footer, permalinks and source links go", function()
  local page = db_of()["lib/functions"]
  has_not(page, "docs-sidebar")
  has_not(page, "docs-navbar")
  has_not(page, "docs-footer")
  has_not(page, "Permalink")
  has_not(page, "docs-sourcelink")
  has_not(page, "<script")
  has(page, "Perform an inner join")
end)

test("a docstring's summary becomes a heading holding its plain id", function()
  local db = db_of()
  has(db["lib/functions"], '<h4 id="' .. plain("DataFrames.innerjoin") .. '">DataFrames.innerjoin — Function</h4>')
  has(db["lib/functions"], '<h4 id="' .. plain("Base.:\\-Tuple{Any, Any}") .. '">Base.:\\ — Method</h4>')
  has_not(db["lib/functions"], "<summary")
  has_not(db["lib/functions"], "<details")
end)

test("a section heading is followed by its text", function()
  has(db_of()["lib/functions"], '<h2 id="Joining">Joining</h2>')
end)

test("a code block names its language", function()
  local page = db_of()["lib/functions"]
  has(page, '<pre data-language="julia">innerjoin(df1, df2; on, makeunique=false)</pre>')
  has(page, '<pre data-language="julia">julia&gt; innerjoin')
end)

test("a link within the page follows the plain ids", function()
  has(db_of()["lib/functions"], 'href="#' .. plain("DataFrames.select-Tuple{AbstractDataFrame, Vararg{Any}}") .. '"')
end)

test("a link to a page of the docset names that page, read against the page's folder", function()
  local db = db_of()
  has(db["lib/functions"], 'href="../man/joins#Database-Style-Joins"')
  has(db["lib/functions"], 'href="types#' .. plain("DataFrames.GroupKey") .. '"')
  has(db["lib/types"], 'href="functions#' .. plain("DataFrames.innerjoin") .. '"')
  has(db["man/joins"], 'href="../lib/functions#' .. plain("DataFrames.innerjoin") .. '"')
  has(db["man/joins"], 'href="../index"')
  has(db["index"], 'href="man/joins"')
  has(db["index"], 'href="lib/functions#' .. plain("DataFrames.innerjoin") .. '"')
end)

test("a link to something the docset does not hold goes back to the site", function()
  local db = db_of()
  has(db["lib/functions"], 'href="' .. site .. 'man/missing/"')
  has(db["index"], 'src="' .. site .. 'assets/logo.png"')
end)

vim.fn.delete(data, "rf")
if failures > 0 then
  print(failures .. " failure(s)")
  os.exit(1)
end
print("all passed")
