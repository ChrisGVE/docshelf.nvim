-- Every source adapter answers the contract in sources/init.lua.
--
-- This walks lua/docshelf/sources/ rather than naming the adapters, so a new one
-- is checked the moment its file exists. It matters because a missing
-- declaration fails SILENTLY: the pickers read a docset's origin from its
-- folder name, so an adapter that declares no language installs docsets that
-- are simply Unknown, and nothing reports it.
-- Run from the repository root: nvim --headless -l tests/sources_contract_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local devdocs_origin = require("docshelf.metadata").devdocs_origin

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

local function is(value, kind, what)
  if type(value) ~= kind then
    error(what .. " must be a " .. kind .. ", got " .. vim.inspect(value), 3)
  end
end

local adapters = {}
for name in vim.fs.dir("lua/docshelf/sources") do
  local module = name:match("^(.+)%.lua$")
  if module and module ~= "init" then
    adapters[module] = require("docshelf.sources." .. module)
  end
end

test("there is at least one adapter to check", function()
  if next(adapters) == nil then
    error("no adapter found in lua/docshelf/sources", 0)
  end
end)

for module, adapter in pairs(adapters) do
  test(module .. " names the origin its docsets install under", function()
    is(adapter.origin, "string", "origin")
    if adapter.origin == "" then
      error("origin must not be empty", 0)
    end
  end)

  test(module .. " hands the installer an index and a db", function()
    is(adapter.index, "function", "index")
    is(adapter.db, "function", "db")
  end)

  test(module .. " declares a language unless it is a whole catalogue", function()
    if adapter.languages ~= nil then
      -- a registry whose packages are written in one of several languages
      -- (hex.pm: Elixir, Erlang, Gleam) lists them, and says which one a
      -- docset is once it has read it
      if adapter.language ~= nil or adapter.catalogue ~= nil then
        error("a source listing its languages must not also declare one, or be a catalogue", 0)
      end
      if not vim.islist(adapter.languages) or #adapter.languages == 0 then
        error("languages must be a non-empty list, got " .. vim.inspect(adapter.languages), 0)
      end
      for _, language in ipairs(adapter.languages) do
        is(language, "string", "each of languages")
      end
      is(adapter.language_of, "function", "language_of")
      return
    end
    if adapter.origin == devdocs_origin then
      -- devdocs documents everything, so it has no one language to declare;
      -- its docsets are linked through source_languages.lua instead.
      return
    end
    if adapter.catalogue == true then
      -- a catalogue of many languages (Dash) says so instead: its docsets
      -- take their language from their name, as languages.lua's rule 3 does.
      if adapter.language ~= nil then
        error("a catalogue must not also declare one language", 0)
      end
      return
    end
    is(adapter.language, "string", "language")
    if adapter.language == "" then
      error("language must not be empty", 0)
    end
  end)

  test(module .. " says what release a docset holds unless a catalogue does", function()
    if adapter.origin == devdocs_origin then
      return
    end
    is(adapter.release, "function", "release")
  end)

  -- `release` reads the version out of a docset's own name, so it says what
  -- is INSTALLED. `latest` asks the source what it offers TODAY, which costs a
  -- request -- so it is optional: devdocs answers for all of its docsets from
  -- one catalogue, and a source that publishes no version (DocC) has nothing
  -- to compare and declares none.
  test(module .. " keeps latest optional, and a function when it is there", function()
    if adapter.latest ~= nil then
      is(adapter.latest, "function", "latest")
    end
  end)

  test(module .. " keeps search optional, and a function when it is there", function()
    if adapter.search ~= nil then
      is(adapter.search, "function", "search")
    end
  end)
end

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
