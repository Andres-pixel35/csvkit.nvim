-- CSV parse / serialize / delimiter detection. Works on buffer lines (no "\n").
local M = {}

local QUOTE = 34 -- '"'
local CANDIDATES = { ",", ";", "\t", "|" }

-- Reads the quoted field whose opening quote is at lines[i]:sub(pos, pos).
-- Returns the value plus the line and position just after the closing quote.
local function read_quoted(lines, i, pos, last)
  local line = lines[i]
  -- fast path: the closing quote is on this line, so one sub (and one gsub
  -- when the field has a "")
  local q, doubled = pos, false
  while true do
    q = line:find('"', q + 1, true)
    if not q then
      break
    elseif line:byte(q + 1) ~= QUOTE then
      local value = line:sub(pos + 1, q - 1)
      return doubled and (value:gsub('""', '"')) or value, i, q + 1
    end
    q, doubled = q + 1, true
  end
  local parts = {}
  pos = pos + 1
  while true do
    local q = line:find('"', pos, true)
    if not q then
      parts[#parts + 1] = line:sub(pos)
      if i >= last then -- unclosed quote: the field runs to the end
        return table.concat(parts), i, #line + 1
      end
      parts[#parts + 1] = "\n"
      i, pos = i + 1, 1
      line = lines[i]
    elseif line:byte(q + 1) == QUOTE then
      parts[#parts + 1] = line:sub(pos, q) -- keeps one quote of the pair
      pos = q + 2
    else
      parts[#parts + 1] = line:sub(pos, q - 1)
      return table.concat(parts), i, q + 1
    end
  end
end

-- Like read_quoted, but builds no value: returns the line and position just
-- after the closing quote.
local function skip_quoted(lines, i, pos, last)
  local line = lines[i]
  pos = pos + 1
  while true do
    local q = line:find('"', pos, true)
    if not q then
      if i >= last then
        return i, #line + 1
      end
      i, pos = i + 1, 1
      line = lines[i]
    elseif line:byte(q + 1) == QUOTE then
      pos = q + 2
    else
      return i, q + 1
    end
  end
end

-- Walks the record of index t that starts at line i, up to its field k
-- (math.huge: the whole record). Builds field k only, every field into out
-- when out is a table, or none when out is false. Returns field k (nil when the record is shorter), the
-- fields walked, whether they were all quoted, and the line and position where
-- the walk stopped: the delimiter after field k, or the record's end + 1.
local function walk(t, i, k, out)
  local lines, last, delim = t.lines, t.last, t.delim
  local line, pos, n, all_quoted = lines[i], 1, 0, true
  while true do
    n = n + 1
    local build, value, d = out or (out == nil and n == k), nil, nil
    if line:byte(pos) == QUOTE then
      if build then
        value, i, pos = read_quoted(lines, i, pos, last)
      else
        i, pos = skip_quoted(lines, i, pos, last)
      end
      line = lines[i]
      d = line:find(delim, pos, true)
      if build and (d or #line + 1) > pos then -- text after a closing quote is kept, like Python's csv
        value = value .. line:sub(pos, d and d - 1 or -1)
      end
    else
      all_quoted = false
      d = line:find(delim, pos, true)
      if build then
        value = line:sub(pos, d and d - 1 or -1)
      end
    end
    if out then
      out[n] = value
    end
    if n == k or not d then
      return value, n, all_quoted, i, d or #line + 1
    end
    pos = d + #delim
  end
end

-- Finds where each record starts without building any field. Returns the
-- index t = { lines, delim, last (the last non-empty line), line_of = {record
-- -> first line}, quote_all } that column(), record() and field_end() read.
-- Trailing empty lines are not records; quote_all is true when every field of
-- the first 50 records is quoted.
function M.index(lines, delim)
  local last = #lines
  while last > 0 and lines[last] == "" do
    last = last - 1
  end
  local t = { lines = lines, delim = delim, last = last, line_of = {}, quote_all = last > 0 }
  local line_of, i, n = t.line_of, 1, 0
  while i <= last do
    n = n + 1
    line_of[n] = i
    if not lines[i]:find('"', 1, true) then -- no quote: the record is this line
      t.quote_all = t.quote_all and n > 50
      i = i + 1
    else
      local _, _, all_quoted, stop = walk(t, i, math.huge)
      t.quote_all = t.quote_all and (all_quoted or n > 50)
      i = stop + 1
    end
  end
  return t
end

-- The fields of record r.
function M.record(t, r)
  local fields = {}
  walk(t, t.line_of[r], math.huge, fields)
  return fields
end

-- Field c of records first (default 1) to the last, as a list from 1; "" for
-- a record that has fewer fields.
function M.column(t, c, first)
  local cells, line_of = {}, t.line_of
  first = first or 1
  for r = first, #line_of do
    cells[r - first + 1] = walk(t, line_of[r], c) or ""
  end
  return cells
end

-- Every field of records first (default 1) to the last, by column: cols[c][i]
-- is field c of record first + i - 1, "" where a record is shorter. Each
-- record is walked once into one reused table, so no table is made per row.
function M.columns(t, first)
  first = first or 1
  local cols, out, line_of, ncols = {}, {}, t.line_of, 0
  for r = first, #line_of do
    local i = r - first + 1
    local _, n = walk(t, line_of[r], math.huge, out)
    for c = 1, n do
      local col = cols[c]
      if not col then -- the widest record so far: earlier ones are blank here
        col = {}
        for k = 1, i - 1 do
          col[k] = ""
        end
        cols[c], ncols = col, c
      end
      col[i] = out[c]
    end
    for c = n + 1, ncols do
      cols[c][i] = ""
    end
  end
  return cols
end

-- Where field k of record r ends: the line, the position of the delimiter
-- after it (or the line's length + 1), and the fields walked. When the record
-- has fewer than k fields, that count is returned with the record's end.
-- A \r ending the line (mixed line endings read as unix) stays after the
-- position, so a field put there does not land after the line ending.
function M.field_end(t, r, k)
  if k == 0 then -- before the first field
    return t.line_of[r], 1, 0
  end
  local _, n, _, i, pos = walk(t, t.line_of[r], k, false)
  local line = t.lines[i]
  if pos > #line and line:byte(-1) == 13 then
    pos = pos - 1
  end
  return i, pos, n
end

-- Returns { rows, line_of = {row -> first line}, quote_all } (see index).
function M.parse(lines, delim)
  local t = M.index(lines, delim)
  local rows = {}
  for r = 1, #t.line_of do
    rows[r] = M.record(t, r)
  end
  return { rows = rows, line_of = t.line_of, quote_all = t.quote_all }
end

-- The field count shared by all non-blank rows, or nil.
local function shared_count(rows)
  local count
  for _, row in ipairs(rows) do
    if #row > 1 or row[1] ~= "" then
      if count and count ~= #row then
        return nil
      end
      count = #row
    end
  end
  return count
end

-- The first candidate that splits every record of the first 20 lines into the
-- same number (> 1) of fields; "," when none does.
function M.detect_delimiter(lines)
  local sample = vim.list_slice(lines, 1, 20)
  for _, delim in ipairs(CANDIDATES) do
    local rows = M.parse(sample, delim).rows
    if #lines > #sample then
      rows[#rows] = nil -- the sample may end mid-record
    end
    if (shared_count(rows) or 1) > 1 then
      return delim
    end
  end
  return ","
end

-- One field, quoted when it has to be (or always with quote_all).
function M.serialize_field(s, delim, quote_all)
  -- plain finds: a pattern costs as much as the rest of an addcol row
  local special = s:find('"', 1, true) or s:find("\n", 1, true) or s:find("\r", 1, true)
  if quote_all or special or s:find(delim, 1, true) then
    return '"' .. s:gsub('"', '""') .. '"'
  end
  return s
end

-- Returns one record as a string; it contains "\n" when a field does, so split
-- it before nvim_buf_set_lines.
function M.serialize_row(fields, delim, quote_all)
  if #fields == 1 and fields[1] == "" then
    return '""' -- a bare empty line would read back as blank
  end
  local out = {}
  for i, s in ipairs(fields) do
    out[i] = M.serialize_field(s, delim, quote_all)
  end
  return table.concat(out, delim)
end

return M
