-- The Maven Central source adapter (Java, Kotlin and Scala libraries).
--
-- Maven Central keeps, beside most releases, a "-javadoc.jar": the HTML
-- documentation its build generated, with the search index the generator wrote
-- for its own search box. Three generators fill those jars, and two of them
-- have changed their index, so the entries come from whichever of these the
-- jar holds (measured on real jars):
--   * *-search-index.js      javadoc from JDK 11 on (guava, commons-lang3):
--                            packages, types and members, each naming its
--                            package, class and anchor
--   * index-all.html         javadoc before that (jackson, junit 4): one <dt>
--                            per package, type and member, saying which it is
--   * scripts/searchData.js  Scala 3's scaladoc (cats-core_3): every page and
--                            member with its kind and "page#anchor"
--   * index.js               Scala 2's scaladoc (cats-core_2.13): the types of
--                            each package with their members
--   * scripts/pages.json     Kotlin's Dokka (ktor): a page per declaration
-- Many Kotlin libraries publish an empty placeholder jar instead (okhttp,
-- kotlinx-coroutines); such a docset is refused, since there is nothing in it.
--
-- This adapter turns that into the index/db pair the installer expects (see
-- sources/devdocs.lua):
--   * a docset is "<artifact>@<group>~<version>" (cats-core_3@org.typelevel~2.13.0):
--     the artifact alone is ambiguous (two unrelated "cats-core" exist), and
--     "@" is in neither a group nor an artifact id, and safe in a folder name;
--   * the pages are the ones the index names -- the jar's class-use pages,
--     trees and class lists are left out, and a link to them goes to
--     javadoc.io, which serves every javadoc jar of Maven Central;
--   * every id becomes plain text (javadoc writes "of(T)" and "&lt;init&gt;()",
--     Scala "as[A,B](fa:F[A]):F[B]"; the installer splits a link on "#" and
--     its buffers read brackets as markdown), and each anchor an entry lands on
--     gets a heading with the entry's name, since the installer takes an
--     entry's text from where its id stands.
--
-- The language of a docset is its generator's: javadoc documents Java,
-- scaladoc Scala, Dokka Kotlin.
local html_text = require("docshelf.html")
local links = require("docshelf.links")

local M = {}

M.origin = "central.sonatype.com"

M.languages = { "Java", "Kotlin", "Scala" }

local search_url = "https://central.sonatype.com/solrsearch/select?rows=20&wt=json&q="
local repository = "https://repo1.maven.org/maven2/"
local site = "https://javadoc.io/doc/"

local user_agent = "docshelf.nvim (https://github.com/ChrisGVE/docshelf.nvim)"

local function fetch(url, system)
  local res = system({ "curl", "-sfL", "-A", user_agent, url })
  if res.code ~= 0 then
    return nil, res.code
  end
  return res.stdout
end

--- The artifacts Maven Central finds for `query` that come with a javadoc
--- jar, each at its newest version.
---@param query string
---@param system fun(cmd: string[]): vim.SystemCompleted
---@return { name: string, version: string }[]
function M.search(query, system)
  local body, code = fetch(search_url .. vim.uri_encode(query, "rfc2396"), system)
  if not body then
    error("could not search Maven Central (curl exit " .. tostring(code) .. ")", 0)
  end
  local ok, answer = pcall(vim.json.decode, body)
  local docs = ok and type(answer) == "table" and type(answer.response) == "table" and answer.response.docs
  if not vim.islist(docs) then
    error("Maven Central answered a search with something other than a list of artifacts", 0)
  end
  local rows = {}
  for _, doc in ipairs(docs) do
    if
      type(doc) == "table"
      and type(doc.g) == "string"
      and type(doc.a) == "string"
      and type(doc.latestVersion) == "string"
      and vim.islist(doc.ec)
      and vim.tbl_contains(doc.ec, "-javadoc.jar")
    then
      rows[#rows + 1] = { name = doc.a .. "@" .. doc.g, version = doc.latestVersion }
    end
  end
  return rows
end

local function split_name(name)
  local artifact, group = name:match("^([%w%._%-]+)@([%w%._%-]+)$")
  if not artifact then
    error("a Maven Central docset is named artifact@group, got " .. name, 0)
  end
  return artifact, group
end

local function artifact_folder(artifact, group)
  return repository .. group:gsub("%.", "/") .. "/" .. artifact .. "/"
end

--- The docset for the newest release of an artifact.
---@param name string artifact@group
---@param system fun(cmd: string[]): vim.SystemCompleted
---@return string docset e.g. "guava@com.google.guava~33.7.1-jre"
function M.resolve(name, system)
  local artifact, group = split_name(name)
  local xml = fetch(artifact_folder(artifact, group) .. "maven-metadata.xml", system)
  local version = xml and (xml:match("<release>%s*(.-)%s*</release>") or xml:match("<latest>%s*(.-)%s*</latest>"))
  if not version or version == "" then
    error("Maven Central has no release of " .. name, 0)
  end
  return name .. "~" .. version
end

local function split_docset(docset)
  local name, version = docset:match("^(.+)~([^~]+)$")
  if not name then
    error("a Maven Central docset is artifact@group~version, got " .. docset, 0)
  end
  local artifact, group = split_name(name)
  return artifact, group, version
end

--- The release a docset holds: it is named for the exact version it came from.
---@param docset string
function M.release(docset)
  local _, _, version = split_docset(docset)
  return version
end

--- The docset Maven Central offers for this artifact today.
---@param docset string
---@param system fun(cmd: string[]): vim.SystemCompleted
function M.latest(docset, system)
  local artifact, group = split_docset(docset)
  return M.resolve(artifact .. "@" .. group, system)
end

local function read_file(path)
  local file = assert(io.open(path, "r"))
  local contents = file:read("*a")
  file:close()
  return contents
end

local function exists(path)
  return vim.fn.filereadable(path) == 1
end

local function url_decode(text)
  return (text:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

--- An id as plain text: decoded as a link and as HTML would write it, then
--- every character that is not a letter, digit, ".", "_" or "-" made "-". A
--- link and the id it names always come out the same.
local function plain_id(id)
  return (html_text.decode_entities(url_decode(id)):gsub("[^%w%._%-]", "-"))
end

-- What a kind is called in the pickers, by the generators' own words.
local kinds = {
  package = "Packages",
  class = "Classes",
  ["case class"] = "Classes",
  trait = "Traits",
  object = "Objects",
  interface = "Interfaces",
  enum = "Enums",
  ["annotation type"] = "Annotations",
  element = "Annotations",
  exception = "Exceptions",
  error = "Errors",
  type = "Types",
  typealias = "Types",
  def = "Methods",
  method = "Methods",
  fun = "Functions",
  constructor = "Constructors",
  val = "Values",
  var = "Values",
  variable = "Fields",
  constant = "Fields",
  given = "Givens",
  extension = "Extensions",
  static = "Guides",
}

--- A generator's kind ("Static variable", "implicit val") as a picker type:
--- the whole phrase if it is known, else its last word.
local function kind_name(kind)
  local lowered = kind:lower()
  return kinds[lowered] or kinds[lowered:match("(%S+)$") or ""] or (lowered:gsub("^%l", string.upper))
end

local function last_segment(name)
  return name:match("([^.]+)$") or name
end

--- The value of a JavaScript index file, `name = <JSON>;` followed maybe by
--- more script.
local function read_script_array(path)
  local text = read_file(path)
  local start, stop = text:find("[", 1, true), text:match(".*()%]")
  return vim.json.decode(text:sub(start, stop))
end

-- Each reader turns a generator's index into items { name, page, anchor?,
-- type }, `page` a path in the jar ending in ".html".
local readers = {}

function readers.javadoc(dir)
  local items = {}
  local function package_dir(entry)
    return (entry.m and (entry.m .. "/") or "") .. entry.p:gsub("%.", "/")
  end
  if exists(dir .. "/package-search-index.js") then
    for _, entry in ipairs(read_script_array(dir .. "/package-search-index.js")) do
      if not entry.u then
        local folder = (entry.m and (entry.m .. "/") or "") .. entry.l:gsub("%.", "/")
        items[#items + 1] = { name = entry.l, page = folder .. "/package-summary.html", type = "Packages" }
      end
    end
  end
  for _, entry in ipairs(read_script_array(dir .. "/type-search-index.js")) do
    if not entry.u and entry.p then
      items[#items + 1] = {
        name = entry.p .. "." .. entry.l,
        page = package_dir(entry) .. "/" .. entry.l .. ".html",
        type = "Types",
      }
    end
  end
  if exists(dir .. "/member-search-index.js") then
    for _, entry in ipairs(read_script_array(dir .. "/member-search-index.js")) do
      if entry.p and entry.c then
        local method = entry.l:match("^([^(]*)%(")
        local kind = not method and "Fields" or method == last_segment(entry.c) and "Constructors" or "Methods"
        items[#items + 1] = {
          name = entry.c .. "." .. entry.l,
          page = package_dir(entry) .. "/" .. entry.c .. ".html",
          anchor = entry.u or entry.l,
          type = kind,
        }
      end
    end
  end
  return items
end

--- The index pages of javadoc before JDK 9: one index-all.html, or one page
--- per letter in index-files/ (javadoc -splitindex).
local function javadoc8_index_pages(dir)
  if exists(dir .. "/index-all.html") then
    return { { file = dir .. "/index-all.html", from = "" } }
  end
  local pages = {}
  for _, file in ipairs(vim.fn.glob(dir .. "/index-files/index-*.html", false, true)) do
    pages[#pages + 1] = { file = file, from = "index-files" }
  end
  return pages
end

function readers.javadoc8(dir)
  local items = {}
  for _, index in ipairs(javadoc8_index_pages(dir)) do
    for dt in read_file(index.file):gmatch("<dt>(.-)</dt>") do
      local href, label = dt:match('<a href="([^"]*)"[^>]*>(.-)</a>')
      local said = html_text.text(dt):match("^.- %- (.*)$")
      if href and said and not href:match("^%a[%w+.-]*:") then
        local target, anchor = href:match("^([^#]*)#?(.*)$")
        local page = links.resolve(index.from, target)
        local kind = kind_name(said:match("^(.-) in ") or said:match("^(.-) for ") or said:match("^(%a+)") or "")
        local name = html_text.text(label)
        if anchor ~= "" then
          name = page:match("([^/]+)%.html$") .. "." .. name
        elseif kind ~= "Packages" then
          name = page:gsub("%.html$", ""):gsub("/", ".")
        end
        items[#items + 1] = { name = name, page = page, anchor = anchor ~= "" and anchor or nil, type = kind }
      end
    end
  end
  return items
end

function readers.scaladoc3(dir)
  local text = read_file(dir .. "/scripts/searchData.js")
  local pages = vim.json.decode(text:match("=%s*(%[.*%])%s*;?%s*$"))
  local items = {}
  for _, entry in ipairs(pages) do
    local page, anchor = tostring(entry.l):match("^([^#]*)#?(.*)$")
    local declared = entry.d ~= "" and entry.d or nil
    local name = entry.n
    if anchor == "" and declared then
      name = declared .. "." .. name
    elseif declared then
      name = last_segment(declared) .. "." .. name
    end
    items[#items + 1] = {
      name = name,
      page = page,
      anchor = anchor ~= "" and anchor or nil,
      type = kind_name(entry.k or ""),
    }
  end
  return items
end

-- The kinds of type Scala 2's scaladoc lists, each a key naming its page.
local scala2_kinds = { "package", "class", "case class", "trait", "object", "type" }

function readers.scaladoc2(dir)
  local text = read_file(dir .. "/index.js")
  local packages = vim.json.decode(text:match("^[^=]*=%s*(.-)%s*;?%s*$"))
  local items = {}
  for package, types in pairs(packages) do
    items[#items + 1] = { name = package, page = package:gsub("%.", "/") .. "/index.html", type = "Packages" }
    for _, entity in ipairs(types) do
      for _, kind in ipairs(scala2_kinds) do
        if type(entity[kind]) == "string" then
          items[#items + 1] = { name = entity.name, page = entity[kind], type = kind_name(kind) }
          for _, member in ipairs(entity["members_" .. kind] or {}) do
            local page, anchor = member.link:match("^([^#]*)#?(.*)$")
            items[#items + 1] = {
              name = last_segment(entity.name) .. "." .. member.label,
              page = page,
              anchor = anchor ~= "" and anchor or nil,
              type = kind_name(member.kind or ""),
            }
          end
        end
      end
    end
  end
  return items
end

-- The words a Dokka declaration starts with that say what it is.
local dokka_keywords =
  { class = true, interface = true, object = true, enum = true, fun = true, val = true, var = true, typealias = true }

function readers.dokka(dir)
  local items = {}
  for _, entry in ipairs(vim.json.decode(read_file(dir .. "/scripts/pages.json"))) do
    local kind = "Declarations"
    for word in tostring(entry.name):gmatch("[%a]+") do
      if dokka_keywords[word] then
        kind = kind_name(word)
        break
      end
    end
    -- a type has a folder of its own, its members a page inside it
    local name = entry.description
    if not entry.location:match("/index%.html$") then
      name = name:match("([^.]+%.[^.]+)$") or name
    end
    items[#items + 1] = { name = name, page = entry.location, type = kind }
  end
  return items
end

--- Which generator wrote the jar unpacked in `dir`, and the language it
--- documents; nil when the jar holds no index docshelf can read.
local function generator(dir)
  if exists(dir .. "/type-search-index.js") then
    return "javadoc", "Java"
  elseif exists(dir .. "/scripts/searchData.js") then
    return "scaladoc3", "Scala"
  elseif exists(dir .. "/scripts/pages.json") then
    return "dokka", "Kotlin"
  elseif exists(dir .. "/index.js") and read_file(dir .. "/index.js"):find("Index.PACKAGES", 1, true) then
    return "scaladoc2", "Scala"
  elseif #javadoc8_index_pages(dir) > 0 then
    return "javadoc8", "Java"
  end
end

-- The downloaded jar of each install, kept between its index and db calls,
-- and the language each docset turned out to be written in.
local downloaded = {}
local languages = {}

local function download(docset, system)
  local artifact, group, version = split_docset(docset)
  local what = artifact .. "@" .. group .. " " .. version
  if vim.fn.executable("unzip") ~= 1 then
    error("the 'unzip' program must be installed to read Maven Central documentation", 0)
  end
  local url = artifact_folder(artifact, group) .. version .. "/" .. artifact .. "-" .. version .. "-javadoc.jar"
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local jar = dir .. ".jar"
  if system({ "curl", "-sfL", "-A", user_agent, "-o", jar, url }).code ~= 0 then
    error("no javadoc jar on Maven Central for " .. what, 0)
  end
  -- only the pages and the indexes: a Scala 3 jar also carries 16 MB of
  -- type-search database and fonts
  local unpacked = system({
    "unzip",
    "-q",
    "-o",
    jar,
    "*.html",
    "*search-index.js",
    "index.js",
    "scripts/searchData.js",
    "scripts/pages.json",
    "-d",
    dir,
  }).code
  os.remove(jar)
  -- unzip exits 11 when nothing matched: an empty jar, refused below
  if unpacked ~= 0 and unpacked ~= 11 then
    error("could not unpack the javadoc jar of " .. what, 0)
  end
  local format, language = generator(dir)
  if not format then
    vim.fn.delete(dir, "rf")
    error("the javadoc jar of " .. what .. " holds no documentation docshelf can read", 0)
  end
  languages[docset] = language
  local items = readers[format](dir)
  -- the pages the index names, and the entry name each anchor lands on
  local pages, names, entries, seen = {}, {}, {}, {}
  for _, item in ipairs(items) do
    if type(item.name) == "string" and type(item.page) == "string" and exists(dir .. "/" .. item.page) then
      local key = item.page:gsub("%.html$", "")
      pages[key] = dir .. "/" .. item.page
      local path = key
      if item.anchor then
        local anchor = plain_id(item.anchor)
        names[key] = names[key] or {}
        names[key][anchor] = names[key][anchor] or item.name
        path = key .. "#" .. anchor
      end
      if not seen[item.name .. "\0" .. path] then
        seen[item.name .. "\0" .. path] = true
        entries[#entries + 1] = { name = item.name, path = path, type = item.type }
      end
    end
  end
  return {
    folder = dir,
    format = format,
    pages = pages,
    names = names,
    entries = entries,
    base = site .. group .. "/" .. artifact .. "/" .. version .. "/",
  }
end

local function held(docset, system)
  downloaded[docset] = downloaded[docset] or download(docset, system)
  return downloaded[docset]
end

function M.index(docset, _, system)
  return { entries = held(docset, system).entries }
end

--- The language a docset is written in, known once it has been downloaded.
---@param docset string
---@return string?
function M.language_of(docset)
  return languages[docset]
end

-- Where each generator's documentation starts on a page, and where it stops.
local bounds = {
  javadoc = { starts = { "<main[%s>]" }, stops = { "</main>", "<footer" } },
  javadoc8 = {
    starts = { '<div class="header"' },
    stops = { '<div class="bottomNav"', "<!%-%- =+ START OF BOTTOM NAVBAR" },
  },
  scaladoc3 = { starts = { '<div id="content"' }, stops = { '<div id="toc"', '<div id="footer"' } },
  scaladoc2 = { starts = { '<div id="definition"' }, stops = { '<div id="tooltip"' } },
  dokka = { starts = { '<div class="main%-content"' }, stops = { '<div class="footer"' } },
}

local function main_content(html, format)
  local body = html
  for _, start in ipairs(bounds[format].starts) do
    local at = html:find(start)
    if at then
      body = html:sub(at)
      break
    end
  end
  local stop
  for _, pattern in ipairs(bounds[format].stops) do
    local at = body:find(pattern)
    stop = at and math.min(stop or at, at) or stop
  end
  return stop and body:sub(1, stop - 1) or body
end

local function escape(text)
  return (text:gsub('[&<>"]', { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" }))
end

--- Every id of a page made plain, an old <a name> made an id, and a heading
--- naming the entry put before each anchor an entry lands on.
local function name_the_anchors(body, names)
  body = body:gsub("<[aA](%s[^>]*)>", function(attributes)
    if attributes:match("%s[iI][dD]=") then
      return nil
    end
    return "<a" .. attributes:gsub('(%s)[nN][aA][mM][eE]="', '%1id="') .. ">"
  end)
  local landed = {}
  return (
    body:gsub('<(%w+)([^>]-)%s[iI][dD]="([^"]*)"([^>]*)>', function(tag, before, id, after)
      local plain = plain_id(id)
      local name = names and names[plain]
      if name and not landed[plain] then
        landed[plain] = true
        return '<h4 id="' .. plain .. '">' .. escape(name) .. "</h4><" .. tag .. before .. after .. ">"
      end
      return "<" .. tag .. before .. ' id="' .. plain .. '"' .. after .. ">"
    end)
  )
end

--- A link's anchor made plain like the ids, unless it leads to another site.
local function plain_fragments(body)
  return (
    body:gsub('(%s[hH][rR][eE][fF]=")([^"#]*)#([^"]*)"', function(attribute, target, anchor)
      if target:match("^%a[%w+.-]*:") or target:match("^//") then
        return nil
      end
      return attribute .. target .. "#" .. plain_id(anchor) .. '"'
    end)
  )
end

local function clean_page(html, format, names)
  local body = main_content(html, format)
    :gsub("<script.-</script>", "")
    :gsub("<style.-</style>", "")
    :gsub("<button.-</button>", "")
    :gsub("<svg.-</svg>", "")
    -- Scala 2's permalink icon beside every member
    :gsub('<span class="permalink">.-</span>', "")
  return plain_fragments(name_the_anchors(body, names))
end

function M.db(docset, _, system)
  local docs = held(docset, system)
  downloaded[docset] = nil
  local known = {}
  for key in pairs(docs.pages) do
    known[key] = true
  end
  local db = {}
  for key, file in pairs(docs.pages) do
    db[key] = links.rewrite_html(clean_page(read_file(file), docs.format, docs.names[key]), {
      dir = key:match("^(.*)/[^/]*$") or "",
      known = known,
      base = docs.base,
    })
  end
  vim.fn.delete(docs.folder, "rf")
  return db
end

return M
