-- A source filter that outlives the picker.
--
-- With a handful of docsets installed, every picker can list all of them. With
-- several dozen -- which is what installing from registries leads to -- a list
-- of everything is no longer a list of what you need. The filter narrows every
-- surface at once: pick python~3.14, numpy and pandas, and from then on open,
-- grep and install only look there, however often the picker is closed and
-- reopened. It lives for this Neovim session only, so a Rust session and a
-- Python session each keep their own.
--
-- A selected language reference also brings in the other installed docsets of
-- its language: python~3.14 adds numpy and scikit_learn, while numpy selected
-- alone stays alone. Another version of the same language does not come along
-- -- python~3.13 is a different reference, not something written in 3.14.
--
-- Narrowing is not only about reading a shorter list: every installed docset is
-- plain files and a grep is one ripgrep over all of them, so the filter is also
-- what keeps searching fast as the collection grows.
--
-- The functions that take `installed` and `links` are pure, so they can be
-- tested without a data folder; the ones that read the world fill those in.

local M = {}

--- The active filter: the docsets picked directly, sorted. `nil` means every
--- installed docset, which is also what an empty selection means -- filtering
--- to nothing would leave every picker empty with no way to tell why.
---@type string[]?
local active = nil

--- The docsets installed right now, as folder names.
---@return string[]
function M.installed()
  local names = {}
  local ok, iter = pcall(vim.fs.dir, require("apidocs.common").data_folder())
  if not ok then
    return names
  end
  for name, kind in iter do
    if kind == "directory" then
      table.insert(names, name)
    end
  end
  table.sort(names)
  return names
end

--- What each installed docset is written in, from the install manifest.
---@param installed string[]
---@return table<string, { language?: string, kind?: string }>
local function language_links(installed)
  return require("apidocs.metadata").installed_languages(installed)
end

--- The filter as it was picked, or nil when none is set. The docsets a
--- language pulls in are not in here: they follow from it, and recomputing
--- them means a docset installed after the filter was set is picked up.
---@return string[]?
function M.active()
  return active and vim.deepcopy(active) or nil
end

--- Set the filter. An empty selection clears it.
---@param names string[]
function M.set(names)
  if not names or #names == 0 then
    active = nil
    return
  end
  active = vim.deepcopy(names)
  table.sort(active)
end

--- Clear the filter: every installed docset again.
function M.clear()
  active = nil
end

--- Drop docsets from the filter -- called when they are uninstalled, so the
--- filter never points at a folder that is gone. Emptying it clears it.
---@param names string[]
function M.forget(names)
  if not active then
    return
  end
  active = vim.tbl_filter(function(name)
    return not vim.tbl_contains(names, name)
  end, active)
  if #active == 0 then
    active = nil
  end
end

--- The docsets a selection actually covers: the ones picked, plus the ones
--- their languages pull in, sorted.
---@param sources string[]
---@param installed string[]
---@param links? table<string, table>
---@return string[]
function M.widen(sources, installed, links)
  local pulled = require("apidocs.languages").pulled_in(sources, installed, links)
  local all = vim.list_extend(vim.deepcopy(sources), pulled)
  table.sort(all)
  return all
end

--- The docsets a selection pulls in through its languages, without the ones
--- picked directly. Pickers show these differently -- they are searched, but
--- they were not chosen.
---@param sources string[]
---@param installed string[]
---@param links? table<string, table>
---@return string[]
function M.pulled_in(sources, installed, links)
  return require("apidocs.languages").pulled_in(sources, installed, links)
end

--- Resolve the filter into `restrict_sources`, which every picker already
--- understands -- so the filter reaches snacks, telescope and ui_select
--- without any of them knowing it exists.
---
--- The options are left untouched when the caller named its own sources
--- (explicit beats implicit), when `follow_filter = false` asks for everything
--- this once, or when no filter is set.
---@param opts? table
---@param installed? string[]
---@param links? table<string, table>
---@return table
function M.restrict(opts, installed, links)
  local resolved = vim.tbl_extend("force", {}, opts or {})
  if resolved.restrict_sources or resolved.follow_filter == false or not active then
    return resolved
  end
  installed = installed or M.installed()
  resolved.restrict_sources = M.widen(active, installed, links)
  return resolved
end

return M
