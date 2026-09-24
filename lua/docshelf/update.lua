-- Keeping installed documentation current.
--
-- A docset is a copy of something that keeps moving: devdocs rebuilds its
-- catalogue, a package publishes a new version, a project's site is edited.
-- This module answers two questions -- which installed docsets are behind, and
-- how to bring them level -- and arms the idle check that asks them on its own.
--
-- The planning half (`plan`, `askable`, `summary`, `due`) is pure: it is handed
-- the manifest, the devdocs catalogue and what each source says it offers now,
-- and it returns a list of items. That is what the specs exercise; nothing in
-- it touches the network or the data folder.
--
-- Where "what is offered now" comes from differs by source, and `release` is
-- not the answer: every adapter's `release(docset)` reads the version out of
-- the docset's own name, which is what is INSTALLED. Asking the source takes
-- one request, so it is a separate, optional part of the contract:
--
--   latest(docset, system) -> docset?   the docset this source offers today
--                                       for the same thing, or nil when it
--                                       cannot say
--
-- devdocs needs none: its catalogue (docs.json) already carries the release and
-- the build time of everything, and one request covers the lot. DocC declares
-- none either -- a DocC site publishes no version at all, so there is nothing
-- to compare and a DocC docset is never reported as stale.
--
-- Two shapes of update come out of this, and they differ in what they leave
-- behind. A devdocs docset keeps its folder (python~3.14 is a moving target
-- whose release goes 3.14.6 -> 3.14.7), so an update is a reinstall in place.
-- Every other source names the folder for the exact version it holds, so
-- text~2.1.2~~hackage.haskell.org becomes text~2.1.3~~hackage.haskell.org: the
-- new one is installed, what the user set on the old one (its language, its
-- place in the filter) moves over, and the old folder is removed.
local M = {}

local folders = require("docshelf.folders")
local metadata = require("docshelf.metadata")

--- The name and version a docset is called, or nil where it carries no
--- version ("swiftui", a DocC site that publishes none).
local function split_version(docset)
  local name, version = docset:match("^(.-)~([^~]*)$")
  if name == nil or name == "" or version == "" then
    return nil
  end
  return name, version
end

-- --------------------------------------------------------------- planning

--- What is out of date, given the manifest, the devdocs catalogue, and the
--- docset each other source says it offers now (by installed folder).
---
--- Anything that cannot be compared is left out rather than reported: a docset
--- installed before metadata was tracked, one the catalogue has dropped, one
--- whose source was not asked or could not answer, and one with no version on
--- either side. None of those means "stale", and reinstalling on a guess costs
--- thousands of requests.
---@param manifest table<string, table>
---@param catalogue table<string, table> devdocs entries by docset name
---@param offered table<string, string> installed folder -> docset offered now
---@return { folder: string, docset: string, origin: string, target: string, kind: string, name: string, installed?: string, available?: string, replaces: boolean }[]
function M.plan(manifest, catalogue, offered)
  local items = {}
  for folder, record in pairs(manifest) do
    local docset, origin = folders.split(folder)
    local item
    if origin == metadata.devdocs_origin then
      local status = metadata.status(record, catalogue[docset])
      if status.kind == "release" then
        item = {
          kind = "release",
          name = folder,
          target = folder,
          installed = status.installed,
          available = status.release,
          replaces = false,
        }
      elseif status.kind == "rebuilt" then
        item = {
          kind = "rebuilt",
          name = folder,
          target = folder,
          installed = record.release,
          available = record.release,
          replaces = false,
        }
      end
    else
      local available_docset = offered[folder]
      if available_docset and available_docset ~= docset then
        local name, installed = split_version(docset)
        local _, available = split_version(available_docset)
        if name and available then
          item = {
            kind = "release",
            name = name,
            target = folders.name(available_docset, origin),
            installed = installed,
            available = available,
            replaces = true,
          }
        end
      end
    end
    if item then
      item.folder, item.docset, item.origin = folder, docset, origin
      items[#items + 1] = item
    end
  end
  table.sort(items, function(a, b)
    return a.folder < b.folder
  end)
  return items
end

--- The installed folders worth asking about: those whose source can say what
--- it offers. devdocs docsets are not among them -- the catalogue answers for
--- all of them in the one request the install picker already makes.
---@param installed string[] folder names
---@param adapter_of fun(origin: string): table?
---@return string[]
function M.askable(installed, adapter_of)
  local askable = {}
  for _, folder in ipairs(installed) do
    local _, origin = folders.split(folder)
    if origin ~= metadata.devdocs_origin then
      local adapter = adapter_of(origin)
      if adapter and type(adapter.latest) == "function" then
        askable[#askable + 1] = folder
      end
    end
  end
  return askable
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
  return require("docshelf.common").data_folder() .. M.stamp_name
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
  vim.fn.mkdir(require("docshelf.common").data_folder(), "p")
  pcall(vim.fn.writefile, { vim.json.encode({ checked_at = now }) }, stamp_path())
end

-- ------------------------------------------------------------ asking round

local function notify(text, level)
  vim.notify("docshelf update: " .. text, level or vim.log.levels.INFO, { id = "docshelf_update", title = "docshelf" })
end

--- Ask each source what it offers now for the docsets installed from it.
--- Only callable from inside `async.run`: every answer is an HTTP request.
--- A source that raises is left out rather than allowed to stop the round --
--- one unreachable registry must not hide what the others have to say.
---@param askable string[] installed folder names, from `askable`
---@param system fun(cmd: string[], opts?: table): vim.SystemCompleted
---@return table<string, string> folder -> the docset it offers now
function M.offered(askable, system)
  local sources = require("docshelf.sources")
  local offered = {}
  for _, folder in ipairs(askable) do
    local docset, origin = folders.split(folder)
    local adapter = sources.get(origin)
    local ok, answer = pcall(adapter.latest, docset, system)
    if ok and type(answer) == "string" then
      offered[folder] = answer
    end
    require("docshelf.async").yield_to_editor()
  end
  return offered
end

--- What is out of date, as `plan` returns it. One devdocs catalogue request
--- plus one request per docset from a source that can be asked.
---@param cont fun(items: table[], catalogue: table, slugs_to_mtimes: table)
---@param on_fail? fun(message: string)
function M.check(cont, on_fail)
  local install = require("docshelf.install")
  local sources = require("docshelf.sources")
  install.fetch_slugs_and_mtimes_and_then(function(slugs_to_mtimes)
    local catalogue = install.catalogue()
    local manifest = metadata.refresh(catalogue)
    local installed = vim.tbl_keys(manifest)
    table.sort(installed)
    require("docshelf.async").run(function()
      local system = function(cmd, opts)
        return require("docshelf.async").system(cmd, opts or { text = true })
      end
      local offered = M.offered(M.askable(installed, sources.get), system)
      cont(M.plan(manifest, catalogue, offered), catalogue, slugs_to_mtimes)
    end, function()
      if on_fail then
        on_fail("the sources could not all be asked")
      end
    end)
  end)
end

-- --------------------------------------------------------------- applying

--- What the user set on a docset, to be carried to the folder that replaces
--- it: the language they assigned, and its place in the filter.
local function carried(folder)
  local manifest = metadata.read(require("docshelf.common").data_folder() .. metadata.manifest_name)
  local record = manifest[folder] or {}
  local ok, filter = pcall(require, "docshelf.filter")
  local filtered = false
  if ok then
    filtered = vim.tbl_contains(filter.active() or {}, folder)
  end
  return { language = record.language_assigned and record.language or nil, filtered = filtered }
end

--- Hand the superseded folder's settings to the one that replaced it, then
--- remove it. Only for a source that names its folder for the version it
--- holds; a devdocs docset was reinstalled in place and has nothing to clean.
local function supersede(item, held)
  if vim.fn.isdirectory(require("docshelf.common").data_folder() .. item.target) ~= 1 then
    return -- the install did not happen; leave what is there alone
  end
  if held.language then
    metadata.assign_language(item.target, held.language)
  end
  local ok, filter = pcall(require, "docshelf.filter")
  if ok and held.filtered then
    local active = vim.tbl_filter(function(name)
      return name ~= item.folder
    end, filter.active() or {})
    active[#active + 1] = item.target
    filter.set(active)
  end
  vim.system({ "rm", "-Rf", require("docshelf.common").data_folder() .. item.folder }, { text = true }):wait()
  metadata.forget(item.folder)
  if ok then
    filter.forget({ item.folder })
  end
end

--- Install everything the plan names, through the same queue as any other
--- install, and hand each superseded folder's settings to its replacement.
---@param items table[]
---@param slugs_to_mtimes table
---@param cont? fun()
function M.apply(items, slugs_to_mtimes, cont)
  local install = require("docshelf.install")
  local held, targets = {}, {}
  for _, item in ipairs(items) do
    if item.replaces then
      held[item.folder] = carried(item.folder)
    end
    targets[#targets + 1] = item.target
  end
  install.queue_install(targets, slugs_to_mtimes, function()
    for _, item in ipairs(items) do
      if item.replaces then
        supersede(item, held[item.folder])
      end
    end
    if cont then
      cont()
    end
  end)
end

-- ------------------------------------------------------------- the command

--- Check what is behind and install it. With no `only`, everything installed
--- is considered.
---@param opts? { only?: string[], quiet?: boolean, on_done?: fun(items: table[]) }
function M.run(opts)
  opts = opts or {}
  local install = require("docshelf.install")
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
  end, function(message)
    if not opts.quiet then
      notify(message, vim.log.levels.WARN)
    end
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
    group = vim.api.nvim_create_augroup("docshelf_update", { clear = true }),
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
