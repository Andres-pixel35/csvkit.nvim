-- :Csvkit subcommand dispatch and completion. Subcommands act on the current
-- buffer; {col} is a header name or a 1-based index, and defaults to the column
-- under the cursor.
local csv = require("csvkit.csv")
local csvkit = require("csvkit")
local edit = require("csvkit.edit")
local types = require("csvkit.types")

local M = {}

local SORT_WORDS = { asc = false, desc = true, num = "number", str = "string", date = "date" }
local MODES = { "value", "formula", "fill" }
-- the words each value-only subcommand accepts, mapped to the stored option
local VALUES = {
  decimal = { words = { ".", ",", "auto" }, map = {} },
  thousands = { words = { ",", ".", "space", "'", "none", "auto" }, map = { space = " ", none = false } },
}

-- Splits up to n words off the front of s ("\ " is a space inside a word).
-- Returns them and the rest of s as typed.
local function split(s, n)
  local words = {}
  s = s:gsub("^%s+", "")
  while s ~= "" and #words < n do
    local word, rest = s:match("^(.-[^\\])%s+(.*)$")
    words[#words + 1] = (word or s):gsub("\\ ", " ")
    s = rest or ""
  end
  return words, s
end

local RESTORE_MODES = { "buffer", "file" }

-- Wraps fn so a "csvkit: ..." error becomes an error message; any other error
-- is a bug and is raised as is, except LuaJIT running out of memory: the
-- write comes last, so the buffer is as it was.
local function guarded(fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then
      if type(err) == "string" and err:find("not enough memory", 1, true) then
        err = "csvkit: out of memory; the buffer is unchanged"
      end
      if type(err) ~= "string" or not err:find("^csvkit: ") then
        error(err, 0)
      end
      vim.notify(err, vim.log.levels.ERROR)
    end
  end
end

M.guarded = guarded

local function in_view()
  return vim.bo.filetype == "csvkit_view"
end

-- :Csvkit sort [{col}] [asc|desc] [num|str|date]
local function sort(args)
  local spec, name = {}, nil
  for _, w in ipairs((split(args, math.huge))) do
    local v = SORT_WORDS[w]
    if type(v) == "boolean" then
      spec.desc = v
    elseif v then
      spec.type = v
    elseif not name then
      name = w
    else
      error(('csvkit: unexpected "%s"'):format(w), 0)
    end
  end
  if in_view() then
    return require("csvkit.view").sort(0, spec, name)
  end
  edit.check_modifiable(0)
  local t = edit.read(0)
  spec.col = name and edit.col_index(t, name) or edit.cursor_col(t, vim.api.nvim_win_get_cursor(0))
  edit.sort(t, spec)
end

local ROW_USAGE = "csvkit: usage: row add [above|below] | row delete [where {expr}|hidden]"

-- Tells how many rows row delete deleted.
local function deleted(n, mode)
  if n > 0 then
    return vim.notify(("csvkit: deleted %d row%s"):format(n, n == 1 and "" or "s"), vim.log.levels.INFO)
  end
  local why = mode == "where" and "no row matches" or "no row is hidden"
  vim.notify(("csvkit: %s; nothing deleted"):format(why), vim.log.levels.INFO)
end

-- The data rows (a set) of the records lines from..to touch; the header and
-- the blank lines after the last record hold none.
local function rows_in(t, from, to)
  local rows = {}
  to = math.min(to, t.last)
  if from <= to then
    for r = edit.record_at(t, from), edit.record_at(t, to) do
      if r > t.h then
        rows[r - t.h] = true
      end
    end
  end
  return rows
end

-- :[range]Csvkit row delete [where {expr}|hidden]: the records on the lines of
-- range (default: the cursor's), the rows where expr is TRUE, or the rows the
-- filters hide. Staged in the view.
local function delete_rows(args, range)
  local w, expr = split(args, 1)
  local mode = w[1]
  if (mode and mode ~= "where" and mode ~= "hidden") or (mode and range)
    or (mode == "where") ~= (expr ~= "") then
    error(ROW_USAGE, 0)
  end
  if in_view() then
    return deleted(require("csvkit.view").delete_rows(0, { mode = mode, expr = expr, range = range }), mode)
  end
  edit.check_modifiable(0)
  local t = edit.read(0)
  local rows = {}
  if mode == "where" then
    local pass, err = edit.formula_matches(t, expr, require("csvkit.filter").hidden(t.buf, t))
    if err then
      error("csvkit: row delete: " .. err, 0)
    end
    for i = 1, t.n do
      rows[i] = pass[i] or nil
    end
  elseif mode == "hidden" then
    rows = require("csvkit.filter").hidden(t.buf, t) or error("csvkit: no rows are hidden: set a filter first", 0)
  else
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local from = range and range[1] or lnum
    rows = rows_in(t, from, range and range[2] or lnum)
    if next(rows) == nil then
      error(from == 1 and t.h == 1 and "csvkit: the header row can't be deleted" or "csvkit: no row there", 0)
    end
  end
  deleted(edit.delete_rows(t, rows), mode)
end

-- :Csvkit row add [above|below] | row delete ...
local function row(args, range)
  local w, rest = split(args, 1)
  if w[1] == "delete" then
    return delete_rows(rest, range)
  end
  w = split(args, math.huge)
  if range or w[1] ~= "add" or #w > 2 or (w[2] and w[2] ~= "above" and w[2] ~= "below") then
    error(range and w[1] == "add" and "csvkit: row add takes no range" or ROW_USAGE, 0)
  end
  if in_view() then
    return require("csvkit.view").add_row(0, w[2] == "above")
  end
  edit.check_modifiable(0)
  local lnum = edit.add_row(edit.read_at(0, vim.api.nvim_win_get_cursor(0)[1]), w[2] == "above")
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
end

local function warn_failures(failures, err)
  if failures and #failures > 0 then
    local rows = vim.list_slice(failures, 1, 5)
    if #failures > 5 then
      rows[6] = "…"
    end
    local cells = #failures == 1 and "cell" or "cells"
    local msg = ("csvkit: %d %s failed (rows %s): %s"):format(#failures, cells, table.concat(rows, ", "), err)
    vim.notify(msg, vim.log.levels.WARN)
  end
end

-- Asks for each data row's value of the new column, highlighting the row in
-- win, then writes once. <Esc> stops; the rows not reached stay empty.
local function fill(t, spec, win)
  local ns = vim.api.nvim_create_namespace("csvkit_fill")
  local values = {}
  local function finish()
    vim.api.nvim_buf_clear_namespace(t.buf, ns, 0, -1)
    for i = #values + 1, t.n do
      values[i] = ""
    end
    spec.values = values
    edit.add_column(t, spec)
  end
  local function ask(i)
    local r = i + t.h
    if r > #t.line_of then
      return finish()
    end
    local fields = {}
    for c, v in ipairs(csv.record(t, r)) do
      local name = t.h == 1 and t.first[c] or tostring(c - 1)
      fields[c] = name .. "=" .. v:gsub("\n", "⏎")
    end
    vim.api.nvim_buf_clear_namespace(t.buf, ns, 0, -1)
    local last = edit.last_line(t, r)
    vim.api.nvim_buf_set_extmark(t.buf, ns, t.line_of[r] - 1, 0, { end_row = last, hl_group = "Visual", hl_eol = true })
    vim.api.nvim_win_set_cursor(win, { t.line_of[r], 0 })
    vim.cmd.redraw()
    local prompt = ("Row %d [%s] > "):format(t.line_of[r], table.concat(fields, ", "))
    vim.ui.input({ prompt = prompt }, guarded(function(s)
      if s == nil then
        return finish()
      end
      values[i] = s
      ask(i + 1)
    end))
  end
  ask(1)
end

-- { before = bool, col = name } from the words "after {col}" or "before {col}";
-- nil for no words.
local function position(w)
  if #w == 0 then
    return nil
  elseif #w ~= 2 or (w[1] ~= "after" and w[1] ~= "before") then
    error("csvkit: the position is after {col} or before {col}", 0)
  end
  return { before = w[1] == "before", col = w[2] }
end

-- Fills in spec's missing name, position (when spec.ask_where), mode and text
-- by prompting, then calls done. <Esc> at any prompt cancels.
local function complete_spec(spec, done)
  local function ask(key, ask_fn)
    ask_fn(function(answer)
      if answer ~= nil then
        spec[key] = answer
        complete_spec(spec, done)
      end
    end)
  end
  if not spec.name then
    ask("name", function(cb)
      vim.ui.input({ prompt = "Column name: " }, cb)
    end)
  elseif spec.ask_where then
    spec.ask_where = nil
    local prompt = "Position (after|before {col}; Enter: after the cursor's column): "
    vim.ui.input({ prompt = prompt }, guarded(function(answer)
      if answer ~= nil then
        spec.where = position(split(answer, math.huge))
        complete_spec(spec, done)
      end
    end))
  elseif not spec.mode then
    ask("mode", function(cb)
      vim.ui.select(MODES, { prompt = "Fill with: " }, cb)
    end)
  elseif not spec.text and spec.mode ~= "fill" then
    ask("text", function(cb)
      vim.ui.input({ prompt = spec.mode == "value" and "Value: " or "Formula: " }, cb)
    end)
  else
    done(spec)
  end
end

-- The column spec.where names, or the cursor's: the new one goes after it.
-- col(name) is a column's index.
local function insert_after(spec, cursor_col, col)
  local where = spec.where
  return where and col(where.col) - (where.before and 1 or 0) or cursor_col
end

-- :Csvkit addcol [{name} [after|before {col}] [value {text} | formula {expr} | fill]]
-- The column goes after the one under the cursor unless placed; missing parts
-- are prompted (the position only when the name is). The buffer, window and
-- cursor are taken before prompting: a vim.ui replacement may answer while
-- its own float is the current window.
local function addcol(args)
  local w, rest = split(args, 1)
  local spec = { name = w[1], ask_where = not w[1] }
  w = split(rest, 1)
  if w[1] == "after" or w[1] == "before" then
    w, rest = split(rest, 2)
    spec.where = position(w)
  end
  w, rest = split(rest, 1)
  spec.mode, spec.text = w[1], rest ~= "" and rest or nil
  if spec.mode and not vim.list_contains(MODES, spec.mode) then
    error(('csvkit: unknown addcol mode "%s" (value|formula|fill)'):format(spec.mode), 0)
  end
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  if in_view() then
    local view = require("csvkit.view")
    local after = view.cursor_col(buf)
    return complete_spec(spec, guarded(function()
      spec.after = insert_after(spec, after, function(name)
        return view.column(buf, name)
      end)
      warn_failures(view.addcol(buf, spec, win))
    end))
  end
  edit.check_modifiable(buf)
  local cursor = vim.api.nvim_win_get_cursor(win)
  complete_spec(spec, guarded(function()
    local t = edit.read(buf)
    spec.after = insert_after(spec, edit.cursor_col(t, cursor), function(name)
      return edit.col_index(t, name)
    end)
    if spec.mode == "fill" then
      return fill(t, spec, win)
    elseif spec.mode == "value" then
      spec.values = {}
      for i = 1, t.n do
        spec.values[i] = spec.text
      end
      return edit.add_column(t, spec)
    end
    local values, failures, err = edit.formula_values(t, spec.text, require("csvkit.filter").hidden(t.buf, t))
    spec.values = values
    edit.add_column(t, spec)
    warn_failures(failures, err)
  end))
end

-- :Csvkit setcol {col} formula {expr}: the cells of the rows the filters show
-- become the formula's values (a failing row's is empty); staged in the view.
-- PREV reads them in the view's sort.
local function setcol(args)
  local w, rest = split(args, 2)
  if not w[1] or w[2] ~= "formula" or rest == "" then
    error("csvkit: usage: setcol {col} formula {expr}", 0)
  end
  if in_view() then
    local view = require("csvkit.view")
    return warn_failures(view.setcol(0, { col = view.column(0, w[1]), text = rest }))
  end
  edit.check_modifiable(0)
  local t = edit.read(0)
  local col = edit.col_index(t, w[1])
  local values, failures, err = edit.formula_values(t, rest, require("csvkit.filter").hidden(t.buf, t))
  edit.set_column(t, { col = col, values = values })
  warn_failures(failures, err)
end

-- :Csvkit decimal {...} / :Csvkit thousands {...}: remembered for the file.
local function remember_opt(key)
  return function(args)
    local w, def = split(args, math.huge), VALUES[key]
    if #w ~= 1 or not vim.list_contains(def.words, w[1]) then
      error(("csvkit: usage: %s {%s}"):format(key, table.concat(def.words, "|")), 0)
    end
    local v = def.map[w[1]]
    if v == nil then
      v = w[1]
    end
    csvkit.remember(vim.api.nvim_get_current_buf(), { [key] = v })
  end
end

-- :Csvkit restore [buffer|file]: the mode defaults to the restore.mode option.
local function restore(args)
  local w = split(args, math.huge)
  local mode = w[1] or csvkit.get_opts(0).restore.mode
  if #w > 1 or (w[1] and not vim.list_contains(RESTORE_MODES, mode)) then
    error("csvkit: usage: restore [buffer|file]", 0)
  elseif not vim.list_contains(RESTORE_MODES, mode) then
    error(('csvkit: restore.mode must be "buffer" or "file", not "%s"'):format(tostring(mode)), 0)
  elseif mode == "file" then
    require("csvkit.backup").restore_file(vim.api.nvim_get_current_buf())
  else
    edit.restore(0)
  end
end

-- :Csvkit align [on|off]: no word toggles.
local function align(args)
  local w = split(args, math.huge)
  if #w > 1 or (w[1] and w[1] ~= "on" and w[1] ~= "off") then
    error("csvkit: usage: align [on|off]", 0)
  end
  local overlay, buf = require("csvkit.overlay"), vim.api.nvim_get_current_buf()
  if (w[1] or (overlay.states[buf] and "off" or "on")) == "on" then
    overlay.enable(buf)
  else
    overlay.disable(buf)
  end
end

-- :Csvkit filter [{col}|{expr}|clear]: the picker for a column, a formula that
-- is TRUE on the rows to show, or remove every filter. One word naming a
-- column is that column; anything else is an expression.
local function filter(args)
  local w, expr = split(args, math.huge), vim.trim(args)
  if in_view() then
    local view = require("csvkit.view")
    if expr == "clear" then
      return view.clear_filters(0)
    elseif #w == 0 or (#w == 1 and pcall(view.column, 0, w[1])) then
      return view.filter(0, w[1])
    end
    return view.where(0, expr)
  end
  local f = require("csvkit.filter")
  if expr == "clear" then
    return f.clear(vim.api.nvim_get_current_buf())
  end
  local t = edit.read(0)
  if #w == 0 then
    return f.pick(t, edit.cursor_col(t, vim.api.nvim_win_get_cursor(0)))
  end
  local ok, col = pcall(edit.col_index, t, w[1])
  if #w == 1 and ok then
    return f.pick(t, col)
  end
  f.where(t.buf, expr, t)
end

-- :Csvkit goto {col}: the cursor goes to column col on its row, and the window
-- scrolls so the column, with the separator before it, starts at its left edge.
local function goto_col(args)
  local w = split(args, math.huge)
  if #w ~= 1 then
    error("csvkit: usage: goto {col}", 0)
  elseif in_view() then
    return require("csvkit.view").goto_col(0, w[1])
  end
  local t = edit.read_at(0, vim.api.nvim_win_get_cursor(0)[1])
  local col = edit.col_index(t, w[1])
  local i, byte = edit.field_start(t, t.r, col)
  if not i then
    error(('csvkit: this row has no column "%s"'):format(w[1]), 0)
  end
  vim.api.nvim_win_set_cursor(0, { t.offset + i, byte })
  -- aligned, the separator is "│ " (and Neovim keeps that space in view)
  local before = col == 1 and 0 or require("csvkit.overlay").states[t.buf] and 2 or 1
  vim.fn.winrestview({ leftcol = vim.fn.virtcol(".") - 1 - before })
end

-- The columns words name: header names, numbers from 0 (negative from the
-- end) and ranges a-b of numbers (2--2: from 2 to the second to last); each
-- once, ascending. resolve(word) is a word's column or raises.
local function columns(words, resolve)
  local set = {}
  for _, w in ipairs(words) do
    local ok, c = pcall(resolve, w)
    local a, b = w:match("^(%-?%d+)%-(%-?%d+)$")
    if ok then -- a name wins: a column may be called "1-2"
      set[c] = true
    elseif a then
      a, b = resolve(a), resolve(b)
      for c = math.min(a, b), math.max(a, b) do
        set[c] = true
      end
    else
      error(c, 0)
    end
  end
  local out = vim.tbl_keys(set)
  table.sort(out)
  return out
end

-- :Csvkit delcol [{col} ...]: delete columns (default: the cursor's), in one
-- edit; staged in the view.
local function delcol(args)
  local w = split(args, math.huge)
  if in_view() then
    local view = require("csvkit.view")
    return view.delcol(0, #w > 0 and columns(w, function(name)
      return view.column(0, name)
    end) or nil)
  end
  edit.check_modifiable(0)
  local t = edit.read(0)
  edit.delete_columns(t, #w > 0 and columns(w, function(name)
    return edit.col_index(t, name)
  end) or { edit.cursor_col(t, vim.api.nvim_win_get_cursor(0)) })
end

-- :Csvkit hide [{col} ...|clear]: hide columns of the view (default: the
-- cursor's), as delcol takes them, or show them all again.
local function hide(args)
  local w = split(args, math.huge)
  if not in_view() then
    error("csvkit: hide works in :Csvkit view and the browser preview", 0)
  end
  local view = require("csvkit.view")
  if w[1] == "clear" and #w == 1 then
    return view.show_hidden(0)
  end
  view.hide(0, #w > 0 and columns(w, function(name)
    return view.column(0, name)
  end) or nil)
end

-- The figures and n of :Csvkit stats from words (the column taken off):
-- { n, only = the set of figures asked for, nil for all }.
local function stats_spec(w)
  local s, spec, given = require("csvkit.stats"), { n = 5 }, false
  for _, word in ipairs(w) do
    local n = tonumber(word:match("^%d+$"))
    if vim.list_contains(s.FIGURES, word) then
      spec.only = spec.only or {}
      spec.only[word] = true
    elseif n and n > 0 and not given then
      spec.n, given = n, true
    else
      error("csvkit: usage: stats [{col}] [{figure} ...] [n]; figures: " .. table.concat(s.FIGURES, ", "), 0)
    end
  end
  if given and spec.only and not (spec.only.largest or spec.only.smallest) then
    error("csvkit: stats: n goes with largest or smallest", 0)
  end
  return spec
end

-- :[range]Csvkit stats [{col}] [{figure} ...] [n]: the figures of a column
-- (default: the cursor's; a first word naming a column is one, else it may be
-- a figure) over the rows shown (only those on the range's lines, if given),
-- all of them or those asked for, with n (default 5) largest and smallest, in
-- a float.
local function stats(args, range)
  local w = split(args, math.huge)
  local view = in_view() and require("csvkit.view")
  local t = not view and edit.read(0)
  local first = w[1] and (pcall(function()
    return view and view.column(0, w[1]) or edit.col_index(t, w[1])
  end) or not vim.list_contains(require("csvkit.stats").FIGURES, w[1]))
  local col = first and table.remove(w, 1) or nil
  local spec = stats_spec(w)
  local cells, name, opts
  if view then
    cells, name, opts = view.shown_cells(0, col, range)
  else
    local c = col and edit.col_index(t, col) or edit.cursor_col(t, vim.api.nvim_win_get_cursor(0))
    local hide = require("csvkit.filter").hidden(t.buf, t) or {}
    local only = range and rows_in(t, range[1], range[2])
    cells, opts = {}, t.opts
    for i, cell in ipairs(csv.column(t, c, t.h + 1)) do
      if not hide[i] and (not only or only[i]) then
        cells[#cells + 1] = cell
      end
    end
    name = t.h == 1 and vim.trim(t.first[c] or "") ~= "" and vim.trim(t.first[c]) or tostring(c - 1)
  end
  if range then
    name = ("%s (lines %d-%d)"):format(name, range[1], range[2])
  end
  local s = require("csvkit.stats")
  s.open((" Stats: %s "):format(name), s.entries(cells, opts, spec))
end

-- Record 1 of the current buffer (nil when it is empty) and whether it is the
-- header. Only the first 100 lines are read: a wide file's lines are long.
local function first_record()
  local opts = csvkit.get_opts(0)
  local t = csv.index(vim.api.nvim_buf_get_lines(0, 0, 100, false), opts.delimiter)
  return t.line_of[1] and csv.record(t, 1), opts.header
end

-- The type of every column (types.infer_column): in the view, over the rows
-- shown; else over every data row, with the columns read in one pass (the
-- file's cells are in memory while it runs, so only dtype pays for it).
local function column_types(ncols)
  local out, view = {}, in_view() and require("csvkit.view")
  local cols = not view and csv.columns(edit.read(0), csvkit.get_opts(0).header and 2 or 1)
  for c = 1, ncols do
    local cells, _, opts
    if view then
      cells, _, opts = view.shown_cells(0, c - 1)
    else
      cells, opts = cols[c] or {}, csvkit.get_opts(0)
    end
    out[c] = types.infer_column(cells, opts)
  end
  return out
end

-- :Csvkit columns [dtype]: every column's number (from 0) and name in a float,
-- staged columns included in the view; with dtype, its type after the name;
-- <CR> copies a name.
local function list_columns(args)
  local w = split(args, 2)
  if #w > 1 or (w[1] and w[1] ~= "dtype") then
    error("csvkit: usage: columns [dtype]", 0)
  end
  local names
  if in_view() then
    names = require("csvkit.view").names(0)
  else
    local row, header = first_record()
    if not row then
      error("csvkit: the buffer has no rows", 0)
    end
    names = header and row or vim.tbl_map(function()
      return ""
    end, row)
  end
  local kinds = w[1] and column_types(#names)
  local entries, width = {}, #tostring(#names - 1)
  for c, name in ipairs(names) do
    name = vim.trim(name):gsub("\n", "⏎")
    local index = tostring(c - 1)
    local text = name == "" and index or ("%-" .. width .. "s  %s"):format(index, name)
    entries[c] = { kinds and ("%s  [%s]"):format(text, kinds[c]) or text, name ~= "" and name or index }
  end
  require("csvkit.stats").open((" Columns (%d) "):format(#names), entries, width + 2)
end

-- :Csvkit view: the table of the buffer in a read-only buffer.
local function view(args)
  if split(args, math.huge)[1] then
    error("csvkit: usage: view", 0)
  end
  require("csvkit.view").open(0)
end

-- :Csvkit apply [sort] / :Csvkit discard: write the view's staged edits to the
-- source, or drop them.
local function apply(args)
  local w = split(args, math.huge)
  if #w > 1 then
    error("csvkit: usage: apply [sort]", 0)
  end
  require("csvkit.view").apply(0, w[1])
end

local function discard(args)
  if split(args, 1)[1] then
    error("csvkit: usage: discard", 0)
  end
  require("csvkit.view").discard(0)
end

-- :Csvkit preview [stop]: the page in the browser, or stop the server.
local function preview(args)
  local w = split(args, math.huge)
  if #w > 1 or (w[1] and w[1] ~= "stop") then
    error("csvkit: usage: preview [stop]", 0)
  end
  local p = require("csvkit.preview")
  if w[1] then
    local running = require("csvkit.server").base()
    p.stop()
    vim.notify(running and "csvkit: preview stopped" or "csvkit: no preview is running")
  else
    p.start(0)
  end
end

local SUBS = {
  addcol = addcol,
  delcol = delcol,
  apply = apply,
  columns = list_columns,
  discard = discard,
  align = align,
  decimal = remember_opt("decimal"),
  filter = filter,
  ["goto"] = goto_col,
  hide = hide,
  preview = preview,
  restore = restore,
  row = row,
  setcol = setcol,
  sort = sort,
  stats = stats,
  thousands = remember_opt("thousands"),
  view = view,
}

-- Runs the :Csvkit command line args; range = { line1, line2 } when one was
-- given (only row and stats take one).
M.run = guarded(function(args, range)
  local w, rest = split(args, 1)
  local sub = SUBS[w[1]]
  if not sub then
    error(('csvkit: unknown subcommand "%s"'):format(w[1] or ""), 0)
  elseif range and sub ~= row and sub ~= stats then
    error(("csvkit: %s takes no range"):format(w[1]), 0)
  end
  sub(rest, range)
end)

-- The current buffer's header names, spaces escaped for the command line.
local function header_names()
  local row, header = first_record()
  return vim.tbl_map(function(name)
    return (vim.trim(name):gsub(" ", "\\ "))
  end, header and row or {})
end

-- Candidates for the word after words (the words already typed).
local function candidates(words)
  local sub, n = words[1], #words
  if n == 0 then
    local subs = vim.tbl_keys(SUBS)
    table.sort(subs)
    return subs
  elseif sub == "sort" then
    return vim.list_extend(header_names(), { "asc", "desc", "num", "str", "date" })
  elseif sub == "goto" then
    return n == 1 and header_names() or {}
  elseif sub == "stats" then
    local figures = require("csvkit.stats").FIGURES
    return n == 1 and vim.list_extend(header_names(), figures) or vim.list_slice(figures)
  elseif sub == "delcol" then
    return header_names()
  elseif sub == "hide" then
    return n == 1 and vim.list_extend(header_names(), { "clear" }) or header_names()
  elseif sub == "filter" then
    return n == 1 and vim.list_extend(header_names(), { "clear" }) or header_names()
  elseif sub == "row" then
    if n == 2 then
      return words[2] == "add" and { "above", "below" } or words[2] == "delete" and { "where", "hidden" } or {}
    end
    return n == 1 and { "add", "delete" } or words[3] == "where" and header_names() or {}
  elseif sub == "columns" then
    return n == 1 and { "dtype" } or {}
  elseif sub == "restore" then
    return n == 1 and RESTORE_MODES or {}
  elseif sub == "apply" then
    return n == 1 and { "sort" } or {}
  elseif sub == "preview" then
    return n == 1 and { "stop" } or {}
  elseif sub == "align" then
    return n == 1 and { "on", "off" } or {}
  elseif sub == "addcol" then
    local placed = words[3] == "after" or words[3] == "before"
    local mode = placed and 5 or 3 -- the word after the position
    if n == 2 then
      return vim.list_extend({ "after", "before" }, MODES)
    elseif placed and n == 3 then
      return header_names()
    end
    return n == mode - 1 and MODES or words[mode] == "formula" and header_names() or {}
  elseif sub == "setcol" then
    return n == 2 and { "formula" } or header_names()
  end
  return n == 1 and VALUES[sub] and VALUES[sub].words or {}
end

-- complete= function for :Csvkit.
function M.complete(arglead, cmdline, pos)
  -- drop modifiers (:silent!, :vert) and the command name, which is the first
  -- word with a capital: a user command's name starts with one, they never do
  local before = cmdline:sub(1, pos):gsub("^[^%u]*%u%S*", "", 1)
  local words = split(before:sub(1, #before - #arglead), math.huge)
  return vim.tbl_filter(function(c)
    return vim.startswith(c, arglead)
  end, candidates(words))
end

return M
