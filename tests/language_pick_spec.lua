-- Tests for lua/docshelf/language_pick.lua (the rows of the language picker).
-- Run from the repository root: nvim --headless -l tests/language_pick_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local pick = require("docshelf.language_pick")
local languages = require("docshelf.languages")

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

local function names_of(rows)
  return vim.tbl_map(function(row)
    return row.add and ("+" .. row.name) or row.name
  end, rows)
end

local names = { "Python", "Rust", "Git", "Haskell" }

test("with nothing typed every name is offered, in order", function()
  eq(names_of(pick.rows(names, "")), names)
  eq(names_of(pick.rows(names, nil)), names)
end)

test("typing narrows to the matches, with the add row while nothing matches exactly", function()
  eq(names_of(pick.rows(names, "pyt")), { "+pyt", "Python" })
  eq(names_of(pick.rows(names, "s")), { "+s", "Rust", "Haskell" })
end)

test("a name typed in full is a choice, not a new name", function()
  eq(names_of(pick.rows(names, "python")), { "Python" })
  eq(names_of(pick.rows(names, " Git ")), { "Git" })
end)

test("an alias of a configured entry is a choice too", function()
  -- py names Python, gh names GitHub; neither is a new name
  eq(names_of(pick.rows(names, "py")), { "Python" })
  eq(names_of(pick.rows({ "GitHub" }, "gh")), { "GitHub" })
end)

test("an unknown word is offered as a new name, first", function()
  eq(names_of(pick.rows(names, "Prolog")), { "+Prolog" })
  eq(names_of(pick.rows(names, "hask")), { "+hask", "Haskell" })
end)

test("the offered names are the lists plus what installed docsets hold, A-Z", function()
  local available = languages.available({ "Prolog", "Python" })
  eq(vim.tbl_contains(available, "Prolog"), true)
  eq(#vim.tbl_filter(function(n)
    return n == "Python"
  end, available), 1)
  local sorted = vim.deepcopy(available)
  table.sort(sorted, function(a, b)
    return a:lower() < b:lower()
  end)
  eq(available, sorted)
end)

if failures > 0 then
  print(failures .. " failure(s)")
  os.exit(1)
end
print("all passed")
