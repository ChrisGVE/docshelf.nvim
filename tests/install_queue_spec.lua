-- Tests for lua/docshelf/install_queue.lua.
-- Run from the repository root: nvim --headless -l tests/install_queue_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local install_queue = require("docshelf.install_queue")

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

-- A fake installer: records each call and lets the test finish it.
local function fake()
  local calls, finish = {}, {}
  local function install(slug, done)
    calls[#calls + 1] = slug
    finish[slug] = done
  end
  return install, calls, finish
end

test("sources install one at a time, in the order given", function()
  local install, calls, finish = fake()
  local queue = install_queue.new(install)
  queue:add({ "numpy~2.5", "rust" })
  eq(calls, { "numpy~2.5" })
  finish["numpy~2.5"](true)
  eq(calls, { "numpy~2.5", "rust" })
  finish["rust"](true)
  eq(calls, { "numpy~2.5", "rust" })
  eq(queue:position("rust"), nil)
end)

test("sources added while one installs wait their turn", function()
  local install, calls, finish = fake()
  local queue = install_queue.new(install)
  queue:add({ "numpy~2.5" })
  queue:add({ "lua~5.4" })
  eq(calls, { "numpy~2.5" })
  finish["numpy~2.5"](true)
  eq(calls, { "numpy~2.5", "lua~5.4" })
end)

test("a failed install does not stop the queue", function()
  local install, calls, finish = fake()
  local queue = install_queue.new(install)
  queue:add({ "numpy~2.5", "rust" })
  finish["numpy~2.5"](false)
  eq(calls, { "numpy~2.5", "rust" })
end)

test("a source already installing or waiting is not queued twice", function()
  local install, calls, finish = fake()
  local queue = install_queue.new(install)
  eq(queue:add({ "numpy~2.5", "rust", "rust" }), { "numpy~2.5", "rust" })
  eq(queue:add({ "numpy~2.5", "rust", "go" }), { "go" })
  finish["numpy~2.5"](true)
  finish["rust"](true)
  eq(calls, { "numpy~2.5", "rust", "go" })
end)

test("position counts the whole run, including sources added later", function()
  local install, _, finish = fake()
  local queue = install_queue.new(install)
  queue:add({ "numpy~2.5", "rust" })
  eq(queue:position("numpy~2.5"), "1/2")
  queue:add({ "go" })
  eq(queue:position("numpy~2.5"), "1/3")
  eq(queue:position("go"), "3/3")
  finish["numpy~2.5"](true)
  eq(queue:position("rust"), "2/3")
end)

test("a run that finished starts counting afresh", function()
  local install, _, finish = fake()
  local queue = install_queue.new(install)
  queue:add({ "numpy~2.5" })
  finish["numpy~2.5"](true)
  queue:add({ "rust" })
  eq(queue:position("rust"), "1/1")
end)

test("position is nil for a source that is not queued", function()
  local install = fake()
  eq(install_queue.new(install):position("rust"), nil)
end)

test("an install that throws counts as failed and the queue moves on", function()
  local calls = {}
  local queue = install_queue.new(function(slug, done)
    calls[#calls + 1] = slug
    if slug == "bad" then
      error("boom")
    end
  end, function() end)
  queue:add({ "bad", "rust" })
  eq(calls, { "bad", "rust" })
end)

test("cont runs once every source of that call has finished", function()
  local install, _, finish = fake()
  local queue = install_queue.new(install)
  local ran = 0
  queue:add({ "numpy~2.5" })
  queue:add({ "numpy~2.5", "rust" }, function()
    ran = ran + 1
  end)
  finish["numpy~2.5"](true)
  eq(ran, 0)
  finish["rust"](false)
  eq(ran, 1)
end)

test("cont may queue more without two installs running at once", function()
  local install, calls, finish = fake()
  local queue = install_queue.new(install)
  queue:add({ "numpy~2.5", "rust" }, function()
    queue:add({ "go" })
  end)
  finish["numpy~2.5"](true)
  finish["rust"](true)
  eq(calls, { "numpy~2.5", "rust", "go" })
  eq(queue:position("go"), "3/3") -- joined the run that was still going
end)

test("cont with nothing to wait for runs at once", function()
  local install = fake()
  local ran = false
  install_queue.new(install):add({}, function()
    ran = true
  end)
  eq(ran, true)
end)

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
