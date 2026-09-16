-- Tests for lua/apidocs/source_drift.lua, and for the shape of the real
-- source_languages.lua table.
-- Run from the repository root: nvim --headless -l tests/source_drift_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local drift = require("apidocs.source_drift")

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

local catalogue = {
  { name = "Python", slug = "python~3.14", links = { code = "https://github.com/python/cpython" } },
  { name = "Python", slug = "python~3.13", links = { code = "https://github.com/python/cpython" } },
  { name = "NumPy", slug = "numpy~2.5", links = { code = "https://github.com/numpy/numpy" } },
  { name = "Git", slug = "git", links = {} },
  { name = "Zig", slug = "zig" },
}

local table_ = {
  python = { kind = "language", language = "Python" },
  git = { kind = "tool" },
  scala = { kind = "language", language = "Scala" },
}

-- families ---------------------------------------------------------------------

test("versions of one source collapse into one family", function()
  local families = drift.families(catalogue)
  eq(families.python, { name = "Python", code = "https://github.com/python/cpython" })
end)

test("a source without a code link still has a family", function()
  local families = drift.families(catalogue)
  eq(families.git, { name = "Git" })
  eq(families.zig, { name = "Zig" })
end)

-- check ------------------------------------------------------------------------

test("families missing from the table are reported, sorted", function()
  eq(drift.check(catalogue, table_).missing, {
    { family = "numpy", name = "NumPy", code = "https://github.com/numpy/numpy" },
    { family = "zig", name = "Zig" },
  })
end)

test("rows whose family left the catalogue are reported", function()
  eq(drift.check(catalogue, table_).gone, { "scala" })
end)

test("a table matching the catalogue reports nothing", function()
  local full = vim.tbl_extend("force", table_, {
    numpy = { kind = "package", language = "Python" },
    zig = { kind = "language", language = "Zig" },
  })
  full.scala = nil
  eq(drift.check(catalogue, full), { missing = {}, gone = {} })
end)

-- github_repo ------------------------------------------------------------------

test("a GitHub code link yields owner/repo", function()
  eq(drift.github_repo("https://github.com/python/cpython"), "python/cpython")
  eq(drift.github_repo("https://github.com/numpy/numpy/"), "numpy/numpy")
  eq(drift.github_repo("https://github.com/rust-lang/rust.git"), "rust-lang/rust")
end)

test("a non-GitHub or absent link yields nothing", function()
  eq(drift.github_repo("https://gitlab.com/a/b"), nil)
  eq(drift.github_repo(nil), nil)
end)

-- proposal ---------------------------------------------------------------------

test("a proposal names the repository language and says it is unchecked", function()
  eq(
    drift.proposal({ family = "numpy", name = "NumPy" }, "Python"),
    '  ["numpy"] = { kind = "package", language = "Python" }, -- NumPy -- PROPOSED from repo language, check kind and language'
  )
end)

test("a proposal without a repository language is a tool placeholder", function()
  eq(
    drift.proposal({ family = "zig", name = "Zig" }, nil),
    '  ["zig"] = { kind = "tool", language = nil }, -- Zig -- PROPOSED, no repo language found, classify by hand'
  )
end)

-- row_errors -------------------------------------------------------------------

local linguist = { Python = {}, Lua = {} }

test("well-formed rows have no errors", function()
  eq(
    drift.row_errors({
      python = { kind = "language", language = "Python" },
      love = { kind = "package", language = "Lua" },
      git = { kind = "tool" },
    }, linguist),
    {}
  )
end)

test("malformed rows are each reported once, sorted by family", function()
  eq(
    drift.row_errors({
      a = { kind = "librery", language = "Python" },
      b = { kind = "package", language = "Pyhton" },
      c = { kind = "language" },
      d = { kind = "tool", language = "Lua" },
    }, linguist),
    {
      'a: kind "librery" is not language, package or tool',
      'b: language "Pyhton" is not a Linguist language',
      "c: a language row needs a language",
      "d: a tool row must not name a language",
    }
  )
end)

-- the real table ---------------------------------------------------------------

test("every row of source_languages.lua is well formed", function()
  eq(drift.row_errors(require("apidocs.source_languages"), require("apidocs.linguist_languages")), {})
end)

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
