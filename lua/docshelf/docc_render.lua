-- DocC render JSON turned into HTML.
--
-- A DocC site does not publish pages: it publishes one JSON document per page,
-- the "render JSON" its own JavaScript draws. That document is a small tree of
-- blocks (paragraph, codeListing, aside, table...) holding runs of inline
-- pieces (text, codeVoice, reference...), plus a table of references naming
-- every other page it links to. So a DocC source has no HTML to clean, the way
-- the Sphinx and pkg.go.dev sources do -- it has HTML to *write*, and this is
-- where it is written. The installer takes it from there exactly as it takes a
-- fetched page: elinks renders it, and the ids become the anchors a link lands
-- on.
--
-- Two rules run through the whole file, and they are what keeps it honest
-- against a schema Apple extends whenever it likes:
--
--  * A node this file does not know is never dropped. Its children are
--    rendered instead (`content`, `inlineContent`, `items`, `text`), so a
--    block added to DocC next year reads as plain prose here rather than
--    vanishing from the page.
--  * Every link is resolved by the caller, through `resolve`. This file knows
--    nothing about docsets, page keys or sites; the adapter passes in a
--    function that turns a reference identifier into an href, and returns nil
--    for a reference that is not a link at all.
local M = {}

local escapes = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" }

--- Text as HTML text: the three characters that would otherwise start a tag or
--- an entity.
---@param text string
function M.escape(text)
  return (tostring(text):gsub("[&<>]", escapes))
end

--- The same, for a value inside double quotes.
local function attribute(value)
  return (M.escape(value):gsub('"', "&quot;"))
end

--- An id an anchor can carry: DocC writes its headings' anchors already, and a
--- symbol page is named by its own identifier, but neither is guaranteed to be
--- free of the characters a URL fragment cannot hold.
local function anchor_id(text)
  return (tostring(text):gsub("[^%w%-_%.:%(%)]+", "-"):gsub("^%-+", ""):gsub("%-+$", ""))
end

-- ------------------------------------------------------------------- inline

local inline = {}

local function inline_list(nodes, ctx)
  local out = {}
  for _, node in ipairs(nodes or {}) do
    out[#out + 1] = M.inline(node, ctx)
  end
  return table.concat(out)
end

--- One inline node as HTML.
---@param node table
---@param ctx { resolve: fun(identifier: string): string?, reference: fun(identifier: string): table? }
function M.inline(node, ctx)
  if type(node) == "string" then
    return M.escape(node)
  end
  if type(node) ~= "table" then
    return ""
  end
  local handler = inline[node.type]
  if handler then
    return handler(node, ctx)
  end
  -- Unknown inline node: whatever it holds is still words worth reading.
  if node.inlineContent then
    return inline_list(node.inlineContent, ctx)
  end
  if node.content then
    return inline_list(node.content, ctx)
  end
  return node.text and M.escape(node.text) or ""
end

inline.text = function(node)
  return M.escape(node.text or "")
end

inline.codeVoice = function(node)
  return "<code>" .. M.escape(node.code or "") .. "</code>"
end

inline.emphasis = function(node, ctx)
  return "<em>" .. inline_list(node.inlineContent, ctx) .. "</em>"
end

inline.strong = function(node, ctx)
  return "<strong>" .. inline_list(node.inlineContent, ctx) .. "</strong>"
end

inline.inlineHead = inline.strong

inline.strikethrough = function(node, ctx)
  return "<s>" .. inline_list(node.inlineContent, ctx) .. "</s>"
end

inline.superscript = function(node, ctx)
  return "<sup>" .. inline_list(node.inlineContent, ctx) .. "</sup>"
end

inline.subscript = function(node, ctx)
  return "<sub>" .. inline_list(node.inlineContent, ctx) .. "</sub>"
end

inline.newLine = function()
  return "<br>"
end

--- The words a reference shows. DocC lets a link override the title of what it
--- points at ("see the guide" rather than "Getting started"), in two shapes:
--- a plain string, and a run of inline nodes.
local function reference_title(node, ctx)
  if node.overridingTitleInlineContent then
    return inline_list(node.overridingTitleInlineContent, ctx)
  end
  if node.overridingTitle then
    return M.escape(node.overridingTitle)
  end
  local target = ctx.reference and ctx.reference(node.identifier)
  if target then
    if target.title then
      return M.escape(target.title)
    end
    if target.fragments then
      return M.escape(M.fragment_text(target.fragments))
    end
  end
  return M.escape(node.identifier or "")
end

inline.reference = function(node, ctx)
  local title = reference_title(node, ctx)
  local href = ctx.resolve and ctx.resolve(node.identifier)
  if not href then
    -- A reference with nowhere to go is still the name of something: it reads
    -- as the name rather than as a link that goes to the page it is on.
    return title
  end
  return '<a href="' .. attribute(href) .. '">' .. title .. "</a>"
end

inline.link = function(node, ctx)
  local href = node.destination or (ctx.resolve and ctx.resolve(node.identifier))
  local title = node.title and M.escape(node.title) or inline_list(node.inlineContent, ctx)
  if title == "" then
    title = M.escape(href or "")
  end
  if not href then
    return title
  end
  return '<a href="' .. attribute(href) .. '">' .. title .. "</a>"
end

inline.image = function(node, ctx)
  local target = ctx.reference and ctx.reference(node.identifier)
  local src = ctx.resolve and ctx.resolve(node.identifier)
  local alt = target and target.alt or node.identifier or ""
  if not src then
    -- An image the site does not say where to find is described rather than
    -- linked: an <img> with no src is a broken link in every reader.
    return alt ~= "" and ("<em>" .. M.escape(alt) .. "</em>") or ""
  end
  return '<img src="' .. attribute(src) .. '" alt="' .. attribute(alt) .. '">'
end

-- -------------------------------------------------------------------- blocks

local blocks = {}

local function block_list(nodes, ctx)
  local out = {}
  for _, node in ipairs(nodes or {}) do
    out[#out + 1] = M.block(node, ctx)
  end
  return table.concat(out, "\n")
end

--- One block node as HTML.
---@param node table
---@param ctx table see M.inline
function M.block(node, ctx)
  if type(node) ~= "table" then
    return ""
  end
  local handler = blocks[node.type]
  if handler then
    return handler(node, ctx)
  end
  -- Unknown block: its children are rendered, so a block DocC adds later still
  -- reads as prose rather than disappearing.
  if node.content then
    return block_list(node.content, ctx)
  end
  if node.inlineContent then
    return "<p>" .. inline_list(node.inlineContent, ctx) .. "</p>"
  end
  if node.items then
    return blocks.unorderedList(node, ctx)
  end
  return ""
end

blocks.paragraph = function(node, ctx)
  return "<p>" .. inline_list(node.inlineContent, ctx) .. "</p>"
end

blocks.heading = function(node)
  -- Levels below 2: a page has one <h1>, its own title, written by M.page.
  local level = math.min(math.max(tonumber(node.level) or 2, 2), 6)
  local id = node.anchor and anchor_id(node.anchor) or nil
  local tag = "h" .. level
  return "<"
    .. tag
    .. (id and id ~= "" and (' id="' .. attribute(id) .. '"') or "")
    .. ">"
    .. M.escape(node.text or "")
    .. "</"
    .. tag
    .. ">"
end

blocks.codeListing = function(node)
  local code = table.concat(node.code or {}, "\n")
  local syntax = node.syntax and (' class="language-' .. attribute(node.syntax) .. '"') or ""
  return "<pre><code" .. syntax .. ">" .. M.escape(code) .. "</code></pre>"
end

blocks.thematicBreak = function()
  return "<hr>"
end

--- A note, a warning, an "Important": DocC calls them asides and names them.
blocks.aside = function(node, ctx)
  local name = node.name or node.style or "Note"
  return "<blockquote><p><strong>"
    .. M.escape(name)
    .. "</strong></p>\n"
    .. block_list(node.content, ctx)
    .. "</blockquote>"
end

local function list_items(node, ctx)
  local out = {}
  for _, item in ipairs(node.items or {}) do
    out[#out + 1] = "<li>" .. block_list(item.content or item, ctx) .. "</li>"
  end
  return table.concat(out, "\n")
end

blocks.unorderedList = function(node, ctx)
  return "<ul>\n" .. list_items(node, ctx) .. "\n</ul>"
end

blocks.orderedList = function(node, ctx)
  local start = tonumber(node.start)
  local open = start and start ~= 1 and ('<ol start="' .. start .. '">') or "<ol>"
  return open .. "\n" .. list_items(node, ctx) .. "\n</ol>"
end

--- A term list is a definition list: each item is a term and what it means.
blocks.termList = function(node, ctx)
  local out = { "<dl>" }
  for _, item in ipairs(node.items or {}) do
    out[#out + 1] = "<dt>" .. inline_list(item.term and item.term.inlineContent, ctx) .. "</dt>"
    out[#out + 1] = "<dd>" .. block_list(item.definition and item.definition.content, ctx) .. "</dd>"
  end
  out[#out + 1] = "</dl>"
  return table.concat(out, "\n")
end

blocks.table = function(node, ctx)
  local out = { "<table>" }
  local rows = node.rows or {}
  local first = 1
  if node.header == "row" and rows[1] then
    local cells = {}
    for _, cell in ipairs(rows[1]) do
      cells[#cells + 1] = "<th>" .. block_list(cell, ctx) .. "</th>"
    end
    out[#out + 1] = "<tr>" .. table.concat(cells) .. "</tr>"
    first = 2
  end
  for i = first, #rows do
    local cells = {}
    for _, cell in ipairs(rows[i]) do
      cells[#cells + 1] = "<td>" .. block_list(cell, ctx) .. "</td>"
    end
    out[#out + 1] = "<tr>" .. table.concat(cells) .. "</tr>"
  end
  out[#out + 1] = "</table>"
  return table.concat(out, "\n")
end

--- Tabs are a reading device, not a structure: a buffer has no tabs, so each
--- one becomes a section with its title above it.
blocks.tabNavigator = function(node, ctx)
  local out = {}
  for _, tab in ipairs(node.tabs or {}) do
    out[#out + 1] = "<h3>" .. M.escape(tab.title or "") .. "</h3>"
    out[#out + 1] = block_list(tab.content, ctx)
  end
  return table.concat(out, "\n")
end

--- A row of columns reads as one column after another.
blocks.row = function(node, ctx)
  local out = {}
  for _, column in ipairs(node.columns or {}) do
    out[#out + 1] = block_list(column.content, ctx)
  end
  return table.concat(out, "\n")
end

--- An image is a block of its own as well as something written inside a
--- sentence; both are the same picture, and inline.image knows where to find
--- it.
blocks.image = function(node, ctx)
  local html = inline.image(node, ctx)
  return html ~= "" and ("<p>" .. html .. "</p>") or ""
end

blocks.small = function(node, ctx)
  return "<p><small>" .. inline_list(node.inlineContent, ctx) .. "</small></p>"
end

-- ------------------------------------------------------------- declarations

--- The text of a run of syntax tokens: a declaration, or the fragments that
--- name a symbol in a link.
---@param tokens table[]
function M.fragment_text(tokens)
  local out = {}
  for _, token in ipairs(tokens or {}) do
    out[#out + 1] = token.text or ""
  end
  return table.concat(out)
end

local function declarations(section, ctx)
  local out = {}
  for _, declaration in ipairs(section.declarations or {}) do
    local platforms = declaration.platforms
        and #declaration.platforms > 0
        and (" <!-- " .. table.concat(declaration.platforms, ", ") .. " -->")
      or ""
    out[#out + 1] = "<pre><code>" .. M.escape(M.fragment_text(declaration.tokens)) .. "</code></pre>" .. platforms
  end
  return table.concat(out, "\n")
end

local function parameters(section, ctx)
  local out = { "<h2>Parameters</h2>", "<dl>" }
  for _, parameter in ipairs(section.parameters or {}) do
    out[#out + 1] = "<dt><code>" .. M.escape(parameter.name or "") .. "</code></dt>"
    out[#out + 1] = "<dd>" .. block_list(parameter.content, ctx) .. "</dd>"
  end
  out[#out + 1] = "</dl>"
  return table.concat(out, "\n")
end

local sections = {
  content = function(section, ctx)
    return block_list(section.content, ctx)
  end,
  declarations = declarations,
  parameters = parameters,
  -- "mentions" is a list of pages that mention this symbol; it is navigation
  -- around the page rather than the page, and the picker is already the way
  -- to reach another page.
  mentions = function()
    return ""
  end,
}

-- ------------------------------------------------------------- whole a page

--- The platforms a symbol is available on, as one line ("iOS 13.0+").
local function availability(platforms)
  local out = {}
  for _, platform in ipairs(platforms or {}) do
    if not platform.unavailable and platform.name then
      local since = platform.introducedAt and (" " .. platform.introducedAt .. "+") or ""
      out[#out + 1] = platform.name .. since .. (platform.deprecated and " (deprecated)" or "")
    end
  end
  return table.concat(out, ", ")
end

--- A list of references as links, each with its abstract: this is how a page
--- of DocC offers the pages below it (its topics), what it conforms to, and
--- what to read next.
local function reference_list(identifiers, ctx)
  local out = { "<ul>" }
  for _, identifier in ipairs(identifiers or {}) do
    local target = ctx.reference and ctx.reference(identifier)
    local href = ctx.resolve and ctx.resolve(identifier)
    local title = target and (target.title or (target.fragments and M.fragment_text(target.fragments)))
    title = M.escape(title or identifier)
    local abstract = target and target.abstract and inline_list(target.abstract, ctx) or ""
    if abstract ~= "" then
      abstract = " — " .. abstract
    end
    if href then
      out[#out + 1] = '<li><a href="' .. attribute(href) .. '">' .. title .. "</a>" .. abstract .. "</li>"
    else
      out[#out + 1] = "<li>" .. title .. abstract .. "</li>"
    end
  end
  out[#out + 1] = "</ul>"
  return table.concat(out, "\n")
end

local function grouped_sections(list, ctx, default_title)
  local out = {}
  for _, section in ipairs(list or {}) do
    local identifiers = section.identifiers
    if identifiers and #identifiers > 0 then
      out[#out + 1] = "<h2>" .. M.escape(section.title or default_title) .. "</h2>"
      out[#out + 1] = reference_list(identifiers, ctx)
    end
  end
  return table.concat(out, "\n")
end

--- A whole DocC page as HTML: its title, what it is, what it declares, its
--- prose, and the pages it leads to.
---@param page table the render JSON, decoded
---@param ctx { resolve: fun(identifier: string): string?, reference: fun(identifier: string): table? }
---@return string
function M.page(page, ctx)
  local metadata = page.metadata or {}
  local title = metadata.title
    or (metadata.fragments and M.fragment_text(metadata.fragments))
    or (page.identifier and page.identifier.url)
    or ""
  local out = {}
  out[#out + 1] = "<h1>" .. M.escape(title) .. "</h1>"
  local role = metadata.roleHeading
  if role and role ~= "" then
    out[#out + 1] = "<p><em>" .. M.escape(role) .. "</em></p>"
  end
  if page.abstract then
    out[#out + 1] = "<p>" .. inline_list(page.abstract, ctx) .. "</p>"
  end
  local platforms = availability(metadata.platforms)
  if platforms ~= "" then
    out[#out + 1] = "<p><small>Available on " .. M.escape(platforms) .. "</small></p>"
  end
  for _, section in ipairs(page.primaryContentSections or {}) do
    local handler = sections[section.kind]
    local html = handler and handler(section, ctx) or M.block(section, ctx)
    if html ~= "" then
      out[#out + 1] = html
    end
  end
  -- Tutorial and article pages put their prose in `sections` instead.
  if page.sections and #page.sections > 0 then
    local html = block_list(page.sections, ctx)
    if html ~= "" then
      out[#out + 1] = html
    end
  end
  local relationships = grouped_sections(page.relationshipsSections, ctx, "Relationships")
  if relationships ~= "" then
    out[#out + 1] = relationships
  end
  local topics = grouped_sections(page.topicSections, ctx, "Topics")
  if topics ~= "" then
    out[#out + 1] = topics
  end
  local see_also = grouped_sections(page.seeAlsoSections, ctx, "See Also")
  if see_also ~= "" then
    out[#out + 1] = see_also
  end
  return table.concat(out, "\n")
end

M._internal = {
  anchor_id = anchor_id,
  availability = availability,
}

return M
