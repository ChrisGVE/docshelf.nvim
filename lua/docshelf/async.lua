-- Running long work without blocking the editor.
--
-- An install prepares and converts thousands of pages, and a registry search
-- waits on the network; both run inside a coroutine that hands control back to
-- Neovim between steps. `run` starts one, `system` runs a command and returns
-- its result to the coroutine, and `yield_to_editor` gives the editor a turn.
local M = {}

-- What to call when a coroutine fails, so a queue can move on.
local on_failure = setmetatable({}, { __mode = "k" })

local function resume(co, ...)
  local ok, err = coroutine.resume(co, ...)
  if not ok then
    vim.notify("docshelf install failed: " .. debug.traceback(co, err), vim.log.levels.ERROR)
    if on_failure[co] then
      on_failure[co]()
    end
  end
end

--- Run `fn` in a coroutine; `on_fail` runs if it raises.
---@param fn fun()
---@param on_fail? fun()
function M.run(fn, on_fail)
  local co = coroutine.create(fn)
  on_failure[co] = on_fail
  resume(co)
end

-- Let the editor redraw and handle input, then continue. A timer, not
-- vim.schedule: callbacks that keep re-scheduling themselves are drained in one
-- pass of the event queue, so input, redraws and other timers would starve.
function M.yield_to_editor()
  local co = coroutine.running()
  vim.defer_fn(function()
    resume(co)
  end, 0)
  coroutine.yield()
end

--- vim.system without blocking the editor; returns the completed result.
--- Only callable from inside `run`.
---@param cmd string[]
---@param opts? table
---@return vim.SystemCompleted
function M.system(cmd, opts)
  local co = coroutine.running()
  vim.system(cmd, opts, function(res)
    vim.schedule(function()
      resume(co, res)
    end)
  end)
  return coroutine.yield()
end

return M
