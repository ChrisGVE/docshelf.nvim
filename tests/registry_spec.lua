-- Tests for lua/apidocs/registry.lua.
-- Run from the repository root: nvim --headless -l tests/registry_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local registry = require("apidocs.registry")
local sources = require("apidocs.sources")

local failures = 0
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local seq = 0

local function test(name, fn)
  sources.configure({})
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

local function fresh_cache()
  seq = seq + 1
  return registry.cache(tmp .. "/cache" .. seq .. ".json")
end

-- A source that answers searches from a table, and records what it was asked.
local function fake_source(origin, answers, opts)
  opts = opts or {}
  local adapter = {
    origin = origin,
    language = opts.language,
    index = function() end,
    db = function() end,
    asked = {},
    search = function(self, query, system)
      table.insert(self.asked, query)
      if opts.fails then
        error("registry unreachable", 0)
      end
      return answers[query] or {}
    end,
  }
  if opts.no_search then
    adapter.search = nil
  end
  return adapter
end

-- `search` is called as adapter.search(query, system); the fakes above want
-- themselves, so wrap them the way a real adapter is written.
local function bind(adapter)
  local search = adapter.search
  if search then
    adapter.search = function(query, system)
      return search(adapter, query, system)
    end
  end
  return adapter
end

-- Drives the coroutine work synchronously: every call returns at once.
local function now(fn, on_fail)
  local ok, err = pcall(fn)
  if not ok and on_fail then
    on_fail(err)
  end
end

local function run_search(query, opts)
  local batches, done = {}, false
  local handle = registry.search(query, vim.tbl_extend("keep", opts, {
    run = now,
    system = function() end,
    on_batch = function(origin, rows)
      table.insert(batches, { origin = origin, rows = rows })
    end,
    on_done = function()
      done = true
    end,
  }))
  return batches, done, handle
end

test("a cache with no file yet is empty", function()
  eq(fresh_cache():rows(), {})
end)

test("what is remembered comes back from a new cache on the same file", function()
  local cache = fresh_cache()
  cache:remember({ { name = "aeson", origin = "hackage.haskell.org" } })
  eq(registry.cache(cache.path):rows(), { { name = "aeson", origin = "hackage.haskell.org" } })
end)

test("remembering the same name twice keeps one row, the newer one", function()
  local cache = fresh_cache()
  cache:remember({ { name = "text", version = "2.1.1", origin = "hackage.haskell.org" } })
  cache:remember({ { name = "text", version = "2.1.2", origin = "hackage.haskell.org" } })
  eq(cache:rows(), { { name = "text", version = "2.1.2", origin = "hackage.haskell.org" } })
end)

test("the same name from two origins is two rows", function()
  local cache = fresh_cache()
  cache:remember({
    { name = "text", origin = "hackage.haskell.org" },
    { name = "text", origin = "example.org" },
  })
  eq(#cache:rows(), 2)
end)

test("a cached row is matched by any part of its name, whatever the case", function()
  local cache = fresh_cache()
  cache:remember({
    { name = "aeson", origin = "hackage.haskell.org" },
    { name = "lens-aeson", origin = "hackage.haskell.org" },
    { name = "text", origin = "hackage.haskell.org" },
  })
  eq(vim.tbl_map(function(r)
    return r.name
  end, cache:match("AES")), { "aeson", "lens-aeson" })
end)

test("an empty query matches nothing: the cache is not a catalogue to browse", function()
  local cache = fresh_cache()
  cache:remember({ { name = "aeson", origin = "hackage.haskell.org" } })
  eq(cache:match(""), {})
end)

test("only sources that can search, and are on, are searched", function()
  sources.register(bind(fake_source("asks.example", {})))
  sources.register(bind(fake_source("silent.example", {}, { no_search = true })))
  local function listed(origin)
    return vim.tbl_contains(registry.searchable(), origin)
  end
  eq(listed("asks.example"), true)
  eq(listed("silent.example"), false)
  sources.configure({ sources = { ["asks.example"] = false } })
  eq(listed("asks.example"), false)
end)

test("a language narrows the sources to the ones that document it", function()
  sources.register(bind(fake_source("haskellish.example", {}, { language = "Haskellish" })))
  sources.register(bind(fake_source("rustish.example", {}, { language = "Rustish" })))
  eq(registry.searchable({ languages = { Haskellish = true } }), { "haskellish.example" })
  eq(
    registry.searchable({ languages = { Haskellish = true, Rustish = true } }),
    { "haskellish.example", "rustish.example" }
  )
end)

test("a source that declares no language is left out when a language is asked for", function()
  sources.register(bind(fake_source("anylang.example", {})))
  eq(registry.searchable({ languages = { Anything = true } }), {})
  eq(vim.tbl_contains(registry.searchable(), "anylang.example"), true)
end)

test("a search asks every named source and reports each answer as it lands", function()
  sources.register(bind(fake_source("one.example", { aeson = { { name = "aeson", version = "2.2" } } })))
  sources.register(bind(fake_source("two.example", { aeson = { { name = "aeson-pretty" } } })))
  local batches, done = run_search("aeson", { origins = { "one.example", "two.example" }, cache = fresh_cache() })
  eq(done, true)
  eq(#batches, 2)
  eq(batches[1].rows, { { name = "aeson", version = "2.2", origin = "one.example" } })
  eq(batches[2].rows, { { name = "aeson-pretty", origin = "two.example" } })
end)

test("what a search finds is remembered", function()
  sources.register(bind(fake_source("one.example", { aeson = { { name = "aeson", version = "2.2" } } })))
  local cache = fresh_cache()
  run_search("aeson", { origins = { "one.example" }, cache = cache })
  eq(cache:match("aeson"), { { name = "aeson", version = "2.2", origin = "one.example" } })
end)

test("a source that fails is reported empty and the others still answer", function()
  sources.register(bind(fake_source("down.example", {}, { fails = true })))
  sources.register(bind(fake_source("up.example", { aeson = { { name = "aeson" } } })))
  local batches, done = run_search("aeson", { origins = { "down.example", "up.example" }, cache = fresh_cache() })
  eq(done, true)
  eq(#batches, 1)
  eq(batches[1].origin, "up.example")
end)

test("an empty query asks nobody", function()
  local source = bind(fake_source("one.example", {}))
  sources.register(source)
  local batches, done = run_search("", { origins = { "one.example" }, cache = fresh_cache() })
  eq(done, true)
  eq(#batches, 0)
end)

test("a handle names the sources still being waited on, and empties as they land", function()
  sources.register(bind(fake_source("one.example", {})))
  local _, _, handle = run_search("aeson", { origins = { "one.example" }, cache = fresh_cache() })
  eq(handle:pending(), {})
end)

test("a cancelled search reports nothing further", function()
  sources.register(bind(fake_source("one.example", { aeson = { { name = "aeson" } } })))
  local batches = {}
  local handle = registry.search("aeson", {
    origins = { "one.example" },
    cache = fresh_cache(),
    -- never resumed: the search is cancelled while still in flight
    run = function() end,
    system = function() end,
    on_batch = function(origin, rows)
      table.insert(batches, { origin = origin, rows = rows })
    end,
    on_done = function() end,
  })
  handle:cancel()
  eq(handle:cancelled(), true)
  eq(#batches, 0)
end)

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
