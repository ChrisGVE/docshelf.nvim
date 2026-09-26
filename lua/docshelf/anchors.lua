--- Anchor naming shared by the sources whose pages come from a documentation
--- generator (Maven Central's javadoc/scaladoc/Dokka, gemdocs.org's YARD).
---
--- The installer splits a page into one file per entry, finding each entry's
--- section by its id and naming it by the text right after that id. Generator
--- pages defeat both: ids hold characters a link writes escaped ("of(T)",
--- "&-instance_method"), and many anchors are empty tags whose next text is
--- something else. So every id is made plain text by the source's own rule,
--- every link's anchor with it, and a heading naming the entry is put before
--- each anchor an entry lands on.
local M = {}

local function escape(text)
  return (text:gsub('[&<>"]', { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" }))
end

--- Every id of `body` made plain by `plain`, an old <a name> made an id, and
--- a heading naming the entry put before each anchor an entry lands on.
---@param body string
---@param names? table<string, string> entry name by plain id
---@param plain fun(id: string): string
function M.name_the_anchors(body, names, plain)
  body = body:gsub("<[aA](%s[^>]*)>", function(attributes)
    if attributes:match("%s[iI][dD]=") then
      return nil
    end
    return "<a" .. attributes:gsub('(%s)[nN][aA][mM][eE]="', '%1id="') .. ">"
  end)
  local landed = {}
  return (
    body:gsub('<(%w+)([^>]-)%s[iI][dD]="([^"]*)"([^>]*)>', function(tag, before, id, after)
      local plain_id = plain(id)
      local name = names and names[plain_id]
      if name and not landed[plain_id] then
        landed[plain_id] = true
        return '<h4 id="' .. plain_id .. '">' .. escape(name) .. "</h4><" .. tag .. before .. after .. ">"
      end
      return "<" .. tag .. before .. ' id="' .. plain_id .. '"' .. after .. ">"
    end)
  )
end

--- Every link's anchor made plain by `plain`, unless it leads to another site.
---@param body string
---@param plain fun(id: string): string
function M.plain_fragments(body, plain)
  return (
    body:gsub('(%s[hH][rR][eE][fF]=")([^"#]*)#([^"]*)"', function(attribute, target, anchor)
      if target:match("^%a[%w+.-]*:") or target:match("^//") then
        return nil
      end
      return attribute .. target .. "#" .. plain(anchor) .. '"'
    end)
  )
end

return M
