-- Times the features run.lua does not: restore, the source filter, the table
-- view and the preview payload, on .bench/NxC.csv (make it with gen.lua):
--   nvim --headless --clean -l tests/bench/features.lua 100000x10 view|filter|restore|restore_file|preview
-- Each mode is its own process, so its peak memory is that feature's. A step's
-- "heap" is the Lua heap it leaves allocated (after a full GC). The code comes
-- from the tree this script is in; the file from that tree's .bench/.
local root = vim.fn.fnamemodify(arg[0], ":p:h:h:h")
vim.opt.rtp:prepend(root)
vim.cmd.runtime("plugin/csvkit.lua")
local csvkit = require("csvkit")

local shape, mode = arg[1], arg[2]
assert(shape and mode, "usage: features.lua NxC view|filter|restore|restore_file|preview")
local path = ("%s/.bench/%s.csv"):format(root, shape)
assert(vim.fn.filereadable(path) == 1, path .. " missing; run tests/bench/gen.lua")
vim.o.swapfile = false
vim.notify = function() end

local function memory()
  local status = table.concat(vim.fn.readfile("/proc/self/status"), "\n")
  return tonumber(status:match("VmRSS:%s+(%d+)")) / 1024, tonumber(status:match("VmHWM:%s+(%d+)")) / 1024
end

local function step(name, fn)
  collectgarbage()
  local heap = collectgarbage("count")
  local t0 = vim.uv.hrtime()
  local r = fn()
  local ms = (vim.uv.hrtime() - t0) / 1e6
  collectgarbage()
  io.write(("%-36s %8.0f ms  heap %+7.1f MB\n"):format(name, ms, (collectgarbage("count") - heap) / 1024))
  return r
end

local header = vim.split(vim.fn.readfile(path, "", 1)[1], ",", { plain = true })
local function col_of(name)
  return vim.fn.index(header, name) + 1
end

csvkit.setup({ date_formats = { "%Y-%m-%d", "%d/%m/%Y" }, align = { enabled = false } })

if mode == "restore" or mode == "restore_file" then
  -- a copy: :w must not change the bench file
  local file = vim.fn.tempname() .. ".csv"
  vim.uv.fs_copyfile(path, file)
  step("open (with the backup copy)", function()
    vim.cmd("silent edit " .. vim.fn.fnameescape(file))
  end)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.cmd("Csvkit sort price")
  vim.cmd("silent write")
  vim.api.nvim_buf_set_text(0, 10, 0, 10, 1, { "X" })
  if mode == "restore" then
    step(":Csvkit restore buffer", function()
      vim.cmd("Csvkit restore buffer")
    end)
  else
    vim.fn.confirm = function()
      return 1
    end
    step(":Csvkit restore file", function()
      vim.cmd("Csvkit restore file")
    end)
  end
  vim.fn.delete(file)
elseif mode == "filter" then
  vim.cmd("silent edit " .. vim.fn.fnameescape(path))
  local filter, edit = require("csvkit.filter"), require("csvkit.edit")
  local buf = vim.api.nvim_get_current_buf()
  step("filter flag = true (folds)", function()
    filter.set(buf, col_of("flag"), { ["true"] = true })
  end)
  step("filter qty blank (AND)", function()
    filter.set(buf, col_of("qty"), { [""] = true })
  end)
  step("filter clear", function()
    filter.clear(buf)
  end)
  local t = edit.read(buf)
  step("picker open: city (5 values)", function()
    filter.pick(t, col_of("city"))
  end)
  vim.cmd("close")
  step("picker open: id (all distinct)", function()
    filter.pick(t, col_of("id"))
  end)
  step("picker: toggle all (a)", function()
    vim.api.nvim_feedkeys("a", "x", false)
  end)
  vim.cmd("close")
elseif mode == "view" then
  vim.cmd("silent edit " .. vim.fn.fnameescape(path))
  local view = require("csvkit.view")
  local src = vim.api.nvim_get_current_buf()
  local vbuf
  step("open", function()
    vim.cmd("Csvkit view")
    vbuf = vim.api.nvim_get_current_buf()
  end)
  local state = view.states[vbuf]
  local function at_col(c) -- the cursor on the first row, in column c
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    vim.fn.cursor(5, vim.fn.virtcol2col(0, 5, state.starts[c] + 2))
  end
  step("scroll to the end", function()
    vim.cmd("normal! G")
    vim.cmd.redraw()
    vim.api.nvim_exec_autocmds("WinScrolled", {})
  end)
  vim.cmd("normal! gg")
  step("sort price (number)", function()
    vim.cmd("Csvkit sort price")
  end)
  step("sort name (text)", function()
    vim.cmd("Csvkit sort name")
  end)
  step("sort price desc", function()
    vim.cmd("Csvkit sort price desc")
  end)
  step("filter flag = true", function()
    view.set_filter(vbuf, col_of("flag"), { ["true"] = true })
  end)
  step("edit a cell (first edit)", function()
    view.set_cell(vbuf, 6, col_of("name"), "Zed")
  end)
  step("edit a cell", function()
    view.set_cell(vbuf, 7, col_of("name"), "Zoe")
  end)
  step("edit a cell in the sorted column", function()
    view.set_cell(vbuf, 8, col_of("price"), "1")
  end)
  step("row add", function()
    vim.api.nvim_win_set_cursor(0, { 6, 0 })
    view.add_row(vbuf, false)
  end)
  at_col(col_of("qty"))
  step("addcol value", function()
    vim.cmd("Csvkit addcol tag value x")
  end)
  at_col(col_of("price"))
  step("addcol formula price * qty + 1", function()
    vim.cmd("Csvkit addcol total formula price * qty + 1")
  end)
  step("apply sort (edits + order)", function()
    vim.cmd("Csvkit apply sort")
  end)
  step("discard", function()
    vim.cmd("Csvkit discard")
  end)
  -- the source changes: the view reads it again after its debounce (the
  -- refresh that apply started runs first)
  vim.wait(view.DEBOUNCE * 3)
  vim.api.nvim_buf_set_text(src, 10, 0, 10, 1, { "Y" })
  local tick = vim.b[src].changedtick
  local t0 = vim.uv.hrtime()
  vim.wait(60000, function()
    return state.t.tick == tick
  end, 1)
  io.write(("%-36s %8.0f ms\n"):format("follow a source edit (no debounce)", (vim.uv.hrtime() - t0) / 1e6 - view.DEBOUNCE))
elseif mode == "preview" then
  vim.cmd("silent edit " .. vim.fn.fnameescape(path))
  local preview = require("csvkit.preview")
  local buf = vim.api.nvim_get_current_buf()
  local payload = step("payload", function()
    return preview.payload(buf)
  end)
  local json = step("vim.json.encode", function()
    return vim.json.encode(payload)
  end)
  io.write(("  %.1f MB of JSON\n"):format(#json / 1e6))
  payload, json = nil, nil
  local url
  vim.ui.open = function(u)
    url = u
  end
  preview.start(buf)
  local base = url:gsub("/%?buf=", "/data?buf=")
  step("GET /data (payload + JSON + send)", function()
    local done
    vim.system({ "curl", "-s", "-o", "/dev/null", base }, {}, function()
      done = true
    end)
    vim.wait(600000, function()
      return done
    end, 1)
  end)
  preview.stop()
else
  error("unknown mode " .. mode)
end
local rss, peak = memory()
io.write(("MEMORY rss %.0f MB peak %.0f MB\n"):format(rss, peak))
