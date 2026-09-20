-- Keeping installed documentation current.
--
-- A docset is a copy of something that keeps moving: devdocs rebuilds its
-- catalogue and the thing it documents publishes new releases. This module
-- answers two questions -- which installed docsets are behind, and how to
-- bring them level -- and arms the idle check that asks them on its own.
--
-- The planning half (`plan`, `summary`, `due`) is pure: it is handed the
-- manifest and the devdocs catalogue, and it returns a list of items. That is
-- what the specs exercise; nothing in it touches the network or the data
-- folder.
--
-- What "behind" means comes from the install record: `.installed.json` keeps
-- the release a docset was installed at and the catalogue's build time, so a
-- new release (3.14.6 -> 3.14.7) and a rebuild at the same release are both
-- visible from one catalogue request, the same one the install picker already
-- makes. A docset installed before metadata was recorded, and one the
-- catalogue has since dropped, cannot be compared -- neither is reported,
-- because reinstalling on a guess costs thousands of requests.
--
-- An update is a reinstall in place: a devdocs docset's name carries the
-- release line, not the release (`python~3.14` covers 3.14.6 and 3.14.7), so
-- the folder that is there is the folder that stays.
local M = {}

local metadata = require("apidocs.metadata")

-- --------------------------------------------------------------- planning

--- What is out of date, given the manifest and the devdocs catalogue.
---@param manifest table<string, table> install records by docset name
---@param catalogue table<string, table> devdocs entries by docset name
---@return { folder: string, docset: string, target: string, kind: string, name: string, installed?: string, available?: string }[]
function M.plan(manifest, catalogue)
  local items = {}
  for docset, record in pairs(manifest) do
    local status = metadata.status(record, catalogue[docset])
    local item
    if status.kind == "release" then
      item = {
        kind = "release",
        installed = status.installed,
        available = status.release,
      }
    elseif status.kind == "rebuilt" then
      item = {
        kind = "rebuilt",
        installed = record.release,
        available = record.release,
      }
    end
    if item then
      item.folder, item.docset, item.name, item.target = docset, docset, docset, docset
      items[#items + 1] = item
    end
  end
  table.sort(items, function(a, b)
    return a.folder < b.folder
  end)
  return items
end

--- One line naming what the plan changes: "python~3.14 3.14.6 → 3.14.7".
---@param items table[]
---@return string
function M.summary(items)
  local parts = {}
  for _, item in ipairs(items) do
    if item.kind == "rebuilt" then
      parts[#parts + 1] = item.name .. " " .. (item.installed or "?") .. " (rebuilt)"
    else
      parts[#parts + 1] = item.name .. " " .. (item.installed or "?") .. " → " .. (item.available or "?")
    end
  end
  return table.concat(parts, ", ")
end

--- Whether the idle check should run. A stamp in the future -- a clock put
--- back, a folder copied from another machine -- would otherwise lock the
--- check out until the future caught up, so it counts as no stamp at all.
---@param stamp table what was last written, or {}
---@param now integer os.time()
---@param every_hours number
---@return boolean
function M.due(stamp, now, every_hours)
  local at = stamp and stamp.checked_at
  if type(at) ~= "number" or at > now then
    return true
  end
  return (now - at) >= every_hours * 3600
end

-- ------------------------------------------------------------- the stamp

-- When the collection was last checked. A dotfile beside the manifest, so
-- ripgrep-based searches over the data folder skip it, and its own file rather
-- than a key in the manifest: the manifest is rebuilt from the folders on disk
-- on every refresh, and anything that is not a docset is dropped.
M.stamp_name = ".update.json"

local function stamp_path()
  return require("apidocs.common").data_folder() .. M.stamp_name
end

function M.read_stamp()
  local path = stamp_path()
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  local ok, stamp = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  return (ok and type(stamp) == "table") and stamp or {}
end

function M.write_stamp(now)
  vim.fn.mkdir(require("apidocs.common").data_folder(), "p")
  pcall(vim.fn.writefile, { vim.json.encode({ checked_at = now }) }, stamp_path())
end

-- ------------------------------------------------------------ asking round

local function notify(text, level)
  vim.notify("apidocs update: " .. text, level or vim.log.levels.INFO, { id = "apidocs_update", title = "apidocs" })
end

--- What is out of date, as `plan` returns it. One devdocs catalogue request,
--- the same one the install picker makes.
---@param cont fun(items: table[], catalogue: table, slugs_to_mtimes: table)
function M.check(cont)
  local install = require("apidocs.install")
  install.fetch_slugs_and_mtimes_and_then(function(slugs_to_mtimes)
    local catalogue = install.catalogue()
    cont(M.plan(metadata.refresh(catalogue), catalogue), catalogue, slugs_to_mtimes)
  end)
end

-- --------------------------------------------------------------- applying

--- Install everything the plan names, through the same queue as any other
--- install.
---@param items table[]
---@param slugs_to_mtimes table
---@param cont? fun()
function M.apply(items, slugs_to_mtimes, cont)
  local targets = {}
  for _, item in ipairs(items) do
    targets[#targets + 1] = item.target
  end
  require("apidocs.install").queue_install(targets, slugs_to_mtimes, cont)
end

-- ------------------------------------------------------------- the command

--- Check what is behind and install it. With no `only`, everything installed
--- is considered.
---@param opts? { only?: string[], quiet?: boolean, on_done?: fun(items: table[]) }
function M.run(opts)
  opts = opts or {}
  local install = require("apidocs.install")
  if install.installing() then
    if not opts.quiet then
      notify("an install is already running; try again when it has finished", vim.log.levels.WARN)
    end
    return
  end
  if not opts.quiet then
    notify("checking what is out of date")
  end
  M.check(function(items, _, slugs_to_mtimes)
    if opts.only then
      local wanted = {}
      for _, name in ipairs(opts.only) do
        wanted[name] = true
      end
      items = vim.tbl_filter(function(item)
        return wanted[item.folder]
      end, items)
    end
    M.write_stamp(os.time())
    if #items == 0 then
      if not opts.quiet then
        notify("everything is up to date")
      end
      if opts.on_done then
        opts.on_done(items)
      end
      return
    end
    notify("updating " .. M.summary(items))
    M.apply(items, slugs_to_mtimes, function()
      if opts.on_done then
        opts.on_done(items)
      end
    end)
  end)
end

-- ----------------------------------------------------------- the idle check

-- Mason updates its packages on its own, and documentation goes stale the same
-- way, so the check runs without being asked -- but never while the user is
-- waiting on the editor. It is armed for the first CursorHold, which is
-- Neovim saying the user has stopped typing, so nothing happens during
-- startup or mid-keystroke, and it runs at most once a session and once a day
-- (the stamp in the data folder). Everything it does afterwards is an ordinary
-- install: the same queue, the same progress notification.
local checked_this_session = false

--- Arm the idle check. `auto = false` in setup() switches it off.
---@param opts? { auto?: boolean, every_hours?: number }
function M.arm(opts)
  opts = opts or {}
  if opts.auto == false then
    return
  end
  local every_hours = opts.every_hours or 24
  vim.api.nvim_create_autocmd("CursorHold", {
    group = vim.api.nvim_create_augroup("apidocs_update", { clear = true }),
    once = true,
    callback = function()
      if checked_this_session or not M.due(M.read_stamp(), os.time(), every_hours) then
        return
      end
      checked_this_session = true
      M.run({ quiet = true })
    end,
  })
end

return M
