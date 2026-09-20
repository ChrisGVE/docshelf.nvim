-- Tests for lua/apidocs/sources/docc.lua and lua/apidocs/docc_render.lua,
-- offline: a fake command runner serves tests/fixtures/docc/site as a DocC
-- site, so the whole path -- the layout probe, the navigator index, the page
-- list, the render-JSON to HTML conversion and the link rewriting -- runs for
-- real against a site that is only on disk.
--
-- The same fixture is served under both layouts, because both exist in the
-- wild: developer.apple.com keeps its JSON under /tutorials/data, and a site
-- built by `docc convert` keeps it under /data.
--
-- Run from the repository root: nvim --headless -l tests/sources_docc_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local docc = require("apidocs.sources.docc")
local render = require("apidocs.docc_render")

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

local function has(haystack, needle)
  if not tostring(haystack):find(needle, 1, true) then
    error("expected to find " .. vim.inspect(needle) .. " in " .. vim.inspect(haystack), 2)
  end
end

local function has_not(haystack, needle)
  if tostring(haystack):find(needle, 1, true) then
    error("expected NOT to find " .. vim.inspect(needle) .. " in " .. vim.inspect(haystack), 2)
  end
end

local fixtures = vim.fn.fnamemodify("tests/fixtures/docc/site", ":p"):gsub("/$", "")

-- The install remembers which site a docset came from beside the installed
-- docsets, so the specs point the data folder at a scratch directory.
local scratch = vim.fn.tempname()
vim.fn.mkdir(scratch, "p")
vim.env.XDG_DATA_HOME = scratch

-- Which fixture file answers which documentation path. "widget/wheel/radius"
-- is deliberately absent: the navigator index names it, the site does not
-- serve it, and an install must lose that one page rather than fail.
local files = {
  ["/documentation/widget"] = "widget.json",
  ["/documentation/widget/wheel"] = "wheel.json",
  ["/documentation/widget/wheel/spin()"] = "spin.json",
  ["/documentation/widget/getting-started"] = "getting-started.json",
}

local docc_site = "https://widget.example/docs"
local apple_site = "https://apple.example"

--- Answers like a DocC site. `layout` picks which of the two shapes it serves;
--- anything asked for under the other one 404s, which is what the adapter's
--- probe reads.
local function runner(opts)
  opts = opts or {}
  local layout = opts.layout or "docc"
  local seen = { urls = {} }
  local base = layout == "apple" and apple_site or docc_site
  local data = base .. (layout == "apple" and "/tutorials/data" or "/data")
  local index = layout == "apple" and (base .. "/tutorials/data/index/widget") or (base .. "/index/index.json")

  local function body(url)
    if url == index then
      return table.concat(vim.fn.readfile(fixtures .. "/index.json"), "\n")
    end
    if url:sub(1, #data) ~= data then
      return nil
    end
    local path = url:sub(#data + 1):gsub("%.json$", "")
    local file = files[path]
    if not file then
      return nil
    end
    return table.concat(vim.fn.readfile(fixtures .. "/" .. file), "\n")
  end

  local function serve(url, out)
    seen.urls[#seen.urls + 1] = url
    local text = body(url)
    if not text then
      return false
    end
    if out then
      vim.fn.mkdir(vim.fn.fnamemodify(out, ":h"), "p")
      vim.fn.writefile(vim.split(text, "\n"), out)
    end
    return true, text
  end

  local system = function(cmd, cmd_opts)
    if cmd[1] ~= "curl" then
      return vim.system(cmd, cmd_opts):wait()
    end
    if cmd[2] == "--help" then
      return { code = 0, stdout = opts.parallel and "--parallel-max <num>" or "", stderr = "" }
    end
    local config, out
    for i, arg in ipairs(cmd) do
      if arg == "-K" then
        config = cmd[i + 1]
      end
      if arg == "-o" then
        out = cmd[i + 1]
      end
    end
    if config then
      local url, ok = nil, true
      for _, line in ipairs(vim.fn.readfile(config)) do
        local value = line:match('"(.*)"')
        if line:match("^url") then
          url = value
        elseif line:match("^output") then
          ok = serve(url, value) and ok
        end
      end
      return { code = ok and 0 or 22, stdout = "", stderr = "" }
    end
    local found, text = serve(cmd[#cmd], out)
    if not found then
      return { code = 22, stdout = "", stderr = "404" }
    end
    return { code = 0, stdout = out and "" or text, stderr = "" }
  end
  return system, seen
end

-- ------------------------------------------------------------ the contract

test("the origin is docc", function()
  eq(docc.origin, "docc")
end)

test("the language every DocC site documents is Swift", function()
  eq(docc.language, "Swift")
  eq(docc.language_of("widget"), "Swift")
end)

test("a documentation URL is recognised, a package name is not", function()
  eq(docc.is_url("https://developer.apple.com/documentation/swiftui"), true)
  eq(docc.is_url("https://docs.swift.org/swift-book/documentation/the-swift-programming-language"), true)
  eq(docc.is_url("https://widget.example/docs/documentation/widget/wheel"), true)
  -- A site with no /documentation/ in it is another source's business.
  eq(docc.is_url("https://numpy.org/doc/stable"), false)
  eq(docc.is_url("swiftui"), false)
  eq(docc.is_url("https://widget.example/doc umentation/widget"), false)
end)

test("there is no registry to search", function()
  eq(docc.search, nil)
end)

-- ---------------------------------------------------------- reading the URL

test("a URL names the site it is on and the module it points into", function()
  local split = docc._internal.split_url
  eq(split("https://developer.apple.com/documentation/swiftui/text"), {
    base = "https://developer.apple.com",
    module = "swiftui",
  })
  eq(split("https://docs.swift.org/swift-book/documentation/the-swift-programming-language/"), {
    base = "https://docs.swift.org/swift-book",
    module = "the-swift-programming-language",
  })
  -- A query or a fragment is part of the browser's address, not of the page.
  eq(split("https://widget.example/docs/documentation/Widget?language=objc#overview").module, "widget")
end)

test("a URL with no module is refused, with a reason", function()
  local ok, err = pcall(docc._internal.split_url, "https://widget.example/docs/documentation/")
  eq(ok, false)
  has(err, "names no module")
end)

-- ------------------------------------------------------------- the index

test("a docset is every page of one module, the module's own page first", function()
  local index = vim.json.decode(table.concat(vim.fn.readfile(fixtures .. "/index.json"), "\n"))
  local pages = docc._internal.pages_of(docc._internal.language_tree(index), "widget")
  eq(
    vim.tbl_map(function(page)
      return page.key
    end, pages),
    {
      "widget",
      "widget/getting-started",
      "widget/wheel",
      "widget/wheel/spin()",
      "widget/wheel/radius",
    }
  )
end)

test("a page of another module is left out, however it is reached", function()
  local index = vim.json.decode(table.concat(vim.fn.readfile(fixtures .. "/index.json"), "\n"))
  local pages = docc._internal.pages_of(docc._internal.language_tree(index), "widget")
  for _, page in ipairs(pages) do
    has_not(page.key, "otherframework")
  end
end)

test("a name carries the type it belongs to, and a kind becomes a group", function()
  local index = vim.json.decode(table.concat(vim.fn.readfile(fixtures .. "/index.json"), "\n"))
  local by_key = {}
  for _, page in ipairs(docc._internal.pages_of(docc._internal.language_tree(index), "widget")) do
    by_key[page.key] = page
  end
  eq(by_key["widget/wheel/spin()"].name, "Wheel.spin()")
  eq(by_key["widget/wheel/spin()"].type, "Methods")
  eq(by_key["widget/wheel"].type, "Structures")
  -- The module is not written into its children's names: "Widget.Wheel" says
  -- nothing "Wheel" does not.
  eq(by_key["widget/wheel"].name, "Wheel")
  eq(by_key["widget/getting-started"].type, "Guides")
  -- A declaration title is shortened before the type is put in front of it.
  eq(by_key["widget/wheel/radius"].name, "Wheel.radius")
end)

test("a declaration becomes the name it declares, with its argument labels", function()
  local short_name = docc._internal.short_name
  -- Apple's navigator titles a symbol with its whole declaration, which is far
  -- more than a row wants; the labels come from the path, where DocC writes
  -- them.
  eq(
    short_name(
      "func generateToken(completionHandler: (Data?, (any Error)?) -> Void)",
      "/documentation/devicecheck/dcdevice/generatetoken(completionhandler:)"
    ),
    "generateToken(completionhandler:)"
  )
  eq(
    short_name("class var shared: DCAppAttestService", "/documentation/devicecheck/dcappattestservice/shared"),
    "shared"
  )
  eq(short_name("var isSupported: Bool", "/documentation/devicecheck/dcdevice/issupported"), "isSupported")
  eq(short_name("struct Wheel", "/documentation/widget/wheel"), "Wheel")
  -- "init" and "subscript" name themselves.
  eq(
    short_name("init<V>(value: Binding<V>, in: ClosedRange<V>)", "/documentation/swiftui/slider/init(value:in:)"),
    "init(value:in:)"
  )
  -- An article, a sample or a guide is prose, and prose is left alone.
  eq(short_name("Getting started", "/documentation/widget/getting-started"), "Getting started")
  eq(
    short_name("Landmarks: Displaying custom activity badges", "/documentation/swiftui/landmarks-badges"),
    "Landmarks: Displaying custom activity badges"
  )
end)

test("a name gives way before a page key does", function()
  local index = vim.json.decode(table.concat(vim.fn.readfile(fixtures .. "/index.json"), "\n"))
  local pages = docc._internal.pages_of(docc._internal.language_tree(index), "widget")
  for _, page in ipairs(pages) do
    -- The installer names a file "<name>#<key>.html.md", capped at 255. The
    -- key is unique and the name is not, so a name is what gets cut: a key cut
    -- short is two pages sharing one file.
    if #page.name + 1 + #page.key > 255 - 8 then
      error("the name of " .. page.key .. " would cut its key", 0)
    end
  end
  local long = docc._internal.pages_of({
    {
      title = ("x"):rep(400),
      path = "/documentation/widget/" .. ("y"):rep(120),
      type = "struct",
    },
  }, "widget")
  eq(#long[1].name + 1 + #long[1].key <= 255 - 8, true)
  has(long[1].name, "...")
end)

test("the Swift tree is the one read, even when an Objective-C one is there", function()
  local tree = docc._internal.language_tree({ interfaceLanguages = { occ = {}, swift = { { title = "S" } } } })
  eq(tree, { { title = "S" } })
end)

-- -------------------------------------------------------- probing a layout

test("a site serving JSON under /data is read there", function()
  local system, seen = runner({ layout = "docc" })
  eq(docc.from_url(docc_site .. "/documentation/widget", system), {
    { name = "widget", pages = 5, url = docc_site .. "/documentation/widget" },
  })
  has(table.concat(seen.urls, "\n"), docc_site .. "/data/documentation/widget.json")
  has(table.concat(seen.urls, "\n"), docc_site .. "/index/index.json")
end)

test("a site serving JSON under /tutorials/data is read there instead", function()
  local system, seen = runner({ layout = "apple" })
  eq(docc.from_url(apple_site .. "/documentation/widget/wheel", system), {
    { name = "widget", pages = 5, url = apple_site .. "/documentation/widget" },
  })
  local urls = table.concat(seen.urls, "\n")
  -- The /data shape is tried first and 404s, which is how the layout is found.
  has(urls, apple_site .. "/data/documentation/widget.json")
  has(urls, apple_site .. "/tutorials/data/documentation/widget.json")
  has(urls, apple_site .. "/tutorials/data/index/widget")
end)

test("a site that serves neither layout is refused, with a reason", function()
  local system = runner({ layout = "docc" })
  local ok, err = pcall(docc.from_url, "https://nowhere.example/documentation/widget", system)
  eq(ok, false)
  has(err, "does not serve DocC documentation")
end)

test("a name typed instead of a URL is not this source's business", function()
  eq(docc.from_url("swiftui", runner()), {})
end)

test("the site a docset came from is remembered, so it installs again", function()
  local system = runner({ layout = "docc" })
  docc.from_url(docc_site .. "/documentation/widget", system)
  eq(docc.site("widget"), { url = docc_site, module = "widget", layout = "docc" })
  eq(vim.fn.filereadable(docc.sites_path()), 1)
end)

test("a docset whose site is not remembered says how to install it again", function()
  local ok, err = pcall(docc.index, "forgotten", "", runner())
  eq(ok, false)
  has(err, "install it again")
end)

test("a DocC site publishes no version of its own", function()
  eq(docc.release("widget"), nil)
end)

-- ---------------------------------------------------------------- the index

test("the index names every page with its kind", function()
  local system = runner({ layout = "docc" })
  docc.from_url(docc_site .. "/documentation/widget", system)
  local entries = docc.index("widget", "", system).entries
  eq(#entries, 5)
  eq(entries[1], { name = "Widget", path = "widget", type = "Modules" })
  eq(entries[4], { name = "Wheel.spin()", path = "widget/wheel/spin()", type = "Methods" })
end)

test("the index is read once for an install, not once per call", function()
  local system, seen = runner({ layout = "docc" })
  docc.from_url(docc_site .. "/documentation/widget", system)
  local before = #seen.urls
  docc.index("widget", "", system)
  eq(#seen.urls, before)
end)

-- ------------------------------------------------------------ the pages

local function installed(opts)
  local system, seen = runner(opts)
  docc.from_url((opts and opts.layout == "apple" and apple_site or docc_site) .. "/documentation/widget", system)
  return docc.db("widget", "", system), seen
end

test("every page the site serves becomes HTML, and a missing one is skipped", function()
  local db = installed()
  eq(vim.tbl_count(db), 4)
  eq(db["widget/wheel/radius"], nil)
  has(db["widget"], "<h1>Widget</h1>")
end)

test("a page carries its abstract, its prose and its code", function()
  local db = installed()
  has(db["widget"], "Build wheels that turn.")
  has(db["widget"], '<h2 id="overview">Overview</h2>')
  has(db["widget"], '<pre><code class="language-swift">let wheel = Wheel()\nwheel.spin()</code></pre>')
  has(db["widget"], "<blockquote><p><strong>Note</strong></p>")
  has(db["widget"], "<em>round</em>")
end)

test("text that looks like a tag is written as text", function()
  local db = installed()
  has(db["widget"], "One &lt;wheel&gt; &amp; another")
end)

test("a table, a list and a term list keep their shape", function()
  local db = installed()
  has(db["widget"], "<th><p>Part</p></th>")
  has(db["widget"], "<td><p>Wheel</p></td>")
  has(db["widget"], "<li><p>Two</p></li>")
  has(db["widget"], "<dt>radius</dt>")
end)

test("a block this plugin has never seen still reads as prose", function()
  local db = installed()
  has(db["widget"], "Still readable.")
end)

test("a link to another page of the docset points at that page", function()
  local db = installed()
  -- From widget/getting-started to widget/wheel: one level up, then across.
  has(db["widget/getting-started"], '<a href="wheel">Wheel</a>')
  has(db["widget"], '<a href="widget/wheel">Wheel</a>')
end)

test("a link to a page the docset does not hold becomes an address", function()
  local db = installed()
  has(db["widget"], '<a href="' .. docc_site .. '/documentation/otherframework">OtherFramework</a>')
end)

test("a link may override the title of what it points at", function()
  local db = installed()
  has(db["widget/wheel"], ">the spin method</a>")
end)

test("an image is addressed on the site, and the light variant is the one used", function()
  local db = installed()
  has(db["widget"], '<img src="https://widget.example/docs/images/widget-hero@2x.png" alt="A wheel, turning">')
  has_not(db["widget"], "~dark")
end)

test("an outside link is left as the address it is", function()
  local db = installed()
  has(db["widget"], '<a href="https://widget.example/handbook">The wheel handbook</a>')
end)

test("a symbol page carries its declaration, its parameters and its platforms", function()
  local db = installed()
  has(db["widget/wheel/spin()"], "<pre><code>func spin(times: Int)</code></pre>")
  has(db["widget/wheel/spin()"], "<h2>Parameters</h2>")
  has(db["widget/wheel/spin()"], "<dt><code>times</code></dt>")
  has(db["widget/wheel"], "Available on iOS 13.0+")
  -- A platform the symbol is not available on is not a platform to list.
  has_not(db["widget/wheel"], "watchOS")
end)

test("the topics and relationships of a page are the way into its children", function()
  local db = installed()
  has(db["widget/wheel"], "<h2>Turning a wheel</h2>")
  has(db["widget/wheel"], "Turns the wheel once.")
  has(db["widget/wheel"], "<h2>Conforms To</h2>")
end)

test("the pages are fetched in one batch, in parallel where curl can", function()
  local _, seen = installed({ parallel = true })
  local fetched = 0
  for _, url in ipairs(seen.urls) do
    if url:find("/data/documentation/", 1, true) then
      fetched = fetched + 1
    end
  end
  -- The module page is fetched once for the layout probe and once with the
  -- rest, and radius is asked for although the site does not serve it.
  eq(fetched, 6)
end)

test("the apple layout installs the same docset as the docc one", function()
  local db = installed({ layout = "apple" })
  eq(vim.tbl_count(db), 4)
  has(db["widget"], '<a href="' .. apple_site .. '/documentation/otherframework">OtherFramework</a>')
  has(db["widget"], '<img src="' .. apple_site .. '/docs/images/widget-hero@2x.png"')
end)

-- --------------------------------------------------------- the renderer

test("an address is joined to the site, and to its root when it already carries it", function()
  local address = docc._internal.address
  eq(
    address("https://widget.example/docs", "/documentation/widget"),
    "https://widget.example/docs/documentation/widget"
  )
  eq(address("https://widget.example/docs", "/docs/images/a.png"), "https://widget.example/docs/images/a.png")
  eq(address("https://widget.example", "/documentation/widget"), "https://widget.example/documentation/widget")
  eq(address("https://widget.example/docs", "https://elsewhere.example/x"), "https://elsewhere.example/x")
  eq(address("https://widget.example/docs", "//cdn.example/x.png"), "https://cdn.example/x.png")
end)

test("a path is written from where it is read, climbing no further than it must", function()
  local relative_to = docc._internal.relative_to
  eq(relative_to("widget/wheel", "widget/wheel/spin()"), "spin()")
  eq(relative_to("widget", "widget/wheel"), "wheel")
  eq(relative_to("widget/wheel", "widget/getting-started"), "../getting-started")
  -- A page's own type is a page as well as the directory its members live in,
  -- so the link to it names it rather than naming nothing: an empty href is a
  -- link to the docset folder.
  eq(relative_to("widget/wheel", "widget/wheel"), "../wheel")
  eq(relative_to("widget", "widget"), "../widget")
  -- The module page itself sits at the top: nothing to climb.
  eq(relative_to("", "widget"), "widget")
end)

test("a link from a member back to its own type names the type", function()
  local db = installed()
  has(db["widget/wheel/spin()"], '<a href="../wheel">Wheel</a>')
  for key, html in pairs(db) do
    if html:find('href=""', 1, true) then
      error("an empty href in " .. key .. ": that is a link to the docset folder", 0)
    end
  end
end)

test("the renderer says what it cannot resolve rather than linking nowhere", function()
  local html = render.page({
    metadata = { title = "Alone" },
    primaryContentSections = {
      {
        kind = "content",
        content = {
          {
            type = "paragraph",
            inlineContent = { { type = "reference", identifier = "doc://nowhere" } },
          },
        },
      },
    },
  }, { resolve = function() end, reference = function() end })
  has(html, "doc://nowhere")
  has_not(html, "<a href")
end)

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
