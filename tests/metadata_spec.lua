-- Tests for lua/apidocs/metadata.lua.
-- Run from the repository root: nvim --headless -l tests/metadata_spec.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local metadata = require("apidocs.metadata")

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

local catalogue_entry = { slug = "haskell~9", version = "9", release = "9.14.1", mtime = 200 }

-- record -------------------------------------------------------------------

test("record keeps version, release, mtime and the install time", function()
  eq(
    metadata.record(catalogue_entry, 500),
    { version = "9", release = "9.14.1", mtime = 200, installed_at = 500, origin = "devdocs.io" }
  )
end)

-- status -------------------------------------------------------------------

test("same release and mtime is current", function()
  eq(metadata.status({ release = "9.14.1", mtime = 200 }, catalogue_entry), { kind = "current" })
end)

test("same release with a newer mtime is a rebuild", function()
  eq(metadata.status({ release = "9.14.1", mtime = 100 }, catalogue_entry), { kind = "rebuilt", mtime = 200 })
end)

test("a different release is a new release, even when mtime also moved", function()
  eq(
    metadata.status({ release = "9.14.0", mtime = 100 }, catalogue_entry),
    { kind = "release", installed = "9.14.0", release = "9.14.1" }
  )
end)

test("sources without a release compare on mtime alone", function()
  local c = { slug = "c", mtime = 300 }
  eq(metadata.status({ mtime = 300 }, c), { kind = "current" })
  eq(metadata.status({ mtime = 100 }, c), { kind = "rebuilt", mtime = 300 })
end)

test("an installed source missing from the catalogue is unavailable", function()
  eq(metadata.status({ release = "3.2.0", mtime = 1 }, nil), { kind = "unavailable" })
end)

test("a record with no mtime (installed before tracking) is unknown", function()
  eq(metadata.status({ installed_at = 50 }, catalogue_entry), { kind = "unknown" })
end)

-- backfill -----------------------------------------------------------------

test("backfill trusts a folder newer than the catalogue mtime", function()
  local manifest = metadata.backfill({}, { "haskell~9" }, { ["haskell~9"] = catalogue_entry }, { ["haskell~9"] = 250 })
  eq(
    manifest["haskell~9"],
    { version = "9", release = "9.14.1", mtime = 200, installed_at = 250, origin = "devdocs.io" }
  )
end)

test("backfill leaves a folder older than the catalogue mtime unknown", function()
  local manifest = metadata.backfill({}, { "haskell~9" }, { ["haskell~9"] = catalogue_entry }, { ["haskell~9"] = 150 })
  eq(manifest["haskell~9"], { installed_at = 150 })
  eq(metadata.status(manifest["haskell~9"], catalogue_entry), { kind = "unknown" })
end)

test("backfill records a source that left the catalogue", function()
  local manifest = metadata.backfill({}, { "scala~3.2" }, {}, { ["scala~3.2"] = 150 })
  eq(manifest["scala~3.2"], { installed_at = 150 })
end)

test("backfill never overwrites an existing record", function()
  local existing = { ["haskell~9"] = { release = "9.14.0", mtime = 1, installed_at = 2 } }
  local manifest = metadata.backfill(
    existing,
    { "haskell~9" },
    { ["haskell~9"] = catalogue_entry },
    { ["haskell~9"] = 999 }
  )
  eq(manifest["haskell~9"], { release = "9.14.0", mtime = 1, installed_at = 2 })
end)

test("backfill drops records whose folder is gone", function()
  local existing = { ["gone"] = { mtime = 1, installed_at = 2 } }
  eq(metadata.backfill(existing, {}, {}, {}), {})
end)

-- origin -------------------------------------------------------------------

test("a devdocs catalogue entry comes from devdocs", function()
  eq(metadata.origin(catalogue_entry), "devdocs.io")
end)

test("an entry names its own origin when it has one", function()
  eq(metadata.origin({ slug = "text~2.1", origin = "hackage.haskell.org" }), "hackage.haskell.org")
end)

test("a source missing from every catalogue has no origin", function()
  eq(metadata.origin(nil), nil)
end)

test("an install record keeps its origin", function()
  eq(metadata.installed_origin({ origin = "hackage.haskell.org" }), "hackage.haskell.org")
end)

test("a record from before origins were kept came from devdocs", function()
  eq(metadata.installed_origin({ installed_at = 1 }), "devdocs.io")
  eq(metadata.installed_origin(nil), "devdocs.io")
end)

test("installed_origins reads each installed source's origin from the manifest", function()
  local dir = vim.fn.tempname() .. "/"
  vim.fn.mkdir(dir, "p")
  local common = require("apidocs.common")
  local data_folder = common.data_folder
  common.data_folder = function()
    return dir
  end
  metadata.write(dir .. metadata.manifest_name, { ["text~2.1"] = { origin = "hackage.haskell.org" }, ["lua~5.4"] = {} })
  local ok, result = pcall(metadata.installed_origins, { "text~2.1", "lua~5.4", "rust" })
  common.data_folder = data_folder
  vim.fn.delete(dir, "rf")
  assert(ok, result)
  eq(result, { ["text~2.1"] = "hackage.haskell.org", ["lua~5.4"] = "devdocs.io", rust = "devdocs.io" })
end)

-- label --------------------------------------------------------------------

test("label for a source that is not installed shows its release", function()
  eq(metadata.label(catalogue_entry, nil), "haskell~9  9.14.1")
end)

test("label for a current install", function()
  eq(metadata.label(catalogue_entry, { release = "9.14.1", mtime = 200 }), "haskell~9  9.14.1  [installed]")
end)

test("label for a rebuild shows the rebuild date", function()
  local rebuilt =
    { slug = "haskell~9", release = "9.14.1", mtime = os.time({ year = 2026, month = 9, day = 14, hour = 12 }) }
  eq(metadata.label(rebuilt, { release = "9.14.1", mtime = 1 }), "haskell~9  9.14.1  [installed · rebuilt 2026-09-14]")
end)

test("label for a new release shows both releases", function()
  eq(
    metadata.label(catalogue_entry, { release = "9.14.0", mtime = 100 }),
    "haskell~9  9.14.1  [installed 9.14.0 · new release 9.14.1]"
  )
end)

test("label for an install that predates tracking", function()
  eq(metadata.label(catalogue_entry, { installed_at = 1 }), "haskell~9  9.14.1  [installed · may be outdated]")
end)

test("label for a source without a release", function()
  eq(metadata.label({ slug = "c", mtime = 3 }, nil), "c")
end)

-- manifest file --------------------------------------------------------------

test("write then read round-trips the manifest", function()
  local path = vim.fn.tempname() .. "/installed.json"
  local manifest = { ["haskell~9"] = { version = "9", release = "9.14.1", mtime = 200, installed_at = 250 } }
  metadata.write(path, manifest)
  eq(metadata.read(path), manifest)
end)

test("reading a missing manifest gives an empty table", function()
  eq(metadata.read(vim.fn.tempname() .. "/none.json"), {})
end)

if failures > 0 then
  print(failures .. " test(s) failed")
  os.exit(1)
end
print("all tests passed")
