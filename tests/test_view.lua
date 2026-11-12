-- View buffer: the table, view-only sort and filter, <CR> to the source (view.lua).
vim.cmd.runtime("plugin/csvkit.lua")
local view = require("csvkit.view")
local filter = require("csvkit.filter")
local overlay = require("csvkit.overlay")

local PEOPLE = {
  "name,city,age",
  "Ana,Bogota,30", -- 2
  "Luis,Madrid,25", -- 3
  "Mia,Paris,9", -- 4
  "Eva,Madrid,41", -- 5
}

-- Opens lines in a fresh buffer in the only window, with no view, overlay or
-- filter left from an earlier test. Returns the source buffer.
local function open(lines)
  for vbuf in pairs(view.states) do
    pcall(vim.api.nvim_buf_delete, vbuf, { force = true })
  end
  for buf in pairs(overlay.states) do
    overlay.disable(buf)
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      vim.api.nvim_win_close(win, true)
    end
  end
  if #vim.api.nvim_list_wins() > 1 then
    vim.cmd("only")
  end
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

-- Opens the view of the current buffer; returns the source and view buffers.
local function open_view(lines)
  local src = open(lines)
  vim.cmd("Csvkit view")
  return src, vim.api.nvim_get_current_buf()
end

local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

-- The text of the view's record lines (no borders, no header), cells trimmed.
local function records(vbuf)
  local out = {}
  for _, l in ipairs(vim.list_slice(lines(vbuf), 5, vim.api.nvim_buf_line_count(vbuf) - 1)) do
    out[#out + 1] = vim.trim((l:gsub("│", " "):gsub(" +", " ")))
  end
  return out
end

-- Goes to the last line and runs what a real UI does after the scroll.
local function scroll_to_end()
  vim.cmd("normal! G")
  vim.cmd.redraw()
  vim.api.nvim_exec_autocmds("WinScrolled", {})
end

-- Puts the cursor of the view on line lnum, inside column c.
local function at(vbuf, lnum, c)
  local vcol = require("csvkit.view").states[vbuf].starts[c] + 2
  vim.api.nvim_win_set_cursor(0, { lnum, vim.fn.virtcol2col(0, lnum, vcol) - 1 })
end

local function press(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "mx", false)
end

return {
  ["renders a box table: borders, header, separator, left-aligned cells"] = function()
    local _, vbuf = open_view(PEOPLE)
    eq(lines(vbuf), {
      " 4 of 4 rows",
      "┌────────┬────────┬───────┐",
      "│ 0 name │ 1 city │ 2 age │",
      "├────────┼────────┼───────┤",
      "│ Ana    │ Bogota │ 30    │",
      "│ Luis   │ Madrid │ 25    │",
      "│ Mia    │ Paris  │ 9     │",
      "│ Eva    │ Madrid │ 41    │",
      "└────────┴────────┴───────┘",
    })
  end,

  ["is a read-only scratch buffer with filetype csvkit_view, in the current window (no split)"] = function()
    local src, vbuf = open_view(PEOPLE)
    eq(vim.bo[vbuf].filetype, "csvkit_view")
    eq(vim.bo[vbuf].buftype, "nofile")
    eq(vim.bo[vbuf].modifiable, false)
    eq(#vim.api.nvim_list_wins(), 1)
    eq(#vim.fn.win_findbuf(src), 0)
    eq(vim.wo.wrap, false)
  end,

  ["<CR> with no window on the source shows it in the view's window; :Csvkit view goes back to the same view"] = function()
    local src, vbuf = open_view(PEOPLE)
    vim.cmd("Csvkit addcol z value 1")
    vim.api.nvim_win_set_cursor(0, { 6, 0 })
    press("<CR>")
    eq(vim.api.nvim_get_current_buf(), src)
    eq(vim.api.nvim_win_get_cursor(0)[1], 3)
    eq(#vim.api.nvim_list_wins(), 1)
    vim.cmd("Csvkit view") -- the hidden view, staged edits kept; not a second one
    eq(vim.api.nvim_get_current_buf(), vbuf)
    eq(view.states[vbuf].pending.cols, 1)
    eq(vim.tbl_count(view.states), 1)
    eq(vim.wo.wrap, false)
  end,

  ["a hidden view is drawn again when shown, not on each change of the source"] = function()
    local src, vbuf = open_view(PEOPLE)
    vim.api.nvim_set_current_buf(src)
    vim.api.nvim_buf_set_lines(src, 1, 2, false, { "Ana,Lima,31" })
    vim.wait(view.DEBOUNCE + 100)
    eq(records(vbuf)[1], "Ana Bogota 30")
    vim.cmd("Csvkit view")
    eq(records(vbuf)[1], "Ana Lima 31")
  end,

  [":bdelete or :bwipeout of the view forgets it"] = function()
    for _, cmd in ipairs({ "bdelete", "bwipeout" }) do
      local src, vbuf = open_view(PEOPLE)
      vim.cmd(cmd .. " " .. vbuf)
      eq(view.states[vbuf], nil)
      vim.api.nvim_set_current_buf(src)
      vim.cmd("Csvkit view")
      assert(vim.api.nvim_get_current_buf() ~= vbuf)
    end
  end,

  ["filter {expr} in the view: ANDed with the value filters, on the first line, never applied"] = function()
    local src, vbuf = open_view(PEOPLE) -- ages 30 25 9 41
    vim.cmd("Csvkit filter age > 20")
    eq(records(vbuf), { "Ana Bogota 30", "Luis Madrid 25", "Eva Madrid 41" })
    eq(lines(vbuf)[1], " 3 of 4 rows │ filter age > 20")
    view.set_filter(vbuf, 2, { Madrid = true })
    eq(lines(vbuf)[1], " 2 of 4 rows │ filter city: Madrid; age > 20")
    local notes, notify = {}, vim.notify
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
    vim.cmd("Csvkit filter age + 1")
    vim.cmd("Csvkit filter nope")
    vim.notify = notify
    eq(notes, { "csvkit: filter: expected TRUE or FALSE, got number", 'csvkit: unknown column "nope" at position 1' })
    eq(records(vbuf), { "Luis Madrid 25", "Eva Madrid 41" }) -- the filter that was there stays
    vim.cmd("Csvkit filter clear")
    eq(lines(vbuf)[1], " 4 of 4 rows")
    eq(lines(src), PEOPLE)
  end,

  ["filter {expr} in the view sees staged cells and columns; a new row always shows"] = function()
    local _, vbuf = open_view(PEOPLE)
    at(vbuf, 5, 3)
    vim.cmd("Csvkit addcol double formula age * 2")
    vim.cmd("Csvkit filter double > 55")
    eq(records(vbuf), { "Ana Bogota 30 60", "Eva Madrid 41 82" })
    local ask = vim.ui.input
    vim.ui.input = function(_, cb)
      cb("10")
    end
    at(vbuf, 6, 4)
    press("i") -- Eva's double: no longer > 55
    vim.ui.input = ask
    eq(records(vbuf), { "Ana Bogota 30 60" })
    at(vbuf, 5, 1)
    vim.cmd("Csvkit row add below")
    eq(records(vbuf), { "Ana Bogota 30 60", "" })
    vim.cmd("Csvkit filter double > 50") -- worked out again: the new row still shows
    eq(records(vbuf), { "Ana Bogota 30 60", "" })
    -- discard drops the staged column, and the expression that needs it
    local notes, notify = {}, vim.notify
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
    vim.cmd("Csvkit discard")
    vim.notify = notify
    eq(notes, { 'csvkit: filter double > 50 removed: unknown column "double" at position 1' })
    eq(lines(vbuf)[1], " 4 of 4 rows")
  end,

  ["by default no cell is cut: a column is as wide as its widest value, as when aligned"] = function()
    local long = ("x"):rep(150)
    local _, vbuf = open_view({ "id,note", "1," .. long, "2,b" })
    eq(records(vbuf), { "1 " .. long, "2 b" })
  end,

  ["cells are cut to view.max_col_width with a …, newlines show as ⏎"] = function()
    vim.b.csvkit = nil
    local src = open({ 'id,note', '1,"abcdefgh"', '2,"a', 'b"', "3,héllo wörld", "4,abcde", "5,abcdef" })
    vim.b[src].csvkit = { view = { max_col_width = 5 } }
    vim.cmd("Csvkit view")
    eq(records(vim.api.nvim_get_current_buf()), { "1 abcd…", "2 a⏎b", "3 héll…", "4 abcde", "5 abcd…" })
  end,

  ["view.max_col_width: 0 cuts nothing; anything but 0 or a positive whole number is refused"] = function()
    vim.b.csvkit = nil
    local src = open({ "id,note", "1,abcdefgh" })
    vim.b[src].csvkit = { view = { max_col_width = 0 } }
    vim.cmd("Csvkit view")
    eq(records(vim.api.nvim_get_current_buf()), { "1 abcdefgh" })
    vim.cmd("bwipeout")
    for _, bad in ipairs({ -1, 2.5, false, true, "10" }) do
      vim.api.nvim_set_current_buf(src)
      vim.b[src].csvkit = { view = { max_col_width = bad } }
      local msgs, notify = {}, vim.notify
      vim.notify = function(msg)
        msgs[#msgs + 1] = msg
      end
      vim.cmd("Csvkit view")
      vim.notify = notify
      eq(#msgs, 1)
      assert(msgs[1]:find("view.max_col_width must be 0 (no limit) or a positive whole number", 1, true), msgs[1])
      eq(vim.api.nvim_get_current_buf(), src) -- no view opened
    end
  end,

  ["a header-less file is headed by column numbers"] = function()
    local src = open({ "a,b", "c,d" })
    vim.b[src].csvkit = { header = false }
    vim.cmd("Csvkit view")
    local vbuf = vim.api.nvim_get_current_buf()
    eq(lines(vbuf)[3], "│ 0 │ 1 │")
    eq(#lines(vbuf), 7)
  end,

  ["ragged rows widen the table to the longest record"] = function()
    local _, vbuf = open_view({ "a,b", "1,2,3", "4" })
    eq(lines(vbuf)[3], "│ 0 a │ 1 b │ 2 │")
    eq(lines(vbuf)[6], "│ 4   │     │   │")
  end,

  ["a record on several lines is one line, and <CR> goes to its first line"] = function()
    local src, vbuf = open_view({ "id,note", '1,"a', 'b"', "2,x" })
    eq(#lines(vbuf), 7)
    vim.api.nvim_win_set_cursor(0, { 6, 0 })
    press("<CR>")
    eq(vim.api.nvim_get_current_buf(), src)
    eq(vim.api.nvim_win_get_cursor(0)[1], 4)
    eq(vim.api.nvim_buf_get_lines(src, 3, 4, false), { "2,x" })
  end,

  ["<CR> on a border does nothing; on the header it goes to line 1"] = function()
    local _, vbuf = open_view(PEOPLE)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    press("<CR>")
    eq(vim.api.nvim_get_current_buf(), vbuf)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    press("<CR>")
    eq(vim.api.nvim_win_get_cursor(0)[1], 1)
  end,

  ["<CR> jumps in the window that already shows the source"] = function()
    local src, vbuf = open_view(PEOPLE)
    local view_win = vim.api.nvim_get_current_win()
    vim.cmd("split")
    vim.api.nvim_set_current_buf(src)
    local src_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(view_win)
    vim.api.nvim_win_set_cursor(0, { 6, 0 })
    press("<CR>")
    eq(vim.api.nvim_get_current_win(), src_win)
    eq(vim.api.nvim_win_get_cursor(0)[1], 3)
    eq(#vim.api.nvim_list_wins(), 2)
    eq(vim.api.nvim_buf_is_valid(vbuf), true)
  end,

  ["sort reorders the view only: the source lines are unchanged"] = function()
    local src, vbuf = open_view(PEOPLE)
    local tick = vim.b[src].changedtick
    vim.cmd("Csvkit sort age desc")
    eq(records(vbuf), { "Eva Madrid 41", "Ana Bogota 30", "Luis Madrid 25", "Mia Paris 9" })
    eq(lines(src), PEOPLE)
    eq(vim.b[src].changedtick, tick)
    vim.cmd("Csvkit sort age")
    eq(records(vbuf), { "Mia Paris 9", "Luis Madrid 25", "Ana Bogota 30", "Eva Madrid 41" })
  end,

  ["sort with no column uses the column under the cursor, by name or number too"] = function()
    local _, vbuf = open_view(PEOPLE)
    vim.api.nvim_win_set_cursor(0, { 5, 11 }) -- inside the city column
    vim.cmd("Csvkit sort desc")
    eq(records(vbuf)[1], "Mia Paris 9")
    vim.cmd("Csvkit sort 0 desc")
    eq(records(vbuf)[1], "Mia Paris 9")
    vim.cmd("Csvkit sort 2 str")
    eq(records(vbuf), { "Luis Madrid 25", "Ana Bogota 30", "Eva Madrid 41", "Mia Paris 9" })
  end,

  ["goto {col} in the view: the cursor goes to the cell, its bar at the left edge"] = function()
    local _, vbuf = open_view(PEOPLE)
    vim.api.nvim_win_set_cursor(0, { 6, 0 })
    vim.cmd("Csvkit goto 2")
    eq(view.cursor_col(vbuf), 3)
    eq(vim.fn.virtcol("."), view.states[vbuf].starts[3] + 2)
    eq(vim.fn.winsaveview().leftcol, view.states[vbuf].starts[3] - 1)
    eq(vim.api.nvim_win_get_cursor(0)[1], 6)
    vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- the first line: to the header
    vim.cmd("Csvkit goto city")
    eq({ vim.api.nvim_win_get_cursor(0)[1], view.cursor_col(vbuf) }, { 3, 2 })
  end,

  ["hide {col}: the column leaves the table, the rest keep their numbers; hide clear brings it back"] = function()
    local src, vbuf = open_view(PEOPLE)
    vim.cmd("Csvkit hide city")
    eq(lines(vbuf)[3], "│ 0 name │ 2 age │")
    eq(lines(vbuf)[1], " 4 of 4 rows │ hidden city")
    eq(records(vbuf)[1], "Ana 30")
    vim.cmd("Csvkit goto age")
    eq(view.cursor_col(vbuf), 3)
    vim.cmd("Csvkit sort desc") -- the cursor's column: age
    eq(records(vbuf)[1], "Eva 41")
    local notes, notify = {}, vim.notify
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
    vim.cmd("Csvkit goto city")
    vim.cmd("Csvkit hide name")
    vim.cmd("Csvkit hide age") -- the last one shown
    vim.notify = notify
    eq(notes, { 'csvkit: column "city" is hidden', "csvkit: can't hide every column" })
    vim.cmd("Csvkit hide clear")
    eq(lines(vbuf)[3], "│ 0 name │ 1 city │ 2 age │")
    eq(lines(src), PEOPLE)
  end,

  ["a hidden column stays hidden as staged columns come and go, and is still written by apply"] = function()
    local src, vbuf = open_view(PEOPLE)
    vim.cmd("Csvkit hide age")
    at(vbuf, 5, 1)
    vim.cmd("Csvkit addcol z value 1") -- after name: age is column 3 now
    eq(lines(vbuf)[3], "│ 0 name │ 1 z │ 2 city │")
    vim.cmd("Csvkit discard")
    eq(lines(vbuf)[3], "│ 0 name │ 1 city │")
    vim.cmd("Csvkit addcol z value 1")
    vim.cmd("Csvkit apply")
    eq(lines(src)[2], "Ana,1,Bogota,30")
    eq(lines(vbuf)[3], "│ 0 name │ 1 z │ 2 city │")
  end,

  ["delcol in the view is staged; apply writes the file without the column"] = function()
    local src, vbuf = open_view({ "name,city,age", "Ana,Bogota,30", "Luis,Madrid,25" })
    vim.cmd("Csvkit delcol city")
    eq(lines(vbuf)[3], "│ 0 name │ 1 age │")
    eq(records(vbuf), { "Ana 30", "Luis 25" })
    eq(lines(vbuf)[1], " 2 of 2 rows │ staged: 1 deleted column (:Csvkit apply | discard)")
    vim.cmd("Csvkit filter age > 26") -- formulas see the columns that are left
    eq(records(vbuf), { "Ana 30" })
    vim.cmd("Csvkit filter clear")
    eq(lines(src), { "name,city,age", "Ana,Bogota,30", "Luis,Madrid,25" })
    vim.cmd("Csvkit apply")
    eq(lines(src), { "name,age", "Ana,30", "Luis,25" })
    eq(lines(vbuf)[1], " 2 of 2 rows")
  end,

  ["delcol keeps the sort, filters and hidden columns on their columns; a staged column just goes; discard undoes it"] = function()
    local src, vbuf = open_view(PEOPLE)
    vim.cmd("Csvkit sort age desc")
    view.set_filter(vbuf, 3, { ["30"] = true, ["41"] = true })
    vim.cmd("Csvkit delcol name")
    eq(records(vbuf), { "Madrid 41", "Bogota 30" })
    eq(lines(vbuf)[1], " 2 of 4 rows │ filter age: 30, 41 │ sort age ↓ │ staged: 1 deleted column (:Csvkit apply | discard)")
    at(vbuf, 5, 2)
    vim.cmd("Csvkit addcol z value 1")
    vim.cmd("Csvkit hide age")
    vim.cmd("Csvkit delcol z")
    eq(lines(vbuf)[3], "│ 0 city │")
    eq(lines(vbuf)[1], " 2 of 4 rows │ filter age: 30, 41 │ sort age ↓ │ hidden age │ staged: 1 deleted column (:Csvkit apply | discard)")
    vim.cmd("Csvkit discard")
    eq(lines(vbuf)[3], "│ 0 name │ 1 city │")
    eq(records(vbuf), { "Ana Bogota", "Eva Madrid" })
    eq(lines(src), PEOPLE)
  end,

  ["stats in the view: the rows shown, staged cells included"] = function()
    local src, vbuf = open_view(PEOPLE)
    vim.cmd("Csvkit setcol age formula age * 2")
    vim.cmd('Csvkit filter city = "Madrid"')
    vim.cmd("Csvkit stats age")
    eq(vim.list_slice(lines(0), 2, 7), {
      "rows         2",
      "empty        0",
      "unique       2",
      "most common  50 (1 time)",
      "min          50",
      "max          82",
    })
    vim.cmd("close")
    eq(vim.api.nvim_get_current_buf(), vbuf)
    vim.cmd("6,7Csvkit stats age") -- view lines: the second and third rows shown
    eq(vim.api.nvim_win_get_config(0).title, { { " Stats: age (lines 6-7) " } })
    eq(lines(0)[2], "rows         1")
    vim.cmd("close")
    vim.cmd("Csvkit filter clear")
    vim.cmd("5,6Csvkit stats age")
    eq(vim.list_slice(lines(0), 2, 7), { "rows         2", "empty        0", "unique       2", "most common  50 (1 time)", "min          50", "max          60" })
    vim.cmd("close")
    eq(lines(src), PEOPLE)
  end,

  ["<CR> on the first line shows all of it: every filter value and hidden column"] = function()
    local _, vbuf = open_view({ "a,b,c,d,e", "1,p,3,4,5", "2,q,3,4,5", "3,r,3,4,5", "4,s,3,4,5", "5,t,3,4,5" })
    view.set_filter(vbuf, 2, { p = true, q = true, r = true, s = true })
    vim.cmd("Csvkit filter a > 1")
    vim.cmd("Csvkit hide c d")
    eq(lines(vbuf)[1], " 3 of 5 rows │ filter b: p, q, r +1; a > 1 │ hidden c, d")
    local notes, notify = {}, vim.notify
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local ok, err = pcall(press, "<CR>")
    vim.notify = notify
    assert(ok, err)
    eq(notes, { "csvkit view:\n3 of 5 rows\nfilter b: p, q, r, s\nfilter a > 1\nhidden c, d" })
    eq(vim.api.nvim_get_current_buf(), vbuf)
  end,

  ["addcol before 0 in the view stages a first column, apply writes it there"] = function()
    local src, vbuf = open_view({ "a,b", '"x', 'y",2', "3,4" })
    at(vbuf, 5, 2)
    vim.cmd("Csvkit addcol n before 0 value v")
    vim.cmd("Csvkit addcol m after a value w")
    eq(lines(vbuf)[3], "│ 0 n │ 1 a │ 2 m │ 3 b │")
    vim.cmd("Csvkit apply")
    eq(lines(src), { "n,a,m,b", 'v,"x', 'y",w,2', "v,3,w,4" })
  end,

  ["delcol with edited cells, new rows and staged columns writes them all"] = function()
    local src, vbuf = open_view({ "a,b,c", "1,2,3", "4,5,6" })
    at(vbuf, 5, 1)
    vim.cmd("Csvkit addcol n value x") -- a, n, b, c
    vim.cmd("Csvkit row add below")
    local ask = vim.ui.input
    vim.ui.input = function(_, cb)
      cb("9")
    end
    at(vbuf, 5, 4)
    press("i") -- row 1, c = 9
    vim.ui.input = ask
    vim.cmd("Csvkit delcol b")
    vim.cmd("Csvkit apply")
    eq(lines(src), { "a,n,c", "1,x,9", ",,", "4,x,6" })
  end,

  ["row delete in the view is staged: at the cursor, a range, where {expr}, hidden; apply writes it"] = function()
    local src, vbuf = open_view(PEOPLE) -- Ana 30, Luis 25, Mia 9, Eva 41
    vim.api.nvim_win_set_cursor(0, { 6, 0 }) -- Luis
    vim.cmd("Csvkit row delete")
    eq(records(vbuf), { "Ana Bogota 30", "Mia Paris 9", "Eva Madrid 41" })
    eq(lines(vbuf)[1], " 3 of 3 rows │ staged: 1 deleted row (:Csvkit apply | discard)")
    eq(lines(src), PEOPLE)
    vim.cmd("Csvkit row delete where age < 10")
    eq(records(vbuf), { "Ana Bogota 30", "Eva Madrid 41" })
    vim.cmd("Csvkit filter age > 35")
    vim.cmd("Csvkit row delete hidden")
    vim.cmd("Csvkit filter clear")
    eq(records(vbuf), { "Eva Madrid 41" })
    vim.cmd("Csvkit apply")
    eq(lines(src), { "name,city,age", "Eva,Madrid,41" })
  end,

  ["row delete in the view: a range of view lines; a new row just goes; discard brings rows back"] = function()
    local src, vbuf = open_view(PEOPLE)
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    vim.cmd("Csvkit row add below")
    eq(lines(vbuf)[1], " 5 of 5 rows │ staged: 1 new row (:Csvkit apply | discard)")
    vim.cmd("6,7Csvkit row delete") -- the new row and Luis
    eq(records(vbuf), { "Ana Bogota 30", "Mia Paris 9", "Eva Madrid 41" })
    eq(lines(vbuf)[1], " 3 of 3 rows │ staged: 1 deleted row (:Csvkit apply | discard)")
    local notes, notify = {}, vim.notify
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
    vim.cmd("1,3Csvkit row delete") -- no row on those lines
    vim.notify = notify
    eq(notes, { "csvkit: put the cursor on a row" })
    eq(#records(vbuf), 3)
    vim.cmd("Csvkit discard")
    eq(#records(vbuf), 4)
    eq(lines(src), PEOPLE)
  end,

  ["row delete keeps staged columns on their rows and drops the edits of the rows it deletes"] = function()
    local src, vbuf = open_view(PEOPLE) -- Ana 30, Luis 25, Mia 9, Eva 41
    at(vbuf, 5, 3)
    vim.cmd("Csvkit addcol double formula age * 2")
    local ask = vim.ui.input
    vim.ui.input = function(_, cb)
      cb("x")
    end
    at(vbuf, 6, 1)
    press("i") -- Luis's name
    vim.ui.input = ask
    eq(lines(vbuf)[1], " 4 of 4 rows │ staged: 1 new column, 1 edited cell (:Csvkit apply | discard)")
    vim.api.nvim_win_set_cursor(0, { 6, 0 })
    vim.cmd("Csvkit row delete") -- the edited row
    eq(lines(vbuf)[1], " 3 of 3 rows │ staged: 1 new column, 1 deleted row (:Csvkit apply | discard)")
    eq(records(vbuf), { "Ana Bogota 30 60", "Mia Paris 9 18", "Eva Madrid 41 82" })
    vim.cmd("Csvkit apply")
    eq(lines(src), { "name,city,age,double", "Ana,Bogota,30,60", "Mia,Paris,9,18", "Eva,Madrid,41,82" })
  end,

  ["setcol in the view stages only the cells that change; apply writes them"] = function()
    local src, vbuf = open_view({ "a,b", "1,x", '"2",y', "3,z" })
    vim.cmd("Csvkit setcol a formula IF(a = 2, 2, a * 10)")
    eq(records(vbuf), { "10 x", "2 y", "30 z" })
    assert(lines(vbuf)[1]:find("staged: 2 edited cells", 1, true), lines(vbuf)[1])
    vim.cmd("Csvkit apply")
    eq(lines(src), { "a,b", "10,x", '"2",y', "30,z" }) -- the row nothing changed keeps its text
  end,

  ["PREV in the view: the rows as sorted and filtered when the command runs"] = function()
    local src, vbuf = open_view({ "year,region,total,g", "2000,A,100,", "2001,B,7,", "2002,A,110,", "2003,B,8,", "2004,A,121," })
    vim.cmd("Csvkit sort year desc")
    vim.cmd('Csvkit filter region = "A"')
    -- shown: 2004, 2002, 2000; the hidden B rows are left alone
    vim.cmd("Csvkit setcol g formula PREV(total)")
    vim.cmd("Csvkit filter clear")
    eq(records(vbuf), { "2004 A 121 0", "2003 B 8", "2002 A 110 121", "2001 B 7", "2000 A 100 110" })
    local notes, notify = {}, vim.notify
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
    vim.cmd("Csvkit filter PREV(total) > 1")
    vim.notify = notify
    eq(notes, { "csvkit: PREV works in addcol and setcol, not in filters" })
    eq(view.states[vbuf].expr, nil)
    vim.cmd("Csvkit discard")
    vim.cmd("Csvkit setcol g formula PREV(total)")
    vim.cmd("Csvkit apply")
    eq(lines(src), { "year,region,total,g", "2000,A,100,0", "2001,B,7,100", "2002,A,110,7", "2003,B,8,110", "2004,A,121,8" })
  end,

  ["formulas in the view see only the visible rows: setcol, addcol, aggregates, row delete where"] = function()
    local src, vbuf = open_view({ "year,region,total,g", "2000,A,100,", "2001,B,7,b", "2002,A,110,", "2003,B,8,b", "2004,A,121," })
    vim.cmd('Csvkit filter region = "A"')
    local notes, notify = {}, vim.notify
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
    vim.cmd("Csvkit setcol g formula SUM(total)")
    vim.cmd("Csvkit addcol growth after total formula (total - PREV(total)) / PREV(total)")
    vim.cmd("Csvkit row delete where total < 50")
    vim.notify = notify
    eq(notes, { "csvkit: 1 cell failed (rows 2): division by zero", "csvkit: no row matches; nothing deleted" })
    vim.cmd("Csvkit filter clear")
    eq(records(vbuf), { "2000 A 100 331", "2001 B 7 b", "2002 A 110 0.1 331", "2003 B 8 b", "2004 A 121 0.1 331" })
    vim.cmd("Csvkit apply")
    eq(lines(src), { "year,region,total,growth,g", "2000,A,100,,331", "2001,B,7,,b", "2002,A,110,0.1,331", "2003,B,8,,b", "2004,A,121,0.1,331" })
    -- a filter expression still reads every row, the ones hidden before too
    vim.cmd('Csvkit filter region = "A"')
    vim.cmd('Csvkit filter region = "B"')
    eq(records(vbuf), { "2001 B 7 b", "2003 B 8 b" })
  end,

  ["negative column numbers in the view count from the end"] = function()
    local _, vbuf = open_view({ "a,b,c,d,e", "1,2,3,4,5" })
    vim.cmd("Csvkit hide -1 1--3")
    eq(lines(vbuf)[3], "│ 0 a │ 3 d │")
    vim.cmd("Csvkit hide clear")
    vim.cmd("Csvkit delcol -2")
    eq(lines(vbuf)[3], "│ 0 a │ 1 b │ 2 c │ 3 e │")
    vim.cmd("Csvkit goto -1")
    eq(vim.api.nvim_win_get_cursor(0)[2], vim.fn.virtcol2col(0, 3, view.states[vbuf].starts[4] + 2) - 1)
    vim.cmd("Csvkit addcol z formula $-1 * 2")
    eq(lines(vbuf)[3], "│ 0 a │ 1 b │ 2 c │ 3 e │ 4 z │")
    vim.cmd("Csvkit sort -1 desc")
    eq(view.states[vbuf].sort.col, 5)
  end,

  ["delcol and hide take several columns and ranges in the view"] = function()
    local src, vbuf = open_view({ "a,b,c,d,e", "1,2,3,4,5" })
    vim.cmd("Csvkit hide 1-2 e")
    eq(lines(vbuf)[3], "│ 0 a │ 3 d │")
    eq(lines(vbuf)[1], " 1 of 1 row │ hidden b, c, e")
    local notes, notify = {}, vim.notify
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
    vim.cmd("Csvkit hide a d")
    vim.cmd("Csvkit delcol 0-4")
    vim.notify = notify
    eq(notes, { "csvkit: can't hide every column", "csvkit: can't delete every column" })
    vim.cmd("Csvkit hide a b") -- b is hidden already: d still shows
    eq(lines(vbuf)[3], "│ 3 d │")
    vim.cmd("Csvkit hide clear")
    vim.cmd("Csvkit delcol 3 0-1")
    eq(lines(vbuf)[3], "│ 0 c │ 1 e │")
    eq(lines(vbuf)[1], " 1 of 1 row │ staged: 3 deleted columns (:Csvkit apply | discard)")
    vim.cmd("Csvkit apply")
    eq(lines(src), { "c,e", "3,5" })
  end,

  ["hide outside a view is an error"] = function()
    local buf = open(PEOPLE)
    local notes, notify = {}, vim.notify
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
    vim.cmd("Csvkit hide city")
    vim.notify = notify
    eq(notes, { "csvkit: hide works in :Csvkit view and the browser preview" })
    eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), PEOPLE)
  end,

  ["the cursor on a column's left bar belongs to that column"] = function()
    local _, vbuf = open_view(PEOPLE)
    vim.api.nvim_win_set_cursor(0, { 5, 0 }) -- the first bar
    vim.cmd("Csvkit sort desc")
    eq(records(vbuf)[1], "Mia Paris 9") -- name, descending
    vim.api.nvim_win_set_cursor(0, { 5, 11 }) -- the bar before city: "│ Ana    │"
    vim.cmd("Csvkit sort asc")
    eq(records(vbuf)[1], "Ana Bogota 30") -- city, ascending
    eq(view.states[vbuf].sort.col, 2)
  end,

  ["sort keeps <CR> pointing at the right source line"] = function()
    local src, vbuf = open_view(PEOPLE)
    vim.cmd("Csvkit sort age desc")
    vim.api.nvim_win_set_cursor(0, { 5, 0 }) -- Eva, source line 5
    press("<CR>")
    eq(vim.api.nvim_get_current_buf(), src)
    eq(vim.api.nvim_win_get_cursor(0)[1], 5)
    eq(vim.api.nvim_buf_is_valid(vbuf), true)
  end,

  ["a filter in the view hides rows there only"] = function()
    local src, vbuf = open_view(PEOPLE)
    vim.cmd("Csvkit filter city")
    press("a") -- none
    press("<Space>") -- Madrid, the most common
    press("<CR>")
    eq(records(vbuf), { "Luis Madrid 25", "Eva Madrid 41" })
    eq(lines(src), PEOPLE)
    eq(filter.states[src], nil)
    eq(vim.fn.foldclosed(2), -1)
  end,

  ["filters in two columns are ANDed, and the picker shows the view's current filter, counted over the other filters' rows"] = function()
    local _, vbuf = open_view(PEOPLE)
    view.set_filter(vbuf, 2, { Madrid = true })
    view.set_filter(vbuf, 3, { ["25"] = true, ["30"] = true })
    eq(records(vbuf), { "Luis Madrid 25" })
    vim.cmd("Csvkit filter city")
    eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "[ ] Bogota (1)", "[x] Madrid (1)" }) -- counts follow the age filter
    press("q")
  end,

  ["filter clear in the view shows every row again; sort stays"] = function()
    local _, vbuf = open_view(PEOPLE)
    vim.cmd("Csvkit sort age desc")
    view.set_filter(vbuf, 2, { Madrid = true })
    eq(#records(vbuf), 2)
    vim.cmd("Csvkit filter clear")
    eq(records(vbuf), { "Eva Madrid 41", "Ana Bogota 30", "Luis Madrid 25", "Mia Paris 9" })
  end,

  ["the view follows the source when it changes (debounced)"] = function()
    local src, vbuf = open_view(PEOPLE)
    vim.cmd("Csvkit sort age desc")
    vim.api.nvim_buf_set_lines(src, 5, 5, false, { "Zed,Lima,99" })
    assert(vim.wait(2000, function()
      return #records(vbuf) == 5
    end), "view not redrawn")
    eq(records(vbuf)[1], "Zed Lima 99")
  end,

  ["the view's copy of the source matches it after random edits, undos and a reload (only changed lines read)"] = function()
    math.randomseed(17)
    local file = vim.fn.tempname() .. ".csv"
    vim.fn.writefile({ "a,b", "1,x", "2,y", "3,z" }, file)
    open({})
    vim.cmd.edit(file)
    local src = vim.api.nvim_get_current_buf()
    vim.cmd("Csvkit view")
    local state = view.states[vim.api.nvim_get_current_buf()]
    local debounce = view.DEBOUNCE
    view.DEBOUNCE = 1
    local function settle()
      assert(vim.wait(2000, function()
        return state.t.tick == vim.b[src].changedtick
      end, 1), "the view did not follow")
      eq(state.t.lines, vim.api.nvim_buf_get_lines(src, 0, -1, false))
    end
    for round = 1, 60 do
      for _ = 1, math.random(1, 3) do -- a burst of edits before one refresh
        local count = vim.api.nvim_buf_line_count(src)
        local first = math.random(1, count) -- never the header
        local last = math.min(count, first + math.random(0, 2))
        local new = {}
        for k = 1, math.random(0, 3) do
          new[k] = ("%d,%s"):format(round * 10 + k, ({ "p", '"q,r"', '"multi', 'line"' })[math.random(4)])
        end
        vim.api.nvim_buf_set_lines(src, first, last, false, new)
      end
      if round % 10 == 0 then
        vim.api.nvim_buf_call(src, function()
          vim.cmd("silent undo")
        end)
      end
      settle()
    end
    vim.api.nvim_buf_call(src, function()
      vim.cmd("silent edit!") -- reload: every line may have changed
    end)
    settle()
    view.DEBOUNCE = debounce
  end,

  ["after :e! on the source the view still follows it, and apply works"] = function()
    local file = vim.fn.tempname() .. ".csv"
    vim.fn.writefile({ "a,b", "1,x", "2,y" }, file)
    open({})
    vim.cmd.edit(file)
    local src = vim.api.nvim_get_current_buf()
    vim.cmd("Csvkit view")
    local vbuf = vim.api.nvim_get_current_buf()
    local state = view.states[vbuf]
    local function follows()
      assert(vim.wait(2000, function()
        return state.t.tick == vim.b[src].changedtick
      end, 5), "the view did not follow")
      eq(state.t.lines, vim.api.nvim_buf_get_lines(src, 0, -1, false))
    end
    vim.api.nvim_buf_set_lines(src, 1, 2, false, { "1,changed" })
    follows()
    vim.api.nvim_buf_call(src, function()
      vim.cmd("silent edit!") -- detaches every nvim_buf_attach of the buffer
    end)
    follows()
    vim.api.nvim_buf_set_lines(src, 2, 3, false, { "2,after reload" })
    follows()
    view.set_cell(vbuf, 5, 2, "z")
    vim.cmd("Csvkit apply")
    eq(vim.api.nvim_buf_get_lines(src, 0, -1, false), { "a,b", "1,z", "2,after reload" })
  end,

  ["discard reads the source only if it changed, and then shows the change"] = function()
    local src, vbuf = open_view(PEOPLE)
    view.set_cell(vbuf, 5, 1, "Zoe")
    local edit = require("csvkit.edit")
    local read, reads = edit.read, 0
    edit.read = function(...)
      reads = reads + 1
      return read(...)
    end
    vim.cmd("Csvkit discard")
    local unchanged = reads
    view.set_cell(vbuf, 5, 1, "Zoe")
    vim.api.nvim_buf_set_lines(src, 1, 2, false, { "Ann,Lima,1" })
    vim.cmd("Csvkit discard")
    edit.read = read
    eq({ unchanged, reads }, { 0, 1 })
    eq(records(vbuf)[1], "Ann Lima 1")
  end,

  ["with staged edits a source change is noted without reading the source"] = function()
    local src, vbuf = open_view(PEOPLE)
    view.set_cell(vbuf, 5, 1, "Zoe")
    local edit = require("csvkit.edit")
    local read, reads = edit.read, 0
    edit.read = function(...)
      reads = reads + 1
      return read(...)
    end
    vim.api.nvim_buf_set_lines(src, 1, 2, false, { "Ann,Lima,1" })
    local ok = vim.wait(2000, function()
      return view.states[vbuf].stale == true
    end)
    edit.read = read
    eq({ ok, reads }, { true, 0 })
  end,

  ["a change to the number of columns drops the view's sort and filters"] = function()
    local src, vbuf = open_view(PEOPLE)
    vim.cmd("Csvkit sort age desc")
    view.set_filter(vbuf, 2, { Madrid = true })
    vim.api.nvim_buf_set_lines(src, 0, -1, false, { "a,b", "1,2", "3,4" })
    assert(vim.wait(2000, function()
      return records(vbuf)[1] == "1 2"
    end), "view not redrawn")
    eq(records(vbuf), { "1 2", "3 4" })
  end,

  ["wiping the view closes its timer and forgets it"] = function()
    local _, vbuf = open_view(PEOPLE)
    local timer = view.states[vbuf].timer
    vim.cmd("bwipeout")
    eq(view.states[vbuf], nil)
    eq(timer:is_closing(), true)
  end,

  ["the winbar is the header row, shifted by the horizontal scroll, % escaped"] = function()
    local _, vbuf = open_view({ "a%,b", "1,2" })
    eq(vim.wo.winbar:find("csvkit.view", 1, true) ~= nil, true)
    eq(vim.api.nvim_eval_statusline(vim.wo.winbar, { winid = 0, use_winbar = true }).str, "│ 0 a% │ 1 b │")
    view.states[vbuf].leftcol[vim.api.nvim_get_current_win()] = 2
    eq(vim.api.nvim_eval_statusline(vim.wo.winbar, { winid = 0, use_winbar = true }).str, "0 a% │ 1 b │")
    -- wider than the window: cut on the right, so it stays over its columns
    view.states[vbuf].leftcol[vim.api.nvim_get_current_win()] = 0
    eq(vim.api.nvim_eval_statusline(vim.wo.winbar, { winid = 0, use_winbar = true, maxwidth = 6 }).str, "│ 0 a>")
  end,

  ["a header longer than Neovim's 4096-byte statusline buffer still starts at column 0"] = function()
    local names = {}
    for k = 1, 300 do
      names[k] = "Total_" .. k
    end
    open_view({ table.concat(names, ","), ("1,"):rep(299) .. "1" })
    local shown = vim.api.nvim_eval_statusline(vim.wo.winbar, { winid = 0, use_winbar = true }).str
    eq(vim.startswith(shown, "│ 0 Total_1 │ 1 Total_2"), true)
  end,

  ["errors: a view of a view, an empty buffer, extra words, sort/filter outside a view"] = function()
    local _, vbuf = open_view(PEOPLE)
    local ok, err = pcall(view.open, vbuf)
    eq(ok, false)
    eq(err, "csvkit: this is already a view")
    local notes, notify = {}, vim.notify
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
    vim.cmd("Csvkit view extra")
    open({})
    vim.cmd("Csvkit view")
    vim.notify = notify
    eq(notes, { "csvkit: usage: view", "csvkit: the buffer has no rows" })
  end,

  ["completion offers view"] = function()
    eq(vim.fn.getcompletion("Csvkit vi", "cmdline"), { "view" })
  end,

  ["<Plug>(csvkit-view) opens the view"] = function()
    open(PEOPLE)
    vim.api.nvim_feedkeys(vim.keycode("<Plug>(csvkit-view)"), "mx", false)
    eq(vim.bo.filetype, "csvkit_view")
  end,
  ["the first line shows the filters and the sort"] = function()
    local _, vbuf = open_view(PEOPLE)
    eq(lines(vbuf)[1], " 4 of 4 rows")
    view.set_filter(vbuf, 2, { Madrid = true, Paris = true })
    vim.cmd("Csvkit sort age desc")
    eq(lines(vbuf)[1], " 3 of 4 rows │ filter city: Madrid, Paris │ sort age ↓")
    view.set_filter(vbuf, 1, { Ana = true, Luis = true, Mia = true, Eva = true })
    view.set_filter(vbuf, 3, { [""] = true, ["9"] = true })
    eq(lines(vbuf)[1], " 1 of 4 rows │ filter name: Ana, Eva, Luis +1; city: Madrid, Paris; age: (empty), 9 │ sort age ↓")
    vim.cmd("Csvkit filter clear")
    eq(lines(vbuf)[1], " 4 of 4 rows │ sort age ↓")
  end,

  ["addcol is staged: value, formula and fill show at once and leave the source alone"] = function()
    local src, vbuf = open_view(PEOPLE)
    local tick = vim.b[src].changedtick
    at(vbuf, 5, 2) -- city
    vim.cmd("Csvkit addcol flag value x")
    at(vbuf, 5, 4) -- age, now the 4th column
    vim.cmd("Csvkit addcol double formula age * 2")
    eq(lines(vbuf)[3], "│ 0 name │ 1 city │ 2 flag │ 3 age │ 4 double │")
    eq(records(vbuf)[1], "Ana Bogota x 30 60")
    eq(lines(src), PEOPLE)
    eq(vim.b[src].changedtick, tick)
    eq(lines(vbuf)[1], " 4 of 4 rows │ staged: 2 new columns (:Csvkit apply | discard)")
    local ask, answers, n = vim.ui.input, { "a", "", "c" }, 0
    vim.ui.input = function(_, cb)
      n = n + 1
      cb(answers[n]) -- the 4th prompt is <Esc>
    end
    at(vbuf, 5, 1)
    vim.cmd("Csvkit addcol note fill")
    vim.ui.input = ask
    eq(records(vbuf), { "Ana a Bogota x 30 60", "Luis Madrid x 25 50", "Mia c Paris x 9 18", "Eva Madrid x 41 82" })
  end,

  ["addcol before the sorted and filtered columns keeps the sort and filter on them"] = function()
    local _, vbuf = open_view(PEOPLE)
    vim.cmd("Csvkit sort age desc")
    view.set_filter(vbuf, 3, { ["30"] = true, ["41"] = true })
    at(vbuf, 5, 1)
    vim.cmd("Csvkit addcol z value 1")
    eq(records(vbuf), { "Eva 1 Madrid 41", "Ana 1 Bogota 30" })
    eq(vim.startswith(lines(vbuf)[1], " 2 of 4 rows │ filter age: 30, 41 │ sort age ↓ │ staged"), true)
    view.set_filter(vbuf, 3, { Madrid = true }) -- city is the 3rd column now
    eq(records(vbuf), { "Eva 1 Madrid 41" })
    view.set_filter(vbuf, 3, nil)
    view.set_filter(vbuf, 2, { ["1"] = true }) -- on the staged column
    vim.cmd("Csvkit discard") -- its filter goes; age's goes back to its place in the source
    eq(records(vbuf), { "Ana Bogota 30", "Eva Madrid 41" })
    eq(lines(vbuf)[1], " 2 of 4 rows │ filter age: 30, 41")
  end,

  ["addcol answered from a prompt float stages after the view's cursor column"] = function()
    -- like dressing / snacks: the answer comes while the prompt's float is current
    local input = vim.ui.input
    vim.ui.input = function(_, cb)
      local win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {
        relative = "editor", row = 0, col = 0, width = 20, height = 1,
      })
      local ok, err = pcall(cb, "v")
      vim.api.nvim_win_close(win, true)
      assert(ok, err)
    end
    local ok, err = pcall(function()
      local _, vbuf = open_view(PEOPLE)
      at(vbuf, 5, 2) -- city
      vim.cmd("Csvkit addcol x value")
      eq(records(vbuf)[1], "Ana Bogota v 30")
      at(vbuf, 5, 1)
      vim.cmd("Csvkit addcol y fill")
      eq(records(vbuf)[4], "Eva v Madrid v 41")
    end)
    vim.ui.input = input
    assert(ok, err)
  end,

  ["a formula over a staged column works, and a failing row warns"] = function()
    local _, vbuf = open_view({ "a,b", "1,2", "x,3", "4,5" })
    local notes, notify = {}, vim.notify
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
    at(vbuf, 5, 2)
    vim.cmd("Csvkit addcol c formula a + b")
    at(vbuf, 5, 3)
    vim.cmd("Csvkit addcol d formula c * 2")
    vim.notify = notify
    eq(#notes, 2)
    eq(notes[1]:find("1 cell failed (rows 3)", 1, true) ~= nil, true)
    eq(records(vbuf), { "1 2 3 6", "x 3", "4 5 9 18" })
  end,

  ["a formula failing on a new row names it as new, source rows by their line"] = function()
    local _, vbuf = open_view({ "a,b", "1,2", "x,3", "4,5" })
    at(vbuf, 5, 1)
    vim.cmd("Csvkit row add below") -- empty: a + b fails there
    local notes, notify = {}, vim.notify
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
    at(vbuf, 5, 2)
    vim.cmd("Csvkit addcol c formula a + b")
    vim.notify = notify
    eq(notes[1]:match("%(rows [^)]*%)"), "(rows new 1, 3)")
  end,

  ["row add is staged, shows even under a filter, and the cursor goes to it"] = function()
    local src, vbuf = open_view(PEOPLE)
    view.set_filter(vbuf, 2, { Madrid = true })
    vim.api.nvim_win_set_cursor(0, { 5, 0 }) -- Luis
    vim.cmd("Csvkit row add below")
    eq(records(vbuf), { "Luis Madrid 25", "", "Eva Madrid 41" })
    eq(vim.api.nvim_win_get_cursor(0)[1], 6)
    eq(lines(src), PEOPLE)
    vim.cmd("Csvkit row add above")
    eq(vim.api.nvim_win_get_cursor(0)[1], 6)
    eq(lines(vbuf)[1]:find("2 new rows", 1, true) ~= nil, true)
    vim.api.nvim_win_set_cursor(0, { 3, 0 }) -- the header
    local notes, notify = {}, vim.notify
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
    vim.cmd("Csvkit row add above")
    vim.notify = notify
    eq(notes, { "csvkit: can't add a row above the header" })
  end,

  ["cell edit (i) is staged; the header row renames the column"] = function()
    local src, vbuf = open_view(PEOPLE)
    local ask, seen = vim.ui.input, nil
    vim.ui.input = function(o, cb)
      seen = o.default
      cb("Anna")
    end
    at(vbuf, 5, 1)
    press("i")
    eq(seen, "Ana")
    eq(records(vbuf)[1], "Anna Bogota 30")
    at(vbuf, 3, 1)
    vim.ui.input = function(o, cb)
      seen = o.default
      cb("who")
    end
    press("i")
    eq(seen, "name")
    eq(lines(vbuf)[3], "│ 0 who │ 1 city │ 2 age │")
    vim.ui.input = ask
    eq(lines(src), PEOPLE)
    eq(lines(vbuf)[1]:find("1 edited cell, 1 new header", 1, true) ~= nil, true)
  end,

  ["a cell edit sorts again only in the sorted column, and copies no other row"] = function()
    local _, vbuf = open_view(PEOPLE)
    vim.cmd("Csvkit sort age") -- Mia 9, Luis 25, Ana 30, Eva 41
    local sort = require("csvkit.sort")
    local sort_rows, calls = sort.sort_rows, 0
    sort.sort_rows = function(...)
      calls = calls + 1
      return sort_rows(...)
    end
    view.set_cell(vbuf, 5, 1, "Zoe") -- name: the order stays
    local after_name = calls
    view.set_cell(vbuf, 5, 3, "99") -- age: sorted again, the row goes last
    sort.sort_rows = sort_rows
    eq({ after_name, calls }, { 0, 1 })
    eq(records(vbuf), { "Luis Madrid 25", "Ana Bogota 30", "Eva Madrid 41", "Zoe Paris 99" })
    local copied = vim.tbl_filter(function(rec) -- an untouched row is just its number
      return type(rec) == "table"
    end, view.states[vbuf].recs)
    eq(#copied, 1)
  end,

  ["staged cell edits, new rows, new and deleted columns and apply sort match a plain model (random)"] = function()
    math.randomseed(11)
    local csvm, sort = require("csvkit.csv"), require("csvkit.sort")
    local words = { "a", "b c", "d,e", '"q"', "x\ny", "", "7", "é", "10" }
    for _ = 1, 30 do
      local model = { { "h1", "h2", "h3" } }
      for r = 2, 9 do
        model[r] = {}
        for c = 1, math.random(1, 3) do -- ragged
          model[r][c] = words[math.random(#words)]
        end
      end
      local text = {}
      for _, row in ipairs(model) do
        vim.list_extend(text, vim.split(csvm.serialize_row(row, ",", false), "\n", { plain = true }))
      end
      local src, vbuf = open_view(text)
      local state = view.states[vbuf]
      local deleted = false
      for _ = 1, 6 do
        local i, op = math.random(1, #model - 1), math.random(5)
        if op <= 2 then -- edit a cell (the line of data row i: no sort, no filter)
          local c, w = math.random(1, state.ncols), words[math.random(#words)]
          view.set_cell(vbuf, 4 + i, c, w)
          for k = #model[i + 1] + 1, c do
            model[i + 1][k] = ""
          end
          model[i + 1][c] = w
        elseif op == 3 then -- a new row below row i
          local empty = {}
          for k = 1, state.ncols do
            empty[k] = ""
          end
          vim.api.nvim_win_set_cursor(0, { 4 + i, 0 })
          view.add_row(vbuf, false)
          table.insert(model, i + 2, empty)
        elseif op == 5 and state.ncols > 2 then -- delete column c (2 stay for the sort)
          local c = math.random(1, state.ncols)
          view.delcol(vbuf, { c })
          deleted = true
          for _, row in ipairs(model) do
            if #row >= c then
              table.remove(row, c)
            end
            row[1] = row[1] or "" -- a line always has a field
          end
        elseif op == 4 then -- a column after column c
          local c = math.random(1, state.ncols)
          view.addcol(vbuf, { name = "n", mode = "value", text = "v", after = c })
          for r, row in ipairs(model) do
            for k = #row + 1, c do
              row[k] = ""
            end
            table.insert(row, c + 1, r == 1 and "n" or "v")
          end
        end
      end
      local shown = {}
      for r = 2, #model do
        shown[r - 1] = vim.trim((table.concat(model[r], " "):gsub("\n", "⏎"):gsub(" +", " ")))
      end
      eq(records(vbuf), shown)
      vim.cmd("Csvkit sort 1")
      local col = {}
      for r = 2, #model do
        col[r - 1] = model[r][2] or ""
      end
      local want = { model[1] }
      for _, i in ipairs(sort.sort_rows(col, { col = 2 }, require("csvkit").get_opts(src))) do
        want[#want + 1] = model[i + 1]
      end
      vim.cmd("Csvkit apply sort")
      local got = csvm.parse(lines(src), ",").rows
      for _, rows in ipairs({ got, want }) do
        if deleted then
          -- a staged column pads short rows; deleting it again takes the
          -- padding with it, where the model keeps it: same cells, fewer fields
          for _, row in ipairs(rows) do
            while #row > 1 and row[#row] == "" do
              row[#row] = nil
            end
          end
        end
        -- a row of one empty field is an empty line, and empty lines at the
        -- end are no rows when read back (the sort puts them last)
        while #rows > 1 and vim.deep_equal(rows[#rows], { "" }) do
          rows[#rows] = nil
        end
      end
      eq(got, want)
      eq(state.t.lines, lines(src)) -- the view's copy is what was written
    end
  end,

  ["after apply the view's copy of the source is the buffer, trailing blank lines too"] = function()
    local src, vbuf = open_view({ "a,b", "1,x", "2,y", "", "" })
    view.set_cell(vbuf, 5, 2, "z")
    vim.cmd("Csvkit apply")
    eq(lines(src), { "a,b", "1,z", "2,y", "", "" })
    eq(view.states[vbuf].t.lines, lines(src))
  end,

  ["apply writes the staged edits to the source in one undo step; untouched rows keep their text"] = function()
    local src, vbuf = open_view({ "name,age", '"Ana",30', "Luis,25", "Eva,41" })
    local ask = vim.ui.input
    vim.ui.input = function(_, cb)
      cb("26")
    end
    at(vbuf, 6, 2)
    press("i") -- Luis age
    vim.ui.input = ask
    at(vbuf, 7, 1)
    vim.cmd("Csvkit row add below")
    at(vbuf, 5, 2)
    vim.cmd("Csvkit addcol tag value t")
    eq(lines(src), { "name,age", '"Ana",30', "Luis,25", "Eva,41" })
    vim.cmd("Csvkit apply")
    eq(lines(src), { "name,age,tag", '"Ana",30,t', "Luis,26,t", "Eva,41,t", ",,t" })
    eq(lines(vbuf)[1], " 4 of 4 rows")
    vim.api.nvim_set_current_buf(src)
    vim.cmd.undo()
    eq(lines(src), { "name,age", '"Ana",30', "Luis,25", "Eva,41" })
  end,

  ["apply with only a cell edit leaves every other line byte-identical"] = function()
    local src, vbuf = open_view({ "name,age", '"A, a",30', '"Eva",41', "Luis,25" })
    local ask = vim.ui.input
    vim.ui.input = function(_, cb)
      cb("26")
    end
    at(vbuf, 7, 2)
    press("i")
    vim.ui.input = ask
    vim.cmd("Csvkit apply")
    eq(lines(src), { "name,age", '"A, a",30', '"Eva",41', "Luis,26" })
  end,

  ["apply sort with staged edits writes both: the edits in the view's order"] = function()
    local src, vbuf = open_view({ "n,v", "b,2", "a,1" })
    vim.cmd("Csvkit sort 0")
    at(vbuf, 5, 2)
    local ask = vim.ui.input
    vim.ui.input = function(_, cb)
      cb("9")
    end
    press("i") -- a's v
    vim.ui.input = ask
    vim.cmd("Csvkit apply sort")
    eq(lines(src), { "n,v", "a,9", "b,2" })
    eq(lines(vbuf)[1], " 2 of 2 rows")
  end,

  ["apply refuses with nothing staged, when the source changed, and with a bad word"] = function()
    local src, vbuf = open_view(PEOPLE)
    local notes, notify = {}, vim.notify
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
    vim.cmd("Csvkit apply")
    vim.cmd("Csvkit apply sort")
    vim.cmd("Csvkit apply now")
    vim.cmd("Csvkit addcol z value 1")
    vim.api.nvim_buf_set_lines(src, 1, 2, false, { "Ana,Lima,31" })
    assert(vim.wait(2000, function()
      return lines(vbuf)[1]:find("the source changed", 1, true) ~= nil
    end), "no stale note")
    vim.cmd("Csvkit apply")
    vim.notify = notify
    eq(notes, {
      "csvkit: nothing staged to apply",
      "csvkit: the view is not sorted",
      "csvkit: usage: apply [sort]",
      "csvkit: the source changed since the view read it; :Csvkit discard first",
    })
    eq(lines(src)[2], "Ana,Lima,31")
    vim.cmd("Csvkit discard")
    eq(records(vbuf)[1], "Ana Lima 31")
    eq(lines(vbuf)[1], " 4 of 4 rows")
  end,

  ["apply keeps the file order; apply sort writes the view's order, and filters never apply"] = function()
    local src, vbuf = open_view(PEOPLE)
    vim.cmd("Csvkit sort age desc")
    view.set_filter(vbuf, 2, { Madrid = true })
    at(vbuf, 5, 3)
    vim.cmd("Csvkit addcol z value 1")
    vim.cmd("Csvkit apply")
    eq(lines(src), { "name,city,age,z", "Ana,Bogota,30,1", "Luis,Madrid,25,1", "Mia,Paris,9,1", "Eva,Madrid,41,1" })
    eq(lines(vbuf)[1], " 2 of 4 rows │ filter city: Madrid │ sort age ↓")
    vim.cmd("Csvkit apply sort")
    eq(lines(src), { "name,city,age,z", "Eva,Madrid,41,1", "Ana,Bogota,30,1", "Luis,Madrid,25,1", "Mia,Paris,9,1" })
    eq(lines(vbuf)[1], " 2 of 4 rows │ filter city: Madrid")
    vim.api.nvim_set_current_buf(src)
    vim.cmd.undo()
    eq(lines(src)[2], "Ana,Bogota,30,1")
  end,

  ["apply sort alone moves the raw lines (quoting kept) and is one undo step"] = function()
    local src, vbuf = open_view({ "n,v", '"b",2', "a,1" })
    vim.cmd("Csvkit sort 0")
    vim.cmd("Csvkit apply sort")
    eq(lines(src), { "n,v", "a,1", '"b",2' })
    vim.api.nvim_set_current_buf(src)
    vim.cmd.undo()
    eq(lines(src), { "n,v", '"b",2', "a,1" })
    eq(vbuf and true, true)
  end,

  ["discard drops the staged edits and the sort; the filters stay"] = function()
    local src, vbuf = open_view(PEOPLE)
    vim.cmd("Csvkit sort age desc")
    view.set_filter(vbuf, 2, { Madrid = true })
    vim.cmd("Csvkit addcol z value 1")
    vim.cmd("Csvkit discard")
    eq(lines(vbuf)[1], " 2 of 4 rows │ filter city: Madrid")
    eq(records(vbuf), { "Luis Madrid 25", "Eva Madrid 41" })
    eq(lines(src), PEOPLE)
  end,

  ["the picker lists the staged values of a column"] = function()
    local _, vbuf = open_view(PEOPLE)
    vim.cmd("Csvkit addcol flag value x")
    vim.cmd("Csvkit filter flag")
    eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "[x] x (4)" })
    press("q")
    eq(vbuf and true, true)
  end,

  ["completion offers apply, discard and apply sort"] = function()
    eq(vim.fn.getcompletion("Csvkit ap", "cmdline"), { "apply" })
    eq(vim.fn.getcompletion("Csvkit dis", "cmdline"), { "discard" })
    eq(vim.fn.getcompletion("Csvkit apply ", "cmdline"), { "sort" })
  end,
  ["above M.EAGER rows only the rows near the window are drawn; scrolling draws more"] = function()
    local data = { "id,v" }
    for i = 1, 6000 do
      data[#data + 1] = i .. "," .. i * 2
    end
    local _, vbuf = open_view(data)
    local l = lines(vbuf)
    eq(#l, 6005)
    eq(l[5], "│ 1    │ 2    │") -- widths from the first 2000 rows
    eq(l[3000], "")
    scroll_to_end()
    assert(vim.wait(1000, function()
      return lines(vbuf)[6004] ~= ""
    end), "last rows not drawn")
    eq(lines(vbuf)[6004], "│ 6000 │ 12000 │") -- the v column grew
    eq(lines(vbuf)[6005]:sub(1, 3), "└")
  end,

  ["row add places the new row as sorting and filtering anew would (random, eager and lazy)"] = function()
    math.randomseed(23)
    local eager = view.EAGER
    for round = 1, 40 do
      view.EAGER = round % 2 == 0 and 5 or 5000
      local text = { "a,b,c" }
      for r = 1, 40 do
        text[#text + 1] = ("%s,%s,%d"):format(({ "x", "y", "", "z" })[math.random(4)], ({ "1", "2", "", "10" })[math.random(4)], r)
      end
      local _, vbuf = open_view(text)
      local state = view.states[vbuf]
      if math.random(3) > 1 then
        vim.cmd(("Csvkit sort %d%s"):format(math.random(0, 2), math.random(2) == 1 and " desc" or ""))
      end
      if math.random(2) == 1 then
        view.set_filter(vbuf, 1, { x = true, [""] = true })
      end
      -- every row line drawn shows its row: column c holds the source row's
      -- number, and is empty in a new row
      local function drawn_right()
        local l = lines(vbuf)
        eq(#l, #state.shown + 5)
        for p = 5, #l - 1 do
          if l[p] ~= "" then
            local rec = state.recs[state.shown[p - 4]]
            local want = type(rec) == "number" and text[rec + 1]:match("[^,]*$") or ""
            eq(vim.trim(vim.split(l[p], "│", { plain = true })[4]), want)
          end
        end
      end
      for _ = 1, 5 do
        scroll_to_end() -- rows drawn at both ends of a lazy view
        vim.api.nvim_win_set_cursor(0, { 4 + math.random(1, #state.shown), 0 })
        view.add_row(vbuf, math.random(2) == 1)
        drawn_right()
        local got = vim.deepcopy(state.shown)
        view.set_filter(vbuf, 1, state.cols[1]) -- the order worked out anew
        eq(got, state.shown)
      end
    end
    view.EAGER = eager
  end,

  ["a lazy view drawn again with as many rows: rows drawn before go back to placeholders"] = function()
    local eager = view.EAGER
    view.EAGER = 10
    local text = { "n,v" }
    for i = 1, 200 do
      text[#text + 1] = ("r%03d,%d"):format(i, 200 - i)
    end
    local _, vbuf = open_view(text)
    scroll_to_end() -- draws the last rows too
    eq(lines(vbuf)[204]:match("r%d+"), "r200")
    vim.cmd("normal! gg")
    vim.cmd("Csvkit sort v") -- reversed: r200 first
    local l = lines(vbuf)
    eq({ #l, l[5]:match("r%d+"), l[204], l[205]:sub(1, 3) }, { 205, "r200", "", "└" })
    eq(vim.tbl_filter(function(s)
      return s ~= ""
    end, vim.list_slice(l, 5, 204))[1]:match("r%d+"), "r200")
    scroll_to_end()
    eq(lines(vbuf)[204]:match("r%d+"), "r001")
    view.EAGER = eager
  end,

  ["a lazily drawn cell wider than its column widens the table and draws the rows again"] = function()
    local data = { "id,v" }
    for i = 1, 6000 do
      data[#data + 1] = i .. "," .. i
    end
    data[#data] = "6000,a long cell"
    local _, vbuf = open_view(data)
    eq(lines(vbuf)[3], "│ 0 id │ 1 v  │")
    scroll_to_end()
    assert(vim.wait(1000, function()
      return lines(vbuf)[3] == "│ 0 id │ 1 v         │"
    end), "table not widened")
    eq(lines(vbuf)[6004], "│ 6000 │ a long cell │")
    eq(lines(vbuf)[6003], "│ 5999 │ 5999        │")
    vim.cmd("normal! gg")
    vim.cmd.redraw()
    vim.api.nvim_exec_autocmds("WinScrolled", {})
    eq(lines(vbuf)[5], "│ 1    │ 1           │") -- drawn before the table was widened
  end,

  ["the <Plug> maps apply, apply-sort and discard exist"] = function()
    for _, name in ipairs({ "apply", "apply-sort", "discard" }) do
      eq(vim.fn.maparg("<Plug>(csvkit-" .. name .. ")", "n") ~= "", true)
    end
    local src, vbuf = open_view(PEOPLE)
    vim.cmd("Csvkit addcol z value 1")
    vim.api.nvim_feedkeys(vim.keycode("<Plug>(csvkit-discard)"), "mx", false)
    eq(lines(vbuf)[1], " 4 of 4 rows")
    vim.cmd("Csvkit addcol z value 1")
    vim.api.nvim_feedkeys(vim.keycode("<Plug>(csvkit-apply)"), "mx", false)
    eq(lines(src)[1], "name,z,city,age")
    eq(lines(vbuf)[1], " 4 of 4 rows")
  end,

  ["apply puts new columns into the record text: quoting and multiline records stay as they are"] = function()
    local src, vbuf = open_view({ 'id,"note",n', '"1","a, b",5', '2,"x', 'y",6', "3,plain,7" })
    at(vbuf, 5, 1)
    vim.cmd("Csvkit addcol A value q,1") -- after id; the comma needs quotes
    at(vbuf, 5, 4)
    vim.cmd("Csvkit addcol B value b") -- after n
    at(vbuf, 5, 1)
    vim.cmd("Csvkit addcol C value c") -- after id, before A
    vim.cmd("Csvkit apply")
    eq(lines(src), { 'id,C,A,"note",n,B', '"1",c,"q,1","a, b",5,b', '2,c,"q,1","x', 'y",6,b', "3,c,\"q,1\",plain,7,b" })
    eq(vim.fn.filter(lines(src), "v:val =~ 'x'"), { '2,c,"q,1","x' })
  end,

  ["apply with a column added to a record too short for it writes the record whole, padded"] = function()
    local src, vbuf = open_view({ "a,b,c", "1,2,3", "4", "5,6,7" })
    at(vbuf, 5, 3)
    vim.cmd("Csvkit addcol d value z")
    vim.cmd("Csvkit apply")
    eq(lines(src), { "a,b,c,d", "1,2,3,z", "4,,,z", "5,6,7,z" })
    eq(vbuf and true, true)
  end,

  ["apply of a column after the last keeps a stray \\r at the line's end"] = function()
    local src, vbuf = open_view({ "a,b\r", "1,2\r", "3,4" })
    at(vbuf, 5, 2)
    vim.cmd("Csvkit addcol n value X")
    vim.cmd("Csvkit apply")
    eq(lines(src), { "a,b,n\r", "1,2,X\r", "3,4,X" })
  end,

  ["apply of staged columns in a quote-all file quotes the new fields"] = function()
    local src, vbuf = open_view({ '"a","b"', '"1","2"', '"3","4"' })
    at(vbuf, 5, 1)
    vim.cmd("Csvkit addcol c value x")
    vim.cmd("Csvkit apply")
    eq(lines(src), { '"a","c","b"', '"1","x","2"', '"3","x","4"' })
  end,

  ["apply of staged columns equals writing every row again (random files)"] = function()
    math.randomseed(7)
    local words = { "a", "b c", "d,e", '"q"', "x\ny", "", "7", "é" }
    for round = 1, 20 do
      local rows = { { "h1", "h2", "h3", "h4" } }
      for r = 1, 12 do
        local row = {}
        for c = 1, math.random(1, 4) do -- ragged
          row[c] = words[math.random(#words)]
        end
        rows[#rows + 1] = row
      end
      local text = {}
      for _, row in ipairs(rows) do
        vim.list_extend(text, vim.split(require("csvkit.csv").serialize_row(row, ",", round % 2 == 0), "\n", { plain = true }))
      end
      local src, vbuf = open_view(text)
      local want = vim.deepcopy(rows)
      for k = 1, math.random(1, 3) do
        local c = math.random(1, view.states[vbuf].ncols)
        at(vbuf, 5, c)
        vim.cmd("Csvkit addcol n" .. k .. " value v," .. k)
        for r, row in ipairs(want) do
          for j = #row + 1, c do
            row[j] = ""
          end
          table.insert(row, c + 1, r == 1 and "n" .. k or "v," .. k)
        end
      end
      vim.cmd("Csvkit apply")
      local got = require("csvkit.csv").parse(lines(src), ",").rows
      eq(got, want)
    end
  end,

}
