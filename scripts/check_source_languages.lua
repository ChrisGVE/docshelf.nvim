-- Check lua/apidocs/source_languages.lua against the live devdocs catalogue.
--
-- Usage, from the repository root:
--   nvim --headless -l scripts/check_source_languages.lua
--
-- Reports families devdocs lists that the table lacks (each with a proposed
-- row seeded from `gh api repos/<owner>/<repo>`), rows whose family devdocs no
-- longer lists, and rows that break the table's rules. It only prints: the
-- table stays hand-edited. Exit status 1 when anything is reported.
-- Needs curl; gh is optional (without it every proposal is a placeholder).
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local drift = require("apidocs.source_drift")

-- devdocs answers 403 to clients without a browser user agent.
local fetched = vim
  .system({ "curl", "-sfL", "-A", "Mozilla/5.0", "https://devdocs.io/docs.json" }, { text = true })
  :wait()
if fetched.code ~= 0 then
  io.stderr:write("could not fetch https://devdocs.io/docs.json (curl exit " .. fetched.code .. ")\n")
  os.exit(2)
end

local function repo_language(repo)
  if not repo or vim.fn.executable("gh") == 0 then
    return nil
  end
  local result = vim.system({ "gh", "api", "repos/" .. repo, "--jq", ".language" }, { text = true }):wait()
  local language = vim.trim(result.stdout or "")
  if result.code ~= 0 or language == "" or language == "null" then
    return nil
  end
  return language
end

local catalogue = vim.json.decode(fetched.stdout)
local result = drift.check(catalogue, require("apidocs.source_languages"))
local errors = drift.row_errors(require("apidocs.source_languages"))

if #result.missing > 0 then
  print(#result.missing .. " families missing from source_languages.lua; proposed rows:")
  for _, missing in ipairs(result.missing) do
    print(drift.proposal(missing, repo_language(drift.github_repo(missing.code))))
  end
end
if #result.gone > 0 then
  print(#result.gone .. " rows whose family devdocs no longer lists:")
  for _, family in ipairs(result.gone) do
    print("  " .. family)
  end
end
if #errors > 0 then
  print(#errors .. " malformed rows:")
  for _, message in ipairs(errors) do
    print("  " .. message)
  end
end

local clean = #result.missing == 0 and #result.gone == 0 and #errors == 0
if clean then
  print(
    "source_languages.lua matches the devdocs catalogue (" .. vim.tbl_count(drift.families(catalogue)) .. " families)"
  )
end
os.exit(clean and 0 or 1)
