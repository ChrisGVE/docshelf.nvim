-- Tests for lua/docshelf/sources/odin.lua, offline: a fake command runner
-- serves tests/fixtures/odin/site as pkg.odin-lang.org, so the whole path --
-- version read, catalogue parse, entry building, page fetch, cleaning, link
-- rewriting -- runs for real against a site that is only on disk.
--
-- The fixture catalogue keeps what the real pkg-data.js does that JSON does
-- not allow (trailing commas, a line break inside a comment), because that is
-- what a plain vim.json.decode fails on.
-- Run from the repository root: nvim --headless -l tests/sources_odin_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local odin = require("docshelf.sources.odin")
local internal = odin._internal

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

local fixtures = vim.fn.fnamemodify("tests/fixtures/odin/site", ":p"):gsub("/$", "")
local site = "https://pkg.odin-lang.org/"

--- Answers like pkg.odin-lang.org: a path is served from the fixture, a
--- folder by its index.html; anything else curl is handed fails as a 404.
local function runner(opts)
  opts = opts or {}
  local seen = { urls = {}, cmds = {} }
  local function body(url)
    seen.urls[#seen.urls + 1] = url
    if url:sub(1, #site) ~= site then
      return nil
    end
    local path = url:sub(#site + 1)
    if path == "" or path:sub(-1) == "/" then
      path = path .. "index.html"
    end
    local file = fixtures .. "/" .. path
    if vim.fn.filereadable(file) ~= 1 then
      return nil
    end
    return table.concat(vim.fn.readfile(file, "b"), "\n")
  end
  local function serve(url, out)
    local text = body(url)
    if text and out then
      vim.fn.writefile(vim.split(text, "\n"), out, "b")
    end
    return text
  end
  return function(cmd)
    seen.cmds[#seen.cmds + 1] = cmd
    if cmd[2] == "--help" then
      return { code = 0, stdout = opts.parallel and "--parallel-max <num>" or "", stderr = "" }
    end
    local config, out
    for i, arg in ipairs(cmd) do
      if arg == "-K" then
        config = cmd[i + 1]
      elseif arg == "-o" then
        out = cmd[i + 1]
      end
    end
    if config then
      local url, ok = nil, true
      for _, line in ipairs(vim.fn.readfile(config)) do
        local value = line:match('"(.*)"')
        if line:match("^url") then
          url = value
        elseif line:match("^output") then
          ok = serve(url, value) ~= nil and ok
        end
      end
      return { code = ok and 0 or 22, stdout = "", stderr = "" }
    end
    local text = serve(cmd[#cmd], out)
    return { code = text and 0 or 22, stdout = out and "" or (text or ""), stderr = "" }
  end,
    seen
end

local function entries_of(docset, system)
  local by_path = {}
  for _, entry in ipairs(odin.index(docset, "", system or runner()).entries) do
    by_path[entry.path] = entry
  end
  return by_path
end

local function db_of(docset, opts)
  local system, seen = runner(opts)
  return odin.db(docset, "", system), seen
end

-- ------------------------------------------------------------ the contract

test("the origin is the site the docs come from", function()
  eq(odin.origin, "pkg.odin-lang.org")
end)

test("every docset documents Odin", function()
  eq(odin.language, "Odin")
end)

test("a docset's release is the Odin version it is named for", function()
  eq(odin.release("odin~dev-2026-09"), "dev-2026-09")
  eq(odin.release("odin_vendor~dev-2026-09"), "dev-2026-09")
end)

-- ------------------------------------------------------------- searching

test("a search offers the two docsets whose name holds what was typed", function()
  local system, seen = runner()
  eq(odin.search("odin", system), { { name = "odin" }, { name = "odin_vendor" } })
  eq(odin.search("VEND", system), { { name = "odin_vendor" } })
  eq(odin.search("fmt", system), {})
  -- the list is fixed: finding it costs no request
  eq(#seen.cmds, 0)
end)

test("a pick is resolved to the version the site documents today", function()
  local system, seen = runner()
  eq(odin.resolve("odin", system), "odin~dev-2026-09")
  -- only the first line of the catalogue is read
  has(table.concat(seen.cmds[1], " "), "-r 0-")
end)

test("a name that is not one of the two docsets is refused", function()
  local ok, err = pcall(odin.resolve, "odin_extra", runner())
  eq(ok, false)
  has(err, "odin_extra")
end)

test("latest is the docset named for today's version", function()
  eq(odin.latest("odin~dev-2026-08", runner()), "odin~dev-2026-09")
  eq(odin.latest("odin_vendor~dev-2026-08", runner()), "odin_vendor~dev-2026-09")
end)

-- ------------------------------------------------------- the catalogue

test("the catalogue's JavaScript is read as JSON, strings untouched", function()
  local value = vim.json.decode(internal.to_json('{"a": ["x, }", "line\nbreak", "q\\"uote",], "b": 1,}'))
  eq(value, { a = { "x, }", "line\nbreak", 'q"uote' }, b = 1 })
end)

-- ---------------------------------------------------------------- entries

test("the odin docset holds base and core, the vendor one vendor only", function()
  local core = entries_of("odin~dev-2026-09")
  eq(core["core/fmt"] ~= nil, true)
  eq(core["base/builtin"] ~= nil, true)
  eq(core["vendor/raylib"], nil)
  local vendor = entries_of("odin_vendor~dev-2026-09")
  local keys = vim.tbl_keys(vendor)
  table.sort(keys)
  eq(keys, { "vendor/raylib", "vendor/raylib#DrawText" })
end)

test("a package is an entry named by its import path", function()
  local core = entries_of("odin~dev-2026-09")
  eq(core["core/fmt"], { name = "fmt", path = "core/fmt", type = "Packages" })
  eq(core["core/encoding/json"], { name = "encoding/json", path = "core/encoding/json", type = "Packages" })
end)

test("each declaration is an entry qualified by its package, typed by kind", function()
  local core = entries_of("odin~dev-2026-09")
  eq(core["core/fmt#println"], { name = "fmt.println", path = "core/fmt#println", type = "Procedures" })
  eq(core["core/fmt#print_any"].type, "Procedure Groups")
  eq(core["core/fmt#Info"].type, "Types")
  eq(core["core/strings#MAX_SIZE"].type, "Constants")
  eq(core["core/strings#default_builder"].type, "Variables")
  eq(core["base/builtin#len"], { name = "builtin.len", path = "base/builtin#len", type = "Builtins" })
  eq(core["core/encoding/json#marshal"].name, "encoding/json.marshal")
end)

-- ------------------------------------------------------------------ pages

test("every package page the site serves is kept, a missing one skipped", function()
  local keys = vim.tbl_keys(db_of("odin~dev-2026-09"))
  table.sort(keys)
  eq(keys, { "base/builtin", "core/encoding/json", "core/fmt", "core/strings" })
end)

test("pages are fetched in one batch, in parallel where curl can", function()
  local _, seen = db_of("odin~dev-2026-09", { parallel = true })
  local batched = vim.tbl_filter(function(cmd)
    return vim.tbl_contains(cmd, "-K") and vim.tbl_contains(cmd, "--parallel")
  end, seen.cmds)
  eq(#batched, 1)
end)

test("only the documentation is kept, without the site around it", function()
  local page = db_of("odin~dev-2026-09")["core/fmt"]
  has(page, "Overview of fmt.")
  has(page, "Writes to")
  for _, chrome in ipairs({
    "navbar",
    "pkg-sidebar",
    "TableOfContents",
    "odin-footer",
    "<script",
    "Source Files",
    "breadcrumb",
  }) do
    has_not(page, chrome)
  end
end)

test("a declaration's heading is its name alone", function()
  local page = db_of("odin~dev-2026-09")["core/fmt"]
  has(page, '<h3 id="println">println</h3>')
  has_not(page, "¶")
  has_not(page, "<em>Source</em>")
end)

test("collapsible blocks become plain text, their labels kept", function()
  local page = db_of("odin~dev-2026-09")["core/fmt"]
  has_not(page, "<details")
  has_not(page, "<summary")
  has(page, "<b>Example:</b>")
  has(page, "Types (1)")
  has(page, 'fmt.println("hi")')
end)

test("a link to a package of the docset names that page", function()
  local db = db_of("odin~dev-2026-09")
  has(db["core/fmt"], 'href="strings#Builder"')
  has(db["core/fmt"], 'href="fmt#Info"')
  has(db["core/fmt"], 'href="../base/builtin#string"')
  has(db["core/encoding/json"], 'href="../strings#Builder"')
  has(db["core/encoding/json"], 'href="json#marshal"')
end)

test("a link to a page the docset does not hold goes back to the site", function()
  local db = db_of("odin~dev-2026-09")
  has(db["core/fmt"], 'href="https://pkg.odin-lang.org/vendor/raylib/#DrawText"')
  has(db["core/fmt"], 'href="https://pkg.odin-lang.org/core/gone/#vanished"')
  has(db["core/fmt"], 'href="https://odin-lang.org/docs/overview/"')
  has(db_of("odin_vendor~dev-2026-09")["vendor/raylib"], 'href="https://pkg.odin-lang.org/core/fmt/#Info"')
end)

test("no page holds a link that leaves the docset by accident", function()
  for key, page in pairs(db_of("odin~dev-2026-09")) do
    for href in page:gmatch('href="([^"]*)"') do
      if href:sub(1, 1) == "/" or href == "" then
        error(key .. " still links " .. vim.inspect(href), 0)
      end
    end
  end
end)

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
