-- In-buffer alignment: extmarks on the visible lines and the sticky header (overlay.lua).
vim.cmd.runtime("plugin/csvkit.lua")
local overlay = require("csvkit.overlay")
local ns = vim.api.nvim_create_namespace("csvkit_align")

-- A listed buffer shown in the current window, which is the only one, with
-- the overlay off everywhere and the window options at their defaults.
local function show(lines)
  for buf in pairs(overlay.states) do
    overlay.disable(buf)
  end
  if #vim.api.nvim_list_wins() > 1 then
    vim.cmd("only")
  end
  vim.wo.conceallevel, vim.wo.concealcursor, vim.wo.winbar = 0, "", ""
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

-- Waits until the width scan and any debounce are over.
local function settle(buf)
  assert(vim.wait(5000, function()
    return not overlay.states[buf].busy
  end, 5), "the overlay never settled")
end

-- o: the buffer's vim.b.csvkit; by default no header row, so the widths are
-- the cells' own (a sticky header adds its column indexes to the first line).
local function on(lines, o)
  local buf = show(lines)
  vim.b[buf].csvkit = o or { header = false }
  overlay.enable(buf)
  settle(buf)
  return buf
end

-- Per row (1-based), per delimiter column (0-based): the text of the padding
-- before it, the separator shown instead of it and the text after it.
local function marks(buf)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local row, col, d = m[2] + 1, m[3], m[4]
    local cell = out[row] or {}
    out[row] = cell
    if d.conceal then
      cell[col] = cell[col] or {}
      cell[col].sep = d.conceal
      cell[col].before = d.virt_text and d.virt_text[1][1]
    else -- the space after a separator sits at the start of the next field
      cell[col - 1] = cell[col - 1] or {}
      cell[col - 1].after = d.virt_text[1][1]
    end
  end
  return out
end

local function count(buf)
  return #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
end

-- Evaluates the winbar of the current window.
local function winbar()
  vim.g.statusline_winid = vim.api.nvim_get_current_win()
  local text = overlay.winbar()
  vim.g.statusline_winid = nil
  return text
end

return {
  ["pads each field to its column's widest cell"] = function()
    local buf = on({ "a,bbb,c", "aaaa,b,cc" })
    eq(overlay.states[buf].widths, { 4, 3, 2 })
    eq(marks(buf), {
      [1] = { [1] = { before = "   " .. " ", sep = "│", after = " " }, [5] = { before = " ", sep = "│", after = " " } },
      [2] = { [4] = { before = " ", sep = "│", after = " " }, [6] = { before = "   ", sep = "│", after = " " } },
    })
  end,

  ["widths cover the whole file, not the visible lines"] = function()
    local lines = { "a,b" }
    for i = 2, 9000 do
      lines[i] = "x,y"
    end
    lines[9000] = "x,wide cell"
    local buf = on(lines)
    eq(overlay.states[buf].widths, { 1, 9 })
    eq(marks(buf)[1][1].before, " ") -- the first field is already as wide as it gets
    eq(count(buf) < 200, true)
  end,

  ["a quoted delimiter stays in its field and widths are display widths"] = function()
    local buf = on({ '"a,b",c', "é,日本" })
    eq(overlay.states[buf].widths, { 5, 4 })
    eq(marks(buf)[1][5].before, " ") -- field 1 is the 5 bytes "a,b" with its quotes
    eq(marks(buf)[2][2].before, "     ") -- é is 2 bytes and 1 cell
    eq(vim.tbl_count(marks(buf)[1]), 1)
  end,

  ["a doubled quote does not end a field, on its line or in a record spanning lines"] = function()
    local buf = on({ '"a""b,c",d', 'x,"one', 'a ""q"" b', 'end",y', "z,w" })
    eq(overlay.states[buf].widths, { 8, 1 })
    eq(marks(buf)[1][8].before, " ")
    eq(marks(buf)[3], nil)
    eq(marks(buf)[4], nil)
    eq(vim.tbl_keys(marks(buf)[5]), { 1 })
  end,

  ["the delimiter is concealed, whatever it is"] = function()
    local buf = on({ "a\tbb", "aa\tb" })
    eq(marks(buf)[1][1].sep, "│")
    eq(marks(buf)[1][1].before, "  ")
  end,

  ["a short or blank row only gets marks for its own delimiters"] = function()
    local buf = on({ "a,b,c", "", "x,y" })
    eq(vim.tbl_keys(marks(buf)[1]), { 1, 3 })
    eq(marks(buf)[2], nil)
    eq(vim.tbl_keys(marks(buf)[3]), { 1 })
  end,

  ["a record spanning lines is left unaligned and keeps out of the widths"] = function()
    local buf = on({ "a,b", 'longer,"two', 'lines",x', "c,d" })
    eq(overlay.states[buf].widths, { 1, 1 })
    eq(marks(buf)[2], nil)
    eq(marks(buf)[3], nil)
    eq(vim.tbl_keys(marks(buf)[4]), { 1 })
  end,

  ["a record with two cells spanning lines is unaligned to its end, and keeps out of the widths"] = function()
    local buf = on({ "a,b", 'c,"one', 'end","two', 'more lines",x', "longer,d" })
    eq(overlay.states[buf].widths, { 6, 1 })
    eq(marks(buf)[3], nil)
    eq(marks(buf)[4], nil)
    eq(vim.tbl_keys(marks(buf)[5]), { 6 })
  end,

  ["a record spanning lines stays unaligned after lines are added above it"] = function()
    local buf = on({ "a,b", 'c,"two', 'lines",x' })
    vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "q,r" })
    settle(buf)
    eq(marks(buf)[3], nil)
    eq(marks(buf)[4], nil)
    eq(vim.tbl_keys(marks(buf)[2]), { 1 })
  end,

  ["records spanning lines move with the lines before the widths are measured again"] = function()
    local buf = on({ "a,b", 'c,"two', 'lines",x' })
    vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "q,r" })
    overlay.redraw(buf) -- the debounce has not run
    eq(marks(buf)[3], nil)
    eq(marks(buf)[4], nil)
    eq(vim.tbl_keys(marks(buf)[2]), { 1 })
    settle(buf)
    vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "c,d" }) -- the record's first line is replaced
    overlay.redraw(buf)
    eq(vim.tbl_keys(marks(buf)[3]), { 1 })
  end,

  ["records spanning lines follow each edit at once: kept above, moved below, dropped inside (random)"] = function()
    math.randomseed(5)
    local lines = {}
    for i = 1, 60 do
      lines[#lines + 1] = i % 4 == 0 and ('%d,"a' .. i):format(i) or ("%d,x"):format(i)
      if i % 4 == 0 then
        lines[#lines + 1] = 'b"'
      end
    end
    local buf = on(lines)
    local state = overlay.states[buf]
    for _ = 1, 200 do
      local count = vim.api.nvim_buf_line_count(buf)
      local first = math.random(0, count - 1)
      local last = math.min(count, first + math.random(0, 3))
      local n = math.random(3) == 1 and math.random(0, 3) or last - first -- mostly in place
      local new = {}
      for k = 1, n do
        new[k] = "e" .. k .. ",y"
      end
      local before = state.opens
      local want = {}
      for l in pairs(before) do
        if l <= first then
          want[l] = true
        elseif l > last then
          want[l + n - (last - first)] = true
        end
      end
      vim.api.nvim_buf_set_lines(buf, first, last, false, new)
      eq(state.opens, want)
    end
    overlay.disable(buf)
  end,

  ["a scan in slices aligns the first screen before it is done"] = function()
    local lines = {}
    for i = 1, 100 do
      lines[i] = i .. ",x"
    end
    local chunk, slice = overlay.CHUNK, overlay.SLICE
    overlay.CHUNK, overlay.SLICE = 10, 0
    local buf = show(lines)
    vim.b[buf].csvkit = { header = false }
    overlay.enable(buf)
    overlay.CHUNK, overlay.SLICE = chunk, slice
    eq(overlay.states[buf].ready, false)
    eq(overlay.states[buf].widths, { 2, 1 }) -- the first 10 lines
    eq(marks(buf)[1] ~= nil, true)
    settle(buf)
    eq(overlay.states[buf].ready, true)
    eq(overlay.states[buf].widths, { 3, 1 })
  end,

  ["editing a cell updates the widths, longer and shorter"] = function()
    local buf = on({ "a,b", "c,d" })
    vim.api.nvim_buf_set_text(buf, 1, 0, 1, 1, { "long" })
    settle(buf)
    eq(overlay.states[buf].widths, { 4, 1 })
    eq(marks(buf)[1][1].before, "    ")
    vim.api.nvim_buf_set_text(buf, 1, 0, 1, 4, { "c" })
    settle(buf)
    eq(overlay.states[buf].widths, { 1, 1 })
    eq(marks(buf)[1][1].before, " ")
  end,

  ["a small edit grows the widths before the full scan is done"] = function()
    local buf = on({ "a,b", "c,d" })
    local state = overlay.states[buf]
    vim.api.nvim_buf_set_text(buf, 1, 0, 1, 1, { "long" })
    -- wait for the debounce only: the incremental step runs first
    vim.wait(overlay.DEBOUNCE + 50, function()
      return state.widths[1] == 4
    end, 5)
    eq(state.widths[1], 4)
  end,

  ["adding a row redraws with the new row aligned"] = function()
    local buf = on({ "a,b", "c,d" })
    vim.api.nvim_buf_set_lines(buf, 2, 2, false, { "wider,x" })
    settle(buf)
    eq(overlay.states[buf].widths, { 5, 1 })
    eq(marks(buf)[3][5].before, " ")
    eq(marks(buf)[1][1].before, "     ")
  end,

  ["only the visible lines have marks, and scrolling moves them"] = function()
    local lines = {}
    for i = 1, 10000 do
      lines[i] = i .. ",x"
    end
    local buf = on(lines)
    local n = count(buf)
    eq(n > 0 and n < 200, true)
    eq(marks(buf)[1] ~= nil and marks(buf)[5000] == nil, true)
    vim.cmd("normal! 5000Gzt")
    vim.api.nvim_exec_autocmds("WinScrolled", {})
    eq(marks(buf)[5000] ~= nil and marks(buf)[1] == nil, true)
    eq(count(buf) < 200, true)
  end,

  ["two windows on a buffer do not double the marks"] = function()
    local buf = on({ "a,bb", "cc,d" })
    local one = count(buf)
    vim.cmd("split")
    overlay.redraw(buf)
    eq(count(buf), one)
    vim.cmd("close")
  end,

  ["off removes the marks, restores the window and stops tracking"] = function()
    local buf = show({ "a,b", "cc,d" })
    vim.wo.conceallevel = 1
    vim.wo.winbar = "mine"
    overlay.enable(buf)
    settle(buf)
    eq(vim.wo.conceallevel, 2)
    eq(vim.wo.winbar ~= "mine", true)
    overlay.disable(buf)
    eq(count(buf), 0)
    eq(vim.wo.conceallevel, 1)
    eq(vim.wo.winbar, "mine")
    eq(overlay.states[buf], nil)
    vim.v.errmsg = ""
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "xxxx,y" }) -- nothing comes back
    vim.wait(overlay.DEBOUNCE + 50)
    eq(count(buf), 0)
    eq(vim.v.errmsg, "")
    vim.wo.conceallevel, vim.wo.winbar = 0, ""
  end,

  ["leaving the buffer restores the window, entering it sets it again"] = function()
    local buf = on({ "a,b" }, {})
    local other = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(other)
    eq(vim.wo.conceallevel, 0)
    eq(vim.wo.winbar, "")
    vim.api.nvim_set_current_buf(buf)
    eq(vim.wo.conceallevel, 2)
    eq(vim.wo.winbar ~= "", true)
    overlay.disable(buf)
  end,

  ["a float opened from the buffer (stats, the filter picker, a prompt) is left alone"] = function()
    -- nvim_open_win enters the float while it still shows this buffer: the
    -- overlay's winbar needs a line a 1-line float has not (E36)
    on({ "a,b", "1,2" }, { header = true })
    local main = vim.api.nvim_get_current_win()
    vim.v.errmsg = ""
    local win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {
      relative = "editor", row = 0, col = 0, width = 20, height = 1,
    })
    local winbar, errmsg = vim.wo[win].winbar, vim.v.errmsg
    vim.api.nvim_win_close(win, true)
    eq({ winbar, errmsg }, { "", "" })
    eq(vim.api.nvim_get_current_win(), main)
    eq(vim.wo.winbar, "%{%v:lua.require'csvkit.overlay'.winbar()%}") -- its own window keeps it
  end,

  ["enable twice changes nothing"] = function()
    local buf = on({ "a,bb", "cc,d" })
    local before = marks(buf)
    overlay.enable(buf)
    settle(buf)
    eq(marks(buf), before)
    overlay.disable(buf)
  end,

  ["a window split from an overlay window restores the original options"] = function()
    local buf = show({ "a,b" })
    vim.wo.conceallevel = 1
    overlay.enable(buf)
    vim.cmd("split")
    overlay.disable(buf)
    eq(vim.wo.conceallevel, 1)
    vim.cmd("close")
    vim.wo.conceallevel = 0
  end,

  ["wiping the buffer drops its state"] = function()
    local buf = on({ "a,b" })
    vim.api.nvim_buf_delete(buf, { force = true })
    eq(overlay.states[buf], nil)
  end,

  ["reloading or re-showing the file does not stack its autocmds"] = function()
    show({})
    local path = vim.fn.tempname() .. ".csv"
    vim.fn.writefile({ "a,b", "1,2" }, path)
    vim.cmd.edit(path)
    local buf = vim.api.nvim_get_current_buf()
    local function n()
      return #vim.api.nvim_get_autocmds({ group = "csvkit_align", buffer = buf })
    end
    eq(n(), 3)
    for _ = 1, 3 do
      vim.cmd("edit!")
    end
    eq(n(), 3)
    vim.cmd("enew")
    vim.cmd.bunload(buf)
    vim.cmd.buffer(buf)
    eq(n(), 3)
    vim.api.nvim_buf_delete(buf, { force = true })
  end,

  ["with a sticky header, a header cell counts with its index in its column's width"] = function()
    local buf = on({ "id,v", "1,2" }, {})
    eq(overlay.states[buf].widths, { 4, 3 }) -- "0 id", "1 v"
    eq(marks(buf)[2][1].before, "    ") -- "1" padded to 4, then the space before the separator
    overlay.disable(buf)
  end,

  ["goto with the overlay on: the column's separator is at the window's left edge"] = function()
    local buf = on({ "a,b,c", "aaaa,bbbb,cccc" }, {})
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd("Csvkit goto 1")
    vim.cmd.redraw()
    eq(vim.api.nvim_win_get_cursor(0), { 2, 5 })
    local row = vim.fn.win_screenpos(0)[1] + 2 -- under the winbar and line 1
    local shown = ""
    for c = 1, 6 do
      shown = shown .. vim.fn.screenstring(row, c)
    end
    eq(shown, "│ bbbb")
    overlay.disable(buf)
  end,

  ["the sticky header is the aligned first row"] = function()
    local buf = on({ "id,name", "1000,x" }, {})
    eq(winbar(), "0 id │ 1 name%<") -- each name after its index
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "id,name,more" })
    settle(buf)
    eq(winbar(), "0 id │ 1 name │ 2 more%<")
    overlay.disable(buf)
  end,

  ["the sticky header follows the horizontal scroll, the number column and escapes %"] = function()
    local buf = on({ "100%,name", "1000,x" }, {})
    eq(winbar(), "0 100%% │ 1 name%<")
    vim.wo.number = true
    local off = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].textoff
    eq(winbar(), (" "):rep(off) .. "0 100%% │ 1 name%<")
    vim.wo.number = false
    overlay.states[buf].leftcol[vim.api.nvim_get_current_win()] = 2
    eq(winbar(), "100%% │ 1 name%<")
    overlay.disable(buf)
  end,

  ["a header wider than the window is cut on the right, so it stays over its columns"] = function()
    local buf = on({ ("a"):rep(30) .. ",b", "1,2" }, {})
    local win = vim.api.nvim_get_current_win()
    vim.g.statusline_winid = win
    local shown = vim.api.nvim_eval_statusline(overlay.winbar(), { winid = win, use_winbar = true, maxwidth = 20 }).str
    vim.g.statusline_winid = nil
    eq(shown, "0 " .. ("a"):rep(17) .. ">")
    overlay.disable(buf)
  end,

  ["a header longer than Neovim's 4096-byte statusline buffer still starts at column 0"] = function()
    local names = {}
    for k = 1, 300 do
      names[k] = "Total_" .. k
    end
    local buf = on({ table.concat(names, ","), ("1,"):rep(299) .. "1" }, {})
    local win = vim.api.nvim_get_current_win()
    vim.g.statusline_winid = win
    local shown = vim.api.nvim_eval_statusline(overlay.winbar(), { winid = win, use_winbar = true }).str
    vim.g.statusline_winid = nil
    eq(vim.startswith(shown, "0 Total_1 │ 1 Total_2"), true)
    overlay.disable(buf)
  end,

  ["aligned lines do not wrap (a wrapped line would put its last columns under its first); off puts wrap back"] = function()
    local buf = show({ "a,b" })
    vim.wo.wrap = true
    overlay.enable(buf)
    eq(vim.wo.wrap, false)
    local other = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(other)
    eq(vim.wo.wrap, true)
    vim.api.nvim_set_current_buf(buf)
    eq(vim.wo.wrap, false)
    overlay.disable(buf)
    eq(vim.wo.wrap, true)
  end,

  ["no sticky header without the option, without a header row, or for a multiline header"] = function()
    local buf = on({ "a,b" }, { align = { sticky_header = false } })
    eq(vim.wo.winbar, "")
    overlay.disable(buf)
    buf = on({ "a,b" }, { header = false })
    eq(vim.wo.winbar, "")
    overlay.disable(buf)
    buf = on({ 'a,"b', 'c"', "x,y" }, {})
    eq(winbar(), "")
    overlay.disable(buf)
  end,

  ["the separator comes from the options"] = function()
    local buf = on({ "a,b" }, { align = { separator = "|" } })
    eq(marks(buf)[1][1].sep, "|")
    overlay.disable(buf)
  end,

  ["attach turns it on when align.enabled, not when it is off"] = function()
    local csvkit = require("csvkit")
    local buf = show({ "a,bb", "cc,d" })
    vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".csv")
    csvkit.attach(buf)
    eq(overlay.states[buf] ~= nil, true)
    overlay.disable(buf)
    csvkit.setup({ align = { enabled = false } })
    local off = show({ "a,bb" })
    vim.api.nvim_buf_set_name(off, vim.fn.tempname() .. ".csv")
    csvkit.attach(off)
    local on_after_attach = overlay.states[off]
    csvkit.setup({})
    overlay.disable(off) -- setup() attached it again
    eq(on_after_attach, nil)
  end,

  [":Csvkit align toggles, turns on and off, rejects other words"] = function()
    local buf = show({ "a,bb", "cc,d" })
    vim.cmd("Csvkit align")
    eq(overlay.states[buf] ~= nil, true)
    vim.cmd("Csvkit align")
    eq(overlay.states[buf], nil)
    vim.cmd("Csvkit align on")
    eq(overlay.states[buf] ~= nil, true)
    vim.cmd("Csvkit align off")
    eq(overlay.states[buf], nil)
    local msgs = {}
    local notify = vim.notify
    vim.notify = function(m)
      msgs[#msgs + 1] = m
    end
    vim.cmd("Csvkit align maybe")
    vim.notify = notify
    eq(msgs, { "csvkit: usage: align [on|off]" })
    eq(require("csvkit.command").complete("", "Csvkit align ", 13), { "on", "off" })
  end,

  ["the plug map toggles"] = function()
    local buf = show({ "a,b" })
    vim.cmd([[execute "normal \<Plug>(csvkit-align-toggle)"]])
    eq(overlay.states[buf] ~= nil, true)
    overlay.disable(buf)
  end,
}
