-- Filter: unique values, folds over hidden rows, the picker and :Csvkit filter (filter.lua).
vim.cmd.runtime("plugin/csvkit.lua")
local filter = require("csvkit.filter")
local overlay = require("csvkit.overlay")

local PEOPLE = {
  "name,city,age",
  "Ana,Bogota,30", -- 2
  "Luis,Madrid,25", -- 3
  "Mia,Paris,30", -- 4
  "Eva,Madrid,41", -- 5
  "Tom,Bogota,25", -- 6
}

-- Opens lines in a fresh listed buffer shown in the only window, with the
-- fold options at their defaults and every overlay and filter off.
local function open(lines)
  for buf in pairs(overlay.states) do
    overlay.disable(buf)
  end
  for buf in pairs(filter.states) do
    filter.clear(buf)
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
  vim.o.undolevels = vim.o.undolevels -- :h undo-break
  vim.wo.foldmethod, vim.wo.foldtext, vim.wo.foldminlines, vim.wo.foldlevel, vim.wo.foldenable =
    "manual", "foldtext()", 1, 0, true
  vim.cmd.normal({ "zE", bang = true })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  return buf
end

-- Lines (1-based) that are inside a closed fold.
local function hidden()
  local out = {}
  for l = 1, vim.api.nvim_buf_line_count(0) do
    if vim.fn.foldclosed(l) ~= -1 then
      out[#out + 1] = l
    end
  end
  return out
end

local function set(values)
  local allowed = {}
  for _, v in ipairs(values) do
    allowed[v] = true
  end
  return allowed
end

local function press(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "mx", false)
end

-- Runs :Csvkit args; returns the vim.notify messages as { msg, level }.
local function csvkit(args)
  local msgs, notify = {}, vim.notify
  vim.notify = function(msg, level)
    msgs[#msgs + 1] = { msg, level }
  end
  local ok, err = pcall(vim.cmd, "Csvkit " .. args)
  vim.notify = notify
  assert(ok, err)
  return msgs
end

local function marked_lines(buf)
  local rows = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace("csvkit_align"), 0, -1, {})) do
    rows[m[2] + 1] = true
  end
  return rows
end

return {
  ["values: counts, by count then value, blanks and spaces folded together"] = function()
    local buf = open({ "k,v", "b,1", "a,2", "c, 1 ", "d,", "e, ", "f,2", "g,1" })
    local t = require("csvkit.edit").read(buf)
    eq(filter.values(t, 2), {
      { value = "1", count = 3 },
      { value = "", count = 2 },
      { value = "2", count = 2 },
    })
    eq(filter.values(t, 3), { { value = "", count = 7 } }) -- a missing field is blank
  end,

  ["counts: by count then value, the same as one sort with both keys (random)"] = function()
    math.randomseed(3)
    for _ = 1, 50 do
      local cells = {}
      for i = 1, math.random(0, 60) do
        cells[i] = ({ "a", "b", "B", " b", "é", "", "10", "9" })[math.random(8)] .. (math.random(3) == 1 and i or "")
      end
      local want = {}
      for value, count in pairs(vim.iter(cells):fold({}, function(acc, c)
        c = vim.trim(c)
        acc[c] = (acc[c] or 0) + 1
        return acc
      end)) do
        want[#want + 1] = { value = value, count = count }
      end
      table.sort(want, function(a, b)
        if a.count ~= b.count then
          return a.count > b.count
        end
        return a.value < b.value
      end)
      eq(filter.counts(cells), want)
    end
  end,

  ["picker: applying reuses its read of the buffer, unless the buffer changed meanwhile"] = function()
    local buf = open(PEOPLE)
    local edit = require("csvkit.edit")
    local read, reads = edit.read, 0
    filter.pick(read(buf), 2)
    edit.read = function(...)
      reads = reads + 1
      return read(...)
    end
    press("<Space><CR>") -- Bogota off
    local unchanged = reads
    filter.clear(buf)
    filter.pick(read(buf), 2)
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "Ana,Madrid,30" }) -- while the picker is open
    press("<Space><CR>") -- Bogota off again: the rows are read anew
    edit.read = read
    eq({ unchanged, reads }, { 0, 1 })
    eq(hidden(), { 6 }) -- only Tom is in Bogota now
  end,

  ["picker: opens on a tiny screen"] = function()
    local buf = open(PEOPLE)
    local lines, columns = vim.o.lines, vim.o.columns
    vim.o.lines, vim.o.columns = 6, 10
    local ok, err = pcall(filter.pick, require("csvkit.edit").read(buf), 2)
    local win = vim.api.nvim_get_current_win()
    local height = ok and vim.api.nvim_win_get_height(win)
    if ok then
      vim.api.nvim_win_close(win, true)
    end
    vim.o.lines, vim.o.columns = lines, columns
    assert(ok, err)
    eq(height, 1)
  end,

  ["values: a header = false file counts its first row"] = function()
    local buf = open({ "a,x", "b,x", "c,y" })
    vim.b[buf].csvkit = { header = false }
    eq(filter.values(require("csvkit.edit").read(buf), 2), { { value = "x", count = 2 }, { value = "y", count = 1 } })
  end,

  ["one column: the rows not allowed are folded, the header and the rest are not"] = function()
    local buf = open(PEOPLE)
    filter.set(buf, 2, set({ "Madrid" }))
    eq(hidden(), { 2, 4, 6 })
    eq(vim.fn.foldclosed(1), -1)
  end,

  ["a run of hidden rows is one fold"] = function()
    local buf = open(PEOPLE)
    filter.set(buf, 2, set({ "Bogota" }))
    eq(hidden(), { 3, 4, 5 })
    eq(vim.fn.foldclosed(5), 3)
    eq(vim.fn.foldclosedend(3), 5)
  end,

  ["two columns are ANDed"] = function()
    local buf = open(PEOPLE)
    filter.set(buf, 2, set({ "Madrid", "Bogota" }))
    eq(hidden(), { 4 })
    filter.set(buf, 3, set({ "25" }))
    eq(hidden(), { 2, 4, 5 })
  end,

  ["a column with nothing allowed hides every data row but not the header"] = function()
    local buf = open(PEOPLE)
    filter.set(buf, 2, {})
    eq(hidden(), { 2, 3, 4, 5, 6 })
  end,

  ["header = false: the first row can be hidden"] = function()
    local buf = open({ "a,1", "b,2", "c,1" })
    vim.b[buf].csvkit = { header = false }
    filter.set(buf, 2, set({ "2" }))
    eq(hidden(), { 1, 3 })
  end,

  ["a record spanning lines is hidden whole, and counts as one row"] = function()
    local buf = open({ "name,memo", 'a,"x', 'y"', "b,z", "c,w" })
    filter.set(buf, 1, set({ "c" }))
    eq(hidden(), { 2, 3, 4 })
    eq(vim.fn.foldtextresult(2), "⋯ 2 hidden rows")
    filter.set(buf, 1, set({ "b", "c" }))
    eq(hidden(), { 2, 3 })
    eq(vim.fn.foldtextresult(2), "⋯ 1 hidden row")
  end,

  ["fold text names the hidden rows"] = function()
    local buf = open(PEOPLE)
    filter.set(buf, 2, set({ "Bogota" }))
    eq(vim.fn.foldtextresult(3), "⋯ 3 hidden rows")
  end,

  ["filtering never changes the buffer"] = function()
    local buf = open(PEOPLE)
    local tick, modified = vim.b[buf].changedtick, vim.bo[buf].modified
    filter.set(buf, 2, set({ "Madrid" }))
    eq(vim.b[buf].changedtick, tick)
    eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), PEOPLE)
    eq(vim.bo[buf].modified, modified)
  end,

  ["clear removes the folds and puts the user's fold options back"] = function()
    local buf = open(PEOPLE)
    vim.wo.foldmethod, vim.wo.foldtext, vim.wo.foldminlines, vim.wo.foldlevel, vim.wo.foldenable =
      "indent", "v:foldstart", 3, 2, false
    filter.set(buf, 2, set({ "Madrid" }))
    eq(vim.wo.foldmethod, "manual")
    eq(vim.wo.foldenable, true)
    filter.clear(buf)
    eq({ vim.wo.foldmethod, vim.wo.foldtext, vim.wo.foldminlines, vim.wo.foldlevel, vim.wo.foldenable }, {
      "indent", "v:foldstart", 3, 2, false,
    })
    vim.wo.foldmethod = "manual"
    eq(hidden(), {})
    eq(filter.states[buf], nil)
  end,

  ["setting a column to nil removes only that filter, the last one clears all"] = function()
    local buf = open(PEOPLE)
    filter.set(buf, 2, set({ "Madrid" }))
    filter.set(buf, 3, set({ "25" }))
    eq(hidden(), { 2, 4, 5, 6 })
    filter.set(buf, 2, nil)
    eq(hidden(), { 2, 4, 5 })
    filter.set(buf, 3, nil)
    eq(filter.states[buf], nil)
    eq(vim.wo.foldmethod, "manual")
    eq(hidden(), {})
  end,

  ["filtering again replaces the folds, never adds to them"] = function()
    local buf = open(PEOPLE)
    filter.set(buf, 2, set({ "Madrid" }))
    filter.set(buf, 2, set({ "Paris" }))
    eq(hidden(), { 2, 3, 5, 6 })
  end,

  ["after an edit the folds follow the new rows"] = function()
    local buf = open(PEOPLE)
    filter.set(buf, 2, set({ "Madrid" }))
    csvkit("sort name")
    -- Ana Bogota, Eva Madrid, Luis Madrid, Mia Paris, Tom Bogota
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    eq(hidden(), { 2, 5, 6 })
    vim.cmd("silent undo")
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    eq(hidden(), { 2, 4, 6 })
  end,

  ["a buffer emptied by an edit loses its filters, with a warning"] = function()
    local buf = open(PEOPLE)
    filter.set(buf, 2, set({ "Madrid" }))
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
    local msgs, notify = {}, vim.notify
    vim.notify = function(msg, level)
      msgs[#msgs + 1] = { msg, level }
    end
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    vim.notify = notify
    eq(msgs, { { "csvkit: filters cleared: the buffer has no rows", vim.log.levels.WARN } })
    eq(filter.states[buf], nil)
    eq(vim.wo.foldmethod, "manual")
  end,

  ["an unchanged buffer is not read again"] = function()
    local buf = open(PEOPLE)
    filter.set(buf, 2, set({ "Madrid" }))
    local reads, read = 0, require("csvkit.edit").read
    require("csvkit.edit").read = function(...)
      reads = reads + 1
      return read(...)
    end
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    require("csvkit.edit").read = read
    eq(reads, 0)
  end,

  ["a different number of columns clears the filters and says so"] = function()
    local buf = open(PEOPLE)
    filter.set(buf, 2, set({ "Madrid" }))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    csvkit("addcol x value 1")
    local msgs = {}
    local notify = vim.notify
    vim.notify = function(msg, level)
      msgs[#msgs + 1] = { msg, level }
    end
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    vim.notify = notify
    eq(msgs, { { "csvkit: filters cleared: the number of columns changed", vim.log.levels.WARN } })
    eq(filter.states[buf], nil)
    eq(vim.wo.foldmethod, "manual")
  end,

  ["leaving the buffer puts the window's options back; coming back folds again"] = function()
    local buf = open(PEOPLE)
    vim.wo.foldminlines = 4
    filter.set(buf, 2, set({ "Madrid" }))
    local other = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(other)
    eq(vim.wo.foldminlines, 4)
    eq(hidden(), {})
    vim.api.nvim_set_current_buf(buf)
    eq(hidden(), { 2, 4, 6 })
  end,

  ["a window that shows the buffer later is folded, and clear puts its options back"] = function()
    local buf = open(PEOPLE)
    vim.wo.foldminlines = 4
    filter.set(buf, 2, set({ "Madrid" }))
    vim.cmd("new")
    vim.api.nvim_set_current_buf(buf)
    eq(hidden(), { 2, 4, 6 })
    eq(vim.wo.foldminlines, 0)
    filter.clear(buf)
    eq(hidden(), {})
    eq(vim.wo.foldminlines, 4)
    vim.cmd("only")
  end,

  ["leaving and coming back keeps the original options for clear"] = function()
    local buf = open(PEOPLE)
    vim.wo.foldminlines = 4
    filter.set(buf, 2, set({ "Madrid" }))
    vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, false))
    vim.api.nvim_set_current_buf(buf)
    filter.clear(buf)
    eq(vim.wo.foldminlines, 4)
    eq(vim.wo.foldtext, "foldtext()")
    eq(hidden(), {})
  end,

  ["a split of a filtered window clears back to the user's options"] = function()
    local buf = open(PEOPLE)
    vim.wo.foldminlines = 4
    filter.set(buf, 2, set({ "Madrid" }))
    vim.cmd("split")
    eq(hidden(), { 2, 4, 6 })
    filter.clear(buf)
    eq(vim.wo.foldminlines, 4)
    vim.cmd("close")
    eq(vim.wo.foldminlines, 4)
  end,

  ["wiping the buffer forgets its filters"] = function()
    local buf = open(PEOPLE)
    filter.set(buf, 2, set({ "Madrid" }))
    vim.cmd("enew")
    vim.cmd.bwipeout({ args = { buf }, bang = true })
    eq(filter.states[buf], nil)
  end,

  ["picker: every value starts checked, <CR> with nothing changed sets no filter"] = function()
    local buf = open(PEOPLE)
    local t = require("csvkit.edit").read(buf)
    filter.pick(t, 2)
    eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "[x] Bogota (2)", "[x] Madrid (2)", "[x] Paris (1)" })
    press("<CR>")
    eq(filter.states[buf], nil)
    eq(vim.api.nvim_get_current_buf(), buf)
  end,

  ["picker: counts only the rows the other columns' filters leave visible, not its own"] = function()
    local buf = open(PEOPLE)
    filter.set(buf, 2, set({ "Madrid" }))
    local t = require("csvkit.edit").read(buf)
    filter.pick(t, 1)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    eq(#lines < #require("csvkit.filter").values(t, 1), true)
    press("q")
    filter.pick(t, 2) -- its own filter is ignored: every city is listed
    eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "[ ] Bogota (2)", "[x] Madrid (2)", "[ ] Paris (1)" })
  end,

  ["picker: <Space> and <Tab> toggle the line, <CR> applies"] = function()
    local buf = open(PEOPLE)
    filter.pick(require("csvkit.edit").read(buf), 2)
    press("<Space>") -- Bogota off
    press("j<Tab>") -- Madrid off
    eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "[ ] Bogota (2)", "[ ] Madrid (2)", "[x] Paris (1)" })
    press("<CR>")
    eq(hidden(), { 2, 3, 5, 6 })
    eq(filter.states[buf].cols[2], { Paris = true })
  end,

  ["picker: a toggles all and none, q and <Esc> cancel"] = function()
    local buf = open(PEOPLE)
    local t = require("csvkit.edit").read(buf)
    filter.pick(t, 2)
    press("a")
    eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "[ ] Bogota (2)", "[ ] Madrid (2)", "[ ] Paris (1)" })
    press("a")
    eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "[x] Bogota (2)", "[x] Madrid (2)", "[x] Paris (1)" })
    press("a")
    press("q")
    eq(filter.states[buf], nil)
    eq(vim.api.nvim_get_current_buf(), buf)
    filter.pick(t, 2)
    press("<Space><Esc>")
    eq(filter.states[buf], nil)
    eq(#vim.api.nvim_list_wins(), 1)
  end,

  ["picker: shows the current filter, (empty) for blanks, and <CR> on a changed set updates it"] = function()
    local buf = open({ "k,v", "a,x", "b,", "c,x", "d,y" })
    filter.set(buf, 2, set({ "x", "" }))
    filter.pick(require("csvkit.edit").read(buf), 2)
    eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "[x] x (2)", "[x] (empty) (1)", "[ ] y (1)" })
    press("<Space>") -- x off
    press("<CR>")
    eq(filter.states[buf].cols[2], { [""] = true })
    eq(hidden(), { 2, 4, 5 })
  end,

  ["picker: checking everything again clears that column's filter"] = function()
    local buf = open(PEOPLE)
    filter.set(buf, 2, set({ "Madrid" }))
    filter.pick(require("csvkit.edit").read(buf), 2)
    press("a") -- only Madrid was checked: now all are
    press("<CR>")
    eq(filter.states[buf], nil)
  end,

  ["picker: a column with no data rows is an error, not an empty float"] = function()
    local buf = open({ "a,b" })
    local ok, err = pcall(filter.pick, require("csvkit.edit").read(buf), 2)
    eq(ok, false)
    eq(err, "csvkit: no values to filter in column 1")
    eq(#vim.api.nvim_list_wins(), 1)
  end,

  [":Csvkit filter {col} opens the picker on that column, clear removes the filters"] = function()
    local buf = open(PEOPLE)
    csvkit("filter city")
    eq(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1], "[x] Bogota (2)")
    press("<Space><CR>")
    eq(hidden(), { 2, 6 })
    csvkit("filter clear")
    eq(filter.states[buf], nil)
    eq(hidden(), {})
  end,

  [":Csvkit filter with no column uses the one under the cursor"] = function()
    open(PEOPLE)
    vim.api.nvim_win_set_cursor(0, { 3, 6 })
    csvkit("filter")
    eq(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1], "[x] Bogota (2)")
    press("q")
    vim.api.nvim_win_set_cursor(0, { 3, 13 })
    csvkit("filter")
    eq(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1], "[x] 25 (2)")
    press("q")
  end,

  [":Csvkit filter {expr}: a formula hides the rows where it is not TRUE"] = function()
    open(PEOPLE) -- ages 30 25 30 41 25
    csvkit("filter age > 25")
    eq(hidden(), { 3, 6 })
    csvkit("filter AND(age>=26,age<=35)") -- between; no spaces needed
    eq(hidden(), { 3, 5, 6 })
    csvkit('filter OR(city = "Madrid", name = "Tom")')
    eq(hidden(), { 2, 4 })
    csvkit("filter [age] < 30") -- a new expression replaces the old one
    eq(hidden(), { 2, 4, 5 })
    csvkit("filter clear")
    eq(hidden(), {})
  end,

  ["an expression is ANDed with the value filters, and setting nil removes only it"] = function()
    local buf = open(PEOPLE)
    filter.set(buf, 2, set({ "Madrid" }))
    filter.where(buf, "age > 25")
    eq(hidden(), { 2, 3, 4, 6 })
    filter.where(buf, nil)
    eq(hidden(), { 2, 4, 6 })
    filter.set(buf, 2, nil)
    eq(filter.states[buf], nil)
    filter.where(buf, "age = 41")
    filter.set(buf, 2, set({ "Madrid" }))
    filter.set(buf, 2, nil) -- the expression keeps the filter on
    eq(hidden(), { 2, 3, 4, 6 })
  end,

  ["an expression: rows that fail are hidden; an expression no row can be evaluated with is an error"] = function()
    local buf = open({ "name,age", "a,30", "b,", "c,old", "d,9" })
    csvkit("filter age > 10")
    eq(hidden(), { 3, 4, 5 })
    for args, msg in pairs({
      ["filter age + 1"] = "csvkit: filter: expected TRUE or FALSE, got number",
      ["filter name > 1"] = "csvkit: filter: cannot compare string and number",
      ["filter age age"] = 'csvkit: unexpected "age" at position 5',
      ["filter nope"] = 'csvkit: unknown column "nope" at position 1',
    }) do
      eq(csvkit(args), { { msg, vim.log.levels.ERROR } })
      eq(hidden(), { 3, 4, 5 }) -- the filter that was there stays
    end
    vim.api.nvim_buf_set_lines(buf, 4, 5, false, { "d,99" }) -- and is the one that follows edits
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    eq(hidden(), { 3, 4 })
    filter.clear(buf)
    eq(csvkit("filter name > 1"), { { "csvkit: filter: cannot compare string and number", vim.log.levels.ERROR } })
    eq(filter.states[buf], nil)
  end,

  ["an expression follows edits; once it can't compile (a renamed column) it goes, with a warning"] = function()
    local buf = open(PEOPLE)
    csvkit("filter age > 25")
    vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "Luis,Madrid,26" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    eq(hidden(), { 6 })
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "name,city,years" })
    local msgs = {}
    local notify = vim.notify
    vim.notify = function(msg, level)
      msgs[#msgs + 1] = { msg, level }
    end
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    vim.notify = notify
    eq(msgs, { { 'csvkit: filter age > 25 removed: unknown column "age" at position 1', vim.log.levels.WARN } })
    eq(filter.states[buf], nil)
    eq(hidden(), {})
  end,

  ["row delete hidden deletes what the filters hide, only when asked; with no filter it is an error"] = function()
    local buf = open(PEOPLE)
    filter.set(buf, 2, set({ "Madrid" }))
    csvkit("filter age > 30")
    eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), PEOPLE) -- filtering never deletes
    eq(csvkit("row delete hidden"), { { "csvkit: deleted 4 rows", vim.log.levels.INFO } })
    eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "name,city,age", "Eva,Madrid,41" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    eq(hidden(), {})
    filter.clear(buf)
    eq(csvkit("row delete hidden"), { { "csvkit: no rows are hidden: set a filter first", vim.log.levels.ERROR } })
  end,

  [":Csvkit filter works on a buffer that is not modifiable"] = function()
    local buf = open(PEOPLE)
    vim.bo[buf].modifiable = false
    filter.set(buf, 2, set({ "Madrid" }))
    eq(hidden(), { 2, 4, 6 })
  end,

  [":Csvkit filter errors"] = function()
    open(PEOPLE)
    for args, msg in pairs({
      ["filter nope"] = 'csvkit: unknown column "nope" at position 1', -- not a column: an expression
      ["filter a b"] = 'csvkit: unknown column "a" at position 1',
    }) do
      local msgs = csvkit(args)
      eq(msgs, { { msg, vim.log.levels.ERROR } })
    end
    eq(csvkit("filter clear"), {}) -- nothing to clear is fine
  end,

  ["completion offers clear and the header names"] = function()
    open(PEOPLE)
    eq(require("csvkit.command").complete("", "Csvkit filter ", 14), { "name", "city", "age", "clear" })
    -- after the first word it is an expression: column names only
    eq(require("csvkit.command").complete("", "Csvkit filter city ", 19), { "name", "city", "age" })
    eq(vim.tbl_contains(require("csvkit.command").complete("fi", "Csvkit fi", 9), "filter"), true)
  end,

  ["<Plug> maps: filter and filter-clear"] = function()
    local buf = open(PEOPLE)
    vim.api.nvim_win_set_cursor(0, { 2, 5 })
    press("<Plug>(csvkit-filter)")
    eq(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1], "[x] Bogota (2)")
    press("<Space><CR>")
    eq(hidden(), { 2, 6 })
    press("<Plug>(csvkit-filter-clear)")
    eq(filter.states[buf], nil)
  end,

  ["overlay: lines inside a closed fold get no marks, and get them when the fold opens"] = function()
    local lines = { "name,city" }
    for i = 2, 20 do
      lines[i] = "n" .. i .. ",c" .. (i % 2)
    end
    local buf = open(lines)
    overlay.enable(buf)
    assert(vim.wait(5000, function()
      return not overlay.states[buf].busy
    end, 5))
    filter.set(buf, 2, set({ "c1" }))
    -- rows 2, 4, ... are c0 and hidden one by one; row 3 is shown
    local marked = marked_lines(buf)
    eq(marked[1], true)
    eq(marked[3], true)
    eq(marked[2], nil)
    eq(marked[4], nil)
    filter.set(buf, 2, set({ "c1" }))
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd.normal({ "zo", bang = true })
    overlay.moved()
    eq(marked_lines(buf)[2], true)
    eq(marked_lines(buf)[4], nil)
  end,

  ["overlay: a fold of thousands of lines costs no marks"] = function()
    local lines = { "name,city" }
    for i = 2, 5000 do
      lines[i] = "n" .. i .. ",c" .. (i == 5000 and 1 or 0)
    end
    local buf = open(lines)
    overlay.enable(buf)
    assert(vim.wait(5000, function()
      return not overlay.states[buf].busy
    end, 5))
    filter.set(buf, 2, set({ "c1" }))
    eq(hidden()[1], 2)
    eq(vim.tbl_count(marked_lines(buf)) <= 2, true) -- the header; the fold stands for the rest
  end,
}
