-- Folder names of installed sources.
--
-- A source installs into <data_folder>/<folder>. A devdocs source's folder is
-- its docset name (python~3.14), as it always was; a source from any other
-- origin appends "~~<origin>" (text~2.1~~hackage.haskell.org), so the same
-- docset from two origins never shares a folder. "~~" because elinks leaves
-- only letters, digits and "-._~" unencoded in the links it writes, and the
-- link fixer must find the folder's own path in them; a docset name never
-- holds two tildes in a row. The folder name is a
-- source's identity (filters, restrict_sources, the install manifest); what a
-- person sees is `display(folder)`, with the origin shown separately.
local M = {}

local devdocs_origin = require("docshelf.metadata").devdocs_origin

M.separator = "~~"

---@param slug string docset name, e.g. "text~2.1"
---@param origin? string short address; nil or devdocs.io for devdocs
function M.name(slug, origin)
  if origin == nil or origin == devdocs_origin then
    return slug
  end
  return slug .. M.separator .. origin
end

--- The docset name and origin a folder was named from.
---@return string slug, string origin
function M.split(folder)
  local slug, origin = folder:match("^(.-)~~([^~]+)$")
  if slug then
    return slug, origin
  end
  return folder, devdocs_origin
end

--- What a person sees for a folder: the docset name alone.
function M.display(folder)
  return (M.split(folder))
end

--- A path relative to the data folder (`<folder>/<page>`), with its folder
--- shown as `display(folder)`.
function M.display_path(path)
  local folder, rest = path:match("^([^/]+)(.*)$")
  return M.display(folder) .. rest
end

return M
