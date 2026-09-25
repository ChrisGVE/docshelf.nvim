-- Tests for following a local:// link (lua/docshelf/common.lua).
--
-- A link target is "<choice>/<file name>" optionally followed by "#<section>",
-- and a file name holds one "#" ("name#page") or two (Lua's "Class#method"
-- pages). The section is the text of the heading the link leads to, and
-- that text may hold "#" itself (Scala's `#::`), so the file name is found by
-- which prefix names a file, never by counting "#".
-- Run from the repository root: nvim --headless -l tests/follow_link_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local common = require("docshelf.common")

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

-- a disk holding exactly these files
local function disk(files)
  local set = {}
  for _, f in ipairs(files) do
    set[f] = true
  end
  return function(file)
    return set[file] == true
  end
end

local split = common.split_local_target

test("a file name alone has no section", function()
  eq({ split("d~1/str#page", disk({ "d~1/str#page" })) }, { "d~1/str#page", nil })
end)

test("a section follows the file name", function()
  eq({ split("d~1/str#page#Methods", disk({ "d~1/str#page" })) }, { "d~1/str#page", "Methods" })
end)

test("a file name with two hashes keeps both (Lua)", function()
  eq({ split("d~1/io#file#read#Returns", disk({ "d~1/io#file#read" })) }, { "d~1/io#file#read", "Returns" })
end)

test("a section holding # stays whole (Scala's #::)", function()
  local target = "d~1/cats.data.Ops#cats_data_Ops#Ops.#::"
  eq({ split(target, disk({ "d~1/cats.data.Ops#cats_data_Ops" })) }, { "d~1/cats.data.Ops#cats_data_Ops", "Ops.#::" })
end)

test("the longest file name that exists wins", function()
  local target = "d~1/a#b#c#Sec"
  eq({ split(target, disk({ "d~1/a#b", "d~1/a#b#c" })) }, { "d~1/a#b#c", "Sec" })
end)

test("a missing file falls back to name#page, the rest as the section", function()
  eq({ split("d~1/a#b#c#d", disk({})) }, { "d~1/a#b", "c#d" })
end)

test("a section is found as text, not as a pattern", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "intro", "aXb[0]", "a.b[0] /x\\y", "end" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  common.find_section("a.b[0] /x\\y")
  eq(vim.api.nvim_win_get_cursor(0)[1], 3)
end)

if failures > 0 then
  print(failures .. " failure(s)")
  os.exit(1)
end
print("all passed")
