-- Install metadata: which catalogue release and build of each source is
-- installed, and when it was installed.
--
-- The manifest lives in <data_folder>/.installed.json. It is a dotfile so that
-- ripgrep-based searches over the data folder skip it. Shape:
--   { ["python~3.14"] = { version = "3.14", release = "3.14.7",
--                         mtime = 1788075102, installed_at = 1789212345 } }
-- `version`, `release` and `mtime` are copied from devdocs' docs.json at
-- install time; `installed_at` is os.time(). A record with no `mtime` belongs
-- to a source installed before metadata was tracked.
--
-- `language` links the source to its language (see languages.lua); a record
-- without one is Unknown. `language_kind` says whether the source is that
-- language's own reference ("language") or not ("package"); it is derived
-- from the language's aliases and recomputed on every refresh. The language
-- is decided at install; an Unknown source is tried again on every refresh.
-- `language_assigned` marks a language the user chose: it is kept when the
-- source is refreshed or reinstalled. Records written before languages were
-- tracked are linked by the same rules when read.
--
-- An installed source is compared with the current catalogue entry:
--   current      same release and same build
--   release      the catalogue has a different release (e.g. 9.14.0 -> 9.14.1)
--   rebuilt      same release, but devdocs regenerated it (mtime changed)
--   unknown      installed before tracking, so its build cannot be compared
--   unavailable  the source is no longer in the catalogue

local M = {}

M.manifest_name = ".installed.json"

-- docs.json uses null for absent fields; treat vim.NIL like nil.
local function present(value)
  if value == vim.NIL then
    return nil
  end
  return value
end

--- The language link of an installed source, decided by languages.resolve.
---@param slug string
---@param origin string
---@param declared? string the language its source declares
local function resolve_language(slug, origin, declared)
  return require("apidocs.languages").resolve(slug, { devdocs = origin == M.devdocs_origin, declared = declared })
end

local function with_language(record, link, assigned)
  record.language = link and link.language or nil
  record.language_kind = link and link.kind or nil
  record.language_assigned = assigned or nil
  return record
end

--- `entry` is the catalogue entry; `slug` (the installed folder) lets the
--- record carry the source's language link.
function M.record(entry, now, slug)
  local record = {
    version = present(entry.version),
    release = present(entry.release),
    mtime = present(entry.mtime),
    installed_at = now,
    origin = M.origin(entry),
  }
  if slug then
    with_language(record, resolve_language(slug, record.origin, present(entry.language)))
  end
  return record
end

--- The language link a record holds, or the one its source would get today
--- when the record predates language tracking. Nil means Unknown.
---@param slug string
---@param record? table
function M.language_link(slug, record)
  if record and record.language then
    return require("apidocs.languages").link(slug, record.language)
  end
  return resolve_language(slug, M.installed_origin(record))
end

function M.status(record, entry)
  if entry == nil then
    return { kind = "unavailable" }
  end
  if record.mtime == nil then
    return { kind = "unknown" }
  end
  local release = present(entry.release)
  if record.release ~= release then
    return { kind = "release", installed = record.release, release = release }
  end
  if record.mtime ~= entry.mtime then
    return { kind = "rebuilt", mtime = entry.mtime }
  end
  return { kind = "current" }
end

-- Reconcile the manifest with the folders actually on disk. Existing records
-- are kept as they are. A folder without a record gets one inferred from its
-- modification time: newer than the catalogue build means the install is that
-- build; older, or absent from the catalogue, means nothing can be inferred.
-- Records whose folder is gone are dropped.
function M.backfill(manifest, installed, catalogue, dir_mtimes)
  local result = {}
  for _, slug in ipairs(installed) do
    local dir_mtime = dir_mtimes[slug]
    local entry = catalogue[slug]
    if manifest[slug] ~= nil then
      result[slug] = manifest[slug]
    elseif entry ~= nil and present(entry.mtime) ~= nil and dir_mtime > entry.mtime then
      result[slug] = M.record(entry, dir_mtime)
    else
      result[slug] = { installed_at = dir_mtime }
    end
    -- An Unknown source is linked again on every refresh, so adding a
    -- language to the user's list can make it known; a language once found
    -- stays, and its kind follows the current aliases.
    local record = result[slug]
    with_language(record, M.language_link(slug, record), record.language_assigned)
  end
  return result
end

-- One line of the install picker: slug, catalogue release, install state.
-- The origin shown for devdocs sources: the site's short address, so a reader
-- knows where the pages were fetched from.
M.devdocs_origin = "devdocs.io"

--- Where a source comes from: devdocs.io for devdocs catalogue entries, the
--- entry's own `origin` (a short address) for any other catalogue, nil for an
--- unknown source.
function M.origin(entry)
  if entry == nil then
    return nil
  end
  return entry.origin or M.devdocs_origin
end

--- Where an installed source came from. Records written before origins were
--- kept have none, and devdocs was then the only source.
function M.installed_origin(record)
  return (record and record.origin) or M.devdocs_origin
end

function M.label(entry, record)
  local release = present(entry.release)
  local text = entry.slug
  if release ~= nil then
    text = text .. "  " .. release
  end
  if record == nil then
    return text
  end
  local status = M.status(record, entry)
  if status.kind == "current" then
    return text .. "  [installed]"
  elseif status.kind == "rebuilt" then
    return text .. "  [installed · rebuilt " .. os.date("%Y-%m-%d", status.mtime) .. "]"
  elseif status.kind == "release" then
    return text .. "  [installed " .. (status.installed or "?") .. " · new release " .. (status.release or "?") .. "]"
  end
  return text .. "  [installed · may be outdated]"
end

function M.read(path)
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"), { luanil = { object = true } })
  if not ok or type(decoded) ~= "table" then
    return {}
  end
  return decoded
end

function M.write(path, manifest)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile({ vim.json.encode(manifest) }, path)
end

-- Helpers bound to the real data folder --------------------------------------

local function manifest_path()
  return require("apidocs.common").data_folder() .. M.manifest_name
end

local function installed_folders()
  local root = require("apidocs.common").data_folder()
  local slugs, mtimes = {}, {}
  for name, kind in vim.fs.dir(root) do
    if kind == "directory" then
      table.insert(slugs, name)
      mtimes[name] = vim.uv.fs_stat(root .. name).mtime.sec
    end
  end
  return slugs, mtimes
end

-- Read the manifest, reconcile it with the folders on disk, save it, return it.
function M.refresh(catalogue)
  local slugs, mtimes = installed_folders()
  local manifest = M.backfill(M.read(manifest_path()), slugs, catalogue, mtimes)
  M.write(manifest_path(), manifest)
  return manifest
end

--- The origin of every installed source, by slug; for pickers over installed
--- sources, which show it next to each name.
function M.installed_origins(installed)
  local manifest = M.read(manifest_path())
  local origins = {}
  for _, slug in ipairs(installed) do
    origins[slug] = M.installed_origin(manifest[slug])
  end
  return origins
end

--- The language link of every installed source, by slug; Unknown sources are
--- absent.
---@param installed string[]
---@return table<string, { kind: string, language?: string }>
function M.installed_languages(installed)
  local manifest = M.read(manifest_path())
  local links = {}
  for _, slug in ipairs(installed) do
    links[slug] = M.language_link(slug, manifest[slug])
  end
  return links
end

--- Give an installed source a language from the user's list, replacing the
--- one it had. The choice is kept across refreshes and reinstalls.
---@param slug string
---@param language string
---@return boolean ok, string? why
function M.assign_language(slug, language)
  if vim.fn.isdirectory(require("apidocs.common").data_folder() .. slug) ~= 1 then
    return false, slug .. " is not installed"
  end
  local path = manifest_path()
  local manifest = M.read(path)
  local link, why = require("apidocs.languages").for_assignment(slug, language)
  if not link then
    return false, why
  end
  manifest[slug] = with_language(manifest[slug] or { installed_at = os.time() }, link, true)
  M.write(path, manifest)
  return true
end

function M.mark_installed(slug, entry)
  local path = manifest_path()
  local manifest = M.read(path)
  local previous = manifest[slug]
  manifest[slug] = M.record(entry, os.time(), slug)
  if previous and previous.language_assigned then
    with_language(manifest[slug], M.language_link(slug, previous), true)
  end
  M.write(path, manifest)
end

function M.forget(slug)
  local path = manifest_path()
  local manifest = M.read(path)
  manifest[slug] = nil
  M.write(path, manifest)
end

return M
