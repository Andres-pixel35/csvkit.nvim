-- Buffer edits: sort (rewrite), row add, addcol. Each reads the buffer once
-- with read(), builds the new lines and writes them with a single
-- nvim_buf_set_lines call, so the edit is one undo step.
local csv = require("csvkit.csv")
local csvkit = require("csvkit")
local formula = require("csvkit.formula")
local memory = require("csvkit.memory")
local sort = require("csvkit.sort")
local types = require("csvkit.types")

local M = {}

-- Indexes buf with its options: csv.index's fields (lines, line_of, last =
-- the last non-blank line, ...) plus buf, opts, tick, h (1 when record 1 is the
-- header, else 0), first (record 1's fields) and n (the number of data rows).
-- Only record 1 is parsed; a command reads the columns it needs with
-- csv.column, so no table per row is ever built. lines (default: buf's lines,
-- read now) lets a caller that keeps a copy up to date skip that read.
function M.read(buf, lines)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local opts = csvkit.get_opts(buf)
  local t = csv.index(lines or vim.api.nvim_buf_get_lines(buf, 0, -1, false), opts.delimiter)
  if #t.line_of == 0 then
    error("csvkit: the buffer has no rows", 0)
  end
  t.buf, t.opts, t.tick = buf, opts, vim.b[buf].changedtick
  t.h = opts.header and 1 or 0
  t.first = csv.record(t, 1)
  t.n = #t.line_of - t.h
  return t
end

-- Raises when buf can't be edited. The commands call it before reading or
-- prompting, and write calls it again (a prompt can be open for a while).
function M.check_modifiable(buf)
  if not vim.bo[buf == 0 and vim.api.nvim_get_current_buf() or buf].modifiable then
    error("csvkit: the buffer is not modifiable", 0)
  end
end

M.CHUNK = 10000 -- lines read at a time by read_at

-- Like read, but reads buf in chunks of M.CHUNK lines, and only up to the
-- record that holds line lnum, so only one chunk is in memory. Returns the
-- chunk's index with read's buf, opts, tick, h and first, quote_all for the
-- whole buffer, offset (line l of the chunk is buffer line offset + l) and r:
-- the record at lnum, an index in the chunk (offset 0 and r 1 is record 1).
function M.read_at(buf, lnum)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local opts = csvkit.get_opts(buf)
  local total, offset, size, head = vim.api.nvim_buf_line_count(buf), 0, M.CHUNK, nil
  while true do
    local t = csv.index(vim.api.nvim_buf_get_lines(buf, offset, offset + size, false), opts.delimiter)
    local n, eof = #t.line_of, offset + size >= total
    if n == 0 and eof then
      error("csvkit: the buffer has no rows", 0)
    end
    -- the chunk's last record may go on in the next chunk, so it is left to
    -- that one; the first chunk must also hold the 50 records quote_all reads
    if eof or n > (offset == 0 and 50 or 1) then
      if not eof then
        t.last, t.line_of[n] = t.line_of[n] - 1, nil
      end
      head = head or { first = csv.record(t, 1), quote_all = t.quote_all }
      if eof or lnum - offset <= t.last then
        t.buf, t.opts, t.tick, t.h = buf, opts, vim.b[buf].changedtick, opts.header and 1 or 0
        t.first, t.quote_all, t.offset = head.first, head.quote_all, offset
        t.r = M.record_at(t, lnum - offset)
        return t
      end
      offset, size = offset + t.last, M.CHUNK
    else
      size = size * 2 -- one record (or blank lines) fills the chunk
    end
  end
end

-- The last line of record r.
function M.last_line(t, r)
  return (t.line_of[r + 1] or t.last + 1) - 1
end

-- The record that contains line lnum (a line after the last record counts as
-- the last record).
function M.record_at(t, lnum)
  local r = 1
  while t.line_of[r + 1] and t.line_of[r + 1] <= lnum do
    r = r + 1
  end
  return r
end

-- The column under cursor { lnum, byte col (0-based) }. A delimiter belongs to
-- the field on its left.
function M.cursor_col(t, cursor)
  local first = t.line_of[M.record_at(t, cursor[1])]
  local prefix = vim.list_slice(t.lines, first, cursor[1])
  prefix[#prefix] = prefix[#prefix]:sub(1, cursor[2])
  -- the record's text up to the cursor has as many fields as the cursor's index
  local row = csv.parse(prefix, t.opts.delimiter).rows[1]
  return math.max(row and #row or 0, 1)
end

-- Where field k of record r starts: its line in t and its 0-based byte
-- column, or nil when the record has fewer fields.
function M.field_start(t, r, k)
  if k == 1 then
    return t.line_of[r], 0
  end
  local i, pos, n = csv.field_end(t, r, k - 1)
  if n < k - 1 or t.lines[i]:sub(pos, pos + #t.delim - 1) ~= t.delim then
    return nil
  end
  return i, pos - 1 + #t.delim
end

-- The index of column name: a header name (trimmed) or a number counting from 0.
function M.col_index(t, name)
  for i, h in ipairs(t.h == 1 and t.first or {}) do
    if types.trim(h) == name then
      return i
    end
  end
  return M.number_col(name, #t.first) or error(('csvkit: no column "%s"'):format(name), 0)
end

-- The column (1-based) word numbers among n columns: from 0, or from the end
-- when negative (-1 is the last); nil when word is no number or out of range.
function M.number_col(word, n)
  local i = tonumber(word:match("^%-?%d+$"))
  i = i and (i < 0 and n + i + 1 or i + 1)
  return i and i >= 1 and i <= n and i or nil
end

-- The 1-based column a move to index (from 0; negative from the end, -1 the
-- last) among n columns puts a column at: past the end is the last.
function M.target(index, n)
  local c = index < 0 and n + index + 1 or math.min(index + 1, n)
  return c >= 1 and c or error(("csvkit: no position %d among %d columns"):format(index, n), 0)
end

local KEEP = 3 -- csvkit edits that replace lines (sort, addcol) undo keeps

-- The seqs of buf's undo entries (a set), alternate branches included.
local function undo_seqs(buf)
  local seqs = {}
  local function walk(entries)
    for _, e in ipairs(entries) do
      seqs[e.seq] = true
      if e.alt then
        walk(e.alt)
      end
    end
  end
  walk(vim.api.nvim_buf_call(buf, vim.fn.undotree).entries)
  return seqs
end

-- Replaces lines [first, last] (1-based; last = first - 1 inserts) unless the
-- buffer changed since t was read. An edit that replaces lines keeps all of
-- them in the undo history (~85 MB per sort at 1M rows), so only the newest
-- KEEP of them stay undoable: for the next one, 'undolevels' is lowered just
-- enough that Neovim frees every entry older than the oldest one kept. An
-- insert (row add) keeps no old text and is not counted. A big rewrite is
-- followed by a memory trim. t is { buf, tick, opts } plus what read adds.
local function write(t, range, lines)
  local buf = t.buf
  M.check_modifiable(buf)
  if vim.b[buf].changedtick ~= t.tick then
    error("csvkit: the buffer changed while prompting; nothing written", 0)
  end
  if range[2] < range[1] then
    return vim.api.nvim_buf_set_lines(buf, range[1] - 1, range[2], false, lines)
  end
  local live = undo_seqs(buf)
  local kept = vim.tbl_filter(function(seq)
    return live[seq]
  end, vim.b[buf].csvkit_undo or {})
  local saved = vim.bo[buf].undolevels
  if #kept >= KEEP then
    local oldest, count = kept[#kept - KEEP + 2], 0
    for seq in pairs(live) do
      count = count + (seq >= oldest and 1 or 0)
    end
    -- -123456: no local value, the global one applies
    if count < (saved == -123456 and vim.go.undolevels or saved) then
      vim.bo[buf].undolevels = count
    end
  end
  local ok, err = pcall(vim.api.nvim_buf_set_lines, buf, range[1] - 1, range[2], false, lines)
  vim.bo[buf].undolevels = saved -- also when the write failed
  if not ok then
    error(err, 0)
  end
  memory.after_edit(t.opts, math.max(range[2] - range[1] + 1, #lines))
  kept[#kept + 1] = vim.api.nvim_buf_call(buf, vim.fn.undotree).seq_last
  vim.b[buf].csvkit_undo = vim.list_slice(kept, #kept - KEEP + 1)
end

M.write = write

-- Reorders the data rows by spec = { col, desc, type } (see sort.sort_rows).
-- Record lines move as they are, so quoting stays byte-identical.
function M.sort(t, spec)
  local perm = sort.sort_rows(csv.column(t, spec.col, t.h + 1), spec, t.opts)
  -- rows already in place are left out of the write: no time, no undo memory
  local lo, hi = 1, #perm
  while lo <= hi and perm[lo] == lo do
    lo = lo + 1
  end
  while hi > lo and perm[hi] == hi do
    hi = hi - 1
  end
  local out, n = {}, 0
  for p = lo, hi do
    for l = t.line_of[perm[p] + t.h], M.last_line(t, perm[p] + t.h) do
      n = n + 1
      out[n] = t.lines[l]
    end
  end
  if n > 0 then
    write(t, { t.line_of[lo + t.h], M.last_line(t, hi + t.h) }, out)
  end
end

-- Inserts an empty row (the first row's field count) above or below record
-- t.r of t (from read_at). Returns the new line.
function M.add_row(t, above)
  if above and t.offset == 0 and t.r == 1 and t.h == 1 then
    error("csvkit: can't add a row above the header", 0)
  end
  local at = t.offset + (above and t.line_of[t.r] or M.last_line(t, t.r) + 1)
  local empty = {}
  for i = 1, #t.first do
    empty[i] = ""
  end
  write(t, { at, at - 1 }, { csv.serialize_row(empty, t.opts.delimiter, t.quote_all) })
  return at
end

-- expr compiled against t's header, and the context to evaluate it on t's
-- rows; hide (a set of data rows, or nil) are the rows it does not see.
local function formula_on(t, expr, hide)
  local ast = formula.compile(expr, t.h == 1 and t.first, #t.first)
  local cols, shown = {}, nil
  for c in pairs(formula.columns(ast)) do
    cols[c] = csv.column(t, c, t.h + 1)
  end
  if hide then
    shown = {}
    for i = 1, t.n do
      if not hide[i] then
        shown[#shown + 1] = i
      end
    end
  end
  return ast, { cols = cols, n = t.n, opts = t.opts, shown = shown }
end

-- formula.matches of the filter expression expr on t's data rows but those in
-- hide (a set, or nil). Raises on a compile error.
function M.formula_matches(t, expr, hide)
  return formula.matches(formula_on(t, expr, hide))
end

-- The values of formula expr for every data row but those in hide (a set, or
-- nil; their value is nil), the lines of the rows that failed, and the first
-- failure's message. Raises on a compile error.
function M.formula_values(t, expr, hide)
  local values, failures, err = formula.eval_column(formula_on(t, expr, hide))
  for k, i in ipairs(failures) do
    failures[k] = t.line_of[i + t.h]
  end
  return values, failures, err
end

-- Deletes the data rows in rows (a set of data row numbers) with one write of
-- the lines from the first of them to the last. Returns how many went.
function M.delete_rows(t, rows)
  local first, last, n = math.huge, 0, 0
  for i in pairs(rows) do
    first, last, n = math.min(first, i + t.h), math.max(last, i + t.h), n + 1
  end
  if n == 0 then
    return 0
  end
  local out = {}
  for r = first, last do
    if not rows[r - t.h] then
      for l = t.line_of[r], M.last_line(t, r) do
        out[#out + 1] = t.lines[l]
      end
    end
  end
  write(t, { t.line_of[first], M.last_line(t, last) }, out)
  return n
end

-- Deletes columns cols (a list, ascending) from every record, the header too,
-- in one write. Only the fields and their delimiters go, so the other fields
-- keep their text; a record without some of them loses the ones it has.
function M.delete_columns(t, cols)
  if #cols >= #t.first then
    error("csvkit: can't delete every column", 0)
  end
  -- runs of neighbouring columns: each is one cut, and cuts never overlap
  local runs = {}
  for _, c in ipairs(cols) do
    local run = runs[#runs]
    if run and run[2] == c - 1 then
      run[2] = c
    else
      runs[#runs + 1] = { c, c }
    end
  end
  local lines, delim, dlen = t.lines, t.delim, #t.delim
  local out, n = {}, 0
  for r = 1, #t.line_of do
    local first, last = t.line_of[r], M.last_line(t, r)
    -- the record as one text; at[l] = where line l starts in it, minus 1
    local text, at = lines[first], { [first] = 0 }
    for l = first + 1, last do
      at[l] = #text + 1
      text = text .. "\n" .. lines[l]
    end
    for k = #runs, 1, -1 do -- right to left: the places found earlier stay right
      local a, b = runs[k][1], runs[k][2]
      local si, sb = M.field_start(t, r, a)
      if si then
        local ei, ep = csv.field_end(t, r, b) -- the delimiter after b, or the end
        local from, to = at[si] + sb + 1 - dlen, at[ei] + ep - 1 -- from the delimiter before a
        if a == 1 then -- from the start, to the delimiter after b
          from = 1
          to = lines[ei]:sub(ep, ep + dlen - 1) == delim and to + dlen or to
        end
        text = text:sub(1, from - 1) .. text:sub(to + 1)
      end
    end
    if first == last then
      n = n + 1
      out[n] = text
    else
      for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
        n = n + 1
        out[n] = l
      end
    end
  end
  write(t, { 1, t.last }, out)
end

-- Record r of t with field `from` moved to place `to`: only the fields between
-- them are touched, as text, so quoting stays. A record shorter than the
-- columns involved is padded with empty fields first.
local function moved_record(t, r, from, to)
  local lines, delim, dlen = t.lines, t.delim, #t.delim
  local first, last = t.line_of[r], M.last_line(t, r)
  -- the record as one text; at[l] = where line l starts in it, minus 1
  local text, at = lines[first], { [first] = 0 }
  for l = first + 1, last do
    at[l] = #text + 1
    text = text .. "\n" .. lines[l]
  end
  local lo, hi = math.min(from, to), math.max(from, to)
  local ei, ep, n = csv.field_end(t, r, hi)
  local stop = at[ei] + ep - 1 -- the last character of field hi, or of the record
  if n < hi then
    local pad = delim .. csv.serialize_field("", delim, t.quote_all)
    text = text:sub(1, stop) .. pad:rep(hi - n) .. text:sub(stop + 1)
    local padded = csv.index(vim.split(text, "\n", { plain = true }), delim)
    return moved_record(padded, 1, from, to)
  end
  local si, sb = M.field_start(t, r, lo)
  local a = at[si] + sb + 1 -- where field lo starts
  if from < to then -- the moved field goes after the ones between
    local fi, fp = csv.field_end(t, r, from)
    local cut = at[fi] + fp - 1
    return text:sub(1, a - 1) .. text:sub(cut + 1 + dlen, stop) .. delim .. text:sub(a, cut) .. text:sub(stop + 1)
  end
  local hi_i, hi_b = M.field_start(t, r, hi)
  local b = at[hi_i] + hi_b + 1 -- where field hi starts
  return text:sub(1, a - 1) .. text:sub(b, stop) .. delim .. text:sub(a, b - 1 - dlen) .. text:sub(stop + 1)
end

-- Moves column `from` to place `to` (1-based, in the final order) in every
-- record, the header too, in one write.
function M.move_column(t, from, to)
  local out, n = {}, 0
  for r = 1, #t.line_of do
    local text = moved_record(t, r, from, to)
    if text:find("\n", 1, true) then
      for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
        n = n + 1
        out[n] = l
      end
    else
      n = n + 1
      out[n] = text
    end
  end
  write(t, { 1, t.last }, out)
end

-- Sets field spec.col of every data record to spec.values[i], quoted in the
-- file's style, in one write. Only that field's text changes; a record
-- without it gets empty fields up to it, and one whose value is nil is kept.
function M.set_column(t, spec)
  local lines, delim, c = t.lines, t.delim, spec.col
  local pad = delim .. csv.serialize_field("", delim, t.quote_all)
  local out, n = {}, 0
  for r = 1, #t.line_of do
    local first, last = t.line_of[r], M.last_line(t, r)
    -- the record as one text; at[l] = where line l starts in it, minus 1
    local text, at = lines[first], { [first] = 0 }
    for l = first + 1, last do
      at[l] = #text + 1
      text = text .. "\n" .. lines[l]
    end
    if r > t.h and spec.values[r - t.h] then
      local value = csv.serialize_field(spec.values[r - t.h], delim, t.quote_all)
      local si, sb = M.field_start(t, r, c)
      local ei, ep, fields = csv.field_end(t, r, c) -- the field's end, or the record's
      local to = at[ei] + ep - 1
      local from = si and at[si] + sb + 1 or to + 1
      if not si then
        value = pad:rep(c - 1 - fields) .. delim .. value
      end
      text = text:sub(1, from - 1) .. value .. text:sub(to + 1)
    end
    if text:find("\n", 1, true) then
      for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
        n = n + 1
        out[n] = l
      end
    else
      n = n + 1
      out[n] = text
    end
  end
  write(t, { 1, t.last }, out)
end

-- Inserts a column after column spec.after (0: first): spec.name in the header (ignored
-- without one) and spec.values[i] (nil: empty) in data row i. The new field
-- goes into each record's text, so the rest of the record stays
-- byte-identical. It is quoted in the file's style, and a short record gets
-- empty fields up to it. Each line and value is dropped from t and spec once
-- used, so the GC can free the old text while the new one is built (t is spent
-- afterwards).
function M.add_column(t, spec)
  local delim, quote_all, lines = t.opts.delimiter, t.quote_all, t.lines
  local pad = delim .. csv.serialize_field("", delim, quote_all)
  -- no closure here: a LuaJIT trace keeps the closure it was recorded with,
  -- and with it every line in out
  local out, n = {}, 0
  for r = 1, #t.line_of do
    local stop, pos, fields = csv.field_end(t, r, spec.after)
    for l = t.line_of[r], stop - 1 do
      n = n + 1
      out[n] = lines[l]
    end
    local value = csv.serialize_field(r > t.h and (spec.values[r - t.h] or "") or spec.name, delim, quote_all)
    local line = lines[stop]
    lines[stop] = nil
    if r > t.h then
      spec.values[r - t.h] = nil
    end
    local field = spec.after == 0 and value .. delim or delim .. value
    line = line:sub(1, pos - 1) .. pad:rep(spec.after - fields) .. field .. line:sub(pos)
    if value:find("\n", 1, true) then
      for _, l in ipairs(vim.split(line, "\n", { plain = true })) do
        n = n + 1
        out[n] = l
      end
    else
      n = n + 1
      out[n] = line
    end
    for l = stop + 1, M.last_line(t, r) do
      n = n + 1
      out[n] = lines[l]
    end
  end
  write(t, { 1, t.last }, out)
end

-- Puts back buf's file as it was opened (backup.lua), as one undoable edit.
-- Only the lines changed since it was read are read (from both) and compared,
-- and only those between the first and the last that differ are written.
function M.restore(buf)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  M.check_modifiable(buf)
  local backup = require("csvkit.backup")
  local copy = backup.check(buf)
  if copy.head == math.huge then
    return -- no change since it was read
  end
  local head, tail = copy.head, copy.tail
  local new = backup.lines(buf, head, copy.lines - tail)
  local old = vim.api.nvim_buf_get_lines(buf, head, vim.api.nvim_buf_line_count(buf) - tail, false)
  local lo, a, b = 1, #old, #new
  while lo <= a and lo <= b and old[lo] == new[lo] do
    lo = lo + 1
  end
  while a >= lo and b >= lo and old[a] == new[b] do
    a, b = a - 1, b - 1
  end
  if lo <= a or lo <= b then
    local t = { buf = buf, tick = vim.b[buf].changedtick, opts = csvkit.get_opts(buf) }
    write(t, { head + lo, head + a }, vim.list_slice(new, lo, b))
  end
end

return M
