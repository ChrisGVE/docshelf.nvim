local function data_folder()
  return vim.fn.stdpath("data") .. "/docshelf-data/"
end

-- https://stackoverflow.com/a/34953646/516188
local function escape_pattern(text)
  return text:gsub("([^%w])", "%%%1")
end

-- The "Visible links" footer elinks appends to each page lists local links in
-- two shapes: "   3. local://…", or, when the link has a description on the line
-- before (rust does this), "\tlocal://…". Returns the matched prefix, or nil.
-- Following a link and filtering search results both rely on it.
local function link_footer_prefix(line)
  return string.match(line, "^%s+%d+%. local://") or string.match(line, "^\tlocal://")
end

local function load_doc_in_buffer(buf, filepath)
  if vim.fn.filereadable(filepath) == 1 then
    local lines = {}
    for line in io.lines(filepath) do
      -- nbsp so that neovim doesn't highlight this as a quoted paragraph
      table.insert(lines, (line:gsub("^    ", "    ")))
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    vim.bo[buf].filetype = "markdown"
  else
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "File not readable: " .. filepath })
  end
end

local function buf_view_switch_to_new(new_buf)
  vim.wo.winfixbuf = false
  vim.api.nvim_win_set_buf(0, new_buf)
  vim.api.nvim_set_option_value("modifiable", false, { buf = 0 })
  vim.wo.winfixbuf = true
  vim.wo.wrap = false
  vim.bo.modified = false

  vim.keymap.set("n", "<C-o>", function()
    vim.wo.winfixbuf = false
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-o>", true, false, true), "n", true)
    vim.defer_fn(function()
      vim.wo.winfixbuf = true
    end, 100)
  end, { buffer = true })
end

-- Splits a local:// link target, "<choice>/<file name>[#<section>]", into
-- the file name and the section. A file name holds one "#" ("name#page") or
-- two (Lua's "Class#method" pages), and a section is a heading's text, which
-- may hold "#" itself (Scala's `#::`): so the file name is the longest prefix
-- that names a file, never a count of "#". `readable(file)` answers for a
-- target without ".html.md". Nothing on disk: "name#page", the rest the section.
local function split_local_target(target, readable)
  local parts = vim.split(target, "#", { plain = true })
  for k = #parts, 2, -1 do
    local file = table.concat(parts, "#", 1, k)
    if readable(file) then
      local section = k < #parts and table.concat(parts, "#", k + 1) or nil
      return file, section
    end
  end
  local section = #parts > 2 and table.concat(parts, "#", 3) or nil
  return table.concat(parts, "#", 1, math.min(2, #parts)), section
end

-- Moves the cursor to the first line holding `section` as plain text (a
-- heading may hold ".", "[", "/" or "\\"), and puts it at the top. The
-- pattern goes in the search register, so "n" finds the next one.
local function find_section(section)
  local pattern = "\\V" .. vim.fn.escape(section, "\\")
  vim.fn.setreg("/", pattern)
  if vim.fn.search(pattern, "cw") > 0 then
    vim.cmd("norm! zt")
  end
end

local function open_doc_in_cur_window(docs_path)
  local buf = vim.api.nvim_create_buf(true, false)
  local follow_link_keymap = Config and Config.follow_link_keymap or "<C-]>"
  vim.api.nvim_win_set_buf(0, buf)
  vim.wo.conceallevel = 2
  vim.wo.concealcursor = "n"
  vim.wo.list = false
  load_doc_in_buffer(buf, docs_path)
  vim.api.nvim_set_option_value("modifiable", false, { buf = 0 })
  vim.wo.wrap = false
  vim.bo.modified = false

  vim.keymap.set("n", follow_link_keymap, function()
    local line = vim.api.nvim_buf_get_lines(0, vim.fn.line(".") - 1, vim.fn.line("."), false)[1]
    local m = link_footer_prefix(line)
    if m then
      -- when parsing the local:// url, drop "<tab>+" text at the end,
      -- we add this marker when we can't resolve the ID reference
      local target = line:sub(#m + 1):gsub("\t%+.+$", "")
      local file, section = split_local_target(target, function(f)
        return vim.fn.filereadable(data_folder() .. f .. ".html.md") == 1
      end)
      local new_buf = vim.api.nvim_create_buf(true, false)
      load_doc_in_buffer(new_buf, data_folder() .. file .. ".html.md")
      buf_view_switch_to_new(new_buf)
      if section then
        find_section(section)
      end
    end
  end, { buf = buf })
end

local function open_doc_in_new_window(docs_path)
  -- create a new window and use winfixbuf on it, because i'll set
  -- conceallevel, and that's tied to the window (not the buffer),
  -- and is very invasive. bufhidden is to enable us to close the window
  -- and have the buffer be closed too -- further tying window & buffer together.
  vim.cmd([[100vsplit]])
  open_doc_in_cur_window(docs_path)
  vim.wo.winfixbuf = true
  vim.bo.bufhidden = "delete"
  local desc = require("docshelf.filenames").display(vim.split(docs_path:match("([^/]+)$"), "#")[1])
  vim.api.nvim_buf_set_name(0, desc)
end

-- convert filename to picker display string
local function filename_to_display(filename)
  local components = vim.split(filename, "#")
  local display = require("docshelf.filenames").display(components[1])
  -- little hack: In some languages the filename contains "Class#method", which messes
  -- up our "#" - separated schema. So if there are 4 "components" in the filename,
  -- the first two (separated by "#") have to be the actual key to display.
  if #components == 4 then
    display = display .. "#" .. components[2]
  end
  return display
end

return {
  data_folder = data_folder,
  escape_pattern = escape_pattern,
  link_footer_prefix = link_footer_prefix,
  load_doc_in_buffer = load_doc_in_buffer,
  open_doc_in_cur_window = open_doc_in_cur_window,
  open_doc_in_new_window = open_doc_in_new_window,
  filename_to_display = filename_to_display,
  split_local_target = split_local_target,
  find_section = find_section,
}
