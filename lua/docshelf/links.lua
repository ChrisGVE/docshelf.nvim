--- Link rewriting shared by the sources that hand the installer pages written
--- for a website (docs.rs, Sphinx, pkg.go.dev, DocC, and every source after
--- them).
---
--- A page is keyed by its path inside the docset. Once it is a buffer, a link
--- to another page of the docset must name that page's key, written relative
--- to the page holding the link; any other link must become an address a
--- browser can open. Four adapters wrote their own copy of this, and a real
--- install found the same bugs in three of them: `src` left site-relative, so
--- an image became `file:///static/...`, and a link to a page's own parent
--- written as the empty string, which reads as the docset folder. This module
--- is the one copy, and its spec pins both.
local M = {}

--- Resolve `href` against the directory `dir` of the page holding it, the way
--- a browser would. Climbing above the root stops at the root.
function M.resolve(dir, href)
  local segments = vim.split(dir, "/", { trimempty = true })
  for _, part in ipairs(vim.split(href, "/", { trimempty = true })) do
    if part == ".." then
      table.remove(segments)
    elseif part ~= "." then
      segments[#segments + 1] = part
    end
  end
  return table.concat(segments, "/")
end

--- `path` written from `dir`, climbing no further than it has to: the
--- installer reads a link against the key of the page holding it, which cannot
--- climb above the docset. The result always names at least one segment -- a
--- link from wheel/spin to the page "wheel" is "../wheel", never "".
function M.relative(dir, path)
  local from = vim.split(dir, "/", { trimempty = true })
  local to = vim.split(path, "/", { trimempty = true })
  local shared = 0
  while from[shared + 1] and from[shared + 1] == to[shared + 1] do
    shared = shared + 1
  end
  if shared == #to and shared > 0 then
    -- `path` is `dir` itself or one of its ancestors: climb to its parent and
    -- name it
    shared = shared - 1
  end
  local out = {}
  for _ = shared + 1, #from do
    out[#out + 1] = ".."
  end
  for i = shared + 1, #to do
    out[#out + 1] = to[i]
  end
  -- a key a source spells with a trailing "/" keeps it
  return table.concat(out, "/") .. (path:match("./$") and "/" or "")
end

local function default_key_of(path)
  return (path:gsub("%.html$", ""):gsub("/$", ""))
end

--- Where `href` should point once its page is a buffer.
---
--- `opts.dir`    the directory of the page holding the link, inside the docset
--- `opts.known`  set of page keys the docset holds
--- `opts.base`   the address the docset's paths hang off, ending in "/"; nil
---               when the pages have no site behind them (an archive)
--- `opts.key_of` maps a resolved path to a page key (default: drop ".html"
---               and a trailing "/")
---
--- Returns nil when the link leads outside the docset and there is no site to
--- send it to: the caller keeps the link's text and drops the link.
function M.rewrite(href, opts)
  if href == "" or href:match("^#") or href:match("^%a[%w+.-]*:") then
    return href
  end
  if href:match("^//") then
    return "https:" .. href
  end
  if href:match("^/") then
    if not opts.base then
      return nil
    end
    return (opts.base:match("^(%a+://[^/]+)") or opts.base) .. href
  end
  local target, anchor = href:match("^([^#]*)(#?.*)$")
  if target == "" then
    return href
  end
  local resolved = M.resolve(opts.dir or "", target)
  local key = (opts.key_of or default_key_of)(resolved)
  if opts.known[key] then
    return M.relative(opts.dir or "", key) .. anchor
  end
  if not opts.base then
    return nil
  end
  return opts.base .. resolved .. anchor
end

--- Rewrite every `href` and `src` in `html` (see `rewrite`). An `<a>` whose
--- link goes nowhere keeps its text and loses the tag; a `src` that goes
--- nowhere is removed.
function M.rewrite_html(html, opts)
  html = html:gsub("(<a%s[^>]*>)(.-)</a>", function(open, text)
    local href = open:match('%shref="([^"]*)"')
    if href and M.rewrite(href, opts) == nil then
      return text
    end
    return nil
  end)
  return (
    html:gsub('(%s)(%a+)="([^"]*)"', function(space, attribute, value)
      if attribute ~= "href" and attribute ~= "src" then
        return nil
      end
      local rewritten = M.rewrite(value, opts)
      if rewritten == nil then
        return ""
      end
      return space .. attribute .. '="' .. rewritten .. '"'
    end)
  )
end

return M
