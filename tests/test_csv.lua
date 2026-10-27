local csv = require("csvkit.csv")

-- Serializes rows into buffer lines (a field with "\n" spans lines).
local function to_lines(rows, delim, quote_all)
  local out = {}
  for _, row in ipairs(rows) do
    vim.list_extend(out, vim.split(csv.serialize_row(row, delim, quote_all), "\n", { plain = true }))
  end
  return out
end

local function read_bytes(path)
  local f = assert(io.open(path, "rb"))
  local bytes = f:read("*a")
  f:close()
  return bytes
end

return {
  ["simple"] = function()
    eq(csv.parse({ "a,b,c", "1,2,3" }, ","), {
      rows = { { "a", "b", "c" }, { "1", "2", "3" } },
      line_of = { 1, 2 },
      quote_all = false,
    })
  end,

  ["quoted delimiter"] = function()
    eq(csv.parse({ '"a,b",c' }, ",").rows, { { "a,b", "c" } })
  end,

  ["escaped quote"] = function()
    eq(csv.parse({ '"say ""hi""",x' }, ",").rows, { { 'say "hi"', "x" } })
  end,

  ["multiline field"] = function()
    local p = csv.parse({ "id,note", '1,"line one', 'line two"', "2,x" }, ",")
    eq(p.rows, { { "id", "note" }, { "1", "line one\nline two" }, { "2", "x" } })
    eq(p.line_of, { 1, 2, 4 })
  end,

  ["empty fields"] = function()
    eq(csv.parse({ "a,,b", "a,", ",", '""' }, ",").rows, {
      { "a", "", "b" },
      { "a", "" },
      { "", "" },
      { "" },
    })
  end,

  ["ragged rows"] = function()
    eq(csv.parse({ "a,b,c", "1", "2,3,4,5" }, ",").rows, { { "a", "b", "c" }, { "1" }, { "2", "3", "4", "5" } })
  end,

  ["only header"] = function()
    local p = csv.parse({ "a,b" }, ",")
    eq(p.rows, { { "a", "b" } })
    eq(p.line_of, { 1 })
  end,

  ["empty buffer"] = function()
    local empty = { rows = {}, line_of = {}, quote_all = false }
    eq(csv.parse({ "" }, ","), empty)
    eq(csv.parse({}, ","), empty)
  end,

  ["trailing empty lines are not rows"] = function()
    eq(csv.parse({ "a,b", "1,2", "", "" }, ",").rows, { { "a", "b" }, { "1", "2" } })
  end,

  ["blank middle line is a one-field row"] = function()
    local p = csv.parse({ "a", "", "b" }, ",")
    eq(p.rows, { { "a" }, { "" }, { "b" } })
    eq(p.line_of, { 1, 2, 3 })
  end,

  ["unicode"] = function()
    local lines = { "名前,ciudad", "José,Bogotá", '"ü,ñ",€' }
    eq(csv.detect_delimiter(lines), ",")
    eq(csv.parse(lines, ",").rows, { { "名前", "ciudad" }, { "José", "Bogotá" }, { "ü,ñ", "€" } })
  end,

  ["malformed quotes are read leniently"] = function()
    -- text after a closing quote is kept; an unclosed quote runs to the end
    eq(csv.parse({ '"ab"c,d', 'x,"open', "rest" }, ",").rows, { { "abc", "d" }, { "x", "open\nrest" } })
  end,

  ["each delimiter detected"] = function()
    for _, d in ipairs({ ",", ";", "\t", "|" }) do
      eq(csv.detect_delimiter({ "a" .. d .. "b" .. d .. "c", "1" .. d .. "2" .. d .. "3" }), d)
    end
  end,

  ["detection counts only outside quotes"] = function()
    eq(csv.detect_delimiter({ "name;desc", '"x,y";1', '"p,q,r";2' }), ";")
    eq(csv.detect_delimiter({ "id;note", '1;"a,b', 'c,d"', "", "2;e" }), ";")
  end,

  ["detection ignores a record cut at line 20"] = function()
    local lines = { "id;note" }
    for i = 1, 18 do
      lines[#lines + 1] = i .. ";x"
    end
    vim.list_extend(lines, { '"cut', 'here";19', "y;20" }) -- line 20 starts a 2-line record
    eq(csv.detect_delimiter(lines), ";")
  end,

  ["detection falls back to comma"] = function()
    eq(csv.detect_delimiter({ "one", "two" }), ",")
    eq(csv.detect_delimiter({ "a;b", "1;2;3" }), ",")
    eq(csv.detect_delimiter({}), ",")
  end,

  ["minimal quoting"] = function()
    eq(csv.serialize_row({ "a", "b c", "x,y", 'q"t', "l\nm", "r\rs", "" }, ",", false), 'a,b c,"x,y","q""t","l\nm","r\rs",')
    eq(csv.serialize_row({ "x,y", "a|b" }, "|", false), 'x,y|"a|b"')
    eq(csv.serialize_row({ "" }, ",", false), '""')
    eq(csv.serialize_field("", ",", false), "") -- one field among others, unlike a 1-field row
    eq(csv.serialize_field("x,y", ",", false), '"x,y"')
    eq(csv.serialize_field("", ",", true), '""')
  end,

  ["quoted fields: doubled quotes, empty, text after the closing quote"] = function()
    eq(csv.parse({ '"a""b",c', '"""",""', '"",x', '"ab"c,"d"e' }, ",").rows, {
      { 'a"b', "c" },
      { '"', "" },
      { "", "x" },
      { "abc", "de" },
    })
  end,

  ["index, column and record agree with parse"] = function()
    local cases = {
      { "a,b,c", "1,2,3" },
      { "id,note", '1,"line one', 'line two"', "2,x" },
      { "a,b,c", "1", "2,3,4,5" },
      { '"ab"c,d', 'x,"open', "rest" },
      { "a", "", "b", "", "" },
      { '"say ""hi""",x', '"",""', '"a","b"' },
      { '"a","b"', '"1","x', 'y"' },
      { "" },
      {},
    }
    for name, delim in pairs({ simple = ",", quoted = ",", multiline = ",", semicolon = ";", tsv = "\t" }) do
      local path = vim.api.nvim_get_runtime_file(("tests/fixtures/%s.csv"):format(name), false)[1]
      cases[#cases + 1] = { delim = delim, unpack(vim.split(read_bytes(path), "\n", { plain = true })) }
    end
    for _, lines in ipairs(cases) do
      local delim = lines.delim or ","
      local p, t = csv.parse(lines, delim), csv.index(lines, delim)
      eq({ lines, t.line_of, t.quote_all }, { lines, p.line_of, p.quote_all })
      for r, row in ipairs(p.rows) do
        eq({ lines, r, csv.record(t, r) }, { lines, r, row })
      end
      for c = 1, 5 do
        local cells = {}
        for r, row in ipairs(p.rows) do
          cells[r] = row[c] or "" -- a missing field is empty
        end
        eq({ lines, c, csv.column(t, c) }, { lines, c, cells })
      end
    end
  end,

  ["columns: every record's fields by column, blank where shorter (random)"] = function()
    math.randomseed(13)
    local words = { "a", "b c", "d,e", '"q"', "x\ny", "", "é" }
    for _ = 1, 50 do
      local rows = {}
      for r = 1, math.random(0, 10) do
        rows[r] = {}
        for c = 1, math.random(1, 4) do
          rows[r][c] = words[math.random(#words)]
        end
      end
      local lines = {}
      for _, row in ipairs(rows) do
        vim.list_extend(lines, vim.split(csv.serialize_row(row, ",", false), "\n", { plain = true }))
      end
      local t = csv.index(lines, ",")
      local first = math.random(1, 2)
      local want, ncols = {}, 0
      for r = first, #t.line_of do
        ncols = math.max(ncols, #csv.record(t, r))
      end
      for c = 1, ncols do
        want[c] = {}
        for r = first, #t.line_of do
          want[c][r - first + 1] = csv.record(t, r)[c] or ""
        end
      end
      eq(csv.columns(t, first), want)
    end
  end,

  ["field_end: the line and position after field k"] = function()
    local t = csv.index({ 'a,"b,c",d', '1,"x', 'y",z', "short" }, ",")
    -- returns the line, the position of the delimiter after the field (or the
    -- line's end + 1) and the fields walked
    eq({ csv.field_end(t, 1, 1) }, { 1, 2, 1 })
    eq({ csv.field_end(t, 1, 2) }, { 1, 8, 2 })
    eq({ csv.field_end(t, 1, 3) }, { 1, 10, 3 })
    eq({ csv.field_end(t, 2, 2) }, { 3, 3, 2 }) -- ends on the record's second line
    eq({ csv.field_end(t, 3, 4) }, { 4, 6, 1 }) -- a shorter record: its end, 1 field
  end,

  ["field_end: a stray \\r ending the line stays after the position"] = function()
    -- mixed line endings read with fileformat=unix keep a \r on some lines
    local t = csv.index({ "a,b\r", '"x"\r', "c,d" }, ",")
    eq({ csv.field_end(t, 1, 1) }, { 1, 2, 1 })
    eq({ csv.field_end(t, 1, 2) }, { 1, 4, 2 })
    eq({ csv.field_end(t, 1, 5) }, { 1, 4, 2 })
    eq({ csv.field_end(t, 2, 1) }, { 2, 4, 1 })
    eq({ csv.field_end(t, 3, 2) }, { 3, 4, 2 })
  end,

  ["quote_all preserved"] = function()
    eq(csv.parse({ '"a","b"', '"1",""' }, ",").quote_all, true)
    eq(csv.parse({ '"a","b"', '"1",2' }, ",").quote_all, false)
    eq(csv.serialize_row({ "1", "", 'q"' }, ",", true), '"1","","q"""')
  end,

  ["quote_all looks at the first 50 rows only"] = function()
    local lines = {}
    for i = 1, 50 do
      lines[i] = '"' .. i .. '"'
    end
    lines[51] = "unquoted"
    eq(csv.parse(lines, ",").quote_all, true)
  end,

  ["parse(serialize(x)) == x"] = function()
    local rows = {
      { "a", "b,c", 'q"t', "multi\nline", "" },
      { "", "x;y", "tab\there", "p|q", "\n" },
      { "" },
      { "last" },
      { "" },
    }
    for _, d in ipairs({ ",", ";", "\t", "|" }) do
      for _, quote_all in ipairs({ false, true }) do
        eq(csv.parse(to_lines(rows, d, quote_all), d).rows, rows)
      end
    end
  end,

  ["fixtures round-trip byte-identically"] = function()
    local fixtures = { simple = ",", quoted = ",", multiline = ",", semicolon = ";", tsv = "\t" }
    for name, delim in pairs(fixtures) do
      local path = vim.api.nvim_get_runtime_file(("tests/fixtures/%s.csv"):format(name), false)[1]
      local bytes = read_bytes(assert(path, name))
      local lines = vim.split(bytes, "\n", { plain = true })
      eq({ name, csv.detect_delimiter(lines) }, { name, delim })
      local p = csv.parse(lines, delim)
      eq({ name, table.concat(to_lines(p.rows, delim, p.quote_all), "\n") .. "\n" }, { name, bytes })
    end
  end,
}
