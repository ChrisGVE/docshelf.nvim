local common = require("docshelf.common")
local Snacks = require("snacks")

local common_layout_options = {
  preview = true,
  preset = "telescope",
}
local common_win_options = {
  preview = {
    wo = {
      number = true,
      relativenumber = false,
      signcolumn = "no",
      conceallevel = 2,
      concealcursor = "n",
      winfixbuf = true,
      list = false,
      wrap = false,
    },
  },
}

-- The layout comes from the call's opts, then from setup(), then the default.
-- A string is a snacks layout preset name ("ivy_split", "vertical"...), a table
-- is a full snacks layout config.
local function get_layout(opts)
  local layout = (opts and opts.layout) or (Config and Config.layout)
  if type(layout) == "string" then
    return { preset = layout }
  end
  return layout or common_layout_options
end

local function get_data_dirs(opts)
  local data_dir = common.data_folder()
  if not (opts and opts.restrict_sources) then
    return { data_dir }
  end
  local dirs = {}
  for _, source in ipairs(opts.restrict_sources) do
    local dir = data_dir .. source .. "/"
    if vim.fn.isdirectory(dir) == 1 then
      table.insert(dirs, dir)
    end
  end
  return dirs
end

local function format_entries(item, picker)
  local parts = vim.split(item.file, "/")
  -- take the last part and set it as the text
  local folder = parts[#parts - 1]
  local filename = parts[#parts]
  local docset, origin = require("docshelf.folders").split(folder)
  local filetype = vim.split(docset, "~")[1]
  local icon, hl = Snacks.util.icon(filetype, "filetype", {
    fallback = picker.opts.icons.files,
  })
  icon = Snacks.picker.util.align(icon, picker.opts.formatters.file.icon_width or 2)
  filename = filename:gsub("%.html%.md$", "")
  local new_item = {
    {
      icon,
      hl,
      virtual = true,
    },
    {
      docset .. " | ",
      "SnacksPickerSpecial",
      field = "file",
    },
  }
  new_item[#new_item + 1] = {
    common.filename_to_display(filename),
    "SnacksPickerFile",
    field = "file",
  }
  -- Where the source came from, dimmed at the right edge.
  new_item[#new_item + 1] = {
    col = 0,
    virt_text = { { origin, "SnacksPickerComment" } },
    virt_text_pos = "right_align",
    hl_mode = "combine",
  }
  return new_item
end

-- A grep match inside a page's "Visible links" footer is a link to the thing
-- searched for, not a mention of it: every page linking to RidgeCV would list
-- one (147 of 258 scikit_learn hits). At this point item.text is
-- "file:line:col:text".
local function drop_link_footer_matches(item)
  local text = item.text:sub(#item.file + 2):match("^%d+:%d+:(.*)$")
  if text and common.link_footer_prefix(text) then
    return false
  end
end

local function docshelf_open(opts)
  Snacks.picker.files({
    layout = get_layout(opts),
    win = common_win_options,
    dirs = get_data_dirs(opts),
    ft = { "markdown", "md" },
    confirm = function(picker, item)
      require("docshelf").open_doc_in_new_window(item.file)
    end,
    format = format_entries,
  })
end

local function docshelf_search(opts)
  Snacks.picker.grep({
    layout = get_layout(opts),
    win = common_win_options,
    dirs = get_data_dirs(opts),
    ft = { "markdown", "md" },
    transform = drop_link_footer_matches,
    confirm = function(picker, item)
      require("docshelf").open_doc_in_new_window(item.file)
    end,
    format = format_entries,
  })
end

-- The language picker: every offered name, narrowed by what is typed, with a
-- first row offering to take an unknown word as a new name (see
-- language_pick.lua). Live, so that row follows every keystroke.
---@param opts { folder: string, display: string, current: string, names: string[], on_choice: fun(name: string) }
local function pick_language(opts)
  Snacks.picker.pick({
    source = "docshelf_language",
    title = "Language of " .. opts.display .. " (now " .. opts.current .. ")",
    -- A list of names, not of documents: the "select" preset (prompt on top,
    -- no preview pane), never the layout chosen for reading pages, which puts
    -- the prompt at the bottom and shows a preview of nothing.
    layout = opts.layout or { preset = "select" },
    live = true,
    finder = function(_, ctx)
      local typed = ctx.filter.search
      if typed == "" then
        typed = ctx.filter.pattern
      end
      local rows = require("docshelf.language_pick").rows(opts.names, typed)
      return vim.tbl_map(function(row)
        return { text = row.name, name = row.name, add = row.add }
      end, rows)
    end,
    format = function(item)
      if item.add then
        return { { "+ add ", "SnacksPickerSpecial" }, { item.name, "SnacksPickerLabel" } }
      end
      return { { item.name, "SnacksPickerLabel" } }
    end,
    confirm = function(picker, item)
      picker:close()
      local name = item and item.name or vim.trim(picker.input.filter.search)
      if name ~= "" then
        opts.on_choice(name)
      end
    end,
  })
end

--- A dimmed right-aligned origin, so provenance shows wherever a docset does
--- without competing with its name.
---@param origin? string
local function origin_mark(origin)
  return {
    col = 0,
    virt_text = { { origin or "", "SnacksPickerComment" } },
    virt_text_pos = "right_align",
    hl_mode = "combine",
  }
end

-- The filter picker: the installed docsets, the active ones first, tab to tick
-- several. Each row reads `language | docset` with the origin dimmed at the
-- right, because the language is what a filter widens through -- so it belongs
-- where the choice is made.
--
-- The assign key relabels the docset under the cursor and redraws, so a docset
-- that came out Unknown can be fixed here rather than in another command. Its
-- hint goes in the title: snacks only shows a key's description behind `?`, and
-- a binding nobody can see is a binding nobody uses.
---@param opts { title: string, selected: string[]?, on_choice: fun(names: string[]), assign_key: string|false, layout?: table }
local function pick_sources(opts)
  local folders = require("docshelf.folders")
  local metadata = require("docshelf.metadata")
  local filter = require("docshelf.filter")

  local title = opts.title
  local keys = {}
  if opts.assign_key then
    keys[opts.assign_key] = { "assign_language", mode = { "n", "i" }, desc = "set this docset's language" }
    title = title .. " · " .. opts.assign_key .. " language"
  end

  -- Rebuilt on every refresh, so a language changed with the assign key shows
  -- at once -- including the docsets it now pulls in.
  local function build()
    local installed = filter.installed()
    return require("docshelf.filter_pick").rows(installed, metadata.installed_languages(installed), opts.selected)
  end

  Snacks.picker.pick({
    source = "docshelf_sources",
    title = title,
    -- A list of names, not of documents: prompt on top, no preview of nothing.
    layout = opts.layout or { preset = "select" },
    finder = build,
    format = function(item)
      -- A filled dot is what the filter holds, a hollow one what a language
      -- pulled in: searched too, but not chosen, and unticking it does nothing.
      local mark = { item.active == 1 and "● " or "  ", "SnacksPickerSpecial" }
      if item.via then
        mark = { "◦ ", "SnacksPickerComment" }
      end
      local row = {
        mark,
        { item.pad .. item.language, "SnacksPickerComment" },
        { " | ", "SnacksPickerDelim" },
        { folders.display(item.name), "SnacksPickerLabel" },
      }
      if item.via then
        table.insert(row, { "  via " .. folders.display(item.via), "SnacksPickerComment" })
      end
      table.insert(row, origin_mark(metadata.installed_origins({ item.name })[item.name]))
      return row
    end,
    win = { input = { keys = keys } },
    actions = {
      assign_language = function(picker, item)
        if not item then
          return
        end
        require("docshelf").assign_language(item.name, function(ok)
          if ok then
            picker:find({ refresh = true })
          end
        end)
      end,
    },
    confirm = function(picker)
      local names = vim.tbl_map(function(item)
        return item.name
      end, picker:selected({ fallback = true }))
      picker:close()
      vim.schedule(function()
        opts.on_choice(names)
      end)
    end,
  })
end

return {
  pick_language = pick_language,
  pick_sources = pick_sources,
  docshelf_open = docshelf_open,
  docshelf_search = docshelf_search,
  drop_link_footer_matches = drop_link_footer_matches,
}
