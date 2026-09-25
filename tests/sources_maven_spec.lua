-- Tests for lua/docshelf/sources/maven.lua, offline: a fake command runner
-- answers the Maven Central requests and serves a folder of
-- tests/fixtures/maven as the artifact's javadoc jar. Each folder is one
-- generator's output, trimmed from a real jar:
--   javadoc    javadoc from JDK 11 on (*-search-index.js), guava's layout
--   javadoc8   javadoc before JDK 9 (index-all.html only), jackson's layout
--   scaladoc3  Scala 3 scaladoc (scripts/searchData.js), cats-core_3's layout
--   scaladoc2  Scala 2 scaladoc (index.js), cats-core_2.13's layout
--   dokka      Kotlin's Dokka (scripts/pages.json), ktor's layout
--   empty      the placeholder jar many Kotlin libraries publish
-- The artifact id names the fixture: demo artifacts are named after them.
-- Run from the repository root: nvim --headless -l tests/sources_maven_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local maven = require("docshelf.sources.maven")

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

local function has(text, part)
  if not text:find(part, 1, true) then
    error("expected to find " .. vim.inspect(part) .. " in:\n" .. text, 2)
  end
end

local function lacks(text, part)
  if text:find(part, 1, true) then
    error("expected no " .. vim.inspect(part) .. " in:\n" .. text, 2)
  end
end

local fixtures = vim.fn.fnamemodify("tests/fixtures/maven", ":p")

local function metadata(release)
  return '<?xml version="1.0" encoding="UTF-8"?>\n<metadata>\n  <groupId>com.example</groupId>\n'
    .. "  <versioning>\n    <latest>"
    .. release
    .. "</latest>\n    <release>"
    .. release
    .. "</release>\n  </versioning>\n</metadata>\n"
end

-- Answers like central.sonatype.com and repo1.maven.org. `releases` maps
-- "group:artifact" to its newest release; `found` is what a search answers.
-- A javadoc jar is a file naming its fixture, which the fake unzip copies.
local function central(releases, found)
  local seen = {}
  return function(cmd)
    seen[#seen + 1] = cmd
    if cmd[1] == "unzip" then
      local jar, into = cmd[3 + 1], cmd[#cmd]
      local file = assert(io.open(jar))
      local folder = file:read("*a")
      file:close()
      vim.fn.mkdir(into, "p")
      return vim.system({ "cp", "-R", fixtures .. folder .. "/.", into }):wait()
    end
    if cmd[1] ~= "curl" then
      return vim.system(cmd):wait()
    end
    local url = cmd[#cmd]
    if url:match("^https://central%.sonatype%.com/solrsearch/select%?") then
      return { code = 0, stdout = vim.json.encode({ response = { numFound = #(found or {}), docs = found or {} } }) }
    end
    local path, artifact = url:match("^https://repo1%.maven%.org/maven2/(.+)/([^/]+)/maven%-metadata%.xml$")
    if path then
      local release = releases[path:gsub("/", ".") .. ":" .. artifact]
      if not release then
        return { code = 22, stdout = "" }
      end
      return { code = 0, stdout = metadata(release) }
    end
    local jar_artifact = url:match("/([^/]+)/[^/]+/[^/]+%-javadoc%.jar$")
    if jar_artifact then
      if vim.fn.isdirectory(fixtures .. jar_artifact) == 0 then
        return { code = 22, stdout = "" }
      end
      local out = cmd[vim.fn.index(cmd, "-o") + 2]
      local file = assert(io.open(out, "w"))
      file:write(jar_artifact)
      file:close()
      return { code = 0, stdout = "" }
    end
    error("unexpected request " .. url)
  end,
    seen
end

local function set_of(entries)
  local set = {}
  for _, entry in ipairs(entries) do
    set[entry.name] = { entry.path, entry.type }
  end
  return set
end

local function keys(db)
  local found = vim.tbl_keys(db)
  table.sort(found)
  return found
end

test("the source says who it is and which languages it may document", function()
  eq(maven.origin, "central.sonatype.com")
  eq(maven.languages, { "Java", "Kotlin", "Scala" })
end)

test("search lists the artifacts with a javadoc jar, named artifact@group", function()
  local system, seen = central({}, {
    {
      g = "org.typelevel",
      a = "cats-core_3",
      latestVersion = "2.13.0",
      ec = { "-sources.jar", ".pom", "-javadoc.jar", ".jar" },
    },
    { g = "org.typelevel", a = "cats-core_0.27", latestVersion = "2.3.0-M2", ec = {} },
    { g = "io.spinnaker.clouddriver", a = "cats-core", latestVersion = "2026.3.1", ec = { "-javadoc.jar" } },
  })
  eq(maven.search("cats core&x", system), {
    { name = "cats-core_3@org.typelevel", version = "2.13.0" },
    { name = "cats-core@io.spinnaker.clouddriver", version = "2026.3.1" },
  })
  has(seen[1][#seen[1]], "q=cats%20core%26x")
end)

test("resolve names the docset after the newest release Maven Central lists", function()
  local system = central({ ["com.example:javadoc"] = "1.2.0" })
  eq(maven.resolve("javadoc@com.example", system), "javadoc@com.example~1.2.0")
end)

test("resolve refuses a name that is not artifact@group", function()
  local ok, err = pcall(maven.resolve, "javadoc", central({}))
  eq(ok, false)
  has(err, "artifact@group")
end)

test("resolve says so when Maven Central has no such artifact", function()
  local ok, err = pcall(maven.resolve, "nothing@com.example", central({}))
  eq(ok, false)
  has(err, "nothing@com.example")
end)

test("release and latest follow the docset's name", function()
  eq(maven.release("cats-core_3@org.typelevel~2.13.0"), "2.13.0")
  eq(maven.latest("javadoc@com.example~1.0", central({ ["com.example:javadoc"] = "1.1" })), "javadoc@com.example~1.1")
end)

test("javadoc: packages, types and members, each on its own anchor", function()
  local system = central({})
  local docset = "javadoc@com.example~1.0"
  eq(set_of(maven.index(docset, nil, system).entries), {
    ["com.example"] = { "com/example/package-summary", "Packages" },
    ["com.example.Box"] = { "com/example/Box", "Types" },
    ["com.example.Box.Builder"] = { "com/example/Box.Builder", "Types" },
    ["Box.Box()"] = { "com/example/Box#-init---", "Constructors" },
    ["Box.of(T)"] = { "com/example/Box#of-T-", "Methods" },
    ["Box.EMPTY"] = { "com/example/Box#EMPTY", "Fields" },
    ["Box.Builder.build()"] = { "com/example/Box.Builder#build--", "Methods" },
  })
  eq(maven.language_of(docset), "Java")
  local db = maven.db(docset, nil, system)
  -- only the pages the index names: no "uses of", no class lists
  eq(keys(db), { "com/example/Box", "com/example/Box.Builder", "com/example/package-summary" })
  local box = db["com/example/Box"]
  has(box, '<h4 id="of-T-">Box.of(T)</h4><section class="detail">')
  has(box, '<h4 id="-init---">Box.Box()</h4>')
  lacks(box, 'id="of(T)"')
  lacks(box, "<footer")
  lacks(box, "Skip navigation")
  lacks(box, "<script")
  has(box, 'href="Box.Builder#build--"')
  has(box, 'href="#EMPTY"')
  has(box, 'href="https://javadoc.io/doc/com.example/javadoc/1.0/com/example/class-use/Box.html"')
  has(box, 'href="https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/lang/Object.html"')
  has(db["com/example/Box.Builder"], 'href="Box#of-T-"')
end)

test("javadoc before JDK 9: the entries come from index-all.html", function()
  local system = central({})
  local docset = "javadoc8@com.example~1.0"
  eq(set_of(maven.index(docset, nil, system).entries), {
    ["com.example"] = { "com/example/package-summary", "Packages" },
    ["com.example.Box"] = { "com/example/Box", "Classes" },
    ["Box.Box()"] = { "com/example/Box#Box--", "Constructors" },
    ["Box.EMPTY"] = { "com/example/Box#EMPTY", "Fields" },
    ["Box.read(File, Class<T>)"] = { "com/example/Box#read-java.io.File-java.lang.Class-", "Methods" },
  })
  eq(maven.language_of(docset), "Java")
  local db = maven.db(docset, nil, system)
  eq(keys(db), { "com/example/Box", "com/example/package-summary" })
  local box = db["com/example/Box"]
  has(box, '<h4 id="read-java.io.File-java.lang.Class-">Box.read(File, Class&lt;T&gt;)</h4>')
  lacks(box, 'name="read-java.io.File-java.lang.Class-"')
  lacks(box, "navbar")
  has(box, 'href="Box#read-java.io.File-java.lang.Class-"')
  has(db["com/example/package-summary"], 'href="Box"')
end)

test("scaladoc 3: the entries come from scripts/searchData.js", function()
  local system = central({})
  local docset = "scaladoc3@com.example~1.0"
  eq(set_of(maven.index(docset, nil, system).entries), {
    ["Demo core"] = { "index", "Guides" },
    ["demo"] = { "demo", "Packages" },
    ["demo.Box"] = { "demo/Box", "Traits" },
    ["Box.as"] = { "demo/Box#as-fffffeeb", "Methods" },
    ["Box.:<:"] = { "demo/Box#----0", "Types" },
  })
  eq(maven.language_of(docset), "Scala")
  local db = maven.db(docset, nil, system)
  eq(keys(db), { "demo", "demo/Box", "index" })
  local box = db["demo/Box"]
  has(box, '<h4 id="as-fffffeeb">Box.as</h4><div class="documentableElement">')
  has(box, '<h4 id="----0">Box.:&lt;:</h4>')
  lacks(box, "leftColumn")
  lacks(box, "toc-nav")
  lacks(box, "<button")
  has(box, 'href="Box#----0"')
  has(box, 'href="Box#as-fffffeeb"')
end)

test("scaladoc 2: the entries come from index.js, packages from their pages", function()
  local system = central({})
  local docset = "scaladoc2@com.example~1.0"
  eq(set_of(maven.index(docset, nil, system).entries), {
    ["demo"] = { "demo/index", "Packages" },
    ["demo.Box"] = { "demo/Box", "Traits" },
    ["Box.as"] = { "demo/Box#as-A-B--fa-F-A--b-B--F-B-", "Methods" },
    ["Box.size"] = { "demo/Box#size-Int", "Values" },
  })
  eq(maven.language_of(docset), "Scala")
  local db = maven.db(docset, nil, system)
  eq(keys(db), { "demo/Box", "demo/index" })
  local box = db["demo/Box"]
  has(box, '<h4 id="as-A-B--fa-F-A--b-B--F-B-">Box.as</h4>')
  -- the other anchor of the same member is kept, made plain
  has(box, 'id="as-A-B--F-A--B--F-B-"')
  lacks(box, '<div id="packages"')
  has(box, 'href="Box#size-Int"')
end)

test("dokka: the entries come from scripts/pages.json, a page per declaration", function()
  local system = central({})
  local docset = "dokka@com.example~1.0"
  eq(set_of(maven.index(docset, nil, system).entries), {
    ["com.example.Box"] = { "lib/com.example/-box/index", "Classes" },
    ["Box.get"] = { "lib/com.example/-box/get", "Functions" },
    ["com.example.Box.EMPTY"] = { "lib/com.example/-box/-e-m-p-t-y/index", "Declarations" },
  })
  eq(maven.language_of(docset), "Kotlin")
  local db = maven.db(docset, nil, system)
  eq(keys(db), { "lib/com.example/-box/-e-m-p-t-y/index", "lib/com.example/-box/get", "lib/com.example/-box/index" })
  local get = db["lib/com.example/-box/get"]
  has(get, 'href="-e-m-p-t-y/index"')
  has(get, 'href="index"')
  lacks(db["lib/com.example/-box/index"], "Generated by dokka")
  lacks(db["lib/com.example/-box/index"], "navigation-wrapper")
end)

test("a jar with no documentation in it is refused", function()
  local ok, err = pcall(maven.index, "empty@com.example~1.0", nil, central({}))
  eq(ok, false)
  has(err, "empty@com.example 1.0")
end)

test("an artifact without a javadoc jar is refused", function()
  local ok, err = pcall(maven.index, "absent@com.example~1.0", nil, central({}))
  eq(ok, false)
  has(err, "absent@com.example 1.0")
end)

if failures > 0 then
  print(failures .. " failure(s)")
  os.exit(1)
end
print("all passed")
