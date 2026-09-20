# Apidocs.nvim

This is an integration of <https://devdocs.io/> in neovim.

This plugin will download devdocs documentations for offline usage and pre-format them for in-neovim display.
It will also extract the documentation for individual methods (`List.add()`...) for nicer browsing, and leverages neovim conceal features for a user-friendly display.

![basic screenshot](https://raw.githubusercontent.com/wiki/emmanueltouzery/apidocs.nvim/shot1.png)

## How to use

Everything below is also in the helpfile, `:help apidocs`.

Call `require("apidocs").setup()` when installing the plugin to register the commands.

The plugin exports the following commands:

- `ApidocsInstall` - ask which documentation to install, and install it. Each row shows a source's release and install state, with where it comes from at the right edge. With snacks.nvim, `<Tab>` marks several sources, and marks are kept when you change the search. Sources install one at a time, in the background, with their place in the queue and their progress shown in a notification; picking more while an install runs adds them to the queue, and a source that fails to install is reported and skipped. A large source can take a minute or more, since the plugin uses Neovim's tree-sitter to post-process the files, but Neovim stays usable meanwhile. Where the rows come from, and how to narrow them, is in [Documentation sources](#documentation-sources).
- `ApidocsOpen` (requires telescope.nvim or snacks.nvim) - open a picker listing all apidocs. If you want to display only a subset of sources, call the lua function: `:lua require("apidocs").apidocs_open({restrict_sources={"rust"}})`. With snacks you can also pick the picker layout: `:lua require("apidocs").apidocs_open({layout="ivy_split"})`
- `ApidocsSearch` (requires telescope.nvim or snacks.nvim) - open a picker to grep for text in all apidocs. If you want to display only a subset of sources, call the lua function: `:lua require("apidocs").apidocs_search({restrict_sources={"rust"}})`. The `layout` option works here too. Each match is shown once: the install writes a `.rgignore` in each source folder listing the per-entry section files, which repeat text from their page (the open picker still lists them), and matches inside a page's footer of links are left out. Sources installed before this change show repeats until they are reinstalled.

  Sources know their language, so a filter can widen itself: `require("apidocs.languages").pulled_in(selected, installed)` returns, for every selected language reference, the other installed sources of that language (selecting `python~3.14` pulls in `numpy~2.5` and `scikit_learn`, but not `python~3.13`; selecting `numpy~2.5` alone pulls in nothing). "Language" is one flat field: a programming language, a file format or a tool (`git` is Git, `docker` is Docker). Each name has aliases that match it too (`ts`, `gh`, `rg`); a source is its language's reference when its name before `~` is the language's name or an alias (`python~3.15`, `openjdk~21` for Java), otherwise it belongs to the language. A source's language is decided at install and kept in `.installed.json`: a source that declares its language (a Hackage package is Haskell) uses it; a devdocs source found in `lua/apidocs/source_languages.lua` (a hand-maintained table) takes that table's answer; otherwise a source whose name before `~` is a name or alias from your lists gets that name. Anything else is Unknown, and `require("apidocs.languages").unknown(installed)` lists those. `require("apidocs").assign_language(slug)` gives any installed source a name, replacing what it had; that choice is kept when the source is refreshed, updated or reinstalled. It opens a picker over your lists plus every language already recorded on an installed source, narrowed as you type; when what you typed names none of them, the first row takes it as a new name, so a language you need once needs no config change. Your lists are the `languages`, `formats` and `tools` setup options (see below). Because the table is kept by hand, `nvim --headless -l scripts/check_source_languages.lua` compares it with the live devdocs catalogue: it lists sources the table lacks (each with a proposed row seeded from its repository's GitHub language, to be checked by a person) and rows for sources devdocs no longer lists. It never edits the table, and it cannot tell that an existing row is wrong.
- `ApidocsFilter` - narrow every apidocs picker to a few sources, until you say otherwise. With a handful of sources installed a picker can list all of them; with several dozen, a list of everything is no longer a list of what you need. Run it with no argument for a picker over the installed sources (with snacks.nvim, tab ticks several), name them directly (`:ApidocsFilter python~3.14 numpy~2.5`, with completion), or clear it with `:ApidocsFilter!`. From then on `ApidocsOpen`, `ApidocsSearch` and `ApidocsInstall` only look inside the filter; each of them takes a `!` to look at everything just this once without clearing it, and naming sources as arguments (`:ApidocsOpen rust`) overrides it for that call. The filter lives for this Neovim session, so a Rust session and a Python session each keep their own. Selecting a language's own source also brings in the other installed sources of that language -- `python~3.14` adds `numpy~2.5` and `scikit_learn`, while `numpy~2.5` selected alone stays alone, and `python~3.13` is a different reference rather than something written in 3.14. In the picker a filled dot marks what you picked and a hollow one what a language brought along; rows read `language | source`, and typing a language narrows to it, "Unknown" included. Narrowing is not only about reading a shorter list: a grep is one ripgrep over the sources in play, so a filter is also what keeps searching fast as the collection grows.
- `ApidocsAssignLanguage <source>` - set which language a source documents, picked from your lists (see `languages` below) plus every language already recorded on an installed source. Useful for a source that came out "Unknown". The same thing is bound to `<c-e>` inside the `ApidocsFilter` picker, where the source under the cursor is relabelled and the list redraws; `require('apidocs').setup({assign_key = "<c-x>"})` moves that key and `false` unbinds it.
- `ApidocsUpdate` - install again whatever has gone out of date: a devdocs source whose release has moved on (3.14.6 to 3.14.7) or that devdocs has rebuilt since, and a source from anywhere else whose origin now offers a newer version. Name sources to limit the round to them, with tab completion; with no argument everything installed is considered. A devdocs source is refreshed in place; a source named for the version it holds (`text~2.1.2`) is installed as `text~2.1.3` and the old folder is removed, carrying over the language you assigned it. A source whose origin publishes no version at all is left alone, as there is nothing to compare, and so is one installed before this release, which recorded nothing to compare with. This also runs on its own: the first time you pause after opening Neovim, and at most once a day, apidocs checks and updates in the background, using the same queue and the same progress notification as any other install. Switch that off with `update = { auto = false }` in `setup()`, or change how long it waits with `update = { every_hours = 24 }`. The automatic check is armed by `setup()`, so if you load the plugin lazily on its commands it first runs once you have opened the docs, not at startup.
- `ApidocsUninstall` - allows to uninstall sources. Press tab to get a completion on the available ones. An uninstalled source also leaves the filter.

## Advanced usage

It is possible to follow links in docs. The links are numbered, `[1]`, `[2]` and so on. To follow links, you must open the document, viewing it in the picker is not enough. Once the doc is opened, position the cursor over the link, and press `*`. That will take you to the link text in the footer. If the link is a URL, open it as you would normally in neovim (probably `gx`). If it's another locally installed doc, the link will be `local://` and you can follow it using `<C-]>`.

When a link takes you to a specific part of a document, you may have to press `n` to get to the right spot, as we jump to the part based on text contents, doing a search in the file.

## Documentation sources

Documentation comes from a **source**, and a source is named by its **origin** -- the short
address it is fetched from. devdocs.io is the one every install starts with; the others are
listed below, and each is an adapter that knows how to fetch and lay out its own pages, so
everything after the fetch (the conversion, the links, the pickers, the filter, the update
check) is the same whatever the origin.

A docset from a source other than devdocs lives in a folder named `<docset>~~<origin>`, which
is why two sources can each document a `text` and neither hides the other. What a person reads
is the docset name; the origin shows dimmed at the right edge of a picker. Each install records
its origin in the data folder's `.installed.json`, so pickers over installed sources can show it
too (`require("apidocs.metadata").installed_origins(slugs)`); sources installed before origins
were recorded count as `devdocs.io`.

Every source is on by default. Switching one off by its origin only removes it from the install
picker; docs already installed from it stay readable and keep updating:

```lua
require('apidocs').setup({sources = {["devdocs.io"] = false}})
```

**Searching the registries.** devdocs ships a catalogue of everything it has, and the install
picker lists it; a package registry cannot ship one, so it is asked instead. With snacks, from
three letters on, every enabled source that can be searched is asked as well (at most `workers`
of them at once), and the answers join the list as they land, with the title naming whichever
registry is still being waited on. What a registry answered is kept in the data folder's
`.registry_cache.json`, so the same name typed again is offered before any request goes out. A
row whose version the registry did not give is resolved when you pick it. Pickers other than
snacks have no live input to drive this and keep offering the catalogue alone.

Narrow the picker to one or more languages -- both the devdocs rows and the registries, which
declare the language they document -- with:

```lua
:lua require("apidocs").apidocs_install({languages = {Haskell = true}})
```

### devdocs.io

The built-in source, and the only one with a catalogue: one request lists every docset it has,
with the release and the build time of each. That is also what makes an update check cheap --
see `ApidocsUpdate`.

### Hackage

`hackage.haskell.org` documents a Haskell package: the Haddock archive a release
ships (`/package/<name>-<version>/docs.tar`) becomes a page per module plus an entry
per documented name, qualified by its module (`Data.Text.pack`). Haddock's own
chrome -- header, contents, synopsis, footer, the Source and self links -- is
dropped. A docset installs as `<name>~<version>~~hackage.haskell.org`, and its
language is Haskell without being asked.

It answers the install picker's search: type three letters of a package name and its
Hackage matches join the list, and picking one asks Hackage which version has
documentation built -- a package whose docs never built is not offered.
### docs.rs

`docs.rs` documents a Rust crate. docs.rs builds every crates.io release and ships
each build as one zip, so an install is a single request (it needs the `unzip`
program). A docset installs as `<crate>~<version>~~docs.rs`, and its language is Rust
without being asked.

It answers the install picker's search: type three letters of a crate name and its
crates.io matches join the list, each already carrying the version that will be
installed.
### Sphinx sites

A Sphinx site -- numpy, the Python docs, most Read the Docs pages -- stands alone:
there is no registry to search, so it is reached by its address. Paste the URL into
the install picker and the row shows the project, its version and how many pages the
install will fetch. That last number is worth reading before you pick: such a site
ships no archive, so the install is one request per page (numpy is 2673 of them).

What makes it readable is the site's own `objects.inv`, the inventory Sphinx
publishes for cross-project linking: every documented name, the page it is on and
the anchor it sits at. A link therefore lands on the item it names rather than at
the top of its page.
### pkg.go.dev

A Go package is named by its address rather than found by a search: pkg.go.dev's
`robots.txt` disallows its search, so there is nothing to type a name into. Paste a
pkg.go.dev URL and the row shows the package, its version and how many pages the
install will fetch -- the package the address names plus every package under it,
internal ones excepted. The standard library is reached the same way. A docset's
language is Go without being asked.
### DocC sites

Apple's frameworks, the Swift book and anything else built with DocC are named by
their address: paste a documentation URL
(`https://developer.apple.com/documentation/swiftui`,
`https://docs.swift.org/swift-book/documentation/the-swift-programming-language`) and
the row shows the module and how many pages the install will fetch. A DocC site
publishes one JSON document per page rather than a page, so the install reads the
site's navigator index once and then fetches a document per symbol -- SwiftUI is over
seven thousand of them, which is why the count is shown before you pick.

A DocC site publishes no version, so such a docset carries none, and the update check
leaves it alone rather than reinstalling it on a guess.

## Dependencies

This plugin requires:

- the [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) neovim plugin (optional, needed for preview and search)
- the [snacks.nvim](https://github.com/folke/snacks.nvim) neovim plugin (optional, needed for preview and search)
- the <https://github.com/rkd77/elinks> elinks TUI browser, to convert HTML
- ripgrep
- curl
- linux and probably OSX. Windows will not work, except maybe using WSL
- treesitter for html and markdown_inline, easiest way to get them is via [treesitter.nvim](https://github.com/nvim-treesitter/nvim-treesitter) plugin

## Installation

### Lazy.nvim

```lua
return {
  'emmanueltouzery/apidocs.nvim',
  dependencies = {
    'nvim-treesitter/nvim-treesitter',
    'nvim-telescope/telescope.nvim', -- or, 'folke/snacks.nvim'
  },
  cmd = { 'ApidocsSearch', 'ApidocsInstall', 'ApidocsOpen', 'ApidocsSelect', 'ApidocsFilter', 'ApidocsAssignLanguage', 'ApidocsUpdate', 'ApidocsUninstall' },
  config = function()
    require('apidocs').setup()
    -- Picker will be auto-detected. To select a picker of your choice explicitly you can set picker by the configuration option 'picker':
    -- require('apidocs').setup({picker = "snacks"})
    -- Possible options are 'ui_select', 'telescope', and 'snacks'
    -- With snacks, the picker layout defaults to the "telescope" preset. Any snacks layout preset name or layout table works:
    -- require('apidocs').setup({picker = "snacks", layout = "ivy_split"})
    -- You can change the keymap for following "local://" links by setting the configuration option 'follow_link_keymap' (default is "<C-]>"):
    -- require('apidocs').setup({follow_link_keymap = "<C-]>"})
    -- The names a source can be linked to, in three lists joined into one. Languages: Python, CPython, Rust, C, C++,
    -- C#, .NET, Java, TypeScript, JavaScript, Go, PHP, Ruby, Odin, Zig, Elixir, Kotlin, Swift, Dart, Scala, Haskell,
    -- Lua, Perl, R, Julia, Erlang, OCaml, Nim, Clojure, WebAssembly, HTML, CSS, Sass, Less, GraphQL, Vue, Svelte, SQL,
    -- PostgreSQL, SQLite, MS SQL, Bash, Zsh, Fish, PowerShell, TeX, LaTeX, BibTeX. Formats: Markdown, JSON, JSON5,
    -- YAML, TOML, Typst. Tools: Git, GitHub, Jujutsu, Docker, tmux, herdr, Neovim, Make, CMake, Homebrew, curl,
    -- ripgrep, fd, jq, SSH. Each SQL engine is its own name rather than a flavour of SQL, and LaTeX, TeX and BibTeX
    -- are distinct. For each list, 'add' extends it and 'only' replaces it. A name can carry aliases that match it too:
    -- require('apidocs').setup({languages = {add = {"Fortran", "Prolog"}}, tools = {add = {{"Kubernetes", aliases = {"k8s"}}}}})
    -- In the ApidocsFilter picker, the key that sets the language of the source under the cursor (false unbinds it):
    -- require('apidocs').setup({assign_key = "<c-e>"})
    -- Async work (page conversion during an install, registry searches) runs 4 jobs at once; 'workers' changes that (installs still run one at a time):
    -- require('apidocs').setup({workers = 8})
    -- Every documentation source is on. Switching one off by its origin only removes it from the install picker; docs already installed from it stay readable and keep updating:
    -- require('apidocs').setup({sources = {["devdocs.io"] = false}})
  end,
  keys = {
    -- A capital letter is the same thing over every source, ignoring the
    -- filter without clearing it.
    { '<leader>sad', '<cmd>ApidocsOpen<cr>', desc = 'Search Api Doc' },
    { '<leader>saD', '<cmd>ApidocsOpen!<cr>', desc = 'Search Api Doc (all sources)' },
    { '<leader>sas', '<cmd>ApidocsSearch<cr>', desc = 'Grep Api Docs' },
    { '<leader>saS', '<cmd>ApidocsSearch!<cr>', desc = 'Grep Api Docs (all sources)' },
    { '<leader>saf', '<cmd>ApidocsFilter<cr>', desc = 'Filter Api Docs' },
    { '<leader>saF', '<cmd>ApidocsFilter!<cr>', desc = 'Clear the Api Docs filter' },
    { '<leader>sai', '<cmd>ApidocsInstall<cr>', desc = 'Install Api Docs' },
    { '<leader>saI', '<cmd>ApidocsInstall!<cr>', desc = 'Install Api Docs (all languages)' },
  },
}
```

### Vim.pack
```lua
vim.schedule(function()
	vim.pack.add({ "https://github.com/emmanueltouzery/apidocs.nvim" })
	require("apidocs").setup() -- You can check the default configuration and add options to the setup. Check `lazy.nvim` installation for examples
end)
```

## Extra screenshots

![basic screenshot](https://raw.githubusercontent.com/wiki/emmanueltouzery/apidocs.nvim/shot2.png)
![basic screenshot](https://raw.githubusercontent.com/wiki/emmanueltouzery/apidocs.nvim/shot3.png)

## Extension points

If you wish to integrate these docs with your own scripts or another picker, you can use the following functions exported by apidocs.nvim:

- `require("apidocs").data_folder()` -- the folder where the converted apidoc files can be found
- `require("apidocs").open_doc_in_new_window(docs_path)` -- open the documentation for a specific apidoc in a new window, where conceal and links navigation is properly set up
- `require("apidocs").open_doc_in_cur_window(docs_path)` -- open the documentation for a specific apidoc in the current window, with conceal and links navigation is properly set up. Compared to open_doc_in_new_window(), winfixbuf is not set.
- `require("apidocs").load_doc_in_buffer(buf, docs_path)` -- open the documentation for a specific apidoc in a buffer. You must set up conceal on the window yourself (conceallevel=2, concealcursor="n"). Link navigation is not set up, this is meant for a picker's preview not standalone display.
- `require("apidocs").apidocs_filter()` -- open the filter picker. `require("apidocs").filter` is the filter itself: `set(names)`, `clear()`, `active()` (the sources picked, or nil), `languages()` (what they are written in) and `installed()`. Every picker call takes `follow_filter = false` to ignore it once, which is what the `!` commands pass.
- `require("apidocs").ensure_install(langs)` -- install all languages in the provided array. E.g. if `langs` is `{ "lua~5.4", "rust" }` then the docs for Lua 5.4 and Rust will be installed. You can call this function after `setup()` in your configuration to ensure that your desired languages are available. Missing ones join the same install queue as `ApidocsInstall`, so they never install at the same time as each other or as sources picked there.

## Credits

Credits go to <https://github.com/luckasRanarison/nvim-devdocs> for the initial project which inspired this.
