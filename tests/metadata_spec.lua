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

test("record links the installed source to its language", function()
  eq(metadata.record(catalogue_entry, 500, "haskell~9").language, "Haskell")
  eq(metadata.record(catalogue_entry, 500, "haskell~9").language_kind, "language")
  eq({ metadata.record({ slug = "git" }, 500, "git").language, metadata.record({ slug = "git" }, 500, "git").language_kind }, { "Git", "language" })
end)

test("a source's declared language wins over the shipped table", function()
  -- devdocs' async is a JavaScript package; Hackage's async is Haskell
  local record = metadata.record({ origin = "hackage.haskell.org", language = "Haskell" }, 1, "async~2.2~~hackage.haskell.org")
  eq({ record.language, record.language_kind }, { "Haskell", "package" })
end)

test("the shipped table only applies to devdocs sources", function()
  local record = metadata.record({ origin = "example.org" }, 1, "numpy~2~~example.org")
  eq(record.language_kind, nil)
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
    { version = "9", release = "9.14.1", mtime = 200, installed_at = 250, origin = "devdocs.io", language = "Haskell", language_kind = "language" }
  )
end)

test("backfill leaves a folder older than the catalogue mtime unknown", function()
  local manifest = metadata.backfill({}, { "haskell~9" }, { ["haskell~9"] = catalogue_entry }, { ["haskell~9"] = 150 })
  eq(manifest["haskell~9"], { installed_at = 150, language = "Haskell", language_kind = "language" })
  eq(metadata.status(manifest["haskell~9"], catalogue_entry), { kind = "unknown" })
end)

test("backfill records a source that left the catalogue", function()
  local manifest = metadata.backfill({}, { "scala~3.2" }, {}, { ["scala~3.2"] = 150 })
  eq(manifest["scala~3.2"], { installed_at = 150, language = "Scala", language_kind = "language" })
end)

test("backfill never overwrites an existing record, only links its language", function()
  local existing = { ["haskell~9"] = { release = "9.14.0", mtime = 1, installed_at = 2 } }
  local manifest = metadata.backfill(
    existing,
    { "haskell~9" },
    { ["haskell~9"] = catalogue_entry },
    { ["haskell~9"] = 999 }
  )
  eq(manifest["haskell~9"], { release = "9.14.0", mtime = 1, installed_at = 2, language = "Haskell", language_kind = "language" })
end)

test("backfill links an Unknown record again, keeps a found language and updates its kind", function()
  local existing = {
    ["mystery"] = { installed_at = 1 },
    ["numpy~2.5"] = { installed_at = 1, language = "Rust", language_kind = "package" },
    ["openjdk~21"] = { installed_at = 1, language = "Java", language_kind = "package" },
  }
  local manifest = metadata.backfill(existing, { "mystery", "numpy~2.5", "openjdk~21" }, {}, {})
  eq(manifest["mystery"], { installed_at = 1 })
  eq(manifest["numpy~2.5"].language, "Rust")
  eq(manifest["openjdk~21"].language_kind, "language")
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

-- assignment --------------------------------------------------------------

local scratch = vim.fn.tempname() .. "/"
for _, dir in ipairs({ "mystery", "python~3.14", "pycairo" }) do
  vim.fn.mkdir(scratch .. dir, "p")
end
require("apidocs.common").data_folder = function()
  return scratch
end

test("an Unknown source can be given a language, by name or alias", function()
  eq({ metadata.assign_language("pycairo", "py") }, { true })
  eq(metadata.installed_languages({ "pycairo" })["pycairo"], { kind = "package", language = "Python" })
end)

test("any source's language can be changed, again and again", function()
  eq({ metadata.assign_language("pycairo", "Rust") }, { true })
  eq(metadata.installed_languages({ "pycairo" })["pycairo"], { kind = "package", language = "Rust" })
  eq({ metadata.assign_language("python~3.14", "Go") }, { true })
  eq(metadata.installed_languages({ "python~3.14" })["python~3.14"], { kind = "package", language = "Go" })
  eq({ metadata.assign_language("python~3.14", "Python") }, { true })
  eq(metadata.installed_languages({ "python~3.14" })["python~3.14"], { kind = "language", language = "Python" })
end)

test("a name no list knows can be given, and is then offered for the next docset", function()
  eq({ metadata.assign_language("mystery", "Prolog") }, { true })
  eq(metadata.installed_languages({ "mystery" })["mystery"], { kind = "package", language = "Prolog" })
  eq(vim.tbl_contains(metadata.recorded_languages(), "Prolog"), true)
  eq(vim.tbl_contains(require("apidocs.languages").available(), "Prolog"), true)
end)

test("a user's choice survives a refresh and a reinstall", function()
  eq({ metadata.assign_language("mystery", "Git") }, { true })
  local manifest = metadata.backfill(
    metadata.read(scratch .. metadata.manifest_name), { "mystery" }, {}, { mystery = 1 })
  eq({ manifest.mystery.language, manifest.mystery.language_assigned }, { "Git", true })
  metadata.write(scratch .. metadata.manifest_name, manifest)
  -- a reinstall writes a fresh record from the catalogue, where the table would say otherwise
  metadata.mark_installed("python~3.14", { slug = "python~3.14", release = "3.14.7", mtime = 5 })
  eq(metadata.installed_languages({ "python~3.14" })["python~3.14"].language, "Python")
  eq({ metadata.assign_language("python~3.14", "Rust") }, { true })
  metadata.mark_installed("python~3.14", { slug = "python~3.14", release = "3.14.8", mtime = 6 })
  local record = metadata.read(scratch .. metadata.manifest_name)["python~3.14"]
  eq({ record.release, record.language, record.language_assigned }, { "3.14.8", "Rust", true })
end)

test("a source that is not installed cannot be assigned", function()
  eq({ metadata.assign_language("nowhere", "Python") }, { false, "nowhere is not installed" })
end)

test("installed_languages leaves Unknown sources out", function()
  vim.fn.delete(scratch .. metadata.manifest_name)
  local links = metadata.installed_languages({ "pycairo", "python~3.14" })
  eq(links["pycairo"], nil)
  eq(links["python~3.14"], { kind = "language", language = "Python" })
end)

vim.fn.delete(scratch, "rf")

if failures > 0 then
  print(failures .. " test(s) failed")
  os.exit(1)
end
print("all tests passed")
