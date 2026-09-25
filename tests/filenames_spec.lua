-- Tests for lua/docshelf/filenames.lua.
-- Run from the repository root: nvim --headless -l tests/filenames_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

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

local readdir = "os.File.ReadDir()#os/index#File.ReadDir"
local readdir_lower = "os.File.Readdir()#os/index#File.Readdir"

test("a stem replaces slashes and quotes, as the installer always did", function()
  eq(filenames.stem("a/b'c"), "a_b_c")
end)

test("a stem leaves room for the .html.md the file will end in", function()
  eq(#filenames.stem(string.rep("x", 400)), 255 - #".html.md")
end)

test("a stem cut to length never splits a character", function()
  -- a file name must be valid UTF-8 on macOS; 246 x's and then "é" (two
  -- bytes) would be cut in the middle of the "é"
  local stem = filenames.stem(string.rep("x", 246) .. "é" .. string.rep("y", 20))
  eq(stem, string.rep("x", 246))
end)

test("names differing only in case are twins", function()
  local twins = filenames.case_twins({ readdir, readdir_lower, "os.Open()#os/index#Open" })
  eq(twins, { [filenames.stem(readdir)] = true, [filenames.stem(readdir_lower)] = true })
end)

test("a name listed twice is not its own twin", function()
  eq(filenames.case_twins({ readdir, readdir }), {})
end)

test("without twins, a name gets its plain stem", function()
  local name = filenames.namer({})
  eq(name(readdir), filenames.stem(readdir))
end)

test("twins get file names that differ even ignoring case", function()
  local name = filenames.namer(filenames.case_twins({ readdir, readdir_lower }))
  local a, b = name(readdir), name(readdir_lower)
  if a:lower() == b:lower() then
    error("twins still share a file on a case-insensitive disk: " .. a .. " / " .. b)
  end
end)

test("a twin's file name keeps every # of its stem", function()
  -- the link fixer and the pickers split file names on "#"
  local name = filenames.namer(filenames.case_twins({ readdir, readdir_lower }))
  eq(#vim.split(name(readdir), "#"), #vim.split(filenames.stem(readdir), "#"))
end)

test("naming a file name again changes nothing", function()
  -- the link fixer passes names it already derived back through the namer
  local name = filenames.namer(filenames.case_twins({ readdir, readdir_lower }))
  eq(name(name(readdir)), name(readdir))
  eq(name(name("os.Open()#os/index#Open")), name("os.Open()#os/index#Open"))
end)

test("a twin's tag uses only characters elinks leaves unencoded", function()
  local name = filenames.namer(filenames.case_twins({ readdir, readdir_lower }))
  local tag = name(readdir):sub(1, #name(readdir) - #filenames.stem(readdir))
  if not tag:match("^[%w%-%._~]+$") then
    error("tag holds a character elinks would encode: " .. tag)
  end
end)

test("display drops a twin's tag and keeps a plain name as it is", function()
  local name = filenames.namer(filenames.case_twins({ readdir, readdir_lower }))
  eq(filenames.display(name(readdir)), filenames.stem(readdir))
  eq(filenames.display("python~3.14"), "python~3.14")
end)

test("display drops the tag behind a folder too", function()
  -- telescope shows "<folder>/<file name>"
  local name = filenames.namer(filenames.case_twins({ readdir, readdir_lower }))
  eq(filenames.display("go/" .. name(readdir)), "go/" .. filenames.stem(readdir))
  eq(filenames.display("python~3.14/str.lower()#x"), "python~3.14/str.lower()#x")
end)

test("the pickers show a twin without its tag", function()
  local common = require("docshelf.common")
  local name = filenames.namer(filenames.case_twins({ readdir, readdir_lower }))
  eq(common.filename_to_display(name(readdir)), "os.File.ReadDir()")
  eq(common.filename_to_display("go/" .. name(readdir)), "go/os.File.ReadDir()")
end)

test("an entry name keeps no # of its own, and shows it again", function()
  -- Ruby names a method Class#method, Scala has a method named #::; the file
  -- name scheme splits on "#" (issue #4)
  local common = require("docshelf.common")
  local named = filenames.entry_name("Nokogiri::XML::NodeSet#css")
  eq(named:find("#", 1, true), nil)
  eq(common.filename_to_display(named .. "#Nokogiri_XML_NodeSet"), "Nokogiri::XML::NodeSet#css")
  eq(common.filename_to_display(filenames.entry_name("Ops.#::") .. "#ops#x"), "Ops.#::")
  eq(filenames.entry_name("str.lower()"), "str.lower()")
end)

if failures > 0 then
  os.exit(1)
end
