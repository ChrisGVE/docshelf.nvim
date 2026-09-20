-- Tests for lua/apidocs/filter.lua.
-- Run from the repository root: nvim --headless -l tests/filter_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local filter = require("apidocs.filter")

local failures = 0
local function test(name, fn)
  filter.clear()
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

-- A stand-in for the install manifest's language links. `kind = "language"` is a
-- language's own reference (python~3.14), `kind = "package"` something written in
-- it (numpy) -- which is what a selected reference pulls in.
local links = {
  ["python~3.14"] = { language = "Python", kind = "language" },
  ["python~3.13"] = { language = "Python", kind = "language" },
  ["numpy~2.5"] = { language = "Python", kind = "package" },
  ["scikit_learn"] = { language = "Python", kind = "package" },
  ["rust"] = { language = "Rust", kind = "language" },
  ["tokio"] = { language = "Rust", kind = "package" },
  ["haskell~9"] = { language = "Haskell", kind = "language" },
  ["mystery"] = { language = nil, kind = nil },
}

local installed = {
  "haskell~9",
  "mystery",
  "numpy~2.5",
  "python~3.13",
  "python~3.14",
  "rust",
  "scikit_learn",
  "tokio",
}

-- the active filter ----------------------------------------------------------

test("no filter is set to begin with", function()
  eq(filter.active(), nil)
end)

test("setting a filter sorts it and keeps it", function()
  filter.set({ "rust", "numpy~2.5" })
  eq(filter.active(), { "numpy~2.5", "rust" })
end)

test("clearing gives every source back", function()
  filter.set({ "rust" })
  filter.clear()
  eq(filter.active(), nil)
end)

test("setting an empty list clears rather than filtering to nothing", function()
  filter.set({})
  eq(filter.active(), nil)
end)

-- widening through a language ------------------------------------------------

test("a language reference pulls in the packages of its language", function()
  eq(filter.widen({ "python~3.14" }, installed, links), { "numpy~2.5", "python~3.14", "scikit_learn" })
end)

test("another version of the same language is not pulled in", function()
  local widened = filter.widen({ "python~3.14" }, installed, links)
  eq(vim.tbl_contains(widened, "python~3.13"), false)
end)

test("a package selected alone stays alone", function()
  eq(filter.widen({ "numpy~2.5" }, installed, links), { "numpy~2.5" })
end)

test("two languages each bring their own", function()
  eq(filter.widen({ "python~3.14", "rust" }, installed, links), {
    "numpy~2.5",
    "python~3.14",
    "rust",
    "scikit_learn",
    "tokio",
  })
end)

test("a language with nothing written in it brings nothing", function()
  eq(filter.widen({ "haskell~9" }, installed, links), { "haskell~9" })
end)

-- the languages a filter covers ----------------------------------------------

test("the languages of a filter are the set its docsets name", function()
  eq(filter.languages_of({ "numpy~2.5", "rust" }, links), { Python = true, Rust = true })
end)

test("a docset with no language contributes none", function()
  eq(filter.languages_of({ "mystery" }, links), nil)
end)

test("no filter covers no particular language", function()
  eq(filter.languages_of(nil, links), nil)
end)

-- resolving a filter into restrict_sources -----------------------------------

test("with no filter set, options are left alone", function()
  eq(filter.restrict({}, installed, links), {})
end)

test("a filter becomes restrict_sources, widened", function()
  filter.set({ "python~3.14" })
  eq(filter.restrict({}, installed, links).restrict_sources, { "numpy~2.5", "python~3.14", "scikit_learn" })
end)

test("follow_filter = false ignores the filter without clearing it", function()
  filter.set({ "python~3.14" })
  eq(filter.restrict({ follow_filter = false }, installed, links).restrict_sources, nil)
  eq(filter.active(), { "python~3.14" })
end)

test("an explicit restrict_sources wins over the filter", function()
  filter.set({ "python~3.14" })
  eq(filter.restrict({ restrict_sources = { "rust" } }, installed, links).restrict_sources, { "rust" })
end)

test("restrict never mutates the options it was given", function()
  filter.set({ "rust" })
  local opts = {}
  filter.restrict(opts, installed, links)
  eq(opts, {})
end)

test("restrict works when given no options at all", function()
  filter.set({ "rust" })
  eq(filter.restrict(nil, installed, links).restrict_sources, { "rust", "tokio" })
end)

-- uninstalling out of the filter ---------------------------------------------

test("an uninstalled source leaves the filter", function()
  filter.set({ "rust", "numpy~2.5" })
  filter.forget({ "rust" })
  eq(filter.active(), { "numpy~2.5" })
end)

test("uninstalling the last of them clears the filter", function()
  filter.set({ "rust" })
  filter.forget({ "rust" })
  eq(filter.active(), nil)
end)

test("forgetting something that was never in the filter changes nothing", function()
  filter.set({ "rust" })
  filter.forget({ "numpy~2.5" })
  eq(filter.active(), { "rust" })
end)

test("forgetting with no filter set is harmless", function()
  filter.forget({ "rust" })
  eq(filter.active(), nil)
end)

if failures > 0 then
  print(failures .. " failure(s)")
  os.exit(1)
end
print("all passed")
