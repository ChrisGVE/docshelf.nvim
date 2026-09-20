-- Every source adapter answers the contract in sources/init.lua.
--
-- This walks lua/apidocs/sources/ rather than naming the adapters, so a new one
-- is checked the moment its file exists. It matters because a missing
-- declaration fails SILENTLY: the pickers read a docset's origin from its
-- folder name, so an adapter that declares no language installs docsets that
-- are simply Unknown, and nothing reports it.
-- Run from the repository root: nvim --headless -l tests/sources_contract_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local devdocs_origin = require("apidocs.metadata").devdocs_origin

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
for name in vim.fs.dir("lua/apidocs/sources") do
  local module = name:match("^(.+)%.lua$")
  if module and module ~= "init" then
    adapters[module] = require("apidocs.sources." .. module)
  end
end

test("there is at least one adapter to check", function()
  if next(adapters) == nil then
    error("no adapter found in lua/apidocs/sources", 0)
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
    if adapter.origin == devdocs_origin then
      -- devdocs documents everything, so it has no one language to declare;
      -- its docsets are linked through source_languages.lua instead.
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
