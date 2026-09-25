-- Tests for lua/docshelf/html.lua: reading text out of HTML.
-- Run from the repository root: nvim --headless -l tests/html_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local html = require("docshelf.html")

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

test("named references are decoded", function()
  eq(html.decode_entities("a &lt;b&gt; &amp; &quot;c&quot; &mdash; d"), 'a <b> & "c" — d')
end)

test("numeric references are decoded, decimal and hexadecimal", function()
  eq(html.decode_entities("&#39;x&#39; &#x2019; &#X41;"), "'x' ’ A")
end)

test("an unknown named reference is left as it is", function()
  eq(html.decode_entities("&bogus; &amp"), "&bogus; &amp")
end)

test("text drops tags, decodes references and folds white space", function()
  eq(html.text("<i>$OBJ</i>-&gt;Seen(<i>[HASHREF]</i>)"), "$OBJ->Seen([HASHREF])")
  eq(html.text("  a\n  <b>b</b>\tc  "), "a b c")
end)

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
