-- Tests for lua/docshelf/filter_pick.lua.
-- Run from the repository root: nvim --headless -l tests/filter_pick_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local filter_pick = require("docshelf.filter_pick")

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

local links = {
  ["python~3.14"] = { language = "Python", kind = "language" },
  ["numpy~2.5"] = { language = "Python", kind = "package" },
  ["rust"] = { language = "Rust", kind = "language" },
  ["tokio"] = { language = "Rust", kind = "package" },
  ["mystery"] = {},
}

local installed = { "mystery", "numpy~2.5", "python~3.14", "rust", "tokio" }

local function names_of(rows)
  return vim.tbl_map(function(row)
    return row.name
  end, rows)
end

test("with no filter every docset is listed, alphabetically", function()
  eq(names_of(filter_pick.rows(installed, links, nil)), { "mystery", "numpy~2.5", "python~3.14", "rust", "tokio" })
end)

test("with no filter nothing is marked", function()
  for _, row in ipairs(filter_pick.rows(installed, links, nil)) do
    eq(row.active, nil)
    eq(row.via, nil)
  end
end)

test("the picked docsets come first", function()
  local rows = filter_pick.rows(installed, links, { "rust" })
  eq(rows[1].name, "rust")
  eq(rows[1].active, 1)
end)

test("what a language pulls in comes next, and says what brought it", function()
  local rows = filter_pick.rows(installed, links, { "rust" })
  eq(rows[2].name, "tokio")
  eq(rows[2].active, 2)
  eq(rows[2].via, "rust")
end)

test("everything else follows, alphabetically", function()
  eq(names_of(filter_pick.rows(installed, links, { "rust" })), {
    "rust",
    "tokio",
    "mystery",
    "numpy~2.5",
    "python~3.14",
  })
end)

test("a package picked alone pulls in nothing", function()
  local rows = filter_pick.rows(installed, links, { "numpy~2.5" })
  eq(rows[1].name, "numpy~2.5")
  eq(rows[1].active, 1)
  eq(rows[2].via, nil)
end)

test("two picked languages each rank their own first", function()
  eq(names_of(filter_pick.rows(installed, links, { "python~3.14", "rust" })), {
    "python~3.14",
    "rust",
    "numpy~2.5",
    "tokio",
    "mystery",
  })
end)

-- what each row shows --------------------------------------------------------

test("a row carries the language it is labelled with", function()
  local rows = filter_pick.rows(installed, links, nil)
  eq(rows[3].name, "python~3.14")
  eq(rows[3].language, "Python")
end)

test("a docset with no language reads as Unknown, so it can be typed for", function()
  local rows = filter_pick.rows(installed, links, nil)
  eq(rows[1].name, "mystery")
  eq(rows[1].language, "Unknown")
end)

test("the language column is padded to the widest, so the names line up", function()
  local rows = filter_pick.rows(installed, links, nil)
  local widths = {}
  for _, row in ipairs(rows) do
    widths[#row.pad + #row.language] = true
  end
  eq(vim.tbl_count(widths), 1)
end)

test("a row's search text holds the language and the docset", function()
  local rows = filter_pick.rows(installed, links, { "rust" })
  eq(rows[1].text:find("Rust", 1, true) ~= nil, true)
  eq(rows[1].text:find("rust", 1, true) ~= nil, true)
end)

test("an empty installed list gives no rows rather than an error", function()
  eq(filter_pick.rows({}, {}, nil), {})
end)

if failures > 0 then
  print(failures .. " failure(s)")
  os.exit(1)
end
print("all passed")
