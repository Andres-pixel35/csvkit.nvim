-- Gives memory freed by a big edit back to the OS: Lua's strings and
-- Neovim's old lines are freed, but glibc keeps the pages until malloc_trim.
local M = {}

M.THRESHOLD = 10000 -- lines an edit rewrites before it is worth a trim

local declared, pending = false, false

-- Collects the garbage and calls malloc_trim(0) through LuaJIT's FFI. Does
-- nothing, without an error, where there is no ffi (a PUC Lua) or no
-- malloc_trim (musl, macOS, Windows). Returns whether it ran.
function M.trim()
  collectgarbage()
  local ok, ffi = pcall(require, "ffi")
  if not ok then
    return false
  end
  if not declared then
    declared = true
    pcall(ffi.cdef, "int malloc_trim(size_t pad);") -- may be declared already
  end
  return (pcall(function()
    return ffi.C.malloc_trim(0)
  end))
end

-- Called after an edit that rewrote n lines with the buffer's options. The
-- trim waits for the command to end, when its locals are garbage.
function M.after_edit(opts, n)
  if opts.memory.trim and n > M.THRESHOLD and not pending then
    pending = true
    vim.schedule(function()
      pending = false
      M.trim()
    end)
  end
end

return M
