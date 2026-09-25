-- Tests for the installer's link fixer (fix_file_links in lua/docshelf/install.lua).
--
-- elinks writes a page's links as a numbered list of file:// addresses; the
-- fixer turns those that lead into the docset into local:// ones. These cases
-- are the links a split entry makes to itself: the entry's file is named
-- "<name>#<page key>#<id>.html" with "/" in the key written "_", and the link
-- should reach the whole page it was split from.
-- Run from the repository root: nvim --headless -l tests/install_links_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local fix_file_links = require("docshelf.install")._internal.fix_file_links
local filenames = require("docshelf.filenames")

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

local target = "/data/set~1"
local name_file = filenames.namer({})

--- The fixed line for one link `href` found in the entry at page `key`, anchor
--- `id`, named `name`, split from the page file `containing`.
local function fixed(opts)
  local file = name_file(opts.name .. "#" .. opts.key .. "#" .. opts.id) .. ".html"
  local lines, changes = fix_file_links(
    target .. "/" .. file .. ".md",
    { "   1. file://" .. target .. "/" .. opts.href },
    target,
    "set~1",
    {},
    { [opts.containing] = { Info = "Info" } },
    opts.key .. "#" .. opts.id,
    opts.containing,
    name_file
  )
  return lines[1], changes
end

test("an entry's link to itself reaches the page it was split from", function()
  local line, changes = fixed({
    name = "fmt.println",
    key = "fmt",
    id = "println",
    containing = "fmt#fmt",
    href = "fmt.println%23fmt%23println.html#Info",
  })
  eq(line, "   1. local://set~1/fmt#fmt#Info")
  eq(changes, true)
end)

test("so does one whose page key is a path", function()
  local line, changes = fixed({
    name = "fmt.println",
    key = "core/fmt",
    id = "println",
    containing = "fmt#core_fmt",
    href = "fmt.println%23core_fmt%23println.html#Info",
  })
  eq(line, "   1. local://set~1/fmt#core_fmt#Info")
  eq(changes, true)
end)

test("a docset folder elinks writes escaped (\"@\" as %40) is still the docset", function()
  local folder = "/data/lib@org.example~1"
  local file = name_file("fmt.println#fmt#println") .. ".html"
  local lines, changes = fix_file_links(
    folder .. "/" .. file .. ".md",
    { "   1. file:///data/lib%40org.example~1/fmt.println%23fmt%23println.html#Info" },
    folder,
    "lib@org.example~1",
    {},
    { ["fmt#fmt"] = { Info = "Info" } },
    "fmt#println",
    "fmt#fmt",
    name_file
  )
  eq(lines[1], "   1. local://lib@org.example~1/fmt#fmt#Info")
  eq(changes, true)
end)

test("an entry whose name held # still reaches the page it was split from", function()
  -- Scala's #:: method: the name's "#" is kept out of the file name, and elinks
  -- percent-encodes what stands in for it
  local escaped = filenames.entry_name("Ops.#::")
  local line, changes = fixed({
    name = escaped,
    key = "cats_data_Ops",
    id = "x",
    containing = "Ops#cats_data_Ops",
    href = vim.uri_encode(escaped, "rfc2396") .. "%23cats_data_Ops%23x.html#Info",
  })
  eq(line, "   1. local://set~1/Ops#cats_data_Ops#Info")
  eq(changes, true)
end)

if failures > 0 then
  print(failures .. " failure(s)")
  os.exit(1)
end
