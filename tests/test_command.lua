-- :Csvkit subcommands, run through the real command from plugin/csvkit.lua.
vim.cmd.runtime("plugin/csvkit.lua")

local SIMPLE = { "name,age,city", "Ana,30,Bogotá", "Luis,25,Madrid", "Mia,,Paris" }

-- Opens lines in a fresh current buffer with the cursor at cursor (default
-- {1, 0}); the next change starts a new undo step.
local function open(lines, cursor)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.o.undolevels = vim.o.undolevels -- :h undo-break
  vim.api.nvim_win_set_cursor(0, cursor or { 1, 0 })
  return buf
end

local function lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

-- Runs :{range}Csvkit args; returns the vim.notify messages as { msg, level }.
local function csvkit(args, range)
  local msgs, notify = {}, vim.notify
  vim.notify = function(msg, level)
    msgs[#msgs + 1] = { msg, level }
  end
  local ok, err = pcall(vim.cmd, (range or "") .. "Csvkit " .. args)
  vim.notify = notify
  assert(ok, err)
  return msgs
end

-- Checks that one undo brings back original, and that it was a single step.
local function undo_restores(original)
  local seq = vim.fn.undotree().seq_cur
  vim.cmd("silent undo")
  eq(lines(), original)
  eq(vim.fn.undotree().seq_cur, seq - 1)
end

-- Runs fn with vim.ui.input / vim.ui.select answering from answers in order
-- (vim.NIL = <Esc>). Returns the prompts shown.
local function answering(answers, fn)
  local prompts, input, select = {}, vim.ui.input, vim.ui.select
  local function answer(prompt, cb)
    prompts[#prompts + 1] = prompt
    local a = table.remove(answers, 1)
    cb(a ~= vim.NIL and a or nil)
  end
  vim.ui.input = function(o, cb)
    answer(o.prompt, cb)
  end
  vim.ui.select = function(items, o, cb)
    answer(o.prompt .. table.concat(items, "|"), cb)
  end
  local ok, err = pcall(fn)
  vim.ui.input, vim.ui.select = input, select
  assert(ok, err)
  eq(answers, {}) -- every answer was used
  return prompts
end

return {
  ["sort rewrites the data rows and keeps the header"] = function()
    open(SIMPLE)
    eq(csvkit("sort age desc"), {})
    eq(lines(), { "name,age,city", "Ana,30,Bogotá", "Luis,25,Madrid", "Mia,,Paris" })
    csvkit("sort age")
    eq(lines(), { "name,age,city", "Luis,25,Madrid", "Ana,30,Bogotá", "Mia,,Paris" })
    undo_restores(SIMPLE)
    csvkit("sort 2 desc") -- numbers count from 0
    eq(lines(), { "name,age,city", "Mia,,Paris", "Luis,25,Madrid", "Ana,30,Bogotá" })
  end,

  ["sort uses the column under the cursor and a type override"] = function()
    local original = { "id,n", "a,9", "b,10", "c,100" }
    open(original, { 3, 3 }) -- on "10"
    csvkit("sort desc")
    eq(lines(), { "id,n", "c,100", "b,10", "a,9" })
    csvkit("sort str")
    eq(lines(), { "id,n", "b,10", "c,100", "a,9" })
    -- on the delimiter: the field to its left
    open({ "id,n", "b,1", "a,2" }, { 2, 1 })
    csvkit("sort")
    eq(lines(), { "id,n", "a,2", "b,1" })
  end,

  ["sort keeps multiline records and quoting byte-identical"] = function()
    local original = vim.fn.readfile("tests/fixtures/multiline.csv")
    open(original)
    csvkit("sort score desc")
    eq(lines(), {
      "id,note,score",
      '2,"has ""quotes"", and commas",20',
      '1,"first line',
      'second line",10',
      "3,plain,",
    })
    undo_restores(original)
    open({ "a,b", '"x",2', "y,1" }) -- quotes a re-serialization would drop
    csvkit("sort b")
    eq(lines(), { "a,b", "y,1", '"x",2' })
  end,

  ["sort with a cursor inside a multiline record"] = function()
    open(vim.fn.readfile("tests/fixtures/multiline.csv"), { 3, 0 }) -- "second line"
    csvkit("sort desc") -- column 2, note
    eq(lines()[2], "3,plain,")
  end,

  ["sort names a column with spaces, keeps trailing blank lines"] = function()
    open({ "item,unit price", "a,2", "b,1", "", "" })
    csvkit([[sort unit\ price]])
    eq(lines(), { "item,unit price", "b,1", "a,2", "", "" })
  end,

  ["sort rewrites only the rows that move"] = function()
    local changes = {}
    local function track(buf)
      changes = {}
      vim.api.nvim_buf_attach(buf, false, {
        on_lines = function(_, _, _, first, last, new_last)
          changes[#changes + 1] = { first, last, new_last }
        end,
      })
    end
    track(open({ "n", "1", "2", "3" }))
    local tick = vim.b.changedtick
    csvkit("sort n")
    eq(changes, {}) -- already sorted: no edit, no undo step
    eq(vim.b.changedtick, tick)
    -- rows 1 and 4 stay; rows 2..3 (lines 3..5, one is multiline) move
    track(open({ "n,t", "1,a", '3,"x', 'y"', "2,b", "4,c" }))
    csvkit("sort n")
    eq(lines(), { "n,t", "1,a", "2,b", '3,"x', 'y"', "4,c" })
    eq(changes, { { 2, 5, 5 } })
    undo_restores({ "n,t", "1,a", '3,"x', 'y"', "2,b", "4,c" })
  end,

  ["sort errors"] = function()
    open(SIMPLE)
    eq(csvkit("sort nope"), { { 'csvkit: no column "nope"', vim.log.levels.ERROR } })
    eq(csvkit("sort 3"), { { 'csvkit: no column "3"', vim.log.levels.ERROR } })
    eq(csvkit("sort age city"), { { 'csvkit: unexpected "city"', vim.log.levels.ERROR } })
    eq(lines(), SIMPLE)
    open({})
    eq(csvkit("sort"), { { "csvkit: the buffer has no rows", vim.log.levels.ERROR } })
  end,

  ["row add below and above"] = function()
    open(SIMPLE, { 3, 0 })
    csvkit("row add")
    eq(lines(), { "name,age,city", "Ana,30,Bogotá", "Luis,25,Madrid", ",,", "Mia,,Paris" })
    eq(vim.api.nvim_win_get_cursor(0), { 4, 0 })
    undo_restores(SIMPLE)
    vim.api.nvim_win_set_cursor(0, { 3, 5 })
    csvkit("row add above")
    eq(lines(), { "name,age,city", "Ana,30,Bogotá", ",,", "Luis,25,Madrid", "Mia,,Paris" })
    eq(vim.api.nvim_win_get_cursor(0), { 3, 0 })
  end,

  ["row add on the header and on the last line"] = function()
    open(SIMPLE)
    csvkit("row add below")
    eq(lines()[2], ",,")
    open(SIMPLE)
    eq(csvkit("row add above"), { { "csvkit: can't add a row above the header", vim.log.levels.ERROR } })
    eq(lines(), SIMPLE)
    vim.b.csvkit = { header = false } -- without a header, row 1 is data
    csvkit("row add above")
    eq(lines()[1], ",,")
    open(SIMPLE, { 4, 0 })
    csvkit("row add below")
    eq(lines()[5], ",,")
    eq(vim.api.nvim_win_get_cursor(0), { 5, 0 })
  end,

  ["row add skips multiline records and keeps the quote style"] = function()
    open({ '"a","b"', '"1","x', 'y"', '"2","z"' }, { 2, 0 })
    csvkit("row add below")
    eq(lines(), { '"a","b"', '"1","x', 'y"', '"",""', '"2","z"' })
    eq(vim.api.nvim_win_get_cursor(0), { 4, 0 })
    open({ "only", "x" }, { 2, 0 })
    csvkit("row add")
    eq(lines(), { "only", "x", '""' }) -- a bare empty line would be blank
  end,

  ["row add reads in chunks: same result on every line"] = function()
    local edit = require("csvkit.edit")
    local chunk = edit.CHUNK
    -- the first chunk grows to 51 records (for quote_all), 96 lines here;
    -- past it come multiline records across chunk boundaries, a record longer
    -- than a chunk, blank lines inside and after the records
    local original = { "a,b" }
    for i = 1, 100 do
      original[#original + 1] = i .. ",v"
    end
    vim.list_extend(original, { '1,"x', "y", 'z"', "2,w", "", '3,"', "", "", "", '"', "4,v", '5,"', '"', "", "" })
    -- and a quoted file whose 31st record, past the first chunks, is not
    local quoted = { '"a","b"' }
    for i = 1, 60 do
      vim.list_extend(quoted, i == 30 and { "x,y" } or { '"' .. i .. '","x', 'y"' })
    end
    for _, file in ipairs({ original, quoted }) do
      for lnum = 1, #file do
        for _, where in ipairs({ "below", "above" }) do
          local results = {}
          for k, size in ipairs({ 1e9, 3 }) do
            edit.CHUNK = size
            open(file, { lnum, 0 })
            results[k] = { csvkit("row add " .. where), lines(), vim.api.nvim_win_get_cursor(0) }
          end
          eq(results[2], results[1])
        end
      end
    end
    edit.CHUNK = chunk
  end,

  ["row needs add or delete"] = function()
    open(SIMPLE)
    for _, args in ipairs({ "row", "row add left", "row delete hidden x", "row delete now" }) do
      eq(csvkit(args), { { "csvkit: usage: row add [above|below] | row delete [where {expr}|hidden]", vim.log.levels.ERROR } })
    end
    eq(csvkit("row add", "2"), { { "csvkit: row add takes no range", vim.log.levels.ERROR } })
    eq(csvkit("row delete hidden", "2"), { { "csvkit: usage: row add [above|below] | row delete [where {expr}|hidden]", vim.log.levels.ERROR } })
    eq(lines(), SIMPLE)
  end,

  ["addcol value goes after the cursor column"] = function()
    open(SIMPLE, { 2, 4 }) -- on "30"
    csvkit("addcol status value to  do")
    eq(lines(), {
      "name,age,status,city",
      "Ana,30,to  do,Bogotá",
      "Luis,25,to  do,Madrid",
      "Mia,,to  do,Paris",
    })
    undo_restores(SIMPLE)
    vim.api.nvim_win_set_cursor(0, { 1, 12 }) -- last column
    csvkit([[addcol my\ note value a,b]])
    eq(lines()[1], "name,age,city,my note")
    eq(lines()[2], 'Ana,30,Bogotá,"a,b"')
  end,

  ["addcol after|before {col} puts the column there, not after the cursor's"] = function()
    open(SIMPLE, { 2, 4 }) -- on "30"
    csvkit("addcol x before 0 value v")
    eq(lines(), { "x,name,age,city", "v,Ana,30,Bogotá", "v,Luis,25,Madrid", "v,Mia,,Paris" })
    undo_restores(SIMPLE)
    csvkit("addcol x after -1 value v")
    eq(lines()[1], "name,age,city,x")
    vim.cmd("silent undo")
    csvkit("addcol x before city formula age * 2")
    eq(lines(), { "name,age,x,city", "Ana,30,60,Bogotá", "Luis,25,50,Madrid", "Mia,,,Paris" })
    vim.cmd("silent undo")
    csvkit([[addcol after after name value v]]) -- a column may be called "after"
    eq(lines()[1], "name,after,age,city")
    -- first column: the file's quote style, multiline records, a stray \r
    open({ '"a","b"', '"1","2"' })
    csvkit("addcol c before 0 value v")
    eq(lines(), { '"c","a","b"', '"v","1","2"' })
    open({ "a,b\r", '"x', 'y",2\r' })
    csvkit("addcol c before a value v")
    eq(lines(), { "c,a,b\r", 'v,"x', 'y",2\r' })
    open(SIMPLE)
    eq(csvkit("addcol x after"), { { "csvkit: the position is after {col} or before {col}", vim.log.levels.ERROR } })
    eq(csvkit("addcol x before nope value v"), { { 'csvkit: no column "nope"', vim.log.levels.ERROR } })
    eq(lines(), SIMPLE)
  end,

  ["addcol quotes the new field in the file's style, pads ragged rows"] = function()
    open({ '"a","b"', '"1","x', 'y"' }, { 1, 5 })
    csvkit("addcol c value v")
    eq(lines(), { '"a","b","c"', '"1","x', 'y","v"' })
    open({ "a,b,c", "1" }, { 1, 4 })
    csvkit("addcol d value v")
    eq(lines(), { "a,b,c,d", "1,,,v" })
    open({ '"a","b"', '"1"' }, { 1, 5 })
    csvkit("addcol c value v")
    eq(lines(), { '"a","b","c"', '"1","","v"' })
  end,

  ["addcol after the last column keeps a stray \\r at the line's end"] = function()
    open({ "a,b\r", "1,2\r", "3,4", "5\r" }, { 1, 2 })
    csvkit("addcol n value X")
    eq(lines(), { "a,b,n\r", "1,2,X\r", "3,4,X", "5,,X\r" })
  end,

  ["addcol answered from a prompt float edits the buffer the command ran in"] = function()
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
      local buf = open(SIMPLE, { 2, 4 }) -- on "30"
      csvkit("addcol x value")
      eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[2], "Ana,30,v,Bogotá")
      buf = open(SIMPLE, { 2, 4 })
      csvkit("addcol x fill")
      eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[4], "Mia,,v,Paris")
    end)
    vim.ui.input = input
    assert(ok, err)
  end,

  ["addcol keeps every record's text as it was"] = function()
    -- quotes a re-serialization would drop, text after a closing quote, a blank line
    local original = { "a,b", '"x",2', '"p"q,"3"', "" , "y,4" }
    open(original, { 1, 0 })
    csvkit("addcol c value v")
    eq(lines(), { "a,c,b", '"x",v,2', '"p"q,v,"3"', ",v", "y,v,4" })
    undo_restores(original)
  end,

  ["addcol splits a new value with a newline into lines"] = function()
    local buf = open({ "a,b", "1,2" })
    local edit = require("csvkit.edit")
    edit.add_column(edit.read(buf), { after = 1, name = "n", values = { "x\ny" } })
    eq(lines(), { "a,n,b", '1,"x', 'y",2' })
  end,

  ["addcol formula with failures"] = function()
    open({ "price,qty", "2,3", "1,0", "x,1", "4,2" }, { 1, 6 })
    local msgs = csvkit("addcol unit formula price / qty")
    eq(lines(), { "price,qty,unit", "2,3,0.666666666666667", "1,0,", "x,1,", "4,2,2" })
    eq(msgs, { { "csvkit: 2 cells failed (rows 3, 4): division by zero", vim.log.levels.WARN } })
    undo_restores({ "price,qty", "2,3", "1,0", "x,1", "4,2" })
    open({ "a", "0", "x" })
    eq(csvkit("addcol b formula 1 / a")[1][1], "csvkit: 2 cells failed (rows 2, 3): division by zero")
    open({ "a", "1", "x" })
    eq(csvkit("addcol b formula 1 / a")[1][1]:match("^csvkit: 1 cell failed %(rows 3%)"), "csvkit: 1 cell failed (rows 3)")
    -- more than five failures: the first five lines, then …
    open({ "a", "x", "x", "x", "x", "x", "x" })
    msgs = csvkit("addcol b formula a * 2")
    eq(msgs[1][1]:match("^csvkit: 6 cells failed %(rows 2, 3, 4, 5, 6, …%): "), "csvkit: 6 cells failed (rows 2, 3, 4, 5, 6, …): ")
  end,

  ["addcol formula without a header takes $N only"] = function()
    open({ "price", "2" })
    vim.b.csvkit = { header = false }
    eq(csvkit("addcol x formula price * 2"), { { 'csvkit: unknown column "price" at position 1', vim.log.levels.ERROR } })
    csvkit("addcol x formula $0 * 2")
    eq(lines(), { "price,", "2,4" })
  end,

  ["addcol formula keeps the expression as typed"] = function()
    open({ "a", "x" })
    csvkit([[addcol b formula CONCAT(a, "  ;  ")]])
    eq(lines()[2], "x,x  ;  ")
  end,

  ["addcol formula compile error leaves the buffer"] = function()
    open(SIMPLE)
    eq(csvkit("addcol x formula nope + 1"), { { 'csvkit: unknown column "nope" at position 1', vim.log.levels.ERROR } })
    eq(lines(), SIMPLE)
  end,

  ["addcol fill prompts row by row"] = function()
    open(SIMPLE)
    local prompts = answering({ "a", "", "c" }, function()
      eq(csvkit("addcol tag fill"), {})
    end)
    eq(prompts, {
      "Row 2 [name=Ana, age=30, city=Bogotá] > ",
      "Row 3 [name=Luis, age=25, city=Madrid] > ",
      "Row 4 [name=Mia, age=, city=Paris] > ",
    })
    eq(lines(), { "name,tag,age,city", "Ana,a,30,Bogotá", "Luis,,25,Madrid", "Mia,c,,Paris" })
    undo_restores(SIMPLE)
  end,

  ["addcol fill stops on Esc and keeps what was typed"] = function()
    open(SIMPLE)
    answering({ "a", vim.NIL }, function()
      csvkit("addcol tag fill")
    end)
    eq(lines(), { "name,tag,age,city", "Ana,a,30,Bogotá", "Luis,,25,Madrid", "Mia,,,Paris" })
    undo_restores(SIMPLE)
    eq(#vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, {}), 0) -- the row highlight is gone
  end,

  ["row delete: the record under the cursor (all its lines), in one undo step; never the header"] = function()
    local original = { "name,note", "Ana,1", 'Luis,"two', 'lines"', "Mia,3" }
    open(original, { 4, 0 }) -- inside Luis's record
    eq(csvkit("row delete"), { { "csvkit: deleted 1 row", vim.log.levels.INFO } })
    eq(lines(), { "name,note", "Ana,1", "Mia,3" })
    undo_restores(original)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    eq(csvkit("row delete"), { { "csvkit: the header row can't be deleted", vim.log.levels.ERROR } })
    eq(lines(), original)
  end,

  ["row delete with a range: every record the lines touch, the header left out"] = function()
    local original = { "name,note", "Ana,1", 'Luis,"two', 'lines"', "Mia,3", "Eva,4" }
    open(original)
    eq(csvkit("row delete", "1,3"), { { "csvkit: deleted 2 rows", vim.log.levels.INFO } })
    eq(lines(), { "name,note", "Mia,3", "Eva,4" })
    undo_restores(original)
    eq(csvkit("sort", "2,3"), { { "csvkit: sort takes no range", vim.log.levels.ERROR } })
  end,

  ["row delete where {expr}: the rows where it is TRUE; failing rows stay"] = function()
    local original = { "name,age", "Ana,30", "Luis,", "Mia,9", "Eva,41" }
    open(original)
    eq(csvkit("row delete where AND(age >= 10, age < 40)"), { { "csvkit: deleted 1 row", vim.log.levels.INFO } })
    eq(lines(), { "name,age", "Luis,", "Mia,9", "Eva,41" })
    undo_restores(original)
    eq(csvkit("row delete where age > 100"), { { "csvkit: no row matches; nothing deleted", vim.log.levels.INFO } })
    eq(csvkit("row delete where name > 1"), { { "csvkit: row delete: cannot compare string and number", vim.log.levels.ERROR } })
    eq(csvkit("row delete where"), { { "csvkit: usage: row add [above|below] | row delete [where {expr}|hidden]", vim.log.levels.ERROR } })
    eq(lines(), original)
  end,

  ["delcol deletes a column from every record, header too, in one undo step; the rest keeps its text"] = function()
    local original = { 'name,"city, x",age', '"Ana",Bogota,30', 'Luis,"two', 'lines",25', "Mia", "Eva,Lima,41\r", "" }
    for col, want in pairs({
      ["1"] = { "name,age", '"Ana",30', "Luis,25", "Mia", "Eva,41\r", "" },
      ["0"] = { '"city, x",age', "Bogota,30", '"two', 'lines",25', "", "Lima,41\r", "" },
      age = { 'name,"city, x"', '"Ana",Bogota', 'Luis,"two', 'lines"', "Mia", "Eva,Lima\r", "" },
    }) do
      open(original)
      csvkit("delcol " .. col)
      eq(lines(), want)
      undo_restores(original)
    end
    open(original, { 2, 7 }) -- in Bogota
    csvkit("delcol")
    eq(lines()[1], "name,age")
  end,

  ["delcol several columns: names, numbers and ranges a-b, in one undo step"] = function()
    local original = { 'a,"b, x",c,d,e', '1,"two', 'lines",3,4,5', "6,7", "8,9,10,11,12\r" }
    for args, want in pairs({
      ["1-3"] = { "a,e", "1,5", "6", "8,12\r" },
      ["0-1"] = { "c,d,e", "3,4,5", "", "10,11,12\r" },
      ["0 2 4"] = { '"b, x",d', '"two', 'lines",4', "7", "9,11\r" },
      ["e 3-2 a"] = { '"b, x"', '"two', 'lines"', "7", "9\r" }, -- a reversed range is fine
      ["3-4"] = { 'a,"b, x",c', '1,"two', 'lines",3', "6,7", "8,9,10\r" },
    }) do
      open(original)
      csvkit("delcol " .. args)
      eq(lines(), want)
      undo_restores(original)
    end
    open({ "x,1-2,y", "1,2,3" })
    csvkit("delcol 1-2") -- a column's name wins over a range
    eq(lines(), { "x,y", "1,3" })
    open(original)
    eq(csvkit("delcol 0-4"), { { "csvkit: can't delete every column", vim.log.levels.ERROR } })
    eq(csvkit("delcol 3-9"), { { 'csvkit: no column "9"', vim.log.levels.ERROR } })
    eq(csvkit("delcol a nope"), { { 'csvkit: no column "nope"', vim.log.levels.ERROR } })
    eq(lines(), original)
  end,

  ["setcol {col} formula {expr}: only that field changes, in the file's style; one undo step"] = function()
    local original = { "a,b,c", '1,"x, y",3', '2,"two', 'lines",4', "5", '"6",7,"8"\r' }
    open(original)
    csvkit("setcol a formula a * 10")
    eq(lines(), { "a,b,c", '10,"x, y",3', '20,"two', 'lines",4', "50", '60,7,"8"\r' })
    undo_restores(original)
    open(original)
    csvkit("setcol -1 formula b") -- reads another column; a short record gets empty fields up to it
    eq(lines(), { "a,b,c", '1,"x, y","x, y"', '2,"two', 'lines","two', 'lines"', "5,,", '"6",7,7\r' })
    undo_restores(original)
    open({ "a,b", "1,x", "y,2" })
    eq(csvkit("setcol a formula a * 2"), {
      { "csvkit: 1 cell failed (rows 3): cannot apply * to string and number", vim.log.levels.WARN },
    })
    eq(lines(), { "a,b", "2,x", ",2" }) -- a failed cell is empty, as in addcol
    for args, msg in pairs({
      ["setcol"] = "csvkit: usage: setcol {col} formula {expr}",
      ["setcol a"] = "csvkit: usage: setcol {col} formula {expr}",
      ["setcol a formula"] = "csvkit: usage: setcol {col} formula {expr}",
      ["setcol a value 1"] = "csvkit: usage: setcol {col} formula {expr}",
      ["setcol nope formula 1"] = 'csvkit: no column "nope"',
      ["setcol a formula nope"] = 'csvkit: unknown column "nope" at position 1',
    }) do
      eq(csvkit(args), { { msg, vim.log.levels.ERROR } })
    end
    eq(lines(), { "a,b", "2,x", ",2" })
  end,

  ["formulas in the buffer see only the visible rows; PREV reads the previous visible one"] = function()
    local original = { "year,region,total,g", "2000,A,100,", "2000,B,7,b", "2001,A,110,", "2001,B,8,b", "2002,A,121," }
    open(original)
    csvkit("setcol g formula PREV(total)")
    eq(lines(), { "year,region,total,g", "2000,A,100,0", "2000,B,7,100", "2001,A,110,7", "2001,B,8,110", "2002,A,121,8" })
    vim.cmd("silent undo")
    csvkit('filter region = "A"')
    csvkit("setcol g formula PREV(total)") -- a hidden row keeps its cell
    eq(lines(), { "year,region,total,g", "2000,A,100,0", "2000,B,7,b", "2001,A,110,100", "2001,B,8,b", "2002,A,121,110" })
    vim.cmd("silent undo")
    csvkit("setcol g formula SUM(total)") -- aggregates too
    eq(lines(), { "year,region,total,g", "2000,A,100,331", "2000,B,7,b", "2001,A,110,331", "2001,B,8,b", "2002,A,121,331" })
    vim.cmd("silent undo")
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    -- addcol takes the same rows; a hidden row's new cell is empty, and only
    -- a visible row's failure is counted
    eq(csvkit("addcol growth formula (total - PREV(total)) / PREV(total)"), {
      { "csvkit: 1 cell failed (rows 2): division by zero", vim.log.levels.WARN },
    })
    eq(lines(), { "year,growth,region,total,g", "2000,,A,100,", "2000,,B,7,b", "2001,0.1,A,110,", "2001,,B,8,b", "2002,0.1,A,121," })
    vim.cmd("silent undo")
    -- row delete where: only visible rows are deleted
    eq(csvkit("row delete where total < 50"), { { "csvkit: no row matches; nothing deleted", vim.log.levels.INFO } })
    eq(csvkit("row delete where total > 105"), { { "csvkit: deleted 2 rows", vim.log.levels.INFO } })
    eq(lines(), { "year,region,total,g", "2000,A,100,", "2000,B,7,b", "2001,B,8,b" })
    vim.cmd("silent undo")
    -- not in filters: the filter stays as it was
    local refused = { { "csvkit: PREV works in addcol and setcol, not in filters", vim.log.levels.ERROR } }
    eq(csvkit("filter PREV(total) > 1"), refused)
    eq(require("csvkit.filter").states[vim.api.nvim_get_current_buf()].expr, 'region = "A"')
    eq(csvkit("row delete where PREV(total) > 1"), refused)
    eq(lines(), original)
  end,

  ["negative column numbers count from the end (-1 is the last): delcol, goto, sort, formulas"] = function()
    local original = { "a,b,c,d,e,f", "1,2,3,4,5,6" }
    for args, want in pairs({
      ["-1"] = { "a,b,c,d,e", "1,2,3,4,5" },
      ["2--2"] = { "a,b,f", "1,2,6" },
      ["-2--3"] = { "a,b,c,f", "1,2,3,6" },
      ["-2-3"] = { "a,b,c,f", "1,2,3,6" },
      ["0 -6"] = { "b,c,d,e,f", "2,3,4,5,6" }, -- the same column twice
    }) do
      open(original)
      csvkit("delcol " .. args)
      eq(lines(), want)
    end
    open(original)
    eq(csvkit("delcol -7"), { { 'csvkit: no column "-7"', vim.log.levels.ERROR } })
    eq(csvkit("delcol 2--9"), { { 'csvkit: no column "-9"', vim.log.levels.ERROR } })
    eq(csvkit("delcol 0--1"), { { "csvkit: can't delete every column", vim.log.levels.ERROR } })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    csvkit("goto -1")
    eq(vim.api.nvim_win_get_cursor(0), { 2, 10 })
    open({ "a,b", "1,z", "2,y" })
    csvkit("sort -1")
    eq(lines(), { "a,b", "2,y", "1,z" })
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    csvkit("addcol c formula CONCAT($-1, $-2)")
    eq(lines(), { "a,b,c", "2,y,y2", "1,z,z1" })
    open({ "1,2,3", "4,5,6" }, { 1, 4 })
    vim.b.csvkit = { header = false } -- the last column of the first record
    csvkit("addcol x formula $-1 * 10")
    eq(lines(), { "1,2,3,30", "4,5,6,60" })
  end,

  ["delcol errors: the only column, no such column, a buffer that can't be changed"] = function()
    open({ "a", "b" })
    eq(csvkit("delcol"), { { "csvkit: can't delete every column", vim.log.levels.ERROR } })
    open(SIMPLE)
    eq(csvkit("delcol nope"), { { 'csvkit: no column "nope"', vim.log.levels.ERROR } })
    vim.bo.modifiable = false
    eq(csvkit("delcol 0"), { { "csvkit: the buffer is not modifiable", vim.log.levels.ERROR } })
    eq(lines(), SIMPLE)
  end,

  ["goto {col}: the cursor goes to the column on its row, which is scrolled to the left edge"] = function()
    open({ "name,city,age", '"Ana, A",Bogota,30', "Luis,Madrid,25" }, { 2, 0 })
    vim.wo.wrap = false
    csvkit("goto 2") -- counts from 0
    eq(vim.api.nvim_win_get_cursor(0), { 2, 16 })
    eq(vim.fn.winsaveview().leftcol, 15) -- from the delimiter before it
    csvkit("goto city")
    eq(vim.api.nvim_win_get_cursor(0), { 2, 9 })
    eq(vim.fn.winsaveview().leftcol, 8)
    csvkit("goto 0")
    eq({ vim.api.nvim_win_get_cursor(0), vim.fn.winsaveview().leftcol }, { { 2, 0 }, 0 })
    vim.api.nvim_win_set_cursor(0, { 3, 2 })
    csvkit("goto 1")
    eq(vim.api.nvim_win_get_cursor(0), { 3, 5 })
  end,

  ["goto: a field after a cell spanning lines, a short row, and errors"] = function()
    open({ "a,b,c", '"x', 'y",z,w', "1" }, { 3, 0 })
    csvkit("goto 2")
    eq(vim.api.nvim_win_get_cursor(0), { 3, 5 })
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    for args, msg in pairs({
      ["goto 1"] = 'csvkit: this row has no column "1"',
      ["goto 3"] = 'csvkit: no column "3"',
      ["goto"] = "csvkit: usage: goto {col}",
      ["goto a b"] = "csvkit: usage: goto {col}",
    }) do
      eq(csvkit(args), { { msg, vim.log.levels.ERROR } })
    end
    eq(vim.api.nvim_win_get_cursor(0), { 4, 0 })
  end,

  ["addcol fill shows newlines as ⏎ and indexes without a header"] = function()
    open({ '1,"a', 'b"' })
    vim.b.csvkit = { header = false }
    local prompts = answering({ "x" }, function()
      csvkit("addcol ignored fill")
    end)
    eq(prompts, { "Row 1 [0=1, 1=a⏎b] > " })
    eq(lines(), { '1,x,"a', 'b"' })
  end,

  ["addcol fill does not write over changes made meanwhile"] = function()
    open(SIMPLE)
    local msgs
    answering({ "a" }, function()
      local input = vim.ui.input
      vim.ui.input = function(o, cb)
        vim.api.nvim_buf_set_lines(0, 3, 4, false, { "Zoe,1,Rome" })
        input(o, cb)
      end
      msgs = csvkit("addcol tag fill")
    end)
    eq(msgs, { { "csvkit: the buffer changed while prompting; nothing written", vim.log.levels.ERROR } })
    eq(lines()[4], "Zoe,1,Rome")
    eq(lines()[1], "name,age,city")
  end,

  ["addcol prompts for what is missing"] = function()
    open(SIMPLE)
    local prompts = answering({ "total", "", "formula", "age * 2" }, function()
      csvkit("addcol")
    end)
    local position = "Position (after|before {col}; Enter: after the cursor's column): "
    eq(prompts, { "Column name: ", position, "Fill with: value|formula|fill", "Formula: " })
    eq(lines()[2], "Ana,60,30,Bogotá")
    -- the position prompted; a bad one stops there
    open(SIMPLE)
    answering({ "total", "after -1", "value", "v" }, function()
      csvkit("addcol")
    end)
    eq(lines()[2], "Ana,30,Bogotá,v")
    open(SIMPLE)
    local msgs
    answering({ "total", "next to age" }, function()
      msgs = csvkit("addcol")
    end)
    eq(msgs, { { "csvkit: the position is after {col} or before {col}", vim.log.levels.ERROR } })
    eq(lines(), SIMPLE)
    -- a name given, the mode and value prompted; Esc cancels
    open(SIMPLE)
    answering({ "value", "v" }, function()
      csvkit("addcol x")
    end)
    eq(lines()[2], "Ana,v,30,Bogotá")
    open(SIMPLE)
    answering({ vim.NIL }, function()
      csvkit("addcol")
    end)
    eq(lines(), SIMPLE)
    eq(csvkit("addcol x paint"), { { 'csvkit: unknown addcol mode "paint" (value|formula|fill)', vim.log.levels.ERROR } })
  end,

  ["stats: a float of the column over the rows the filters show; <CR> copies a value"] = function()
    local original = { "name,age", "Ana,30", "Luis,25", "Mia,", "Eva,41" }
    local src = open(original, { 2, 4 }) -- on "30"
    csvkit('filter name <> "Eva"')
    csvkit("stats")
    eq(vim.api.nvim_win_get_config(0).title, { { " Stats: age " } })
    eq(vim.list_slice(lines(), 1, 7), {
      "type         number",
      "rows         3",
      "empty        1",
      "unique       2",
      "most common  25 (1 time)",
      "min          25",
      "max          30",
    })
    local regs, setreg, notify, msgs = {}, vim.fn.setreg, vim.notify, {}
    vim.fn.setreg = function(reg, value)
      regs[reg] = value
    end
    vim.notify = function(msg)
      msgs[#msgs + 1] = msg
    end
    vim.api.nvim_win_set_cursor(0, { 7, 0 })
    local ok, err = pcall(vim.api.nvim_feedkeys, vim.keycode("<CR>"), "mx", false)
    vim.fn.setreg, vim.notify = setreg, notify
    assert(ok, err)
    eq(regs['"'], "30")
    eq(msgs, { "csvkit: copied 30" })
    eq(vim.api.nvim_get_current_buf(), src) -- the float closed
    -- a named column and n; the buffer is never changed
    csvkit("stats name 1")
    eq(vim.list_slice(lines(), 1, 2), { "type         string", "rows         3" })
    vim.cmd("close")
    eq(lines(), original)
    local usage = "csvkit: usage: stats [{col}] [{figure} ...] [n]; figures: type, rows, empty, unique, common, "
      .. "min, max, oldest, newest, sum, average, largest, smallest, values"
    for args, msg in pairs({
      ["stats age x"] = usage,
      ["stats age 0"] = usage,
      ["stats age 1 2"] = usage,
      ["stats age max 3"] = "csvkit: stats: n goes with largest or smallest",
      ["stats name sum"] = "csvkit: stats: sum needs a number column, and this one is string",
      ["stats nope"] = 'csvkit: no column "nope"',
    }) do
      eq(csvkit(args), { { msg, vim.log.levels.ERROR } })
    end
    csvkit("filter clear")
  end,

  ["stats {figure} ...: only those figures; the first word is a column when one has that name"] = function()
    open({ "name,age,type", "Ana,30,TV", "Luis,25,TV", "Mia,,OVA", "Eva,41,TV" }, { 2, 4 }) -- on "30"
    csvkit("stats max sum") -- figures only: the cursor's column
    eq(vim.api.nvim_win_get_config(0).title, { { " Stats: age " } })
    eq(lines(), { "max          41", "sum          96" })
    vim.cmd("close")
    csvkit("stats age largest smallest 1")
    eq(lines(), { "largest 1", "  41", "smallest 1", "  25" })
    vim.cmd("close")
    csvkit("stats type") -- a column called "type", not the figure
    eq(lines()[1], "type         string")
    eq(lines()[5], "most common  TV (3 times)")
    vim.cmd("close")
    csvkit("stats type common")
    eq(lines(), { "most common  TV (3 times)" })
    vim.cmd("close")
    csvkit("stats 1 average") -- by number
    eq(lines(), { "average      32" })
    vim.cmd("close")
  end,

  ["stats with a range: only the rows those lines touch, minus the hidden ones"] = function()
    open({ "name,age", "Ana,30", '"Lu', 'is",25', "Mia,12", "Eva,41" })
    csvkit("stats age", "4,5") -- the second line of Luis's record counts it
    eq(vim.api.nvim_win_get_config(0).title, { { " Stats: age (lines 4-5) " } })
    eq(vim.list_slice(lines(), 2, 7), { "rows         2", "empty        0", "unique       2", "most common  12 (1 time)", "min          12", "max          25" })
    vim.cmd("close")
    csvkit('filter name <> "Mia"')
    csvkit("stats age", "1,5") -- the header holds no row
    eq(vim.list_slice(lines(), 2, 7), { "rows         2", "empty        0", "unique       2", "most common  25 (1 time)", "min          25", "max          30" })
    vim.cmd("close")
    csvkit("filter clear")
  end,

  ["columns: a float of every column's number and name; long names wrap under the name"] = function()
    local long = ("x"):rep(200)
    local header = { "id", "unit price", long, '"two', 'lines"', "" }
    for c = 5, 11 do
      header[#header + 1] = "c" .. c
    end
    local original = { table.concat(header, ",", 1, 4), table.concat(header, ",", 5), "1,2,3,4,5,6,7,8,9,10,11,12" }
    local src = open(original)
    csvkit("columns")
    eq(vim.api.nvim_win_get_config(0).title, { { " Columns (12) " } })
    eq(vim.list_slice(lines(), 1, 6), { "0   id", "1   unit price", "2   " .. long, "3   two⏎lines", "4", "5   c5" })
    eq(lines()[12], "11  c11")
    -- the 204-wide line takes 3 rows in the 76 wide float (rows 2 and 3 start 4 in)
    eq(vim.api.nvim_win_get_width(0), vim.o.columns - 4)
    eq({ vim.wo.wrap, vim.wo.breakindent, vim.wo.breakindentopt }, { true, true, "shift:4" })
    eq(vim.api.nvim_win_get_height(0), 14)
    local regs, setreg, notify = {}, vim.fn.setreg, vim.notify
    vim.fn.setreg = function(reg, value)
      regs[reg] = value
    end
    vim.notify = function() end
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local ok, err = pcall(vim.api.nvim_feedkeys, vim.keycode("<CR>"), "mx", false)
    vim.fn.setreg, vim.notify = setreg, notify
    assert(ok, err)
    eq(regs['"'], "unit price")
    eq(vim.api.nvim_get_current_buf(), src)
    eq(lines(), original)
    eq(csvkit("columns x"), { { "csvkit: usage: columns [dtype]", vim.log.levels.ERROR } })
    eq(csvkit("columns", "1,2"), { { "csvkit: columns takes no range", vim.log.levels.ERROR } })
    -- many columns and no header: numbers only; the float fits the screen and scrolls
    open({ ("v,"):rep(999) .. "v" })
    vim.b.csvkit = { header = false }
    csvkit("columns")
    eq(vim.api.nvim_win_get_config(0).title, { { " Columns (1000) " } })
    eq({ lines()[1], lines()[1000], #lines() }, { "0", "999", 1000 })
    eq(vim.api.nvim_win_get_height(0), vim.o.lines - 6)
    vim.cmd("close")
    open({})
    eq(csvkit("columns"), { { "csvkit: the buffer has no rows", vim.log.levels.ERROR } })
  end,

  ["columns dtype: each column's type after its name, in the file and in the view"] = function()
    open({ "a,b,3,", "1,x,TRUE,", "2,y,,", "1,,FALSE," })
    csvkit("columns dtype")
    eq(lines(), { "0  a  [number]", "1  b  [string]", "2  3  [bool]", "3  [string]" })
    vim.cmd("close")
    eq(csvkit("columns dtype x"), { { "csvkit: usage: columns [dtype]", vim.log.levels.ERROR } })
    csvkit("view")
    csvkit("columns dtype")
    eq(lines(), { "0  a  [number]", "1  b  [string]", "2  3  [bool]", "3  [string]" })
    vim.cmd("close")
    csvkit("discard")
  end,

  ["columns in the table view: its columns, staged ones included"] = function()
    open({ "a,b", "1,2" })
    csvkit("view")
    csvkit("addcol new after b value z")
    csvkit("delcol a")
    csvkit("columns")
    eq(lines(), { "0  b", "1  new" })
    vim.cmd("close")
    csvkit("discard")
  end,

  ["undo keeps the last 3 sorts / addcols and what came after"] = function()
    -- vim.go: vim.o would copy a local undolevels to the global one
    local function step(cmd) -- each command is its own undo step
      csvkit(cmd)
      vim.go.undolevels = vim.go.undolevels
    end
    local function undo_all() -- undoes as far as the history goes; returns the steps
      local n = 0
      while vim.fn.undotree().seq_cur > 0 and n < 50 do
        vim.cmd("silent undo")
        n = n + 1
      end
      return n
    end
    open({ "n", "3", "1", "2" }, { 2, 0 })
    step("sort n") -- 1, 2, 3
    local after_first = lines()
    step("sort n desc") -- 3, 2, 1
    vim.api.nvim_buf_set_lines(0, 1, 2, false, { "9" }) -- an edit of the user's
    vim.go.undolevels = vim.go.undolevels
    step("row add") -- not counted: it keeps no old text
    step("sort n")
    eq(#vim.fn.undotree().entries, 6) -- open's set_lines, 3 sorts, the edit, row add
    step("addcol x value 1") -- the 4th: the oldest sort and what came before it go
    eq(#vim.fn.undotree().entries, 5)
    eq(vim.go.undolevels, 1000) -- the setting is back as it was
    eq(vim.bo.undolevels, -123456)
    eq(undo_all(), 5)
    eq(lines(), after_first)
  end,

  ["undo cap leaves a lower undolevels alone"] = function()
    open({ "n", "3", "1", "2" })
    vim.bo.undolevels = 2
    for _, cmd in ipairs({ "sort n", "sort n desc", "sort n", "sort n desc" }) do
      csvkit(cmd)
      vim.go.undolevels = vim.go.undolevels
    end
    eq(#vim.fn.undotree().entries, 3) -- undolevels 2 keeps 2 + the newest
    eq(vim.bo.undolevels, 2)
  end,

  ["commands keep no Lua memory once done"] = function()
    -- a LuaJIT trace keeps the closures it was recorded with, so a closure in a
    -- hot loop would keep its upvalues (the new lines, the sort keys) alive.
    -- Long mixed-case names make that ~10 MB, far above what LuaJIT's string
    -- table may keep after growing (< 1 MB here).
    local data, pad = { "id,price,name" }, ("Xy"):rep(250)
    for i = 1, 20000 do
      data[#data + 1] = ("%d,%d.5,%s%d"):format(i, i % 97, pad, i)
    end
    open(data, { 1, 4 })
    local function heap()
      for _ = 1, 4 do
        collectgarbage()
      end
      return collectgarbage("count")
    end
    for _, cmd in ipairs({ "sort price", "sort name", "addcol x value v", "addcol y formula price * 2" }) do
      local before = heap()
      csvkit(cmd)
      local kept = heap() - before
      assert(kept < 2048, ("%s kept %.0f KB"):format(cmd, kept))
    end
  end,

  ["decimal and thousands are remembered for the file"] = function()
    local buf = open({ "a,b", "1.5,2" })
    vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".csv")
    csvkit("decimal ,")
    csvkit("thousands space")
    local o = require("csvkit").get_opts(buf)
    eq({ o.decimal, o.thousands }, { ",", " " })
    csvkit("thousands none")
    eq(require("csvkit").get_opts(buf).thousands, false)
    csvkit("decimal auto")
    eq(require("csvkit").get_opts(buf).decimal, ".")
    eq(csvkit("decimal ;"), { { "csvkit: usage: decimal {.|,|auto}", vim.log.levels.ERROR } })
    open({ "a,b" })
    eq(csvkit("decimal ,"), { { "csvkit: buffer has no file name", vim.log.levels.ERROR } })
  end,

  ["unknown subcommand"] = function()
    open(SIMPLE)
    eq(csvkit("paint"), { { 'csvkit: unknown subcommand "paint"', vim.log.levels.ERROR } })
    eq(csvkit(""), { { 'csvkit: unknown subcommand ""', vim.log.levels.ERROR } })
  end,

  ["mv col moves a column in every record, header too, in one undo step; the rest keeps its text"] = function()
    local original = { 'name,"city, x",age', '"Ana",Bogota,30', 'Luis,"two', 'lines",25', "Mia", "Eva,Lima,41\r", "" }
    for args, want in pairs({
      ["name 2"] = { '"city, x",age,name', "Bogota,30,\"Ana\"", '"two', 'lines",25,Luis', ",,Mia", "Lima,41,Eva\r", "" },
      ["name -1"] = { '"city, x",age,name', "Bogota,30,\"Ana\"", '"two', 'lines",25,Luis', ",,Mia", "Lima,41,Eva\r", "" },
      ["name 99"] = { '"city, x",age,name', "Bogota,30,\"Ana\"", '"two', 'lines",25,Luis', ",,Mia", "Lima,41,Eva\r", "" },
      ["age 0"] = { 'age,name,"city, x"', '30,"Ana",Bogota', '25,Luis,"two', 'lines"', ",Mia,", "41,Eva,Lima\r", "" },
      ["age 1"] = { 'name,age,"city, x"', '"Ana",30,Bogota', 'Luis,25,"two', 'lines"', "Mia,,", "Eva,41,Lima\r", "" },
      ["1 -2"] = original, -- already second to last
    }) do
      open(original)
      csvkit("mv col " .. args)
      eq(lines(), want)
      if want ~= original then
        undo_restores(original)
      end
    end
  end,

  ["mv col takes a name or a number, writes nothing when the column stays, and checks its words"] = function()
    open(SIMPLE)
    eq(csvkit("mv col 0 -3"), {})
    eq(lines(), SIMPLE)
    csvkit("mv col 2 0")
    eq(lines()[1], "city,name,age")
    eq(csvkit("mv col nope 1"), { { 'csvkit: no column "nope"', vim.log.levels.ERROR } })
    eq(csvkit("mv col 0 -9"), { { "csvkit: no position -9 among 3 columns", vim.log.levels.ERROR } })
    for _, args in ipairs({ "", "col", "col 0", "col 0 x", "0 1", "col 0 1 2" }) do
      eq(csvkit("mv " .. args), { { "csvkit: usage: mv col {col} {index}", vim.log.levels.ERROR } })
    end
  end,

  ["completion in the view offers the view's columns, not its first line"] = function()
    open({ "name,unit price,age", "a,1,2" })
    vim.cmd("Csvkit view")
    vim.cmd("Csvkit addcol new value 1")
    vim.cmd("Csvkit delcol age")
    eq(require("csvkit.command").complete("", "Csvkit filter ", 14), { "name", "new", "unit\\ price", "clear" })
    eq(require("csvkit.command").complete("", "Csvkit mv col ", 14), { "name", "new", "unit\\ price" })
    eq(require("csvkit.command").complete("", "Csvkit mv ", 10), { "col" })
    vim.cmd("bdelete")
  end,

  ["completion"] = function()
    open({ "name,unit price,age", "a,1,2" })
    local function complete(line)
      return vim.fn.getcompletion(line, "cmdline")
    end
    eq(complete("Csvkit "), { "addcol", "align", "apply", "columns", "decimal", "delcol", "discard", "filter", "goto", "hide", "mv", "preview", "restore", "row", "setcol", "sort", "stats", "thousands", "view" })
    eq(complete("Csvkit row "), { "add", "delete" })
    eq(complete("Csvkit row delete "), { "where", "hidden" })
    eq(complete("Csvkit row delete where "), { "name", [[unit\ price]], "age" })
    eq(complete("Csvkit goto "), { "name", [[unit\ price]], "age" })
    local figures = { "type", "rows", "empty", "unique", "common", "min", "max", "oldest", "newest", "sum", "average", "largest", "smallest", "values" }
    eq(complete("Csvkit stats "), vim.list_extend({ "name", [[unit\ price]], "age" }, figures))
    eq(complete("Csvkit stats age "), figures)
    eq(complete("Csvkit stats age max l"), { "largest" })
    eq(complete("Csvkit hide "), { "name", [[unit\ price]], "age", "clear" })
    eq(complete("Csvkit so"), { "sort" })
    eq(complete("Csvkit sort "), { "name", [[unit\ price]], "age", "asc", "desc", "num", "str", "date" })
    eq(complete("Csvkit sort a"), { "age", "asc" })
    eq(complete("Csvkit SO"), { "sort" })
    eq(complete("Csvkit sort NA"), { "name" })
    eq(complete("Csvkit sort A"), { "age", "asc" })
    eq(complete([[Csvkit sort unit\ p]]), { [[unit\ price]] })
    eq(complete("Csvkit row add "), { "above", "below" })
    eq(complete("Csvkit addcol x "), { "after", "before", "value", "formula", "fill" })
    eq(complete("Csvkit addcol x formula "), { "name", [[unit\ price]], "age" })
    eq(complete("Csvkit addcol x before "), { "name", [[unit\ price]], "age" })
    eq(complete("Csvkit addcol x before age "), { "value", "formula", "fill" })
    eq(complete("Csvkit addcol x after age formula "), { "name", [[unit\ price]], "age" })
    eq(complete("Csvkit thousands "), { ",", ".", "space", "'", "none", "auto" })
    eq(complete("Csvkit decimal , "), {})
    -- after modifiers, a range or an abbreviated name
    eq(complete("silent! vert Csvkit row "), { "add", "delete" })
    eq(complete("'<,'>Csvkit row "), { "add", "delete" })
    eq(complete("Csvk sort a"), { "age", "asc" })
  end,

  ["<Plug> maps run their subcommand"] = function()
    open({ "n", "2", "1" }, { 2, 0 })
    vim.api.nvim_feedkeys(vim.keycode("<Plug>(csvkit-sort-asc)"), "x", false)
    eq(lines(), { "n", "1", "2" })
    vim.api.nvim_feedkeys(vim.keycode("<Plug>(csvkit-row-above)"), "x", false)
    eq(lines(), { "n", '""', "1", "2" })
    eq(vim.fn.maparg("<Plug>(csvkit-restore)", "n"), "<Cmd>Csvkit restore<CR>")
  end,

  ["a buffer that is not modifiable: every editing command says so, and edits nothing"] = function()
    open(SIMPLE)
    vim.bo.modifiable = false
    local msg = { { "csvkit: the buffer is not modifiable", vim.log.levels.ERROR } }
    local prompted, reads = false, 0
    local input, edit = vim.ui.input, require("csvkit.edit")
    local read, read_at = edit.read, edit.read_at
    vim.ui.input = function()
      prompted = true
    end
    edit.read = function(...)
      reads = reads + 1
      return read(...)
    end
    edit.read_at = function(...)
      reads = reads + 1
      return read_at(...)
    end
    for _, cmd in ipairs({ "sort age", "row add", "addcol x value 1", "addcol x fill", "addcol", "restore" }) do
      eq(csvkit(cmd), msg)
    end
    vim.ui.input, edit.read, edit.read_at = input, read, read_at
    eq({ prompted, reads }, { false, 0 }) -- refused before reading or asking anything
    eq(lines(), SIMPLE)
    -- it turns not modifiable while a prompt is open: the write refuses
    vim.bo.modifiable = true
    local pending
    vim.ui.input = function(_, cb)
      pending = cb
    end
    eq(csvkit("addcol x fill"), {})
    vim.bo.modifiable = false
    local notified, notify = {}, vim.notify
    vim.notify = function(m)
      notified[#notified + 1] = m
    end
    for _ = 1, 3 do -- the last answer writes
      pending("v")
    end
    vim.notify = notify
    vim.ui.input = input
    eq(notified, { msg[1][1] })
    eq(lines(), SIMPLE)
  end,

  ["a readonly buffer can still be edited"] = function()
    open({ "n", "2", "1" })
    vim.bo.readonly = true
    eq(csvkit("sort n"), {})
    eq(lines(), { "n", "1", "2" })
  end,

  ["running out of memory is reported and leaves the buffer alone"] = function()
    open(SIMPLE)
    local edit = require("csvkit.edit")
    local read = edit.read
    edit.read = function()
      error("not enough memory")
    end
    local msgs = csvkit("sort age")
    edit.read = read
    eq(msgs, { { "csvkit: out of memory; the buffer is unchanged", vim.log.levels.ERROR } })
    eq(lines(), SIMPLE)
  end,

  ["a failing write puts 'undolevels' back"] = function()
    open({ "n", "3", "2", "1" })
    for _, cmd in ipairs({ "sort n", "sort n desc", "sort n" }) do
      csvkit(cmd)
      vim.go.undolevels = vim.go.undolevels
    end
    local set_lines = vim.api.nvim_buf_set_lines
    vim.api.nvim_buf_set_lines = function()
      error("boom")
    end
    local ok, err = pcall(vim.cmd, "Csvkit sort n desc") -- the 4th: the undo cap lowers the setting
    vim.api.nvim_buf_set_lines = set_lines
    eq(ok, false)
    assert(err:find("boom", 1, true), err)
    eq(vim.bo.undolevels, -123456)
    eq(vim.go.undolevels, 1000)
  end,

  ["restore leaves no scratch buffer behind when it fails"] = function()
    local file = vim.fn.tempname() .. ".csv"
    vim.fn.writefile(SIMPLE, file)
    vim.cmd.edit(file)
    vim.api.nvim_buf_set_lines(0, 1, 2, false, { "x,1,y" })
    local before = #vim.api.nvim_list_bufs()
    local real, get_lines = vim.api.nvim_get_current_buf(), vim.api.nvim_buf_get_lines
    vim.api.nvim_buf_get_lines = function(buf, ...)
      if buf ~= real then
        error("boom")
      end
      return get_lines(buf, ...)
    end
    local ok = pcall(vim.cmd, "Csvkit restore")
    vim.api.nvim_buf_get_lines = get_lines
    eq(ok, false)
    eq(#vim.api.nvim_list_bufs(), before)
  end,

  ["the undo cap works with 'undolevels' at -1 and 0"] = function()
    for _, levels in ipairs({ -1, 0 }) do
      open({ "n", "3", "2", "1" })
      vim.bo.undolevels = levels
      for _, cmd in ipairs({ "sort n", "sort n desc", "sort n", "sort n desc", "sort n" }) do
        eq(csvkit(cmd), {})
      end
      eq(lines(), { "n", "1", "2", "3" })
      eq(vim.bo.undolevels, levels)
    end
  end,

  ["restore with nothing to change is no edit"] = function()
    local file = vim.fn.tempname() .. ".csv"
    vim.fn.writefile(SIMPLE, file)
    vim.cmd.edit(file)
    vim.api.nvim_buf_set_lines(0, 1, 2, false, { "x,1,y" })
    vim.cmd("silent undo")
    local tick = vim.b.changedtick
    eq(csvkit("restore"), {})
    eq(vim.b.changedtick, tick)
    eq(vim.bo.modified, false)
  end,
}
