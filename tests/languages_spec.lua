-- Tests for lua/apidocs/languages.lua.
-- Run from the repository root: nvim --headless -l tests/languages_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local languages = require("apidocs.languages")

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

local table_ = {
  python = { kind = "language", language = "Python" },
  numpy = { kind = "package", language = "Python" },
  scikit_learn = { kind = "package", language = "Python" },
  lua = { kind = "language", language = "Lua" },
  love = { kind = "package", language = "Lua" },
  git = { kind = "tool" },
  c = { kind = "language", language = "C" },
}

-- lookup -----------------------------------------------------------------------

test("a versioned slug is looked up by its family", function()
  eq(languages.of("python~3.14", table_), { kind = "language", language = "Python" })
end)

test("an unversioned slug is its own family", function()
  eq(languages.of("numpy", table_), { kind = "package", language = "Python" })
end)

test("a family missing from the table is unlinked", function()
  eq(languages.of("brand_new~1", table_), nil)
end)

-- pulled in -----------------------------------------------------------------------

local installed =
  { "c", "git", "lua~5.1", "lua~5.4", "love", "numpy~2.5", "python~3.13", "python~3.14", "scikit_learn" }

test("selecting a language pulls in its installed packages", function()
  eq(languages.pulled_in({ "python~3.14" }, installed, table_), { "numpy~2.5", "scikit_learn" })
end)

test("other versions of the language are not pulled in", function()
  -- python~3.13 is the same language but a different reference: picking 3.14 means 3.14
  eq(vim.tbl_contains(languages.pulled_in({ "python~3.14" }, installed, table_), "python~3.13"), false)
end)

test("selecting only a package pulls in nothing", function()
  eq(languages.pulled_in({ "numpy~2.5" }, installed, table_), {})
end)

test("a tool pulls in nothing, and is never pulled in", function()
  eq(languages.pulled_in({ "git", "c" }, installed, table_), {})
end)

test("sources already selected are not repeated", function()
  eq(languages.pulled_in({ "python~3.14", "numpy~2.5" }, installed, table_), { "scikit_learn" })
end)

test("two languages pull in both sets, sorted", function()
  eq(languages.pulled_in({ "lua~5.4", "python~3.14" }, installed, table_), { "love", "numpy~2.5", "scikit_learn" })
end)

-- the shipped data ------------------------------------------------------------------

test("every language in the shipped source table is a Linguist language", function()
  local linguist = require("apidocs.linguist_languages")
  local unknown = {}
  for family, entry in pairs(require("apidocs.source_languages")) do
    if entry.language and not linguist[entry.language] then
      table.insert(unknown, family .. "=" .. entry.language)
    end
    if entry.kind ~= "tool" and not entry.language then
      table.insert(unknown, family .. " has no language")
    end
  end
  eq(unknown, {})
end)

test("the shipped table is used by default", function()
  eq(languages.of("scikit_learn"), { kind = "package", language = "Python" })
end)

if failures > 0 then
  print(failures .. " failure(s)")
  os.exit(1)
end
print("all passed")
