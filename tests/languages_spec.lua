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
-- pulled_in reads each installed docset's recorded link
local links = {}
for _, slug in ipairs(installed) do
  links[slug] = languages.of(slug, table_)
end

test("selecting a language pulls in its installed packages", function()
  eq(languages.pulled_in({ "python~3.14" }, installed, links), { "numpy~2.5", "scikit_learn" })
end)

test("other versions of the language are not pulled in", function()
  -- python~3.13 is the same language but a different reference: picking 3.14 means 3.14
  eq(vim.tbl_contains(languages.pulled_in({ "python~3.14" }, installed, links), "python~3.13"), false)
end)

test("selecting only a package pulls in nothing", function()
  eq(languages.pulled_in({ "numpy~2.5" }, installed, links), {})
end)

test("a tool pulls in nothing, and is never pulled in", function()
  eq(languages.pulled_in({ "git", "c" }, installed, links), {})
end)

test("sources already selected are not repeated", function()
  eq(languages.pulled_in({ "python~3.14", "numpy~2.5" }, installed, links), { "scikit_learn" })
end)

test("two languages pull in both sets, sorted", function()
  eq(languages.pulled_in({ "lua~5.4", "python~3.14" }, installed, links), { "love", "numpy~2.5", "scikit_learn" })
end)

test("Unknown lists installed docsets with no link", function()
  eq(languages.unknown({ "zzz", "numpy~2.5", "aaa" }, { ["numpy~2.5"] = links["numpy~2.5"] }), { "aaa", "zzz" })
end)

-- the user's language list ---------------------------------------------------------

local function reset()
  languages.configure({})
end

test("the default list is offered when setup() says nothing", function()
  reset()
  eq(languages.list(), languages.defaults)
end)

test("add extends the defaults, in canonical spelling, without repeats", function()
  languages.configure({ add = { "haskell", "Lua", "python" } })
  local list = languages.list()
  eq({ list[#list - 1], list[#list] }, { "Haskell", "Lua" })
  eq(#list, #languages.defaults + 2)
  reset()
end)

test("only replaces the defaults", function()
  languages.configure({ only = { "Lua", "c++" } })
  eq(languages.list(), { "Lua", "C++" })
  reset()
end)

test("a name Linguist does not know is refused and the list kept", function()
  for _, bad in ipairs({ { add = { "Klingon" } }, { only = "Lua" }, { add = {}, only = {} }, { extra = {} }, "Lua" }) do
    eq(pcall(languages.configure, bad), false)
    eq(languages.list(), languages.defaults)
  end
end)

-- resolving a docset's language ------------------------------------------------------

test("a docset named after a listed language is that language", function()
  eq(languages.guess("python~3.15"), { kind = "language", language = "Python" })
  eq(languages.guess("cpp"), { kind = "language", language = "C++" })
end)

test("the whole family name must match, not a prefix", function()
  eq(languages.guess("d3~7"), nil)
  eq(languages.guess("go_cobra"), nil)
end)

test("only languages in the user's list are guessed", function()
  eq(languages.guess("haskell~9"), nil)
  languages.configure({ add = { "Haskell" } })
  eq(languages.guess("haskell~9"), { kind = "language", language = "Haskell" })
  reset()
end)

test("for devdocs the shipped table wins over the name rule", function()
  -- the table says bash is Shell; Shell is not in the default list, and the rule would not match anyway
  eq(languages.resolve("bash", { devdocs = true }), { kind = "language", language = "Shell" })
  eq(languages.resolve("git", { devdocs = true }), { kind = "tool" })
end)

test("a family missing from the table falls back to the name rule", function()
  eq(languages.resolve("typst~0.14", { devdocs = true }), { kind = "language", language = "Typst" })
  eq(languages.resolve("brand_new~1", { devdocs = true }), nil)
end)

test("a declared language is a package unless the docset is named after it", function()
  eq(languages.resolve("text~2.1~~hackage.haskell.org", { declared = "Haskell" }), { kind = "package", language = "Haskell" })
  eq(languages.resolve("haskell~9~~example.org", { declared = "Haskell" }), { kind = "language", language = "Haskell" })
end)

test("an assignment must name a listed language", function()
  eq(languages.for_assignment("pycairo", "python"), { kind = "package", language = "Python" })
  eq(languages.for_assignment("golang", "Go"), { kind = "language", language = "Go" })
  eq({ languages.for_assignment("pycairo", "Haskell") }, { nil, '"Haskell" is not in the configured language list' })
end)

test("labels read Unknown, Tool or the language", function()
  eq({ languages.label(nil), languages.label({ kind = "tool" }), languages.label({ kind = "package", language = "Go" }) },
    { "Unknown", "Tool", "Go" })
end)

test("every default language is a Linguist language", function()
  for _, name in ipairs(languages.defaults) do
    eq(languages.canonical(name), name)
  end
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
