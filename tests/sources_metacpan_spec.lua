-- Tests for lua/docshelf/sources/metacpan.lua, offline: a fake command runner
-- serves tests/fixtures/metacpan/api as fastapi.metacpan.org/v1, so the whole
-- path -- search, release lookup, documented files, page fetch, heading
-- naming, link rewriting -- runs for real against an API that is only on disk.
--
-- The fixture pages are shaped like MetaCPAN's pod HTML: a table of contents,
-- headings whose own id is their whole text with POD's short ids nested
-- inside, =item terms as <dt>, and links as absolute metacpan.org addresses.
-- Run from the repository root: nvim --headless -l tests/sources_metacpan_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local metacpan = require("docshelf.sources.metacpan")

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

local fixtures = vim.fn.fnamemodify("tests/fixtures/metacpan/api", ":p"):gsub("/$", "")
local api = "https://fastapi.metacpan.org/v1/"

--- The fixture file answering `url`, or nil for a 404.
local function file_for(url)
  if url:sub(1, #api) ~= api then
    return nil
  end
  local path = url:sub(#api + 1)
  local index = path:match("^(%w+)/_search$")
  if index then
    path = "_search/" .. index .. ".json"
  elseif path:match("^search/autocomplete/suggest%?") then
    path = "search/autocomplete/suggest.json"
  elseif path:match("^release/") then
    path = path .. ".json"
  else
    path = path:gsub("%?content%-type=text/html$", "")
  end
  local file = fixtures .. "/" .. path
  return vim.fn.filereadable(file) == 1 and file or nil
end

--- Answers like fastapi.metacpan.org: every request is recorded, with the
--- query a POST sends.
local function runner(opts)
  opts = opts or {}
  local seen = { urls = {}, cmds = {}, posts = {} }
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
    local config
    for i, arg in ipairs(cmd) do
      if arg == "-K" then
        config = cmd[i + 1]
      elseif arg == "-d" then
        seen.posts[cmd[#cmd]] = vim.json.decode(cmd[i + 1])
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

local docset = "Demo-Dist~1.02"

local function entries_of(system)
  local by_path = {}
  for _, entry in ipairs(metacpan.index(docset, "", system or runner()).entries) do
    by_path[entry.path] = entry
  end
  return by_path
end

local function db_of(opts)
  local system, seen = runner(opts)
  metacpan.index(docset, "", system)
  return metacpan.db(docset, "", system), seen
end

-- ------------------------------------------------------------ the contract

test("the origin is the site the docs come from", function()
  eq(metacpan.origin, "metacpan.org")
end)

test("every docset documents Perl", function()
  eq(metacpan.language, "Perl")
end)

test("a docset's release is the version it is named for", function()
  eq(metacpan.release("Demo-Dist~1.02"), "1.02")
  eq(metacpan.release("Demo-Extra~0.001_002"), "0.001_002")
end)

-- ------------------------------------------------------------- searching

test("a search lists each distribution once, at the release it names", function()
  local system, seen = runner()
  eq(metacpan.search("demo", system), {
    { name = "Demo-Dist", version = "1.02" },
    { name = "Demo-Extra", version = "0.001_002" },
  })
  has(seen.urls[1], "suggest?q=demo")
end)

test("what was typed is sent encoded", function()
  local system, seen = runner()
  metacpan.search("json xs&more", system)
  has(seen.urls[1], "q=json%20xs%26more")
end)

test("a pick is resolved to the distribution's latest release", function()
  eq(metacpan.resolve("Demo-Dist", runner()), "Demo-Dist~1.02")
end)

test("a version is the one the release is named for, not its numified form", function()
  -- perl-5.44.0 has the version 5.044000: the docset says 5.44.0, as the
  -- search row did
  eq(metacpan.release(metacpan.resolve("Demo-Dist", runner())), "1.02")
end)

test("a module name is read as its distribution", function()
  eq(metacpan.resolve("Demo::Dist", runner()), "Demo-Dist~1.02")
end)

test("a distribution MetaCPAN does not have is refused by name", function()
  local ok, err = pcall(metacpan.resolve, "No-Such", runner())
  eq(ok, false)
  has(err, "No-Such")
end)

test("latest is the docset named for today's release", function()
  eq(metacpan.latest("Demo-Dist~0.9", runner()), "Demo-Dist~1.02")
end)

-- ------------------------------------------------------ the release

test("the release is the authorized upload of that version", function()
  local system, seen = runner()
  metacpan.index(docset, "", system)
  local release_query = seen.posts[api .. "release/_search"]
  has(vim.json.encode(release_query), '"name":"Demo-Dist-1.02"')
  -- the files asked for are ALICE's, not MALLORY's
  has(vim.json.encode(seen.posts[api .. "file/_search"]), '"author":"ALICE"')
  for _, url in ipairs(seen.urls) do
    has_not(url, "MALLORY")
  end
end)

-- ---------------------------------------------------------------- entries

test("each module is an entry, keyed by its name with :: as /", function()
  local entries = entries_of()
  eq(entries["Demo/Dist"], { name = "Demo::Dist", path = "Demo/Dist", type = "Modules" })
  eq(entries["Demo/Dist/Manual"], { name = "Demo::Dist::Manual", path = "Demo/Dist/Manual", type = "Modules" })
end)

test("a module documented twice is read from its file under lib/", function()
  local _, seen = db_of()
  local pods = vim.tbl_filter(function(url)
    return url:find("/pod/", 1, true) ~= nil
  end, seen.urls)
  for _, url in ipairs(pods) do
    has_not(url, "bin/demo")
  end
  has(table.concat(pods, " "), "lib/Demo/Dist.pm")
end)

test("a heading is an entry by its short id, typed by the heading holding it", function()
  local entries = entries_of()
  eq(entries["Demo/Dist#frobnicate"], { name = "Demo::Dist frobnicate($x)", path = "Demo/Dist#frobnicate", type = "Functions" })
  eq(entries["Demo/Dist#reset"], { name = "Demo::Dist reset", path = "Demo/Dist#reset", type = "Functions" })
  eq(entries["Demo/Dist/Util#HELPERS"].type, "Methods")
end)

test("an =item is an entry, its text decoded", function()
  local entries = entries_of()
  eq(entries["Demo/Dist/Util#helper"], {
    name = "Demo::Dist::Util $obj->helper(%args)",
    path = "Demo/Dist/Util#helper",
    type = "Helpers And More",
  })
end)

test("a short id another heading already has leaves the heading its own", function()
  eq(entries_of()["Demo/Dist/Util#reset"].name, "Demo::Dist::Util reset, again")
end)

test("an id holding # loses it, since the installer splits a link on every #", function()
  local entries = entries_of()
  eq(entries["Demo/Dist/Util#'-'-not-allowed"].name, "Demo::Dist::Util '#' not allowed")
  local db = db_of()
  has(db["Demo/Dist/Util"], [[<dt id="'-'-not-allowed">]])
  has(db["Demo/Dist/Util"], [[href="#'-'-not-allowed"]])
  has(db["Demo/Dist"], [[href="Dist/Util#'-'-not-allowed"]])
end)

test("an id is written as plain text, so a link decoded from an address meets it", function()
  local db = db_of()
  -- MetaCPAN writes the id escaped (&#39;), links carry it decoded (%27)
  has(db["Demo/Dist/Util"], [[<dt id="'-'-not-allowed">&#39;#&#39; not allowed</dt>]])
  -- a nested short id wins over a long one full of escapes
  has(db["Demo/Dist"], [[href="Dist/Util#x"]])
end)

test("a link to an id the page no longer has holds no # either", function()
  -- the installer then opens the page at its top, as a browser would
  has(db_of()["Demo/Dist"], [[href="Dist/Util#$--gone"]])
end)

test("top-level sections are not entries", function()
  local entries = entries_of()
  eq(entries["Demo/Dist#NAME"], nil)
  eq(entries["Demo/Dist#FUNCTIONS"], nil)
end)

-- ------------------------------------------------------------------ pages

test("every page MetaCPAN serves is kept, a missing one skipped", function()
  local keys = vim.tbl_keys(db_of())
  table.sort(keys)
  eq(keys, { "Demo/Dist", "Demo/Dist/Manual", "Demo/Dist/Util" })
end)

test("pages are fetched in one batch, in parallel where curl can", function()
  local _, seen = db_of({ parallel = true })
  local batched = vim.tbl_filter(function(cmd)
    return vim.tbl_contains(cmd, "-K") and vim.tbl_contains(cmd, "--parallel")
  end, seen.cmds)
  eq(#batched, 1)
end)

test("the table of contents goes, the documentation stays", function()
  local page = db_of()["Demo/Dist"]
  has_not(page, "<nav>")
  has(page, "a distribution to test with")
end)

test("a heading keeps one id, the short one, and its text right after it", function()
  local page = db_of()["Demo/Dist"]
  has(page, '<h2 id="frobnicate">frobnicate($x)</h2>')
  has_not(page, "<a id=")
end)

test("a link within the page follows its heading's new id", function()
  local page = db_of()["Demo/Dist"]
  has(page, 'href="#frobnicate"')
  has(page, 'href="#reset"')
end)

test("a link to a module of the docset names that page", function()
  local db = db_of()
  has(db["Demo/Dist"], 'href="Dist/Util#helper"')
  -- a heading's long id, as another page links to it, follows it too
  has(db["Demo/Dist"], 'href="Dist/Util#HELPERS"')
  has(db["Demo/Dist/Util"], 'href="../Dist#FUNCTIONS"')
end)

test("a link to a file of the release names that module's page", function()
  local db = db_of()
  has(db["Demo/Dist"], 'href="Dist/Manual"')
  has(db["Demo/Dist/Manual"], 'href="../Dist#reset"')
end)

test("a link to a module the docset does not hold stays on metacpan.org", function()
  local page = db_of()["Demo/Dist"]
  has(page, 'href="https://metacpan.org/pod/Other::Module"')
  has(page, 'href="https://metacpan.org/pod/Demo::Dist::Gone"')
end)

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
