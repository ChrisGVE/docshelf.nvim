-- Tests for lua/apidocs/update.lua -- the planning half, which is pure: it is
-- handed a manifest and the devdocs catalogue, and it answers what is out of
-- date. Nothing here touches the network or the data folder.
-- Run from the repository root: nvim --headless -l tests/update_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local update = require("apidocs.update")

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

-- A devdocs catalogue entry and the record an install of it wrote.
local function entry(slug, release, mtime)
  return { slug = slug, version = slug:match("~(.*)$"), release = release, mtime = mtime }
end

local function record(release, mtime, extra)
  return vim.tbl_extend("force", { release = release, mtime = mtime, installed_at = 1 }, extra or {})
end

-- --------------------------------------------------------- what is behind

test("a docset with a newer release in the catalogue is out of date", function()
  local items = update.plan(
    { ["python~3.14"] = record("3.14.6", 100) },
    { ["python~3.14"] = entry("python~3.14", "3.14.7", 200) }
  )
  eq(#items, 1)
  eq(items[1].folder, "python~3.14")
  eq(items[1].target, "python~3.14")
  eq(items[1].kind, "release")
  eq(items[1].installed, "3.14.6")
  eq(items[1].available, "3.14.7")
end)

test("a docset devdocs rebuilt at the same release is out of date", function()
  local items = update.plan({ ["go"] = record("1.25", 100) }, { ["go"] = entry("go", "1.25", 200) })
  eq(#items, 1)
  eq(items[1].kind, "rebuilt")
  eq(items[1].target, "go")
end)

test("a docset matching the catalogue is left alone", function()
  eq(update.plan({ ["go"] = record("1.25", 100) }, { ["go"] = entry("go", "1.25", 100) }), {})
end)

test("a docset installed before tracking cannot be compared, so it is skipped", function()
  eq(update.plan({ ["go"] = { installed_at = 1 } }, { ["go"] = entry("go", "1.25", 100) }), {})
end)

test("a docset the catalogue no longer carries is skipped, not reinstalled", function()
  eq(update.plan({ ["go"] = record("1.25", 100) }, {}), {})
end)

test("the plan is sorted by folder, so the report reads the same way twice", function()
  local items = update.plan({
    ["rust"] = record("1.90", 100),
    ["go"] = record("1.25", 100),
  }, {
    ["rust"] = entry("rust", "1.91", 200),
    ["go"] = entry("go", "1.26", 200),
  })
  eq(vim.tbl_map(function(i)
    return i.folder
  end, items), { "go", "rust" })
end)

-- -------------------------------------------------------------- the report

test("the report names what changes, and how", function()
  local items = update.plan(
    { ["python~3.14"] = record("3.14.6", 100) },
    { ["python~3.14"] = entry("python~3.14", "3.14.7", 200) }
  )
  eq(update.summary(items), "python~3.14 3.14.6 → 3.14.7")
end)

test("a rebuild says so rather than showing the same version twice", function()
  local items = update.plan({ ["go"] = record("1.25", 100) }, { ["go"] = entry("go", "1.25", 200) })
  eq(update.summary(items), "go 1.25 (rebuilt)")
end)

-- ------------------------------------------------- when the idle check runs

test("the first check of a collection is due", function()
  eq(update.due({}, 1000, 24), true)
end)

test("a check inside the window is not due, one past it is", function()
  eq(update.due({ checked_at = 1000 }, 1000 + 23 * 3600, 24), false)
  eq(update.due({ checked_at = 1000 }, 1000 + 24 * 3600, 24), true)
end)

test("a stamp from the future does not lock the check out for ever", function()
  eq(update.due({ checked_at = 10000 }, 1000, 24), true)
end)

test("a nonsense stamp is treated as no stamp", function()
  eq(update.due({ checked_at = "yesterday" }, 1000, 24), true)
end)

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
