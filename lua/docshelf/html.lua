--- Reading text out of HTML, shared by the sources that turn a page's own
--- words into entry names (Dash page titles, MetaCPAN headings).
local M = {}

-- The named entities those words actually use; any other is written as a
-- number, which `decode_entities` reads whatever it is.
local named_entities = {
  amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ",
  mdash = "—", ndash = "–", hellip = "…", lsquo = "‘", rsquo = "’",
  ldquo = "“", rdquo = "”", copy = "©", reg = "®", trade = "™",
}

--- `text` with its character references written as the characters. An
--- unknown named one is left as it is.
---@param text string
function M.decode_entities(text)
  return (
    text:gsub("&(#?[xX]?)(%w+);", function(kind, value)
      local number = (kind == "#" and tonumber(value)) or ((kind == "#x" or kind == "#X") and tonumber(value, 16))
      if number then
        return vim.fn.nr2char(number, true)
      end
      return kind == "" and named_entities[value] or nil
    end)
  )
end

--- The words of an HTML fragment: its tags dropped, its references decoded,
--- its runs of white space made one space.
---@param fragment string
function M.text(fragment)
  return vim.trim(M.decode_entities(fragment:gsub("<[^>]*>", "")):gsub("%s+", " "))
end

return M
