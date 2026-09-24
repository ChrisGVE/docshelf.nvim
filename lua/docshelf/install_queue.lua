-- A queue of sources to install, one at a time.
--
-- Every install goes through here, whether it comes from the install picker or
-- from ensure_install, so two installs never run at once: each already
-- converts pages in parallel, and fifty at once would swamp the machine.
-- Sources queued while a run is in progress join the end of it. A failed
-- install, including one that throws before it gets going, hands over to the
-- next source, so one bad source never strands the rest.
--
-- The installer is injected (`install(slug, done)`, where `done(ok)` is called
-- once the install ends), so the queue is tested without touching the network.
local M = {}

---@param install fun(slug: string, done: fun(ok: boolean))
---@param report? fun(message: string) where a thrown error is reported
function M.new(install, report)
  report = report
    or function(message)
      vim.notify("docshelf install failed: " .. message, vim.log.levels.ERROR, { title = "docshelf" })
    end

  local queue = {
    run = {}, -- every source of the current run, in order, finished ones included
    next_index = 1, -- run[next_index] is the next source to start
    current = nil, -- the source installing now
    waiters = {}, -- { pending = set of slugs, cont = fn } per add() call with a cont
  }

  local start_next

  -- Called once per install, however it ended. `current` stays set while the
  -- waiters run, so a cont that queues more cannot start a second install.
  local function finished(slug)
    local still_waiting = {}
    for _, waiter in ipairs(queue.waiters) do
      waiter.pending[slug] = nil
      if next(waiter.pending) then
        still_waiting[#still_waiting + 1] = waiter
      else
        waiter.cont()
      end
    end
    queue.waiters = still_waiting
    start_next()
  end

  start_next = function()
    local slug = queue.run[queue.next_index]
    if not slug then
      queue.run, queue.next_index, queue.current = {}, 1, nil
      return
    end
    queue.next_index = queue.next_index + 1
    queue.current = slug
    local ended = false
    local function done()
      if not ended then
        ended = true
        finished(slug)
      end
    end
    local ok, err = pcall(install, slug, done)
    if not ok then
      report(tostring(err))
      done()
    end
  end

  --- Queue sources not already installing or waiting; returns those queued.
  --- `cont`, if given, runs once every source named here has finished.
  ---@param slugs string[]
  ---@param cont? fun()
  ---@return string[]
  function queue:add(slugs, cont)
    local added = {}
    for _, slug in ipairs(slugs) do
      if not self:position(slug) then
        self.run[#self.run + 1] = slug
        added[#added + 1] = slug
      end
    end
    if cont then
      local pending = {}
      for _, slug in ipairs(slugs) do
        pending[slug] = true
      end
      if next(pending) then
        self.waiters[#self.waiters + 1] = { pending = pending, cont = cont }
      else
        cont()
      end
    end
    if not self.current then
      start_next()
    end
    return added
  end

  --- "2/5" for a source installing or waiting in this run, else nil.
  ---@param slug string
  ---@return string?
  function queue:position(slug)
    local first = self.current and self.next_index - 1 or self.next_index
    for i = first, #self.run do
      if self.run[i] == slug then
        return i .. "/" .. #self.run
      end
    end
    return nil
  end

  return queue
end

return M
