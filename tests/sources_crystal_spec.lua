-- Tests for lua/docshelf/sources/crystal.lua, offline: a fake command runner
-- serves tests/fixtures/crystal/api as crystal-lang.org/api, so the whole
-- path -- the latest redirect, the API index, page fetch, anchor naming, link
-- rewriting -- runs for real against a site that is only on disk.
--
-- The fixture index and pages are cut down from Crystal 1.21.0's: members
-- whose ids are whole signatures holding operators ("&(other:Array(U)):..."),
-- written escaped on the page and url-encoded in links, overloads, a nested
-- type, constants as <dt>, the top level's methods and macros, and a type
-- whose page the site does not serve.
-- Run from the repository root: nvim --headless -l tests/sources_crystal_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local crystal = require("docshelf.sources.crystal")
local hex = require("docshelf.anchors").hex_id

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

local fixtures = vim.fn.fnamemodify("tests/fixtures/crystal/api", ":p"):gsub("/$", "")
local site = "https://crystal-lang.org/api/"

--- The fixture file answering `url`, or nil for a 404.
local function file_for(url)
  if url:sub(1, #site) ~= site then
    return nil
  end
  local path = url:sub(#site + 1)
  local file = fixtures .. "/" .. (path == "" and "redirect" or path)
  return vim.fn.filereadable(file) == 1 and file or nil
end

--- Answers like crystal-lang.org; every request is recorded.
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
      return { code = 0, stdout = text and text:match("^302 (%S+)") or "", stderr = "" }
    end
    return { code = text and 0 or 22, stdout = text or "", stderr = "" }
  end,
    seen
end

local docset = "crystal~1.21.0"

local function entries_of(system)
  local by_path = {}
  for _, entry in ipairs(crystal.index(docset, "", system or runner()).entries) do
    by_path[entry.path] = entry
  end
  return by_path
end

local function db_of(opts)
  local system, seen = runner(opts)
  crystal.index(docset, "", system)
  return crystal.db(docset, "", system), seen
end

-- ------------------------------------------------------------ the contract

test("the origin is the site the docs come from", function()
  eq(crystal.origin, "crystal-lang.org")
end)

test("every docset documents Crystal", function()
  eq(crystal.language, "Crystal")
end)

test("a docset's release is the version it is named for", function()
  eq(crystal.release("crystal~1.21.0"), "1.21.0")
end)

test("a docset not named crystal is refused", function()
  eq(pcall(crystal.release, "ruby~1.0"), false)
end)

-- ------------------------------------------------------------- searching

test("a search offers the one docset when what was typed is in its name", function()
  local system, seen = runner()
  eq(crystal.search("Cry", system), { { name = "crystal" } })
  eq(crystal.search("ruby", system), {})
  eq(#seen.urls, 0)
end)

test("a pick is resolved to the newest release the site redirects to", function()
  eq(crystal.resolve("crystal", runner()), "crystal~1.21.0")
end)

test("a name other than crystal is refused", function()
  local ok, err = pcall(crystal.resolve, "shards", runner())
  eq(ok, false)
  has(err, "shards")
end)

test("latest is the docset named for today's release", function()
  eq(crystal.latest("crystal~1.20.0", runner()), "crystal~1.21.0")
end)

-- ---------------------------------------------------------------- entries

test("the index is asked for decompressed", function()
  local system, seen = runner()
  crystal.index(docset, "", system)
  local asked = vim.tbl_filter(function(cmd)
    return cmd[#cmd]:find("index.json", 1, true) ~= nil
  end, seen.cmds)
  eq(#asked, 1)
  eq(vim.tbl_contains(asked[1], "--compressed"), true)
end)

test("every type is an entry, named without its type parameters", function()
  local entries = entries_of()
  eq(entries["Array"], { name = "Array", path = "Array", type = "Classes" })
  eq(entries["Atomic/Flag"], { name = "Atomic::Flag", path = "Atomic/Flag", type = "Structs" })
  eq(entries["Signal"].type, "Enums")
end)

test("the top level is an entry, and its members, unprefixed", function()
  local entries = entries_of()
  -- the installer resolves a link to "toplevel#ARGV" through this entry
  eq(entries["toplevel"], { name = "Top Level Namespace", path = "toplevel", type = "Modules" })
  eq(entries["toplevel#" .. hex("puts(*objects):Nil-class-method")].name, "puts(*objects)")
  eq(entries["toplevel#" .. hex("record(__name,*properties,**kwargs,&block)-macro")], {
    name = "record(__name, *properties, **kwargs, &block)",
    path = "toplevel#" .. hex("record(__name,*properties,**kwargs,&block)-macro"),
    type = "Macros",
  })
  eq(entries["toplevel#ARGV"].name, "ARGV")
end)

test("each overload is its own entry, named with its parameters", function()
  local entries = entries_of()
  eq(entries["Array#" .. hex("new(initial_capacity:Int)-class-method")], {
    name = "Array.new(initial_capacity : Int)",
    path = "Array#" .. hex("new(initial_capacity:Int)-class-method"),
    type = "Constructors",
  })
  eq(entries["Array#new-class-method"].name, "Array.new")
end)

test("an instance method is joined with #, its return type left out", function()
  local entries = entries_of()
  eq(entries["Array#" .. hex("&(other:Array(U)):Array(T)forallU-instance-method")], {
    name = "Array#&(other : Array(U))",
    path = "Array#" .. hex("&(other:Array(U)):Array(T)forallU-instance-method"),
    type = "Instance Methods",
  })
  eq(entries["Array#" .. hex("clear:self-instance-method")].name, "Array#clear")
  eq(entries["Atomic/Flag#" .. hex("test_and_set:Bool-instance-method")].name, "Atomic::Flag#test_and_set")
end)

test("a constant is an entry joined with ::", function()
  eq(entries_of()["Signal#INT"], { name = "Signal::INT", path = "Signal#INT", type = "Constants" })
end)

-- ------------------------------------------------------------------ pages

test("every page the site serves is kept, a missing one skipped", function()
  local keys = vim.tbl_keys(db_of())
  table.sort(keys)
  eq(keys, { "Array", "Atomic", "Atomic/Flag", "Signal", "toplevel" })
end)

test("pages are fetched in one batch, in parallel where curl can", function()
  local _, seen = db_of({ parallel = true })
  local batched = vim.tbl_filter(function(cmd)
    return vim.tbl_contains(cmd, "-K") and vim.tbl_contains(cmd, "--parallel")
  end, seen.cmds)
  eq(#batched, 1)
end)

test("the sidebar, the icons, the permalinks and the source links go", function()
  local page = db_of()["Array"]
  has_not(page, "types-list")
  has_not(page, "<svg")
  has_not(page, "method-permalink")
  has_not(page, "View source")
  has(page, "Set intersection")
end)

test("a heading naming the entry goes before each member it lands on", function()
  local db = db_of()
  has(db["Array"], '<h4 id="' .. hex("&(other:Array(U)):Array(T)forallU-instance-method") .. '">Array#&amp;(other : Array(U))</h4>')
  has(db["Array"], '<h4 id="' .. hex("-(other:Array(U)):Array(T)forallU-instance-method") .. '">Array#-(other : Array(U))</h4>')
  has(db["Signal"], '<h4 id="INT">Signal::INT</h4>')
end)

test("a link within the page follows the plain ids", function()
  has(db_of()["Array"], 'href="#' .. hex("-(other:Array(U)):Array(T)forallU-instance-method") .. '"')
end)

test("a link to a page of the docset names that page", function()
  local db = db_of()
  has(db["Array"], 'href="Signal#INT"')
  has(db["Array"], 'href="Atomic/Flag#' .. hex("test_and_set:Bool-instance-method") .. '"')
  has(db["Atomic/Flag"], 'href="../Atomic"')
  has(db["toplevel"], 'href="Array#' .. hex("clear:self-instance-method") .. '"')
end)

test("a link to a page the docset does not hold stays on crystal-lang.org", function()
  local db = db_of()
  has(db["Array"], 'href="https://crystal-lang.org/api/1.21.0/Hash.html"')
  has(db["Atomic/Flag"], 'href="https://crystal-lang.org/api/1.21.0/Bool.html"')
end)

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
