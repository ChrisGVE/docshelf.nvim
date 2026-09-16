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

local function reset()
  languages.configure({})
end

local table_ = {
  python = { language = "Python" },
  numpy = { language = "Python" },
  git = { language = "Git" },
}

-- lookup -----------------------------------------------------------------------

test("a versioned slug is looked up by its family", function()
  eq(languages.of("python~3.14", table_), "Python")
end)

test("a folder from another origin is looked up by its docset family", function()
  eq(languages.of("numpy~2.5~~docs.scipy.org", table_), "Python")
end)

test("an unversioned folder from another origin is looked up by its name", function()
  eq(languages.of("git~~git-scm.com", table_), "Git")
end)

test("a language pulls in its packages from any origin", function()
  local folders = { "python~3.14", "numpy~2.5~~docs.scipy.org", "git" }
  local by_folder = {}
  for _, folder in ipairs(folders) do
    by_folder[folder] = languages.link(folder, languages.of(folder, table_))
  end
  eq(languages.pulled_in({ "python~3.14" }, folders, by_folder), { "numpy~2.5~~docs.scipy.org" })
end)

test("an unversioned slug is its own family", function()
  eq(languages.of("numpy", table_), "Python")
end)

test("a family missing from the table is unlinked", function()
  eq(languages.of("brand_new~1", table_), nil)
end)

test("the shipped table is used by default", function()
  eq(languages.of("scikit_learn"), "Python")
end)

-- reference or not ------------------------------------------------------------------

test("a docset named after its language is the reference", function()
  eq(languages.kind("python~3.14", "Python"), "language")
  eq(languages.kind("numpy~2.5", "Python"), "package")
end)

test("an alias names the reference too", function()
  eq(languages.kind("openjdk~21", "Java"), "language")
  eq(languages.kind("gnu_make~4", "Make"), "language")
end)

test("each SQL engine is its own name, so none is a package of SQL", function()
  eq(languages.kind("postgresql~17", "PostgreSQL"), "language")
  eq(languages.kind("sqlite", "SQLite"), "language")
  eq(languages.of("postgresql~17"), "PostgreSQL")
  eq(languages.of("mariadb"), "MariaDB")
  eq(languages.find("postgres"), "PostgreSQL")
end)

test("LaTeX and TeX are distinct names, neither an alias of the other", function()
  eq(languages.of("latex"), "LaTeX")
  eq(languages.kind("latex", "LaTeX"), "language")
  eq(languages.find("latex"), "LaTeX")
  eq(languages.find("tex"), "TeX")
end)

test("shipped aliases apply to a language not in the user's list", function()
  eq(languages.kind("gnu_fortran~14", "Fortran"), "language")
end)

test("names compare ignoring case, spaces and punctuation", function()
  eq(languages.kind("gnu_make~4", "GNU Make"), "language")
  eq(languages.kind("apache_http_server", "Apache HTTP Server"), "language")
end)

test("a tool is its own language", function()
  eq(languages.resolve("git", { devdocs = true }), { kind = "language", language = "Git" })
end)

-- pulled in -----------------------------------------------------------------------

local installed = {
  "c",
  "git",
  "git_cheatsheet",
  "lua~5.1",
  "lua~5.4",
  "love",
  "numpy~2.5",
  "python~3.13",
  "python~3.14",
  "scikit_learn",
}
local links = {
  c = languages.link("c", "C"),
  git = languages.link("git", "Git"),
  git_cheatsheet = languages.link("git_cheatsheet", "Git"),
  ["lua~5.1"] = languages.link("lua~5.1", "Lua"),
  ["lua~5.4"] = languages.link("lua~5.4", "Lua"),
  love = languages.link("love", "Lua"),
  ["numpy~2.5"] = languages.link("numpy~2.5", "Python"),
  ["python~3.13"] = languages.link("python~3.13", "Python"),
  ["python~3.14"] = languages.link("python~3.14", "Python"),
  scikit_learn = languages.link("scikit_learn", "Python"),
}

test("selecting a reference pulls in the rest of its language", function()
  eq(languages.pulled_in({ "python~3.14" }, installed, links), { "numpy~2.5", "scikit_learn" })
end)

test("other versions of the reference are not pulled in", function()
  eq(vim.tbl_contains(languages.pulled_in({ "python~3.14" }, installed, links), "python~3.13"), false)
end)

test("selecting anything else pulls in nothing", function()
  eq(languages.pulled_in({ "numpy~2.5" }, installed, links), {})
  eq(languages.pulled_in({ "git_cheatsheet" }, installed, links), {})
end)

test("a tool's reference pulls in the tool's other docsets", function()
  eq(languages.pulled_in({ "git" }, installed, links), { "git_cheatsheet" })
end)

test("sources already selected are not repeated", function()
  eq(languages.pulled_in({ "python~3.14", "numpy~2.5" }, installed, links), { "scikit_learn" })
end)

test("two references pull in both sets, sorted", function()
  eq(languages.pulled_in({ "lua~5.4", "python~3.14" }, installed, links), { "love", "numpy~2.5", "scikit_learn" })
end)

test("Unknown lists installed docsets with no link", function()
  eq(languages.unknown({ "zzz", "numpy~2.5", "aaa" }, { ["numpy~2.5"] = links["numpy~2.5"] }), { "aaa", "zzz" })
end)

-- the user's lists ---------------------------------------------------------------

test("the defaults are languages, then formats, then tools, in one list", function()
  reset()
  local list = languages.list()
  eq(list[1], "Python")
  eq(vim.tbl_contains(list, "C#"), true)
  eq(vim.tbl_contains(list, "YAML"), true)
  eq(list[#list], "SSH")
  eq(#list, #languages.defaults.languages + #languages.defaults.formats + #languages.defaults.tools)
end)

test("add extends a list, in the shipped spelling, without repeats", function()
  languages.configure({ languages = { add = { "haskell", "python" } }, tools = { add = { "Kubectl" } } })
  local list = languages.list()
  eq(vim.tbl_contains(list, "Haskell") or vim.tbl_contains(list, "haskell"), true)
  eq(#vim.tbl_filter(function(n)
    return n == "Python"
  end, list), 1)
  eq(list[#list], "Kubectl")
  reset()
end)

test("only replaces one list and leaves the others", function()
  languages.configure({ languages = { only = { "Lua", "c++" } } })
  local list = languages.list()
  eq({ list[1], list[2], list[3] }, { "Lua", "C++", "Markdown" })
  reset()
end)

test("any name is accepted, with its own aliases", function()
  languages.configure({ tools = { add = { { "Kubernetes", aliases = { "k8s" } } } } })
  eq(languages.find("K8S"), "Kubernetes")
  eq(languages.guess("k8s~1.30"), { kind = "language", language = "Kubernetes" })
  reset()
end)

test("user aliases add to the shipped ones", function()
  languages.configure({ languages = { add = { { "python", aliases = { "py3k" } } } } })
  eq(languages.find("py"), "Python")
  eq(languages.find("py3k"), "Python")
  reset()
end)

test("aliases find their entry", function()
  eq(
    { languages.find("ts"), languages.find("GH"), languages.find("rg"), languages.find("jj") },
    { "TypeScript", "GitHub", "ripgrep", "Jujutsu" }
  )
  eq(languages.find("klingon"), nil)
end)

test("a bad option is refused and the lists kept", function()
  reset()
  local before = languages.list()
  for _, bad in ipairs({
    { languages = { add = { 42 } } },
    { languages = { only = "Lua" } },
    { languages = { add = {}, only = {} } },
    { languages = { extra = {} } },
    { tools = { add = { { "X", aliases = "x" } } } },
    { tools = { add = { { "Pythonic", aliases = { "py" } } } } }, -- py already names Python
    "Lua",
  }) do
    eq(pcall(languages.configure, bad), false)
    eq(languages.list(), before)
  end
end)

-- resolving a docset's language ------------------------------------------------------

test("a docset named after a listed entry is that entry", function()
  eq(languages.guess("python~3.15"), { kind = "language", language = "Python" })
  eq(languages.guess("cpp"), { kind = "language", language = "C++" })
  eq(languages.guess("jj"), { kind = "language", language = "Jujutsu" })
end)

test("the whole family name must match, not a prefix", function()
  eq(languages.guess("d3~7"), nil)
  eq(languages.guess("go_cobra"), nil)
end)

test("only entries in the user's list are guessed", function()
  eq(languages.guess("fortran"), nil)
  languages.configure({ languages = { add = { "Fortran" } } })
  eq(languages.guess("fortran"), { kind = "language", language = "Fortran" })
  eq(languages.guess("gnu_fortran~14"), { kind = "language", language = "Fortran" })
  reset()
end)

test("for devdocs the shipped table wins over the name rule", function()
  eq(languages.resolve("bash", { devdocs = true }), { kind = "language", language = "Bash" })
  eq(languages.resolve("node~22", { devdocs = true }), { kind = "package", language = "JavaScript" })
end)

test("a family missing from the table falls back to the name rule", function()
  eq(languages.resolve("typst~0.14", { devdocs = true }), { kind = "language", language = "Typst" })
  eq(languages.resolve("brand_new~1", { devdocs = true }), nil)
end)

test("a declared language is a package unless the docset is named after it", function()
  eq(
    languages.resolve("text~2.1~~hackage.haskell.org", { declared = "Haskell" }),
    { kind = "package", language = "Haskell" }
  )
  eq(languages.resolve("haskell~9~~example.org", { declared = "Haskell" }), { kind = "language", language = "Haskell" })
end)

test("an assignment records a listed entry in its listed spelling", function()
  eq(languages.for_assignment("pycairo", "python"), { kind = "package", language = "Python" })
  eq(languages.for_assignment("golang", "Go"), { kind = "language", language = "Go" })
  eq(languages.for_assignment("git_cheatsheet", "git"), { kind = "package", language = "Git" })
end)

test("a name no list knows is taken as typed", function()
  eq(languages.for_assignment("swi_prolog", "Prolog"), { kind = "package", language = "Prolog" })
  eq(languages.for_assignment("prolog~9", "Prolog"), { kind = "language", language = "Prolog" })
  eq({ languages.for_assignment("pycairo", "  ") }, { nil, '"  " is not a name' })
end)

test("labels read Unknown or the language", function()
  eq({ languages.label(nil), languages.label({ kind = "language", language = "Git" }) }, { "Unknown", "Git" })
end)

-- the shipped data ------------------------------------------------------------------

test("every shipped default resolves to itself", function()
  for _, what in ipairs({ "languages", "formats", "tools" }) do
    for _, name in ipairs(languages.defaults[what]) do
      eq(languages.find(name), name)
    end
  end
end)

if failures > 0 then
  print(failures .. " failure(s)")
  os.exit(1)
end
print("all passed")
