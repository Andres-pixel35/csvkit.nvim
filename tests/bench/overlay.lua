-- Times the overlay on .bench/NxC.csv (make it with gen.lua):
--   nvim --headless --clean -l tests/bench/overlay.lua 1000000x10
-- Opens the file with the overlay on (the default), then edits a cell. Prints
-- ms from the start of :edit to the first aligned screen, to the end of the
-- first scan, the redraw of one screen, the edit's on_lines, and the time from
-- the edit to the first redraw (the grown widths on screen; vim.wait can't
-- show it: it does not return while a scan keeps scheduling its next slice) and
-- to the end of the full re-scan.
local root = vim.fn.fnamemodify(arg[0], ":p:h:h:h")
vim.opt.rtp:prepend(root)
vim.cmd.runtime("plugin/csvkit.lua")
local overlay = require("csvkit.overlay")

local shape = arg[1] or error("usage: overlay.lua NxC")
local path = ("%s/.bench/%s.csv"):format(root, shape)
assert(vim.fn.filereadable(path) == 1, path .. " missing; run tests/bench/gen.lua")
vim.o.swapfile = false

local function ms(t0)
  return (vim.uv.hrtime() - t0) / 1e6
end
local function memory()
  local status = table.concat(vim.fn.readfile("/proc/self/status"), "\n")
  return tonumber(status:match("VmRSS:%s+(%d+)")) / 1024, tonumber(status:match("VmHWM:%s+(%d+)")) / 1024
end
local ns = vim.api.nvim_create_namespace("csvkit_align")

local t0 = vim.uv.hrtime()
vim.cmd("silent edit " .. vim.fn.fnameescape(path))
local buf = vim.api.nvim_get_current_buf()
local state = overlay.states[buf]
io.write(("first paint        %8.0f ms  (%d marks)\n"):format(ms(t0), #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})))
assert(vim.wait(600000, function()
  return not state.busy
end, 5))
io.write(("first scan done    %8.0f ms\n"):format(ms(t0)))

local t1 = vim.uv.hrtime()
for _ = 1, 30 do
  overlay.redraw(buf)
end
io.write(("redraw (one screen)%8.2f ms\n"):format(ms(t1) / 30))

-- grow the first column's widest cell, line 101
local want = state.widths[1] + 10
local first_redraw
local redraw = overlay.redraw
overlay.redraw = function(b)
  first_redraw = first_redraw or vim.uv.hrtime()
  return redraw(b)
end
local t2 = vim.uv.hrtime()
vim.api.nvim_buf_set_text(buf, 100, 0, 100, 1, { ("X"):rep(want) })
io.write(("on_lines           %8.2f ms\n"):format(ms(t2)))
local t3 = vim.uv.hrtime()
vim.wait(600000, function()
  return not state.busy
end, 5)
io.write(("widths grown       %8.0f ms after the edit (first redraw)\n"):format((first_redraw - t3) / 1e6))
io.write(("re-scan done       %8.0f ms after the edit\n"):format(ms(t3)))
assert(state.widths[1] >= want)
local rss, peak = memory()
io.write(("MEMORY rss %.0f MB peak %.0f MB\n"):format(rss, peak))
