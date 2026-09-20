-- Tests for lua/apidocs/install_pick.lua.
-- Run from the repository root: nvim --headless -l tests/install_pick_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local pick = require("apidocs.install_pick")

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

local function names(items)
  return vim.tbl_map(function(item)
    return item.text
  end, items)
end

local function items(...)
  return vim.tbl_map(function(text)
    return { text = text }
  end, { ... })
end

test("an empty query keeps every row, in the order given", function()
  eq(names(pick.order(items("python", "rust", "go"), "")), { "python", "rust", "go" })
end)

test("a query drops the rows it does not match", function()
  local ordered = names(pick.order(items("python~3.14", "rust", "go"), "rust"))
  eq(ordered, { "rust" })
end)

test("matching ignores case", function()
  eq(names(pick.order(items("Rust", "go"), "rust")), { "Rust" })
end)

-- snacks is not on the path when the specs run headless; then order() falls
-- back to a substring filter, which keeps the rows in the order given.
local has_matcher = pcall(require, "snacks.picker.core.matcher")

test("every row holding the query is kept, in the order it was offered in", function()
  eq(names(pick.order(items("aeson", "aeson-pretty"), "aeson")), { "aeson", "aeson-pretty" })
end)

test("with snacks' matcher, a row that is exactly what was typed goes first", function()
  if not has_matcher then
    return print("     (skipped: snacks is not on the path)")
  end
  eq(names(pick.order(items("aeson-pretty", "aeson"), "aeson"))[1], "aeson")
end)

test("a registry row with a version installs into a folder named after it", function()
  local row = pick.registry_row({ name = "text", version = "2.1.2", origin = "hackage.haskell.org" }, "Haskell")
  eq(row.label, "text~2.1.2")
  eq(row.slug, "text~2.1.2~~hackage.haskell.org")
  eq(row.language, "Haskell")
end)

test("a registry row with no version yet has no folder, and shows its name alone", function()
  local row = pick.registry_row({ name = "text", origin = "hackage.haskell.org" })
  eq(row.label, "text")
  eq(row.slug, nil)
  eq(row.name, "text")
  eq(row.language, "")
end)

test("the title says nothing extra when nothing is being waited on", function()
  eq(pick.title("Install documentation", {}), "Install documentation")
end)

test("the title names the one registry still being waited on", function()
  eq(pick.title("Install", { "hackage.haskell.org" }), "Install · searching hackage.haskell.org…")
end)

test("the title counts the registries when there are several", function()
  eq(pick.title("Install", { "one.example", "two.example" }), "Install · searching 2 registries…")
end)

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
