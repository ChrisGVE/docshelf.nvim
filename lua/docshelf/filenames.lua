-- File names of installed pages.
--
-- The installer writes one file per page and one per entry, named
-- "<name>#<path>" (os.File.ReadDir()#os/index#File.ReadDir), and the pickers
-- show the part before the first "#". Two entries whose names differ only in
-- case -- Go's File.ReadDir and File.Readdir -- get file names that differ only
-- in case too, and on a case-insensitive disk (macOS, Windows) the second one
-- overwrites the first: the page is gone without a word. python~3.14 lost 19
-- entries that way, numpy 11, haskell 8.
--
-- So an install first collects every file name it will write, finds the
-- names that have such a twin, and gives each twin a short prefix tag derived
-- from its exact spelling: "~1a2b3c4d~os.File.Readdir()#...". A prefix keeps
-- every "#" where the link fixer and the pickers expect it, and `display`
-- drops it again before a name is shown. The tag uses only characters elinks
-- leaves unencoded in the links it writes, so the link fixer finds the file.
local M = {}

-- A file name ends in ".html" and then ".html.md" once elinks has converted
-- it, and a file name holds at most 255 bytes.
local longest = 255 - #".html.md"

local tag_pattern = "^~%x%x%x%x%x%x%x%x~"

--- The plain file name for `name`: no "/" (it would be a folder) and no "'"
--- (it would break the shell command that converts the pages).
---@param name string
function M.stem(name)
  return (name:gsub("/", "_"):gsub("'", "_"):sub(1, longest))
end

--- The stems among `names` that another, differently spelled stem equals once
--- case is ignored.
---@param names string[]
---@return table<string, true>
function M.case_twins(names)
  local spellings = {}
  for _, name in ipairs(names) do
    local stem = M.stem(name)
    local folded = stem:lower()
    spellings[folded] = spellings[folded] or {}
    spellings[folded][stem] = true
  end
  local twins = {}
  for _, stems in pairs(spellings) do
    if vim.tbl_count(stems) > 1 then
      for stem in pairs(stems) do
        twins[stem] = true
      end
    end
  end
  return twins
end

--- A function naming files for one install whose twins are `twins`. Naming a
--- name it already produced gives that name back, which the link fixer relies
--- on: it passes names it read from links through it again.
---@param twins table<string, true>
---@return fun(name: string): string
function M.namer(twins)
  return function(name)
    local stem = M.stem(name)
    if twins[stem] then
      return ("~" .. vim.fn.sha256(stem):sub(1, 8) .. "~" .. stem):sub(1, longest)
    end
    return stem
  end
end

--- A file name as a person should see it: without a twin's tag. The name may
--- come behind its folder ("go/~1a2b3c4d~os.File.Readdir()"), as telescope
--- shows it.
---@param name string
function M.display(name)
  local folder, file = name:match("^([^/]*/)(.*)$")
  if not folder then
    folder, file = "", name
  end
  return folder .. file:gsub(tag_pattern, "")
end

return M
