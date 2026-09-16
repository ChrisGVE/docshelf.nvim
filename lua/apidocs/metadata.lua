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

function M.record(entry, now)
  return {
    version = present(entry.version),
    release = present(entry.release),
    mtime = present(entry.mtime),
    installed_at = now,
    origin = M.origin(entry),
  }
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
  end
  return result
end

-- One line of the install picker: slug, catalogue release, install state.
--- Where a source comes from: "devdocs" for devdocs catalogue entries, the
--- entry's own `origin` for any other catalogue, nil for an unknown source.
function M.origin(entry)
  if entry == nil then
    return nil
  end
  return entry.origin or "devdocs"
end

--- Where an installed source came from. Records written before origins were
--- kept have none, and devdocs was then the only source.
function M.installed_origin(record)
  return (record and record.origin) or "devdocs"
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

function M.mark_installed(slug, entry)
  local path = manifest_path()
  local manifest = M.read(path)
  manifest[slug] = M.record(entry, os.time())
  M.write(path, manifest)
end

function M.forget(slug)
  local path = manifest_path()
  local manifest = M.read(path)
  manifest[slug] = nil
  M.write(path, manifest)
end

return M
