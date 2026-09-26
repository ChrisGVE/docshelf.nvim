-- Tests for lua/docshelf/anchors.lua: ids made plain by a source's own rule,
-- a heading naming the entry before each anchor an entry lands on, and link
-- anchors made plain the same way.
-- Run from the repository root: nvim --headless -l tests/anchors_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local anchors = require("docshelf.anchors")

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
  if actual ~= expected then
    error("expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual), 2)
  end
end

-- a rule a test can read: every character outside letters and "-" made "_"
local function plain(id)
  return (id:gsub("[^%a%-]", "_"))
end

test("every id is made plain by the source's rule", function()
  eq(anchors.name_the_anchors('<span id="a&b">x</span>', nil, plain), '<span id="a_b">x</span>')
end)

test("an old <a name> becomes an id", function()
  eq(anchors.name_the_anchors('<a name="x1"></a>', nil, plain), '<a id="x_"></a>')
end)

test("an <a> with both keeps its id and its name", function()
  eq(anchors.name_the_anchors('<a id="k" name="n"></a>', nil, plain), '<a id="k" name="n"></a>')
end)

test("a heading naming the entry goes before the anchor it lands on, once", function()
  local names = { a_b = "Demo#a&b" }
  eq(
    anchors.name_the_anchors('<span id="a&b"></span><p id="a&b"></p>', names, plain),
    '<h4 id="a_b">Demo#a&amp;b</h4><span></span><p id="a_b"></p>'
  )
end)

test("a link's anchor is made plain like the ids", function()
  eq(anchors.plain_fragments('<a href="X.html#a&b">', plain), '<a href="X.html#a_b">')
  eq(anchors.plain_fragments('<a href="#a&b">', plain), '<a href="#a_b">')
end)

test("a link to another site keeps its anchor", function()
  local html = '<a href="https://example.org/x#a&b"><a href="//example.org/y#a&b">'
  eq(anchors.plain_fragments(html, plain), html)
end)

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
