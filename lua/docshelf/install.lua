local common = require("docshelf.common")
local sections = require("docshelf.sections")
local filenames = require("docshelf.filenames")
local install_queue = require("docshelf.install_queue")
local folders = require("docshelf.folders")
-- Source adapters by origin, and the settings that govern them.
local sources = require("docshelf.sources")
local metadata = require("docshelf.metadata")
-- Coroutine helpers: long work that keeps the editor responsive.
local async = require("docshelf.async")
-- Searching the registries behind the sources, and the rows that come back.
local registry = require("docshelf.registry")
local install_pick = require("docshelf.install_pick")

-- docs.json entries by slug, filled by fetch_slugs_and_mtimes_and_then
local catalogue = {}

-- Installing is long: a large source means thousands of pages to prepare and
-- convert. The work runs in a coroutine that hands control back to the editor
-- between batches, so Neovim stays responsive, and reports its stage in one
-- notification that each update replaces (`id` is honoured by snacks.nvim).
local queue -- set below, once apidoc_install exists

local function progress(choice, text)
  local position = queue and queue:position(choice)
  local prefix = position and ("docshelf " .. position .. " ") or "docshelf "
  vim.notify(prefix .. folders.display(choice) .. ": " .. text, vim.log.levels.INFO, { id = "docshelf_install_" .. choice, title = "docshelf" })
end

local run = async.run
local yield_to_editor = async.yield_to_editor

local function count_files(dir, suffix)
  local count = 0
  local fs = vim.uv.fs_scandir(dir)
  while fs do
    local name = vim.uv.fs_scandir_next(fs)
    if not name then
      break
    end
    if vim.endswith(name, suffix) then
      count = count + 1
    end
  end
  return count
end

local system_async = async.system

local function fetch_slugs_and_mtimes_and_then(cont)
  vim.system({"curl", "-L", "https://devdocs.io/docs.json"}, {text=true}, vim.schedule_wrap(function(res)
    local data = vim.fn.json_decode(res.stdout)
    local slugs_to_mtimes = {}
    for _, doc in ipairs(data) do
      slugs_to_mtimes[doc['slug']] = doc['mtime']
      catalogue[doc['slug']] = doc
    end
    cont(slugs_to_mtimes)
  end))
end

-- if the line contains table cells it's sensitive to alignment...
-- in that case compensate the neovim conceal that hides the ` and other characters
-- by adding extra spaces not to break the table borders alignment.
local function add_spaces_to_compensate_conceals_cols(lines)
  local lines_str = vim.fn.join(lines, "\n")

  local query = vim.treesitter.query.parse('markdown_inline', [[[
    (code_span_delimiter) (emphasis_delimiter)
    (full_reference_link
      [
        "["
      ])
     (shortcut_link
       [
         "["
       ])
     (collapsed_reference_link
       [
         "["
       ])
     (inline_link
       [
         "["
         "("
         (link_destination)
       ])
      (image
        [
          "!"
          "["
          "("
          (link_destination)
        ])
    ] @concealed]])

  local parser = vim.treesitter.get_string_parser(lines_str, "markdown")
  parser:parse(true)

  parser:for_each_tree(function(tree)
    local pos_to_insert = {}
    for id, node, metadata in query:iter_captures(tree:root(), lines) do
      local row, col, bytes = node:start()
      if lines[row+1]:match("│") then
        table.insert(pos_to_insert, {row, col, bytes})
      end
    end
    -- go from the end because inserting is going to move offsets
    for i = #pos_to_insert, 1, -1 do
      local row, col, bytes = unpack(pos_to_insert[i])
      lines[row+1] = lines[row+1]:sub(1, col) .. " " .. lines[row+1]:sub(col+1)
    end
  end)

  local lines_str = vim.fn.join(lines, "\n")

  local query = vim.treesitter.query.parse('markdown_inline', [[[
    (full_reference_link
      [
        "]"
      ])
     (shortcut_link
       [
         "]"
       ])
     (collapsed_reference_link
       [
         "]"
       ])
     (inline_link
       [
         "]"
         ")"
       ])
      (image
        [
          "]"
          ")"
        ])
    ] @concealed]])

  local parser = vim.treesitter.get_string_parser(lines_str, "markdown")
  parser:parse(true)
  parser:for_each_tree(function(tree)

    local pos_to_insert = {}
    for id, node, metadata in query:iter_captures(tree:root(), lines) do
      local row, col, bytes = node:end_()
      if lines[row+1]:match("│") then
        table.insert(pos_to_insert, {row, col, bytes})
      end
    end
    -- go from the end because inserting is going to move offsets
    for i = #pos_to_insert, 1, -1 do
      local row, col, bytes = unpack(pos_to_insert[i])
      lines[row+1] = lines[row+1]:sub(1, col) .. " " .. lines[row+1]:sub(col+1)
    end
  end)

  return lines
end

-- elinks percent-encodes everything outside the unreserved set, so a page
-- whose name holds a non-ASCII character comes back as its UTF-8 bytes
-- ("Why not%e2%80%a6"). Decoding only a handful of escapes left those links
-- pointing at a file name that does not exist, and they stayed raw file://
-- addresses; decoding every escape puts the name back byte for byte.
local function urldecode(url)
  return (url:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

local function fix_file_links_resolve_fname(choice, path_to_name, file_guessed_subpath_str, link_target, name_file)
  local name = path_to_name[file_guessed_subpath_str .. "/" .. link_target] or path_to_name[link_target]
  if name ~= nil then
    if #file_guessed_subpath_str > 0 then
      return "local://" .. choice .. "/", name_file(name .. "#" .. file_guessed_subpath_str .. "/" .. link_target)
    else
      return "local://" .. choice .. "/", name_file(name .. "#" .. link_target)
    end
  end
  return nil, nil
end

local function fix_file_links(fname, lines, target_path, choice, path_to_name,
    name_and_id_to_string_nearby, orig_path, orig_containing_path, name_file)
  local changes = false
  for i = #lines, 1, -1 do
    -- elinks right-aligns link numbers to four columns, so from 1000 on there is
    -- no leading space
    local l, m = lines[i]:match("^( *%d+%. )(.*)$")
    if m == nil and i > 1 and lines[i-1]:match("^ *%d+%. .*$") and vim.startswith(lines[i], "\t") then
      -- sometimes the format is not "number. link", but "number. desc\n\tlink". maybe when the link has
      -- a description? this happens with rust
      l, m = lines[i]:match("^(\t)(.*)$")
    end
    -- remove the path prefix, which could be the folder in which we store the files, or
    -- any parent of it, in case it's a link to '../../filename'
    if m ~= nil and m:match("^file://") then
      local file_guessed_subpath_str = orig_path:gsub("/[^/]+$", "") -- take the parent the first time, it's the filename
      if not orig_path:match("/") then
        -- completing the gsub before.. no child folder. remove the filename
        file_guessed_subpath_str = ""
      end
      local prefix = "file://" .. target_path
      -- elinks escapes the folder's own name too ("@" is "%40"), so the prefix
      -- is looked for in the decoded link
      local decoded = urldecode(m)
      -- if the link points to target_path/orig_subfolder/../../ then i must use orig_path/../../
      while #prefix > 0 do
        -- take the parent folder of the prefix until it is a prefix of the link.
        if decoded:match("^" .. common.escape_pattern(prefix)) then
          break
        end
        -- everytime i take the parent of prefix, take the parent of orig_path too
        prefix = prefix:gsub("/[^/]+$", "")
        if file_guessed_subpath_str:match("/") then
          file_guessed_subpath_str = file_guessed_subpath_str:gsub("/[^/]+$", "")
        else
          file_guessed_subpath_str = ""
        end
      end

      local link_target = decoded:gsub("^" .. common.escape_pattern(prefix), "")
      local file_id = vim.split(link_target, "#")
      if #file_id == 4 then
        -- it's a link to the same file, which was already properly named... "name#pa#th#id"
        -- the trick is that if we're a file split from a larger file and we're pointing back
        -- to ourself, we likely want to point back to the original large file, not to us,
        -- which are the smaller split file.
        local link_file = file_id[2] .. "#" .. file_id[3]:gsub("%.html$", "")
        local path = name_file(file_id[1]:gsub("^/", "") .. "#" .. link_file) -- TODO is that ever used?
        -- Whether the link names the very file holding it is read off the file
        -- names: orig_path is the page key as the source spelt it, and a key
        -- holding "/" is written "_" in the file name, so the two never match.
        local own_file = vim.fs.basename(fname):gsub("%.md$", "")
        local linked_file = table.concat({ file_id[1]:gsub("^/", ""), file_id[2], file_id[3] }, "#")
        if linked_file == own_file and orig_containing_path ~= nil then
          path = orig_containing_path
        end
        if path ~= nil then
          if name_and_id_to_string_nearby[path] ~= nil then
            local text_section = name_and_id_to_string_nearby[path][file_id[4]]
            if text_section ~= nil then
              lines[i] = l .. "local://" .. choice .. "/" .. name_file(path) .. "#" .. text_section
              changes = true
            else
              -- can't find a header by that name in the source file. sometimes the files
              -- are just broken. for instance date_fns/I18n Contribution Guide.
              -- in that case do the same as upstream devdocs/the browser: show the file at the top, ignoring the ID.
              lines[i] = l .. "local://" .. choice .. "/" .. name_file(path) .. "\t+" .. file_id[4]
              changes = true
            end
          end
        end
      elseif #file_id == 3 then
        -- it's a link to the same file, which was already properly named... "name#path#id"
        local path = name_file(file_id[1]:gsub("^/", "") .. "#" .. file_id[2]:gsub("%.html$", ""))
        if path ~= nil and name_and_id_to_string_nearby[path] ~= nil then
          local text_section = name_and_id_to_string_nearby[path][file_id[3]]
          if text_section ~= nil then
            lines[i] = l .. "local://" .. choice .. "/" .. name_file(path) .. "#" .. text_section
            changes = true
          else
            -- can't find a header by that name in the source file. sometimes the files
            -- are just broken. for instance date_fns/I18n Contribution Guide.
            -- in that case do the same as upstream devdocs/the browser: show the file at the top, ignoring the ID.
            lines[i] = l .. "local://" .. choice .. "/" .. name_file(path) .. "\t+" .. file_id[3]
            changes = true
          end
        end
      elseif #file_id == 2 then
        -- link to another file, ID lookup
        local local_path, local_fname = fix_file_links_resolve_fname(choice, path_to_name, file_guessed_subpath_str, file_id[1]:gsub("^/", ""), name_file)
        if local_path ~= nil and name_and_id_to_string_nearby[local_fname] then
          local text_section = name_and_id_to_string_nearby[local_fname][file_id[2]]
          if text_section ~= nil then
            lines[i] = l .. local_path .. local_fname .. "#" .. text_section
            changes = true
          else
            -- can't find a header by that name in the source file. sometimes the files
            -- are just broken. for instance date_fns/I18n Contribution Guide.
            -- in that case do the same as upstream devdocs/the browser: show the file at the top, ignoring the ID.
            lines[i] = l .. local_path .. local_fname .. "\t+" .. file_id[2]
            changes = true
          end
        end
      else
        local local_path, local_fname = fix_file_links_resolve_fname(choice, path_to_name, file_guessed_subpath_str, link_target:gsub("^/", ""), name_file)
        if local_path ~= nil then
          lines[i] = l .. local_path .. local_fname
          changes = true
        end
      end
    end
  end
  return lines, changes
end

local function html_extra_css(source)
  if source:match("openjdk") then
    return [[
<html>
  <head>
    <style>
      ul.inheritance {
        list-style:none
      }
      ul.inheritance ul.inheritance {
        margin:0
      }
    </style>
  </head>
  <body>
    ]]
  else
    return ""
  end
end

local function apply_source_specific_workarounds(source, contents)
  if source == "dom" then
    -- dom/Clipboard.read for instance has text like ["text", "text2"], and we parse it
    -- as markdown links. But it's multiline in table columns and it looks horrible.
    local res = contents
      :gsub("%[\"", "{\"") -- [" -> {"
      :gsub("\"%]", "\"}") -- "] -> "}
    return res
  end
  return contents
end

-- `choice` is the source's folder name (see folders.lua): the docset name, plus
-- "~~origin" for anything but devdocs. `cont` runs after a successful install,
-- `on_fail` after a failed one.
local function apidoc_install(choice, slugs_to_mtimes, cont, on_fail)
  local slug, origin = folders.split(choice)
  progress(choice, "fetching index")
  local data_folder = common.data_folder()
  vim.fn.mkdir(data_folder, "p")
  local elinks_conf_path = data_folder .. "elinks.conf"
  if vim.fn.filereadable(elinks_conf_path) ~= 1 then
    local file = io.open(elinks_conf_path, "w")
    -- nice table borders
    file:write("set terminal._template_.type = 2\n")
    file:close()
  end
  local start_install = vim.loop.hrtime()
  -- A source missing from the catalogue has no mtime; its download then fails
  -- inside the coroutine below and is reported like any other failure.
  local mtime = slugs_to_mtimes[choice] or ""
  local adapter, no_adapter = sources.get(origin)
  local function system(cmd)
    return system_async(cmd, { text = true })
  end
  run(function()
    if not adapter then
      error(no_adapter, 0)
    end
    -- A source with no archive fetches a page at a time and can take minutes;
    -- `report` lets it say how far along it is in the same notification the
    -- rest of the install uses. A source that downloads one archive ignores it.
    local function report(text)
      progress(choice, text)
    end
    local data = adapter.index(slug, mtime, system, report)
    local path_to_name = {}
    local path_to_type = {}
    local known_keys_per_path = {}
    for _, entry in ipairs(data["entries"]) do
      path_to_name[entry.path] = entry.name
      path_to_type[entry.path] = entry.type

      local file_id = vim.split(entry.path, "#")
      if #file_id == 2 then
        path_to_name[entry.path] = entry.name
        local sanitized_fname = filenames.stem(file_id[1])
        if known_keys_per_path[file_id[1]] == nil then
          known_keys_per_path[file_id[1]] = {[file_id[2]] = true}
        else
          known_keys_per_path[file_id[1]][file_id[2]] = true
        end
      end
    end

    progress(choice, "fetching pages")
    do
      local data = adapter.db(slug, mtime, system, report)
      local target_path = data_folder .. choice
      vim.system({"sh", "-c", "rm -Rf " .. target_path}):wait()
      vim.fn.mkdir(target_path, "p")
      -- every file name this install writes, so that names differing only in
      -- case get told apart before one overwrites the other (filenames.lua)
      local file_names = {}
      for key in pairs(data) do
        file_names[#file_names + 1] = (path_to_name[key] or key) .. "#" .. key
      end
      for path, name in pairs(path_to_name) do
        if #vim.split(path, "#") == 2 then
          file_names[#file_names + 1] = filenames.stem(name) .. "#" .. path
        end
      end
      local name_file = filenames.namer(filenames.case_twins(file_names))
      -- used to split files in sections based on ids referenced from the toplevel
      local name_and_id_to_pos = {}
      -- used to gather all section "titles" so that we can prepare links to this
      -- part of the files later on. So we gather this for ALL ids, whether we know
      -- about them or not.
      local name_and_id_to_string_nearby = {}
      local name_known_byte_offsets = {}
      local name_to_contents = {}
      local out_path_to_orig_path = {}
      local out_path_to_orig_containing_path = {}

      local query = vim.treesitter.query.parse('html', [[
      (attribute
      (attribute_name) @_name
      (#eq? @_name "id")
    )
    ]])
    all_parsing = 0
    all_reading_ids = 0

    -- save all the files
    local page_count, pages_done = vim.tbl_count(data), 0
    for _, key in ipairs(vim.tbl_keys(data)) do
      pages_done = pages_done + 1
      if pages_done % 25 == 0 then
        progress(choice, "preparing pages " .. pages_done .. "/" .. page_count)
        yield_to_editor()
      end
      local sanitized_key = name_file((path_to_name[key] or key) .. "#" .. key)
      out_path_to_orig_path[sanitized_key .. ".html"] = key
      local fname = target_path .. "/" .. sanitized_key  .. ".html"
      local file = io.open(fname, "w")
      if file == nil then
        print("Error opening file " .. fname)
      end
      contents = data[key]
      :gsub("<pre([^>]*)>(.-)</pre>", function(pre_attrs, children)
        local match = pre_attrs:match("[^<>]*data%-language=\"(%w+)\"")
        -- don't put ``` unless it's multiline
        if match and children:match("\n") then
          return "<pre>\n```" .. match .. "\n" .. children:gsub("</?code>", "") .. "\n```</pre>"
        elseif not children:match("<code") and children:match("\n") then
          return "<pre" ..pre_attrs .. ">\n```\n" .. children .. "\n```</pre>"
        elseif not children:match("<code") and not children:match("\n") then
          return "<pre" ..pre_attrs .. ">\n`" .. children .. "`</pre>"
        else
          -- sometimes there is <pre><code></code></pre>. don't add double ```, let <code> handle it
          return "<pre" .. pre_attrs .. ">" .. children .. "</pre>"
        end
      end)
      :gsub("<td class=.font%-monospace.>([^<]+)</td>", "<td>`%1`</td>")
      :gsub("<code([^>]*)>(.-)</code>", function(code_attrs, children)
        local match = code_attrs:match("class=\"javascript\"")
        if match and children:match("\n") then
          return "<code" .. code_attrs .. ">\n```javascript\n" .. children .. "\n```</code>"
        elseif not children:match("<a") then
          -- don't wrap a tags in `` or we lose the links
          if children:match("\n") then
            return "<code" .. code_attrs .. ">\n```\n" .. children .. "\n```\n</code>"
          else
            return "<code" .. code_attrs .. ">`" .. children .. "`</code>"
          end
        else
          return "<code" .. code_attrs .. ">" .. children .. "</code>"
        end
      end)
      :gsub("<table", "<table border=\"1\"")
      file:write(html_extra_css(slug))
      if path_to_type[key] ~= nil then
        file:write("<p>&gt; " .. slug .. "/" .. path_to_type[key] .. "\n</p>\n")
      end
      file:write(apply_source_specific_workarounds(slug, contents))
      file:close()

      local start_parse = vim.loop.hrtime()
      local parser = vim.treesitter.get_string_parser(contents, "html")
      local tree = parser:parse()[1]
      local elapsed = (vim.loop.hrtime() - start_parse) / 1e9
      all_parsing = all_parsing + elapsed

      name_to_contents[sanitized_key] = contents
      name_and_id_to_pos[sanitized_key] = {}
      name_and_id_to_string_nearby[sanitized_key] = {}
      name_known_byte_offsets[sanitized_key] = {#contents}

      local start_ids = vim.loop.hrtime()
      for id, node, metadata in query:iter_captures(tree:root(), contents) do
        if node:next_named_sibling():named_child_count() > 0 then
          local id_val = vim.treesitter.get_node_text(node:next_named_sibling():named_child(), contents)
          if known_keys_per_path[key] ~= nil and known_keys_per_path[key][id_val] then
            _, _, byte_pos = node:parent():parent():start()
            name_and_id_to_pos[sanitized_key][id_val] = byte_pos+1
            table.insert(name_known_byte_offsets[sanitized_key], byte_pos+1)
          end
          if node:parent() ~= nil and node:parent():parent() ~= nil
            and node:parent():parent():next_named_sibling() ~= nil
            and node:parent():parent():next_named_sibling():type() == "text" then
            name_and_id_to_string_nearby[sanitized_key][id_val] =
              vim.treesitter.get_node_text(node:parent():parent():next_named_sibling(), contents)
          elseif node:parent() ~= nil and node:parent():parent() ~= nil
            and node:parent():parent():next_named_sibling() ~= nil
            and node:parent():parent():next_named_sibling():type() == "element"
            and node:parent():parent():next_named_sibling():named_child_count() > 1
            and node:parent():parent():next_named_sibling():named_children()[2]:type() == "text" then
            -- happens with lua, but seems generic enough not to gate it
            name_and_id_to_string_nearby[sanitized_key][id_val] =
              vim.treesitter.get_node_text(node:parent():parent():next_named_sibling():named_children()[2], contents)
          elseif slug == "rust" and node:parent() ~= nil and node:parent():parent() ~= nil and node:parent():parent():parent() ~= nil then
            -- for rust, the node text is a little harder to find
            local elt = node:parent():parent():parent()
            if elt:type() == "element" and elt:named_child_count() >= 3 then
              local next_elt = elt:named_children()[3]
              if next_elt:type() == "element" and next_elt:named_child_count() >= 2 then
                local text = next_elt:named_children()[2]
                if text:type() == "text" then
                  local text_contents = vim.treesitter.get_node_text(text, contents)
                  local lines = vim.split(text_contents, "\n")
                  if #lines > 1 then
                    text_contents = lines[1]
                    for i = 2, #lines do
                      if #lines[i] > #text_contents then
                        text_contents = lines[i]
                      end
                    end
                  end
                  name_and_id_to_string_nearby[sanitized_key][id_val] = text_contents
                end
              end
            end
          end
        end
      end
      all_reading_ids = all_reading_ids + elapsed

      -- need to sort offsets, later i search for the byte offset after my current one
      -- to know where to stop when extracting docs from a larger file
      table.sort(name_known_byte_offsets[sanitized_key])
    end

    -- now extract all the entries to non-html files
    local start_writing = vim.loop.hrtime()
    local entry_count, entries_done = vim.tbl_count(path_to_name), 0
    for path, name in pairs(path_to_name) do
      entries_done = entries_done + 1
      if entries_done % 200 == 0 then
        progress(choice, "splitting entries " .. entries_done .. "/" .. entry_count)
        yield_to_editor()
      end
      local file_id = vim.split(path, "#")
      local sanitized_fname = filenames.stem(name)
      if #file_id == 2 then
        local sanitized_containing_file_name = name_file((path_to_name[file_id[1]] or file_id[1]) .. "#" .. file_id[1])
        if name_and_id_to_pos[sanitized_containing_file_name] == nil then
          -- devdocs's index.json is referencing a file that the db.json doesn't contain.
          -- this happens with bash, and we also get a 404 on devdocs.io in that case.
        else
          local byte = name_and_id_to_pos[sanitized_containing_file_name][file_id[2]]
          local to_write_contents = nil
          if byte == nil then
            -- bad id. this happens with openjdk~8, Vector.add() for instance. Behave the same
            -- as the devdocs UI, point to the whole file since we can't delimitate the correct subpart.
            to_write_contents = name_to_contents[sanitized_containing_file_name]
          else
            local next_byte = nil
            for i,val in ipairs(name_known_byte_offsets[sanitized_containing_file_name]) do
              if val == byte then
                next_byte = name_known_byte_offsets[sanitized_containing_file_name][i+1]
              end
            end
            to_write_contents = string.sub(name_to_contents[sanitized_containing_file_name], byte, next_byte-1)
          end
          local sanitized_name = filenames.stem(name)
          local out_path = name_file(sanitized_name .. "#" .. path) .. ".html"
          out_path_to_orig_path[out_path] = path
          out_path_to_orig_containing_path[out_path] = sanitized_containing_file_name
          local file = io.open(target_path .. "/" .. out_path, "w")
          file:write(html_extra_css(slug))
          if path_to_type[file_id[1]] ~= nil then
            file:write("<p>&gt; " .. slug .. "/" .. path_to_type[file_id[1]] .. "/" .. path_to_name[file_id[1]] .. "\n</p>\n")
          else
            file:write("<p>&gt; " .. slug .. "\n</p>\n")
          end
          file:write(to_write_contents)
          file:close()
        end
      end
    end
    local elapsed_writing = (vim.loop.hrtime() - start_writing) / 1e9

    -- elinks deletes each .html once converted, so the remaining count is the progress
    local html_total = count_files(target_path, ".html")
    local converting = vim.uv.new_timer()
    converting:start(0, 1000, vim.schedule_wrap(function()
      local left = count_files(target_path, ".html")
      progress(choice, "converting pages " .. (html_total - left) .. "/" .. html_total)
    end))
    local start_elinks = vim.loop.hrtime()
    -- convert the html to text, on `workers` processes concurrently (setup option)
    local sysname = vim.loop.os_uname().sysname
    local xargs_cmd = "xargs"
    if sysname == "Darwin" then
      -- need a larger buffer than default on OSX.
      -- Also hardcode the path to xargs as a user may install
      -- the GNU xpath in their path
      xargs_cmd = "/usr/bin/xargs -S1024"
    end
    system_async({
      "sh", "-c",
      [[find . -maxdepth 1 -name '*.html' -print0 | ]] .. xargs_cmd .. [[ -0 -P ]] .. sources.workers() .. [[ -I param sh -c "elinks -config-dir ]] .. data_folder .. [[ -dump 'param' > 'param'.md && rm 'param'"]]
      -- [[find . -maxdepth 1 -name '*.html' -print0 | xargs -0 -P 8 -I param sh -c "elinks -config-dir ]] .. data_folder .. [[ -dump 'param' > 'param'.md"]]
    }, {cwd=target_path})
    converting:stop()
    converting:close()
    local elapsed_elinks = (vim.loop.hrtime() - start_elinks) / 1e9

    local start_pp = vim.loop.hrtime()

    -- unfortunately i must post-process the markdown to fix conceal table alignment and fix links..
    progress(choice, "post-processing")
    local res = system_async({"rg", "-l", "│"}, {cwd=target_path})
    do
      local table_files = vim.fn.split(res.stdout, "\n")
      for i, fname in ipairs(table_files) do
        -- each file can hold large tables and takes a full treesitter pass: yield every time
        progress(choice, "aligning tables " .. i .. "/" .. #table_files)
        yield_to_editor()
        local filepath = target_path .. "/" .. fname
        local lines = {}
        for line in io.lines(filepath) do
          table.insert(lines, line)
        end
        local file = io.open(filepath, "w")
        local after_conceal = add_spaces_to_compensate_conceals_cols(lines)
        file:write(vim.fn.join(after_conceal, "\n"))
        file:close()
      end

      local post_done = 0
      local fs = vim.uv.fs_scandir(target_path)
      while true do
        local name, type = vim.uv.fs_scandir_next(fs)
        if not name then break end
        if type ~= 'directory' then
          post_done = post_done + 1
          if post_done % 200 == 0 then
            progress(choice, "fixing links " .. post_done .. "/" .. html_total)
            yield_to_editor()
          end
          local filepath = target_path .. "/" .. name
          local lines = {}
          for line in io.lines(filepath) do
            table.insert(lines, line)
          end
          local after_links, changes = fix_file_links(
            filepath, lines, target_path, choice, path_to_name, name_and_id_to_string_nearby,
            out_path_to_orig_path[name:gsub(".md$", "")], out_path_to_orig_containing_path[name:gsub(".md$", "")],
            name_file)
          if changes then
            local file = io.open(filepath, "w")
            file:write(vim.fn.join(after_links, "\n"))
            file:close()
          end
        end
      end

      -- section files repeat their page's text: keep them out of searches
      sections.write(target_path, vim.tbl_keys(out_path_to_orig_containing_path))

      local elapsed_pp = (vim.loop.hrtime() - start_pp) / 1e9

      local elapsed = (vim.loop.hrtime() - start_install) / 1e9

      -- devdocs' catalogue entry carries the release and mtime. Another source
      -- has no catalogue, so it says what it installed itself: an adapter that
      -- knows its version reports it, and the record can then be compared with
      -- what the source offers later.
      local entry = catalogue[choice]
      if not entry then
        -- A source that documents one language declares it; one that does
        -- not -- a Sphinx site documents whatever its project is -- reads it
        -- from what it just installed, and that is the better answer.
        local declared = adapter and adapter.language
        if adapter and adapter.language_of then
          declared = adapter.language_of(slug) or declared
        end
        entry = { mtime = mtime, origin = origin, language = declared }
        if adapter and adapter.release then
          entry.release = adapter.release(slug)
        end
      end
      metadata.mark_installed(choice, entry)

      progress(choice, "finished in " .. elapsed .. "s. All parsing: " .. all_parsing
      .. "s. All reading IDs: " .. all_reading_ids .. "s. All writing: " .. elapsed_writing .. "s. All elinks: " .. elapsed_elinks .. "s. All post-process: " .. elapsed_pp .. "s.")

      if cont ~= nil then
        cont()
      end
    end
    end
  end, on_fail)
end

local slugs_to_mtimes_for_queue = {}
queue = install_queue.new(function(slug, done)
  apidoc_install(slug, slugs_to_mtimes_for_queue, function() done(true) end, function() done(false) end)
end)

-- The only way in: queue sources for install, one at a time; `cont` runs once
-- all of them have finished, whether or not each succeeded.
local function queue_install(slugs, slugs_to_mtimes, cont)
  for slug, mtime in pairs(slugs_to_mtimes) do
    slugs_to_mtimes_for_queue[slug] = mtime
  end
  return queue:add(slugs, cont)
end

-- Queue the picked sources. With snacks the picker takes several at once
-- (<Tab> marks one, and marks survive a change of search); other pickers take
-- one per call. Picking again while sources install adds to the same run.
-- `format_item(slug)` is the name, release and install state; `origin_of(slug)`
-- is where the source comes from, shown dimmed at the right edge;
-- `language_of(slug)` is the language it would be installed with, in a column
-- before the name, so the list can be narrowed by language as well as by name.
-- A language wider than this is cut: the column is a signpost, not the answer.
local language_column = 18

local picker_title = "Install documentation (<Tab> marks several)"

-- How long a typed URL must stand still before the site behind it is asked.
local url_settle_ms = 600

-- The live picker re-runs its finder whenever an answer lands, so the search
-- has to be fired from the typed name changing, never from the finder running.
local search_state = { query = nil, handle = nil }

local function stop_registry_search()
  if search_state.handle then
    search_state.handle:cancel()
  end
  search_state = { query = nil, handle = nil }
end

---@param opts? { languages?: table<string, boolean> }
local function pick_and_queue(keys, format_item, origin_of, language_of, slugs_to_mtimes, opts)
  opts = opts or {}
  local function language(slug)
    local name = language_of(slug)
    if vim.fn.strdisplaywidth(name) > language_column then
      name = vim.fn.strcharpart(name, 0, language_column - 1) .. "…"
    end
    return name
  end
  local width = 0
  for _, slug in ipairs(keys) do
    width = math.max(width, vim.fn.strdisplaywidth(language(slug)))
  end
  local function padded(slug)
    local name = language(slug)
    return string.rep(" ", width - vim.fn.strdisplaywidth(name)) .. name
  end
  local function enqueue(choices)
    local added = queue_install(choices, slugs_to_mtimes)
    if #added < #choices then
      vim.notify("docshelf: already queued: " .. table.concat(vim.tbl_filter(function(c)
        return not vim.tbl_contains(added, c)
      end, choices), ", "), vim.log.levels.INFO, { title = "docshelf" })
    end
  end
  -- A registry row whose version is not known yet: ask the source which
  -- version has documentation, then queue that. One request, so it is done
  -- when the row is picked rather than for every row a search returns.
  local function resolve_then_enqueue(item)
    local adapter = sources.get(item.origin)
    if not (adapter and adapter.resolve) then
      vim.notify("docshelf: " .. item.origin .. " cannot say which version of " .. item.name
        .. " to install", vim.log.levels.ERROR, { title = "docshelf" })
      return
    end
    vim.notify("docshelf: asking " .. item.origin .. " about " .. item.name, vim.log.levels.INFO,
      { id = "docshelf_resolve_" .. item.name, title = "docshelf" })
    run(function()
      local docset = adapter.resolve(item.name, function(cmd)
        return system_async(cmd, { text = true })
      end)
      enqueue({ folders.name(docset, item.origin) })
    end)
  end
  local function queue_items(items)
    for _, item in ipairs(items) do
      if item.slug then
        enqueue({ item.slug })
      else
        resolve_then_enqueue(item)
      end
    end
  end
  if Config and Config.picker == "snacks" then
    -- The rows known before a key is pressed: the devdocs catalogue.
    local function catalogue_rows()
      return vim.tbl_map(function(slug)
        return {
          text = language(slug) .. " " .. format_item(slug),
          label = format_item(slug),
          language = padded(slug),
          slug = slug,
          origin = origin_of(slug),
        }
      end, keys)
    end
    local cache = registry.default_cache()
    local origins = registry.searchable({ languages = opts.languages })
    -- A URL names one specific site, so the language filter does not narrow
    -- this: the user has already said which documentation they mean, and what
    -- language it turns out to document is only known once it is asked.
    local url_origins = registry.searchable({ method = "from_url" })
    local function origin_language(origin)
      local adapter = sources.get(origin)
      return adapter and adapter.language or ""
    end
    stop_registry_search()
    require("snacks").picker.pick({
      title = picker_title,
      layout = { preset = "select" },
      -- Live: what is typed is the query the registries are asked, so snacks
      -- does no matching of its own and install_pick.order does it instead.
      live = true,
      on_close = stop_registry_search,
      finder = function(_, ctx)
        local typed = ctx.filter.search or ""
        local items = catalogue_rows()
        for _, row in ipairs(cache:match(typed)) do
          items[#items + 1] = install_pick.registry_row(row, origin_language(row.origin))
        end
        if typed ~= search_state.query then
          stop_registry_search()
          search_state.query = typed
          local url = install_pick.is_url(typed)
          local asked = url and url_origins
            or install_pick.worth_asking(origins, typed, function(origin)
              local adapter = sources.get(origin)
              return adapter ~= nil and adapter.catalogue == true
            end)
          if #asked > 0 then
            local picker = ctx.picker
            local function answered()
              vim.schedule(function()
                if picker.closed then
                  return
                end
                picker.title = install_pick.title(
                  picker_title,
                  search_state.handle and search_state.handle:pending() or {}
                )
                picker:update_titles()
                picker:find({ refresh = true })
              end)
            end
            local function ask()
              search_state.handle = registry.search(typed, {
                origins = asked,
                method = url and "from_url" or "search",
                cache = cache,
                on_batch = answered,
                on_done = answered,
              })
            end
            if url then
              -- A URL is typed character by character, and every prefix of one
              -- is still a URL: asking on each keystroke would send a stream of
              -- requests to a site for addresses that do not exist yet. Wait
              -- until the typing stops.
              vim.defer_fn(function()
                if search_state.query == typed and not picker.closed then
                  ask()
                end
              end, url_settle_ms)
            else
              ask()
            end
          end
        end
        return install_pick.order(items, typed)
      end,
      format = function(item)
        local line = { { item.language, "SnacksPickerComment" }, { " | ", "SnacksPickerDelim" }, { item.label } }
        if item.origin then
          line[#line + 1] = {
            col = 0,
            virt_text = { { item.origin, "SnacksPickerComment" } },
            virt_text_pos = "right_align",
            hl_mode = "combine",
          }
        end
        return line
      end,
      confirm = function(picker)
        local items = picker:selected({ fallback = true })
        picker:close()
        queue_items(items)
      end,
    })
    return
  end
  -- Pickers other than snacks have no live search, so they offer the
  -- catalogue and whatever a snacks search has already remembered.
  local function format_with_origin(slug)
    local line = padded(slug) .. " | " .. format_item(slug)
    local origin = origin_of(slug)
    return origin and (line .. "  · " .. origin) or line
  end
  vim.ui.select(keys, { prompt = "Pick a documentation to install", format_item = format_with_origin }, function(choice)
    if choice ~= nil then
      enqueue({ choice })
    end
  end)
end

--- Open the install picker. `languages` narrows it to the docsets of those
--- languages, and to the registries that document one of them, so a filtered
--- reading list can be extended without wading through everything else.
---@param opts? { languages?: table<string, boolean> }
local function docshelf_install(opts)
  opts = opts or {}
  if vim.fn.executable("elinks") ~= 1 or vim.fn.executable("rg") ~= 1 or vim.fn.executable("find") ~= 1 then
    print("The 'elinks', 'rg' and 'find' programs must be installed to proceed, refusing to run.")
  else
    -- A switched-off source is only left out of the picker. devdocs is the
    -- only catalogue there is; with it off, a registry search is all that is
    -- left, and with no searchable source either there is nothing to show.
    local devdocs_on = sources.is_enabled(metadata.devdocs_origin)
    local askable = #registry.searchable({ languages = opts.languages }) + #registry.searchable({ method = "from_url" })
    if not devdocs_on and askable == 0 then
      vim.notify("docshelf: " .. metadata.devdocs_origin .. " is switched off in setup(), so the install picker has nothing to list",
        vim.log.levels.WARN, { title = "docshelf" })
      return
    end
    fetch_slugs_and_mtimes_and_then(function (slugs_to_mtimes)
      local manifest = metadata.refresh(catalogue)
      local languages = require("docshelf.languages")
      local function language_of(slug)
        -- An installed source shows the language it was installed with, which
        -- the user may have changed; anything else, the one it would get.
        local link = manifest[slug] and metadata.language_link(slug, manifest[slug])
        return languages.label(
          link or languages.resolve(slug, { devdocs = metadata.origin(catalogue[slug]) == metadata.devdocs_origin })
        )
      end
      local keys = {}
      for slug in pairs(slugs_to_mtimes) do
        if devdocs_on and not (opts.languages and not opts.languages[language_of(slug)]) then
          keys[#keys + 1] = slug
        end
      end
      table.sort(keys)
      pick_and_queue(keys, function(slug)
        return metadata.label(catalogue[slug], manifest[slug])
      end, function(slug)
        return metadata.origin(catalogue[slug])
      end, language_of, slugs_to_mtimes, opts)
    end)
  end
end


return {
  -- for the specs only
  _internal = { fix_file_links = fix_file_links },
  fetch_slugs_and_mtimes_and_then = fetch_slugs_and_mtimes_and_then,
  -- devdocs' catalogue entries by docset name, as the last
  -- fetch_slugs_and_mtimes_and_then left them. Empty until one has run.
  catalogue = function()
    return catalogue
  end,
  -- Whether a source is installing now. An update check that queued work
  -- while an install was running would report progress for both at once, and
  -- the idle check would rather wait for a quiet moment.
  installing = function()
    return queue.current ~= nil
  end,
  apidoc_install = apidoc_install,
  -- Add a source adapter (see sources/devdocs.lua); its folders are
  -- "<docset>~~<adapter.origin>".
  register_source = sources.register,
  queue_install = queue_install,
  docshelf_install = docshelf_install,
}
