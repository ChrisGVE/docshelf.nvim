-- Tests for lua/docshelf/sources/gemdocs.lua, offline: a fake command runner
-- serves tests/fixtures/gemdocs/site as gemdocs.org and
-- tests/fixtures/gemdocs/rubygems as rubygems.org's API, so the whole path --
-- search, the latest redirect, YARD's lists, page fetch, anchor naming, link
-- rewriting -- runs for real against sites that are only on disk.
--
-- The fixture pages are cut down from gemdocs.org's YARD pages for nokogiri
-- 1.19.2: lists of links titled "<name> (<kind>)", method anchors holding
-- Ruby's operators ("&-instance_method", "<=>-instance_method"), an empty
-- <span> anchor for an attribute writer, constants as <dt>, and the source of
-- every method in a table.
-- Run from the repository root: nvim --headless -l tests/sources_gemdocs_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local gemdocs = require("docshelf.sources.gemdocs")

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

local fixtures = vim.fn.fnamemodify("tests/fixtures/gemdocs", ":p"):gsub("/$", "")
local site = "https://gemdocs.org/"
local rubygems = "https://rubygems.org/api/v1/"

--- The fixture file answering `url`, or nil for a 404.
local function file_for(url)
  local path
  if url:sub(1, #site) == site then
    path = "site/" .. url:sub(#site + 1)
  elseif url:sub(1, #rubygems) == rubygems and url:find("search.json?", 1, true) then
    path = "rubygems/search.json"
  else
    return nil
  end
  local file = fixtures .. "/" .. path
  return vim.fn.filereadable(file) == 1 and file or nil
end

--- Answers like gemdocs.org and rubygems.org; every request is recorded.
local function runner(opts)
  opts = opts or {}
  local seen = { urls = {}, cmds = {} }
  local function body(url)
    seen.urls[#seen.urls + 1] = url
    local file = file_for(url)
    return file and table.concat(vim.fn.readfile(file, "b"), "\n") or nil
  end
  return function(cmd)
    seen.cmds[#seen.cmds + 1] = cmd
    if cmd[2] == "--help" then
      return { code = 0, stdout = opts.parallel and "--parallel-max <num>" or "", stderr = "" }
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
    local text = body(cmd[#cmd])
    if write_out == "%{redirect_url}" then
      -- curl without -f: a 404 still exits 0, with no redirect to write
      local redirect = text and text:match("^302 (%S+)") or ""
      return { code = 0, stdout = redirect, stderr = "" }
    end
    return { code = text and 0 or 22, stdout = text or "", stderr = "" }
  end,
    seen
end

local docset = "demo~1.2.0"

local function entries_of(system)
  local by_path = {}
  for _, entry in ipairs(gemdocs.index(docset, "", system or runner()).entries) do
    by_path[entry.path] = entry
  end
  return by_path
end

local function db_of(opts)
  local system, seen = runner(opts)
  gemdocs.index(docset, "", system)
  return gemdocs.db(docset, "", system), seen
end

-- ------------------------------------------------------------ the contract

test("the origin is the site the docs come from", function()
  eq(gemdocs.origin, "gemdocs.org")
end)

test("every docset documents Ruby", function()
  eq(gemdocs.language, "Ruby")
end)

test("a docset's release is the version it is named for", function()
  eq(gemdocs.release("demo~1.2.0"), "1.2.0")
  eq(gemdocs.release("aws-sdk-core~3.201.0.pre"), "3.201.0.pre")
end)

-- ------------------------------------------------------------- searching

test("a search lists rubygems.org's gems, the most downloaded first", function()
  local system, seen = runner()
  eq(gemdocs.search("noko", system), { { name = "nokogiri" }, { name = "noko" }, { name = "noko_builder" } })
  has(seen.urls[1], "rubygems.org/api/v1/search.json?query=noko")
end)

test("what was typed is sent encoded", function()
  local system, seen = runner()
  gemdocs.search("a&b+c", system)
  has(seen.urls[1]:upper(), "QUERY=A%26B%2BC")
end)

test("a pick is resolved to the newest version gemdocs has built", function()
  eq(gemdocs.resolve("demo", runner()), "demo~1.2.0")
end)

test("a gem gemdocs has not built is refused by name", function()
  local ok, err = pcall(gemdocs.resolve, "no-such-gem", runner())
  eq(ok, false)
  has(err, "no-such-gem")
end)

test("latest is the docset named for the version gemdocs has today", function()
  eq(gemdocs.latest("demo~1.0.0", runner()), "demo~1.2.0")
end)

-- ------------------------------------------------------------------ ids

test("an id keeps letters, digits, _ and -, and writes anything else in hex", function()
  local plain = gemdocs._internal.plain_id
  eq(plain("css-instance_method"), "css-instance_method")
  eq(plain("&-instance_method"), ".26-instance_method")
  eq(plain("&amp;-instance_method"), ".26-instance_method")
  eq(plain("%25-class_method"), ".25-class_method")
  eq(plain("&lt;=&gt;-instance_method"), plain("<=>-instance_method"))
end)

test("two operators never share an id", function()
  local plain = gemdocs._internal.plain_id
  local ids = {}
  for _, op in ipairs({ "&", "-", "|", "^", "+", "[]", "[]=", "==", "===", "=~", "<=>", "<<", "-@", "!", "!=" }) do
    local id = plain(op .. "-instance_method")
    eq(ids[id], nil)
    ids[id] = op
  end
end)

-- ---------------------------------------------------------------- entries

test("every class and module is an entry, keyed by its page", function()
  local entries = entries_of()
  eq(entries["Demo"], { name = "Demo", path = "Demo", type = "Modules" })
  eq(entries["Demo/Set"], { name = "Demo::Set", path = "Demo/Set", type = "Classes" })
end)

test("every page is an entry, the top-level namespace too", function()
  -- the installer resolves a link to "Page#anchor" through the page's entry
  local entries = entries_of()
  eq(entries["top-level-namespace"], { name = "Top Level Namespace", path = "top-level-namespace", type = "Modules" })
  eq(entries["Object/Extra"], { name = "Object::Extra", path = "Object/Extra", type = "Modules" })
end)

test("every method is an entry named as YARD names it", function()
  local entries = entries_of()
  eq(entries["Demo/Set#css-instance_method"], {
    name = "Demo::Set#css",
    path = "Demo/Set#css-instance_method",
    type = "Instance Methods",
  })
  eq(entries["Demo#parse-class_method"], { name = "Demo.parse", path = "Demo#parse-class_method", type = "Class Methods" })
  eq(entries["Demo/Set#.25-class_method"].name, "Demo::Set.%")
end)

test("an operator method is an entry with its own plain anchor", function()
  local entries = entries_of()
  eq(entries["Demo/Set#.26-instance_method"].name, "Demo::Set#&")
  eq(entries["Demo/Set#--instance_method"].name, "Demo::Set#-")
  eq(entries["Demo/Set#.3C.3D.3E-instance_method"].name, "Demo::Set#<=>")
  eq(entries["Demo/Set#.5B.5D-instance_method"].name, "Demo::Set#[]")
end)

test("a constant is an entry, read from its class's page", function()
  eq(entries_of()["Demo#VERSION-constant"], { name = "Demo::VERSION", path = "Demo#VERSION-constant", type = "Constants" })
end)

test("an extra file is an entry named with the gem", function()
  eq(entries_of()["index"], { name = "demo README", path = "index", type = "Guides" })
end)

test("nothing is an entry on a page gemdocs did not serve", function()
  local entries = entries_of()
  eq(entries["Demo/Gone"], nil)
  eq(entries["Demo/Gone#vanish-instance_method"], nil)
end)

-- ------------------------------------------------------------------ pages

test("every page an entry names is kept, a missing one skipped", function()
  local keys = vim.tbl_keys(db_of())
  table.sort(keys)
  eq(keys, { "Demo", "Demo/Set", "Object/Extra", "index", "top-level-namespace" })
end)

test("pages are fetched in one batch, in parallel where curl can", function()
  local _, seen = db_of({ parallel = true })
  local batched = vim.tbl_filter(function(cmd)
    return vim.tbl_contains(cmd, "-K") and vim.tbl_contains(cmd, "--parallel")
  end, seen.cmds)
  eq(#batched, 1)
end)

test("the menu, the scripts, the footer and the source go, the documentation stays", function()
  local page = db_of()["Demo/Set"]
  has_not(page, 'id="menu"')
  has_not(page, "<script")
  has_not(page, "Generated on")
  has_not(page, "source_code")
  has_not(page, "lib/demo/set.rb")
  has(page, "Set intersection")
end)

test("the site's switches go", function()
  local page = db_of()["Demo/Set"]
  has_not(page, "collapse")
  has_not(page, "show all")
end)

test("a heading naming the entry goes before each member it lands on", function()
  local page = db_of()["Demo/Set"]
  has(page, '<h4 id=".26-instance_method">Demo::Set#&amp;</h4>')
  has(page, '<h4 id="--instance_method">Demo::Set#-</h4>')
  has(page, '<h4 id=".3C.3D.3E-instance_method">Demo::Set#&lt;=&gt;</h4>')
  has(page, '<h4 id=".25-class_method">Demo::Set.%</h4>')
  has(db_of()["Demo"], '<h4 id="VERSION-constant">Demo::VERSION</h4>')
end)

test("an attribute writer's empty anchor gets its heading too", function()
  has(db_of()["Demo/Set"], '<h4 id="document.3D-instance_method">Demo::Set#document=</h4>')
end)

test("a link within the page follows the plain ids", function()
  local page = db_of()["Demo/Set"]
  has(page, 'href="#.26-instance_method"')
  has(page, 'href="#--instance_method"')
  has(page, 'href="#.5B.5D-instance_method"')
end)

test("a link to a page of the docset names that page", function()
  local db = db_of()
  has(db["Demo"], 'href="Demo/Set"')
  has(db["Demo"], 'href="Demo/Set#css-instance_method"')
  has(db["Demo/Set"], 'href="../Demo#VERSION-constant"')
  has(db["index"], 'href="Demo/Set#css-instance_method"')
end)

test("a link to the page holding it keeps its text and loses the link", function()
  local page = db_of()["Demo/Set"]
  has_not(page, 'href=""')
  has(page, "Compare with <span class='object_link'>Demo::Set</span>")
end)

test("a link to a page the docset does not hold stays on gemdocs.org", function()
  local db = db_of()
  has(db["Demo"], 'href="https://gemdocs.org/gems/demo/1.2.0/Other.html"')
  has(db["Demo/Set"], 'href="https://gemdocs.org/gems/demo/1.2.0/_index.html"')
  has(db["Demo/Set"], 'href="https://gemdocs.org/gems/other/1.0.0/Other.html#x&amp;y"')
end)

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
