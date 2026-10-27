-- Returning freed memory to the OS after big edits (memory.lua).
vim.cmd.runtime("plugin/csvkit.lua")
local memory = require("csvkit.memory")

local function big(n)
  local rows = { "n,v" }
  for i = 1, n do
    rows[#rows + 1] = (n - i) .. ",x"
  end
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, rows)
  return buf
end

-- Turns the trim on for the current buffer (it is off by default).
local function on()
  vim.b.csvkit = { memory = { trim = true } }
end

-- Runs fn with memory.trim counted; waits for what it schedules.
local function trims(fn)
  vim.wait(20) -- a trim scheduled by an earlier test is not ours
  local count, trim = 0, memory.trim
  memory.trim = function()
    count = count + 1
  end
  local ok, err = pcall(function()
    fn()
    vim.wait(50)
  end)
  memory.trim = trim
  assert(ok, err)
  return count
end

return {
  ["trim runs after a big edit, not after a small one or an insert"] = function()
    big(memory.THRESHOLD + 5)
    on()
    eq(trims(function()
      vim.cmd("Csvkit sort n")
    end), 1)
    eq(trims(function()
      vim.cmd("Csvkit row add below")
    end), 0)
    big(20)
    on()
    eq(trims(function()
      vim.cmd("Csvkit sort n")
    end), 0)
  end,

  ["several big edits in a row trim once"] = function()
    big(memory.THRESHOLD + 5)
    on()
    eq(trims(function()
      vim.cmd("Csvkit sort n")
      vim.cmd("Csvkit sort n desc")
    end), 1)
  end,

  ["the trim is off by default"] = function()
    big(memory.THRESHOLD + 5)
    eq(trims(function()
      vim.cmd("Csvkit sort n")
    end), 0)
    vim.b.csvkit = { memory = { trim = false } }
    eq(trims(function()
      vim.cmd("Csvkit sort n desc")
    end), 0)
  end,

  ["trim does nothing, without an error, where ffi or malloc_trim is missing"] = function()
    local ffi = package.loaded.ffi
    local missing = { cdef = function() error("no") end, C = setmetatable({}, { __index = function() error("undefined symbol") end }) }
    package.loaded.ffi = missing
    local ok, ran = pcall(memory.trim)
    eq({ ok, ran }, { true, false })
    package.loaded.ffi = nil
    package.preload.ffi = function()
      error("module 'ffi' not found") -- a Lua without it
    end
    ok, ran = pcall(memory.trim)
    package.preload.ffi, package.loaded.ffi = nil, ffi
    eq({ ok, ran }, { true, false })
  end,

  ["trim calls malloc_trim when it exists"] = function()
    local ffi = require("ffi")
    if not pcall(function() return ffi.C.malloc_trim end) then
      return -- musl, macOS, Windows
    end
    eq(memory.trim(), true)
    eq(memory.trim(), true) -- a second declaration is no problem
  end,

  ["trim collects the garbage first, so what the edit freed can be returned"] = function()
    local weak = setmetatable({ {} }, { __mode = "v" })
    memory.trim()
    eq(weak[1], nil)
  end,
}
