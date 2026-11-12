-- :Csvkit view: the buffer as a table in a scratch buffer shown in the
-- source's window, drawn with box characters. Everything done in it is staged:
-- sort, filters, new columns, new rows and edited cells show at once, and the
-- source is only written by :Csvkit apply (one undo step). Filters are never
-- applied: they only hide. Until then the view works on its own copy of the
-- rows (`recs`). Hidden (<CR> to the source, :b), the view stays, with its
-- staged edits, until :bdelete or :bwipeout; :Csvkit view shows it again.
local csv = require("csvkit.csv")
local csvkit = require("csvkit")
local edit = require("csvkit.edit")
local formula = require("csvkit.formula")
local sort = require("csvkit.sort")
local types = require("csvkit.types")

local M = {}

M.DEBOUNCE = 150 -- ms after the last change of the source before the view is drawn again

M.states = {} -- view buf -> state, see open

local api, rep = vim.api, string.rep
local group = api.nvim_create_augroup("csvkit_view", { clear = true })
local ns = api.nvim_create_namespace("csvkit_view")
local WINBAR = "%{%v:lua.require'csvkit.view'.winbar()%}"
-- lines: 1 what is active, 2 top border, 3 header, 4 separator, 5.. rows
local HEADER_LINE, FIRST_ROW = 3, 5

-- The text of one cell, newlines as ⏎, cut to max display columns with a …,
-- and its display width.
local function cell_text(s, max)
  if not s:find("[\n\t\128-\255]") then -- plain ASCII: the usual cell
    local n = #s
    if n > max then
      return s:sub(1, max - 1) .. "…", max
    end
    return s, n
  end
  s = (s:gsub("\n", "⏎"):gsub("\t", " "))
  local w = api.nvim_strwidth(s)
  if w <= max then
    return s, w
  end
  local n = vim.fn.strchars(s)
  while n > 0 and api.nvim_strwidth(vim.fn.strcharpart(s, 0, n)) > max - 1 do
    n = n - 1
  end
  s = vim.fn.strcharpart(s, 0, n) .. "…"
  return s, api.nvim_strwidth(s)
end

-- The data rows are numbered 1..count in the order of the source. Until
-- something is staged they are read from the source (state.t); after, from
-- state.recs and state.staged = { [column] = the staged column's value of
-- each row }. A row of recs nothing was done to is just its row number in the
-- source (no table per row); a new row, or one with an edited cell, is
-- { src = row of the source or nil for a new row, f = its own copy of every
-- field (staged columns included), edited = true }. The other rows are the
-- source's fields with the staged values put in.
local function count(state)
  return state.recs and #state.recs or state.t.n
end

-- Pads list with "" up to n items.
local function pad_to(list, n)
  for k = #list + 1, n do
    list[k] = ""
  end
end

-- The fields of data row i (a new list unless the row has its own).
-- The source row of rec, a row of state.recs (nil for a new row).
local function src_of(rec)
  if type(rec) == "number" then
    return rec
  end
  return rec.src
end

local function fields(state, i)
  local rec = state.recs and state.recs[i]
  if type(rec) == "table" then
    return rec.f
  end
  local f = csv.record(state.t, (rec or i) + state.t.h)
  for _, s in ipairs(state.removed) do -- descending: each index still points at its field
    if s <= #f then
      table.remove(f, s)
    end
  end
  for _, c in ipairs(state.added) do -- ascending: each goes where it was put
    pad_to(f, c - 1)
    table.insert(f, c, state.staged[c][i])
  end
  return f
end

-- The fields of data row i, as its own copy from now on.
local function own(state, i)
  local rec = state.recs[i]
  if type(rec) == "number" then
    rec = { src = rec, f = fields(state, i), edited = true }
    state.recs[i] = rec
  end
  return rec.f
end

-- The source's column shown as column c of the view, or nil for a staged one.
local function source_of(state, c)
  if vim.list_contains(state.added, c) then
    return nil
  end
  local j, s = c, 0
  for _, a in ipairs(state.added) do
    j = j - (a < c and 1 or 0)
  end
  while j > 0 do -- the j-th column of the source that is not deleted
    s = s + 1
    j = j - (vim.list_contains(state.removed, s) and 0 or 1)
  end
  return s
end

-- Column c of the source's data rows, c a column of the view (not a staged
-- one). The columns of the sort and the filters are kept (state.keep) until
-- the source is read again or a column is staged, so a new sort, filter or
-- edit does not read them again.
local function source_column(state, c)
  local col = state.keep[c]
  if not col then
    col = csv.column(state.t, source_of(state, c), state.t.h + 1)
  end
  if (state.sort and state.sort.col == c) or state.cols[c] then
    state.keep[c] = col
  end
  return col
end

-- Column c of the data rows, as a list.
local function cells(state, c)
  local recs, staged = state.recs, state.staged[c]
  local col = not staged and source_column(state, c)
  if not recs then
    return col
  end
  local out = {}
  for i, rec in ipairs(recs) do
    if type(rec) == "table" then
      out[i] = rec.f[c] or ""
    else
      out[i] = staged and staged[i] or col[rec]
    end
  end
  return out
end

-- expr compiled against the view's header, and the context to evaluate it on
-- the rows shown, in their order (staged cells included). Raises on a compile
-- error.
local function formula_on(state, expr)
  local ast = formula.compile(expr, state.t.h == 1 and state.hdr, state.ncols)
  local cols = {}
  for c in pairs(formula.columns(ast)) do
    cols[c] = cells(state, c)
  end
  return ast, { cols = cols, n = count(state), opts = state.t.opts, shown = state.shown }
end

local function header_of(t)
  return t.h == 1 and vim.list_slice(t.first) or {}
end

local function pending(state)
  local p = state.pending
  return p.cols + p.cells + p.rows + p.names + p.dels + p.gone > 0
end

-- Starts working on a list of the rows, so rows can be added and changed.
local function materialize(state)
  if not state.recs then
    local recs = {}
    for i = 1, state.t.n do
      recs[i] = i
    end
    state.recs = recs
  end
end

-- Goes back to the source as it is: no staged edits (the sort and filters stay).
local function reset(state)
  state.recs, state.pending, state.stale = nil, { cols = 0, cells = 0, rows = 0, names = 0, dels = 0, gone = 0 }, nil
  state.added = {} -- the columns staged, as sorted final column numbers
  state.removed = {} -- the source's columns deleted, in descending order
  state.staged = {}
  state.hdr = header_of(state.t)
  state.ordered, state.keep = nil, {}
end

-- The data rows to show, as numbers in source order: sorted by the view's sort,
-- without the rows some column's filter or the expression does not allow (a
-- new row is always shown). Also returns why no row could be evaluated with
-- the expression, if so. An expression that no longer compiles is removed.
-- skip: a column whose filter is ignored (and state.keep left alone).
local function order(state, skip)
  local perm, recs = {}, state.recs
  for c in pairs(skip and {} or state.keep) do -- a column no longer sorted or filtered
    if not ((state.sort and state.sort.col == c) or state.cols[c]) then
      state.keep[c] = nil
    end
  end
  if state.sort then
    perm = sort.sort_rows(cells(state, state.sort.col), state.sort, state.t.opts)
  else
    for i = 1, count(state) do
      perm[i] = i
    end
  end
  local hide, err = {}, nil
  for c, allowed in pairs(state.cols) do
    if c ~= skip then
      for i, cell in ipairs(cells(state, c)) do
        if not allowed[types.trim(cell)] then
          hide[i] = true
        end
      end
    end
  end
  if state.expr then
    local ok, ast, ctx = pcall(formula_on, state, state.expr)
    if ok then
      ctx.shown = nil -- the filter decides what is shown, so it reads every row
      local pass
      pass, err = formula.matches(ast, ctx)
      for i = 1, ctx.n do
        if not pass[i] then
          hide[i] = true
        end
      end
    else
      require("csvkit.filter").dropped(state.expr, ast)
      state.expr = nil
    end
  end
  for i in pairs(hide) do
    if recs and not src_of(recs[i]) then
      hide[i] = nil
    end
  end
  if next(hide) == nil then
    return perm, err
  end
  return vim.tbl_filter(function(i)
    return not hide[i]
  end, perm), err
end

local function name_of(state, c)
  local name = state.t.h == 1 and types.trim(state.hdr[c] or "") or ""
  return name ~= "" and name or tostring(c - 1)
end

local function plural(n, word)
  return ("%d %s%s"):format(n, word, n == 1 and "" or "s")
end

-- The parts of the first line: rows shown, the filters, the sort and the
-- staged edits. full lists every value of each filter, one filter a part.
local function info_parts(state, shown, full)
  local parts = { ("%d of %s"):format(shown, plural(count(state), "row")) }
  local cols = vim.tbl_keys(state.cols)
  table.sort(cols)
  local filters = {}
  for _, c in ipairs(cols) do
    local values = vim.tbl_keys(state.cols[c])
    table.sort(values)
    for k, v in ipairs(values) do
      values[k] = v == "" and "(empty)" or (v:gsub("\n", "⏎"))
    end
    local cut = full and #values or math.min(#values, 3)
    local more = #values > cut and (" +%d"):format(#values - cut) or ""
    filters[#filters + 1] = name_of(state, c) .. ": " .. table.concat(values, ", ", 1, cut) .. more
  end
  filters[#filters + 1] = state.expr
  if full then
    for _, f in ipairs(filters) do
      parts[#parts + 1] = "filter " .. f
    end
  elseif #filters > 0 then
    parts[#parts + 1] = "filter " .. table.concat(filters, "; ")
  end
  if state.sort then
    parts[#parts + 1] = ("sort %s %s"):format(name_of(state, state.sort.col), state.sort.desc and "↓" or "↑")
  end
  local hidden = vim.tbl_keys(state.hidden)
  if #hidden > 0 then
    table.sort(hidden)
    for k, c in ipairs(hidden) do
      hidden[k] = name_of(state, c)
    end
    parts[#parts + 1] = "hidden " .. table.concat(hidden, ", ")
  end
  local p, staged = state.pending, {}
  for _, item in ipairs({
    { "cols", "new column" },
    { "dels", "deleted column" },
    { "rows", "new row" },
    { "gone", "deleted row" },
    { "cells", "edited cell" },
    { "names", "new header" },
  }) do
    if p[item[1]] > 0 then
      staged[#staged + 1] = plural(p[item[1]], item[2])
    end
  end
  if #staged > 0 then
    parts[#parts + 1] = "staged: " .. table.concat(staged, ", ") .. " (:Csvkit apply | discard)"
  end
  if state.stale then
    parts[#parts + 1] = "the source changed: :Csvkit discard to read it again"
  end
  return parts
end

local function info(state, shown)
  return " " .. table.concat(info_parts(state, shown), " │ ")
end

-- Where the text of the table comes from: the columns are measured on the
-- header and the first SAMPLE shown rows (all of them up to M.EAGER rows); a
-- row is drawn when it comes near a window (up to M.EAGER rows, all at once).
-- A cell wider than its column widens the column and draws the rows again.
M.EAGER = 5000
local SAMPLE = 2000

-- One parts list is reused for every row, and spaces come from a cache.
local parts, pad = { "│ " }, setmetatable({}, {
  __index = function(spaces, n)
    spaces[n] = rep(" ", n)
    return spaces[n]
  end,
})

-- The line of a row from its cell texts and widths.
local function row_line(state, texts, widths)
  local colw, vis, k = state.colw, state.vis, 1
  for p, c in ipairs(vis) do
    parts[k + 1], parts[k + 2], parts[k + 3] = texts[c], pad[colw[c] - widths[c]], p < #vis and " │ " or " │"
    k = k + 3
  end
  return table.concat(parts, "", 1, k)
end

-- The texts and widths of a list of fields (the shown columns only), widening
-- state.colw where a cell is wider; returns them and whether a column grew.
local function measure_row(state, row)
  local colw, texts, widths, grew = state.colw, {}, {}, false
  for _, c in ipairs(state.vis) do
    local text, w = cell_text(row[c] or "", state.max)
    texts[c], widths[c] = text, w
    if w > colw[c] then
      colw[c], grew = w, true
    end
  end
  return texts, widths, grew
end

-- Sets the columns' widths, the table's frame and the header row from the
-- header and the sample. Returns the top border, the header row, the
-- separator and the bottom border.
local function frame(state, measure)
  local t = state.t
  if measure then
    local ncols = #t.first
    for _, s in ipairs(state.removed) do
      ncols = ncols - (s <= #t.first and 1 or 0)
    end
    ncols = math.max(ncols, #state.hdr)
    local last = state.lazy and math.min(#state.shown, SAMPLE) or #state.shown
    for p = 1, last do
      ncols = math.max(ncols, #fields(state, state.shown[p]))
    end
    state.ncols, state.colw, state.vis = ncols, {}, {}
    for c = 1, ncols do
      state.colw[c] = 1
      if not state.hidden[c] then
        state.vis[#state.vis + 1] = c
      end
    end
    for p = 1, last do
      measure_row(state, fields(state, state.shown[p]))
    end
    state.head = {} -- each name after its index, which :Csvkit goto takes
    for c = 1, ncols do
      local name = types.trim(state.hdr[c] or "")
      state.head[c] = tostring(c - 1) .. (name ~= "" and " " .. name or "")
    end
  end
  local texts, widths = measure_row(state, state.head)
  local starts, bars, prev = {}, {}, nil -- starts[c]: the display column of c's left bar
  for _, c in ipairs(state.vis) do
    starts[c] = prev and starts[prev] + state.colw[prev] + 3 or 1
    bars[#bars + 1] = rep("─", state.colw[c] + 2)
    prev = c
  end
  local function border(left, mid, right)
    return left .. table.concat(bars, mid) .. right
  end
  state.starts, state.header = starts, row_line(state, texts, widths)
  return border("┌", "┬", "┐"), state.header, border("├", "┼", "┤"), border("└", "┴", "┘")
end

-- Replaces buffer lines [first, last) (0-based) of the view.
local function put(vbuf, first, last, lines)
  vim.bo[vbuf].modifiable = true
  api.nvim_buf_set_lines(vbuf, first, last, false, lines)
  vim.bo[vbuf].modifiable = false
end

-- Draws the shown rows from..to that are not drawn yet.
local function fill(state, from, to)
  local first, last = from, to
  while first <= last and state.filled[first] do
    first = first + 1
  end
  while last >= first and state.filled[last] do
    last = last - 1
  end
  if first > last then
    return
  end
  local lines, grew = {}, false
  for p = first, last do
    local texts, widths, widened = measure_row(state, fields(state, state.shown[p]))
    grew = grew or widened
    lines[#lines + 1] = row_line(state, texts, widths)
  end
  if grew then -- the rows drawn so far are too narrow: all again
    local top, head, sep, bottom = frame(state)
    put(state.vbuf, 1, 4, { top, head, sep })
    put(state.vbuf, FIRST_ROW - 1 + #state.shown, -1, { bottom })
    state.filled = {}
    return fill(state, from, to)
  end
  put(state.vbuf, FIRST_ROW - 2 + first, FIRST_ROW - 1 + last, lines)
  for p = first, last do
    state.filled[p] = true
  end
end

-- Draws the rows near each window that shows the view.
local function fill_visible(state)
  if not state.lazy then
    return fill(state, 1, #state.shown)
  end
  for _, win in ipairs(vim.fn.win_findbuf(state.vbuf)) do
    local w = vim.fn.getwininfo(win)[1]
    local from = math.max(1, w.topline - w.height - FIRST_ROW + 1)
    fill(state, from, math.min(#state.shown, w.botline + w.height - FIRST_ROW + 1))
  end
end

-- The data row on line lnum of the view, and its line in the source (nil for
-- a new row).
local function row_at(state, lnum)
  return lnum >= FIRST_ROW and state.shown[lnum - FIRST_ROW + 1] or nil
end

local function source_line(state, i)
  local src = state.recs and src_of(state.recs[i]) or not state.recs and i
  if src then
    return state.t.line_of[src + state.t.h]
  end
end

-- Draws the view again, keeping the cursor line when it can. The rows shown
-- are only worked out again when state.ordered was cleared: by a new sort or
-- filter, a new row, or a changed cell in a sorted or filtered column.
local function render(state)
  if not state.ordered then
    state.shown, state.ordered = order(state), true
  end
  local n, vbuf = #state.shown, state.vbuf
  state.lazy = n > M.EAGER
  local top, head, sep, bottom = frame(state, true)
  local total = FIRST_ROW + n -- 4 lines above the rows, the rows, the bottom border
  if state.lazy and api.nvim_buf_line_count(vbuf) == total then
    -- as many rows as before: only the lines around them and the rows drawn
    -- so far (which may hold other rows now) are written, not every row
    put(vbuf, 0, FIRST_ROW - 1, { info(state, n), top, head, sep })
    put(vbuf, total - 1, total, { bottom })
    local drawn = vim.tbl_keys(state.filled)
    table.sort(drawn)
    local k = 1
    while k <= #drawn do -- each run of drawn rows back to placeholders
      local j, blank = k, { "" }
      while drawn[j + 1] == drawn[j] + 1 do
        j, blank[#blank + 1] = j + 1, ""
      end
      put(vbuf, FIRST_ROW - 2 + drawn[k], FIRST_ROW - 1 + drawn[j], blank)
      k = j + 1
    end
  else
    local lines = { info(state, n), top, head, sep }
    for p = 1, n do
      lines[p + 4] = ""
    end
    lines[n + 5] = bottom
    put(vbuf, 0, -1, lines)
  end
  state.filled = {}
  api.nvim_buf_clear_namespace(vbuf, ns, 0, -1)
  api.nvim_buf_set_extmark(vbuf, ns, 0, 0, { end_row = 1, hl_group = "Comment" })
  fill_visible(state)
  for _, win in ipairs(vim.fn.win_findbuf(vbuf)) do
    if api.nvim_win_get_cursor(win)[1] > total then
      api.nvim_win_set_cursor(win, { total, 0 })
    end
  end
  vim.cmd.redrawstatus({ bang = true })
end

-- Reads the source again. Column numbers mean nothing once the columns
-- change, so the sort and the filters go then. Staged edits are kept: the
-- view says the source changed, and apply refuses.
-- The source's lines now, or nil to read them all: the lines changed since
-- state.t was read come from the buffer, the rest from state.t.lines (the
-- first state.lead and the last state.trail lines did not change). A new list:
-- state.t stays as it was if the new lines are not taken.
local function source_lines(state)
  local old, total = state.t.lines, api.nvim_buf_line_count(state.src)
  local head, tail = state.lead, state.trail
  if head + tail > math.min(#old, total) then
    return nil -- nothing changed since the read: read it all to be safe
  end
  local lines = {}
  for k = 1, head do
    lines[k] = old[k]
  end
  local n = head
  for _, l in ipairs(api.nvim_buf_get_lines(state.src, head, total - tail, false)) do
    n = n + 1
    lines[n] = l
  end
  for k = #old - tail + 1, #old do
    n = n + 1
    lines[n] = old[k]
  end
  return lines
end

-- Notes that state.t holds the source as it is now.
local function synced(state)
  state.lead, state.trail = math.huge, math.huge
end

local function refresh(state)
  if not api.nvim_buf_is_valid(state.vbuf) or not api.nvim_buf_is_loaded(state.src) then
    return
  elseif vim.b[state.src].changedtick == state.t.tick then
    return -- read since the change (apply, discard)
  end
  if pending(state) then -- the view does not read the source then, only notes the change
    if vim.b[state.src].changedtick ~= state.t.tick and not state.stale then
      state.stale = true
      render(state)
    end
    return
  end
  local ok, t = pcall(edit.read, state.src, source_lines(state))
  if not ok then
    return -- the source has no rows now: the view keeps the last table
  end
  synced(state)
  if #t.first ~= #state.t.first then
    state.sort, state.cols, state.hidden = nil, {}, {}
  end
  state.t = t
  reset(state)
  render(state)
end

-- The header row for the winbar of window vim.g.statusline_winid, shifted by
-- the window's horizontal scroll.
function M.winbar()
  local win = vim.g.statusline_winid or api.nvim_get_current_win() -- unset when nothing is drawn
  local state = M.states[api.nvim_win_get_buf(win)]
  if not state then
    return ""
  end
  -- the scroll is counted in characters, so wide ones shift the header
  -- cut to the window width: past 4096 bytes Neovim drops the trailing %<
  local info = vim.fn.getwininfo(win)[1]
  local text = vim.fn.strcharpart(state.header, state.leftcol[win] or 0, info.width)
  -- %< at the end: too wide for the window, it is cut on the right, so it
  -- stays over its columns (the default cuts it on the left)
  return rep(" ", info.textoff) .. text:gsub("%%", "%%%%") .. "%<"
end

api.nvim_create_autocmd({ "WinScrolled", "WinResized" }, {
  group = group,
  callback = function()
    for vbuf, state in pairs(M.states) do
      for _, win in ipairs(vim.fn.win_findbuf(vbuf)) do
        api.nvim_win_call(win, function()
          state.leftcol[win] = vim.fn.winsaveview().leftcol
        end)
      end
      fill_visible(state)
    end
    vim.cmd.redrawstatus({ bang = true })
  end,
})

local function state_of(vbuf)
  local state = M.states[vbuf == 0 and api.nvim_get_current_buf() or vbuf]
  if not state then
    error("csvkit: not a view buffer", 0)
  end
  return state
end

-- The column under the cursor of the view: the one whose cells (and the bar
-- before them) cover the cursor's display column.
local function cursor_col(state)
  local x, col = vim.fn.virtcol("."), state.vis[1]
  for _, c in ipairs(state.vis) do
    if state.starts[c] <= x then
      col = c
    end
  end
  return col
end

-- The column under the cursor of view vbuf (the current window).
function M.cursor_col(vbuf)
  return cursor_col(state_of(vbuf))
end

-- The index of column name (a header name or a number), or the cursor's;
-- raises when there is no such column.
local function column(state, name)
  if not name then
    return cursor_col(state)
  elseif type(name) == "number" then -- a 0-based number, never a header's name
    return name + 1
  end
  for c, h in ipairs(state.t.h == 1 and state.hdr or {}) do
    if types.trim(h) == name then
      return c
    end
  end
  return edit.number_col(name, state.ncols) or error(('csvkit: no column "%s"'):format(name), 0)
end

-- The cells of column name (default: the cursor's) on the rows shown (only
-- those on the view's lines range, if given), in their order, staged cells
-- included; its name; the source's options.
function M.shown_cells(vbuf, name, range)
  local state = state_of(vbuf)
  local c = column(state, name)
  local col, out, rows = cells(state, c), {}, state.shown
  if range then
    rows = {}
    for l = range[1], range[2] do
      rows[#rows + 1] = row_at(state, l)
    end
  end
  for p, i in ipairs(rows) do
    out[p] = col[i] or ""
  end
  return out, name_of(state, c), state.t.opts
end

function M.column(vbuf, name)
  return column(state_of(vbuf), name)
end

-- The names of the view's columns, staged ones included ("" for no name).
function M.names(vbuf)
  local state, out = state_of(vbuf), {}
  for c = 1, state.ncols do
    out[c] = state.t.h == 1 and state.hdr[c] or ""
  end
  return out
end

-- Moves the cursor to column name on its row (the header row when it is above
-- it), with the column's left bar at the window's left edge.
function M.goto_col(vbuf, name)
  local state = state_of(vbuf)
  local c = column(state, name)
  if state.hidden[c] then
    error(('csvkit: column "%s" is hidden'):format(name), 0)
  end
  local lnum = math.max(api.nvim_win_get_cursor(0)[1], HEADER_LINE)
  local byte = vim.fn.virtcol2col(0, lnum, state.starts[c] + 2)
  api.nvim_win_set_cursor(0, { lnum, math.max(byte - 1, 0) })
  vim.fn.winrestview({ leftcol = state.starts[c] - 1 })
end

-- Moves the cursor to the source line of the record under it. On the first
-- line, shows that line uncut: every filter value, one part a line.
function M.jump(vbuf)
  local state = state_of(vbuf)
  local lnum = api.nvim_win_get_cursor(0)[1]
  if lnum == 1 then
    local parts = info_parts(state, #state.shown, true)
    return vim.notify("csvkit view:\n" .. table.concat(parts, "\n"), vim.log.levels.INFO)
  end
  local i = row_at(state, lnum)
  local line = i and source_line(state, i) or lnum == HEADER_LINE and state.t.h == 1 and state.t.line_of[1] or nil
  if not line then
    return
  end
  local win = vim.fn.win_findbuf(state.src)[1]
  if win then
    api.nvim_set_current_win(win)
  else
    api.nvim_set_current_buf(state.src)
  end
  api.nvim_win_set_cursor(0, { math.min(line, api.nvim_buf_line_count(state.src)), 0 })
end

-- Sorts the view by spec = { desc, type }; the column is name or the cursor's.
-- The order is only applied to the source by apply("sort").
function M.sort(vbuf, spec, name)
  local state = state_of(vbuf)
  spec.col = column(state, name)
  state.sort, state.ordered = spec, nil
  render(state)
end

-- Sets the values of column col that stay in the view (a set), or removes the
-- column's filter when allowed is nil.
function M.set_filter(vbuf, col, allowed)
  local state = state_of(vbuf)
  state.cols[col], state.ordered = allowed, nil
  render(state)
end

-- Opens the filter picker on the column name (or the cursor's).
function M.filter(vbuf, name)
  local state = state_of(vbuf)
  local col = column(state, name)
  local all, shown = cells(state, col), {}
  for _, i in ipairs((order(state, col))) do
    shown[#shown + 1] = all[i]
  end
  require("csvkit.filter").pick(state.t, col, {
    current = state.cols[col],
    cells = shown,
    name = name_of(state, col),
    apply = function(c, allowed)
      M.set_filter(state.vbuf, c, allowed)
    end,
  })
end

-- Sets the filter expression of the view (as filter.where does for a buffer),
-- or removes it when expr is nil. Raises, leaving the view as it was, when it
-- does not compile or no row gives TRUE or FALSE.
function M.where(vbuf, expr)
  local state = state_of(vbuf)
  if expr then
    formula.filterable(formula.compile(expr, state.t.h == 1 and state.hdr, state.ncols))
  end
  local old = state.expr
  state.expr = expr
  local shown, err = order(state)
  if err then
    state.expr = old
    error("csvkit: filter: " .. err, 0)
  end
  state.shown, state.ordered = shown, true
  render(state)
end

-- Hides columns cols (a list; default: the cursor's) from the view; never
-- applied.
function M.hide(vbuf, cols)
  local state = state_of(vbuf)
  cols = cols or { cursor_col(state) }
  local left = #state.vis
  for _, c in ipairs(cols) do
    left = left - (state.hidden[c] and 0 or 1)
  end
  if left < 1 then
    error("csvkit: can't hide every column", 0)
  end
  for _, c in ipairs(cols) do
    state.hidden[c] = true
  end
  render(state)
end

-- Shows the hidden columns again.
function M.show_hidden(vbuf)
  local state = state_of(vbuf)
  state.hidden = {}
  render(state)
end

-- Removes every filter of the view.
function M.clear_filters(vbuf)
  local state = state_of(vbuf)
  state.cols, state.expr, state.ordered = {}, nil, nil
  render(state)
end

-- Stages text as cell col of data row i (state.recs exists).
local function stage_cell(state, i, col, text)
  local f = own(state, i)
  pad_to(f, col)
  f[col] = text
  state.recs[i].cells = (state.recs[i].cells or 0) + 1 -- taken back if the row is deleted
  state.pending.cells = state.pending.cells + 1
end

-- Stages cell col of the row at line lnum (the header row renames the column).
function M.set_cell(vbuf, lnum, col, text)
  local state = state_of(vbuf)
  local i = row_at(state, lnum)
  if lnum == HEADER_LINE then
    if state.t.h == 0 then
      error("csvkit: the file has no header", 0)
    end
    materialize(state)
    pad_to(state.hdr, col)
    state.hdr[col] = text
    state.pending.names = state.pending.names + 1
  elseif i then
    materialize(state)
    stage_cell(state, i, col, text)
    if (state.sort and state.sort.col == col) or state.cols[col] or state.expr then
      state.ordered = nil
    end
  else
    error("csvkit: put the cursor on a row", 0)
  end
  render(state)
end

-- Stages the deletion of rows and returns how many went: spec.mode nil = the
-- rows on the view's lines spec.range (default: the cursor's), "where" = the
-- rows where formula spec.expr is TRUE, "hidden" = the rows the filters hide.
-- A new row just goes, and so do the edits of a deleted row.
function M.delete_rows(vbuf, spec)
  local state = state_of(vbuf)
  local del = {}
  if spec.mode == "where" then
    local pass, err = formula.matches(formula_on(state, spec.expr))
    if err then
      error("csvkit: row delete: " .. err, 0)
    end
    for i, ok in pairs(pass) do
      del[i] = ok or nil
    end
  elseif spec.mode == "hidden" then
    if next(state.cols) == nil and not state.expr then
      error("csvkit: no rows are hidden: set a filter first", 0)
    end
    for i = 1, count(state) do
      del[i] = true
    end
    for _, i in ipairs(state.shown) do
      del[i] = nil
    end
  else
    local lnum = api.nvim_win_get_cursor(0)[1]
    for l = spec.range and spec.range[1] or lnum, spec.range and spec.range[2] or lnum do
      local i = row_at(state, l)
      if i then
        del[i] = true
      end
    end
    if next(del) == nil then
      error("csvkit: put the cursor on a row", 0)
    end
  end
  if next(del) == nil then
    return 0
  end
  materialize(state)
  local recs, p, n = {}, state.pending, 0
  for i, rec in ipairs(state.recs) do
    if del[i] then
      n = n + 1
      if src_of(rec) then
        p.gone = p.gone + 1
      else
        p.rows = p.rows - 1
      end
      p.cells = p.cells - (type(rec) == "table" and rec.cells or 0)
    else
      recs[#recs + 1] = rec
    end
  end
  for c, col in pairs(state.staged) do -- the staged columns stay aligned with recs
    local kept = {}
    for i = 1, #state.recs do
      if not del[i] then
        kept[#kept + 1] = col[i]
      end
    end
    state.staged[c] = kept
  end
  state.recs, state.ordered = recs, nil
  render(state)
  return n
end

-- Puts data row at, a new empty row (rows at and after it moved one down),
-- into state.shown without working the order out again; returns its place.
-- A filter never hides a new row; with no sort the rows are in the file's
-- order, and a sort puts empty cells last, in the file's order.
local function insert_shown(state, at)
  local shown = state.shown
  for p, i in ipairs(shown) do
    if i >= at then
      shown[p] = i + 1
    end
  end
  local lo, hi = 1, #shown + 1
  if state.sort then -- where the rows with an empty sort cell start
    local c = state.sort.col
    while lo < hi do
      local mid = math.floor((lo + hi) / 2)
      if types.trim(fields(state, shown[mid])[c] or "") == "" then
        hi = mid
      else
        lo = mid + 1
      end
    end
    hi = #shown + 1
  end
  while lo < hi do -- then by the file's order
    local mid = math.floor((lo + hi) / 2)
    if shown[mid] < at then
      lo = mid + 1
    else
      hi = mid
    end
  end
  table.insert(shown, lo, at)
  return lo
end

-- Stages an empty row above or below the row under the cursor (the cursor
-- goes to it). Below the header it is the first row.
function M.add_row(vbuf, above)
  local state = state_of(vbuf)
  local lnum = api.nvim_win_get_cursor(0)[1]
  local i, at = row_at(state, lnum), nil
  if lnum == HEADER_LINE and state.t.h == 1 then
    if above then
      error("csvkit: can't add a row above the header", 0)
    end
    at = 1
  elseif i then
    at = above and i or i + 1
  else
    error("csvkit: put the cursor on a row", 0)
  end
  materialize(state)
  local empty = {}
  pad_to(empty, state.ncols)
  table.insert(state.recs, at, { f = empty, edited = true })
  for _, col in pairs(state.staged) do -- keeps them aligned with recs (f wins)
    table.insert(col, at, "")
  end
  state.pending.rows = state.pending.rows + 1
  if state.ordered then
    local pos = insert_shown(state, at)
    if state.lazy then -- a placeholder for it, so the rows drawn keep their lines
      put(state.vbuf, FIRST_ROW - 2 + pos, FIRST_ROW - 2 + pos, { "" })
      local filled = {}
      for q in pairs(state.filled) do
        filled[q >= pos and q + 1 or q] = true
      end
      state.filled = filled
    end
  end
  render(state)
  for p, n in ipairs(state.shown) do
    if n == at then
      api.nvim_win_set_cursor(0, { FIRST_ROW + p - 1, 0 })
      fill_visible(state)
    end
  end
end

-- The values of formula expr for every shown row (nil for the others), the
-- lines of the rows that failed and the first failure's message. Raises on a
-- compile error.
local function formula_values(state, expr)
  local values, failures, err = formula.eval_column(formula_on(state, expr))
  -- a row of the source is named by its line; a new row, which has none, as
  -- "new N" (the N-th new row in the file's order)
  local new, n = {}, 0
  for i, rec in ipairs(#failures > 0 and state.recs or {}) do
    if not src_of(rec) then
      n = n + 1
      new[i] = "new " .. n
    end
  end
  for k, i in ipairs(failures) do
    local rec = state.recs and state.recs[i]
    failures[k] = new[i] or state.t.line_of[(rec and src_of(rec) or i) + state.t.h]
  end
  return values, failures, err
end

-- Moves the keys of map after column `after` one to the right.
local function shift_keys(map, after)
  local out = {}
  for c, v in pairs(map) do
    out[c > after and c + 1 or c] = v
  end
  return out
end

-- Drops key c of map and moves the keys after it one to the left.
local function drop_key(map, c)
  local out = {}
  for k, v in pairs(map) do
    if k ~= c then
      out[k > c and k - 1 or k] = v
    end
  end
  return out
end

-- Deletes column c of the view: a column of the source is noted in
-- state.removed, a staged column just goes; the sort, the filters and the
-- hidden columns stay on their columns.
local function drop_column(state, c)
  local s = source_of(state, c)
  if s then
    table.insert(state.removed, s)
    table.sort(state.removed, function(a, b)
      return a > b
    end)
    state.pending.dels = state.pending.dels + 1
  else
    table.remove(state.added, vim.fn.index(state.added, c) + 1)
    state.pending.cols = state.pending.cols - 1
  end
  for _, rec in ipairs(state.recs) do
    if type(rec) == "table" and #rec.f >= c then
      table.remove(rec.f, c)
    end
  end
  for i, a in ipairs(state.added) do
    state.added[i] = a > c and a - 1 or a
  end
  if state.sort and state.sort.col == c then
    state.sort = nil
  elseif state.sort and state.sort.col > c then
    state.sort.col = state.sort.col - 1
  end
  state.cols, state.hidden = drop_key(state.cols, c), drop_key(state.hidden, c)
  state.keep, state.staged = drop_key(state.keep, c), drop_key(state.staged, c)
  if state.t.h == 1 and #state.hdr >= c then
    table.remove(state.hdr, c)
  end
end

-- Stages the deletion of columns cols (a list; default: the cursor's).
function M.delcol(vbuf, cols)
  local state = state_of(vbuf)
  cols = vim.list_extend({}, cols or { cursor_col(state) })
  if #cols >= state.ncols then
    error("csvkit: can't delete every column", 0)
  end
  materialize(state)
  table.sort(cols, function(a, b)
    return a > b -- right to left: the numbers of the ones before stay right
  end)
  for _, c in ipairs(cols) do
    drop_column(state, c)
  end
  state.ordered = nil
  render(state)
end

-- Puts a column named spec.name after column spec.after, with values[i] in
-- data row i (values becomes the staged column). Only the rows with their own
-- fields get it in them; the others read it from state.staged.
local function insert_column(state, spec, values)
  materialize(state)
  for i, rec in ipairs(state.recs) do
    values[i] = values[i] or ""
    if type(rec) == "table" then
      pad_to(rec.f, spec.after)
      table.insert(rec.f, spec.after + 1, values[i])
    end
  end
  for i, c in ipairs(state.added) do
    state.added[i] = c >= spec.after + 1 and c + 1 or c
  end
  -- what is keyed by column stays on its column, which moves right
  if state.sort and state.sort.col > spec.after then
    state.sort.col = state.sort.col + 1
  end
  state.cols = shift_keys(state.cols, spec.after)
  state.hidden = shift_keys(state.hidden, spec.after)
  state.keep = shift_keys(state.keep, spec.after)
  state.staged = shift_keys(state.staged, spec.after)
  state.staged[spec.after + 1] = values
  table.insert(state.added, spec.after + 1)
  table.sort(state.added)
  if state.t.h == 1 then
    pad_to(state.hdr, spec.after)
    table.insert(state.hdr, spec.after + 1, spec.name)
  end
  state.pending.cols = state.pending.cols + 1
  render(state)
end

-- Asks for the value of each shown row (the cursor of win goes to it), then
-- stages the column. <Esc> stops; the rows not reached stay empty.
local function prompt_fill(state, spec, win)
  local t, shown, values = state.t, state.shown, {}
  local function finish()
    if state.t ~= t then
      return vim.notify("csvkit: the source changed while prompting; nothing staged", vim.log.levels.ERROR)
    end
    insert_column(state, spec, values)
  end
  local function ask(p)
    local i = shown[p]
    if not i then
      return finish()
    end
    local row, named = fields(state, i), {}
    for c = 1, state.ncols do
      named[c] = name_of(state, c) .. "=" .. (row[c] or ""):gsub("\n", "⏎")
    end
    api.nvim_win_set_cursor(win, { FIRST_ROW + p - 1, 0 })
    fill_visible(state)
    vim.cmd.redraw()
    local prompt = ("Row %d [%s] > "):format(p, table.concat(named, ", "))
    vim.ui.input({ prompt = prompt }, require("csvkit.command").guarded(function(s)
      if s == nil then
        return finish()
      end
      values[i] = s
      ask(p + 1)
    end))
  end
  ask(1)
end

-- Stages a column after column spec.after (default: the cursor's): spec = {
-- name, mode = "value" | "formula" | "fill", text }. win (default: current) is
-- the view window fill moves the cursor in. Returns the lines of the rows a
-- formula failed on and the first failure's message.
function M.addcol(vbuf, spec, win)
  local state = state_of(vbuf)
  spec.after = spec.after or cursor_col(state)
  if spec.mode == "fill" then
    return prompt_fill(state, spec, win or api.nvim_get_current_win())
  end
  local values, failures, err = {}, nil, nil
  if spec.mode == "value" then
    for i = 1, count(state) do
      values[i] = spec.text
    end
  else
    values, failures, err = formula_values(state, spec.text)
  end
  insert_column(state, spec, values)
  return failures, err
end

-- Stages formula spec.text as the cells of column spec.col on the shown rows,
-- where they change (a row the formula fails on gets an empty cell). Returns
-- the lines of the rows it failed on and the first failure's message.
function M.setcol(vbuf, spec)
  local state = state_of(vbuf)
  local values, failures, err = formula_values(state, spec.text)
  local old = cells(state, spec.col)
  materialize(state)
  for i, v in pairs(values) do
    if v ~= (old[i] or "") then
      stage_cell(state, i, spec.col, v)
    end
  end
  state.ordered = nil
  render(state)
  return failures, err
end

-- Drops the staged edits and the sort; the filters stay.
function M.discard(vbuf)
  local state = state_of(vbuf)
  if vim.b[state.src].changedtick ~= state.t.tick then -- else state.t is the source as it is
    local ok, t = pcall(edit.read, state.src, source_lines(state))
    if ok then
      state.t = t
      synced(state)
    end
  end
  state.sort = nil
  -- the filters and hidden columns go back to the source's columns: a staged
  -- column's go, the others move to their column of the source
  local function back(map)
    local out = {}
    for c, v in pairs(map) do
      local s = source_of(state, c)
      if s then
        out[s] = v
      end
    end
    return out
  end
  state.cols, state.hidden = back(state.cols), back(state.hidden)
  reset(state)
  render(state)
end

-- The staged columns as groups { k = number of columns of the source before
-- them, cols = their final numbers }, from the rightmost: the new fields go
-- into the text of a record right to left, so the places found in the
-- original text stay right.
local function column_groups(added)
  local groups = {}
  for n, c in ipairs(added) do
    local k, last = c - n, groups[#groups]
    if last and last.k == k then
      last.cols[#last.cols + 1] = c
    else
      groups[#groups + 1] = { k = k, cols = { c } }
    end
  end
  return vim.iter(groups):rev():totable()
end

-- The lines of the source with the staged edits, rows in the order perm. A
-- record only a column was added to gets the new fields put into its text,
-- so the rest stays byte-identical; a record with an edited cell, a new row,
-- and a record too short to hold the place of a new field (it needs empty
-- fields before it) are written again from their fields in the file's quote
-- style. A record nothing touched keeps its text.
local function staged_lines(state, perm)
  local t, out = state.t, {}
  local delim, quote_all, lines = t.opts.delimiter, t.quote_all, t.lines
  local groups = column_groups(state.added)
  local pad = delim .. csv.serialize_field("", delim, quote_all)
  local function emit(text)
    if text:find("\n", 1, true) then
      vim.list_extend(out, vim.split(text, "\n", { plain = true }))
    else
      out[#out + 1] = text
    end
  end
  local function raw(r)
    for l = t.line_of[r], edit.last_line(t, r) do
      out[#out + 1] = lines[l]
    end
  end
  local function serialized(row)
    emit(csv.serialize_row(row, delim, quote_all))
  end
  -- record r with the staged columns' fields put in, from row (the header)
  -- or else the staged values of data row i; false when its text is too
  -- short for that. One table for every record (changed: line -> its new
  -- text) and no table per field, which at 1M rows would be 2M tables for the GC.
  local changed = {}
  local function inserted(r, row, i)
    local first, last = t.line_of[r], edit.last_line(t, r)
    for _, group in ipairs(groups) do
      local stop, pos, n = csv.field_end(t, r, group.k)
      if n < group.k then
        for l = first, last do
          changed[l] = nil
        end
        return false
      end
      local new = ""
      for _, c in ipairs(group.cols) do
        new = new .. delim .. csv.serialize_field(row and (row[c] or "") or state.staged[c][i], delim, quote_all)
      end
      if group.k == 0 then -- before the first field: the delimiter goes after
        new = new:sub(#delim + 1) .. delim
      end
      local line = changed[stop] or lines[stop]
      changed[stop] = line:sub(1, pos - 1) .. new .. line:sub(pos)
    end
    for l = first, last do
      emit(changed[l] or lines[l])
      changed[l] = nil
    end
    return true
  end
  local dropped = #state.removed > 0
  if t.h == 1 then
    local p = state.pending
    if p.names == 0 and p.cols == 0 and not dropped then
      raw(1)
    elseif dropped or p.names > 0 or not inserted(1, state.hdr) then
      serialized(state.hdr)
    end
  end
  for _, i in ipairs(perm) do
    local rec = state.recs[i]
    if type(rec) == "table" then -- a new or edited row
      serialized(rec.f)
    elseif dropped then
      serialized(fields(state, i))
    elseif #groups == 0 then
      raw(rec + t.h)
    elseif not inserted(rec + t.h, nil, i) then
      serialized(fields(state, i))
    end
  end
  return out
end

-- Writes the staged edits to the source, in one undo step; with what =
-- "sort", in the view's sort order too (the filters never apply). Refuses if
-- the source changed since the view read it.
function M.apply(vbuf, what)
  local state = state_of(vbuf)
  if what ~= nil and what ~= "sort" then
    error("csvkit: usage: apply [sort]", 0)
  elseif what == "sort" and not state.sort then
    error("csvkit: the view is not sorted", 0)
  elseif not pending(state) and not what then
    error("csvkit: nothing staged to apply", 0)
  end
  local t = state.t
  edit.check_modifiable(state.src)
  if vim.b[state.src].changedtick ~= t.tick then
    error("csvkit: the source changed since the view read it; :Csvkit discard first", 0)
  end
  local written -- the source's lines after the write, when known
  if not pending(state) then
    edit.sort(t, state.sort) -- only the order: the lines move as they are
  else
    local perm = {}
    if what then
      perm = sort.sort_rows(cells(state, state.sort.col), state.sort, t.opts)
    else
      for i = 1, #state.recs do
        perm[i] = i
      end
    end
    written = staged_lines(state, perm)
    edit.write(t, { 1, t.last }, written)
    for _ = t.last + 1, #t.lines do -- the blank lines after the last record stay
      written[#written + 1] = ""
    end
  end
  if what then
    state.sort = nil
  end
  -- the old copy of the source and the staged rows go before the new copy is
  -- made, so the two are not in memory at once (~120 MB at 1M rows); the
  -- lines just written are the source now: no need to read them back
  t, state.t, state.recs, state.staged, state.keep = nil, nil, nil, {}, {}
  state.t = edit.read(state.src, written)
  synced(state)
  reset(state)
  render(state)
end

-- The view's window options, set on each window that shows it.
local function set_options(win)
  for name, value in pairs({ wrap = false, cursorline = true, winbar = WINBAR }) do
    vim.wo[win][name] = value
  end
end

-- Shows the view of buf in the current window, made unless buf has one (then
-- the window that shows it is entered, if any).
function M.open(buf)
  buf = buf == 0 and api.nvim_get_current_buf() or buf
  if M.states[buf] then
    error("csvkit: this is already a view", 0)
  end
  for vbuf, st in pairs(M.states) do
    if st.src == buf then
      local win = vim.fn.win_findbuf(vbuf)[1]
      if win then
        return api.nvim_set_current_win(win)
      end
      return api.nvim_win_set_buf(0, vbuf)
    end
  end
  local state = { src = buf, t = edit.read(buf), cols = {}, hidden = {}, leftcol = {}, timer = vim.uv.new_timer() }
  synced(state)
  reset(state)
  state.max = csvkit.max_col_width(csvkit.get_opts(buf)) or math.huge
  local vbuf = api.nvim_create_buf(false, true)
  state.vbuf = vbuf
  M.states[vbuf] = state
  vim.bo[vbuf].bufhidden = "hide"
  vim.bo[vbuf].filetype = "csvkit_view"
  vim.bo[vbuf].undolevels = -1
  api.nvim_win_set_buf(0, vbuf)
  set_options(api.nvim_get_current_win())
  render(state)
  local guarded = require("csvkit.command").guarded
  local function map(key, fn, desc)
    vim.keymap.set("n", key, guarded(fn), { buffer = vbuf, desc = "csvkit: " .. desc })
  end
  map("<CR>", function()
    M.jump(vbuf)
  end, "go to the record in the source")
  map("i", function()
    local lnum, col = api.nvim_win_get_cursor(0)[1], cursor_col(state)
    local row = lnum == HEADER_LINE and state.hdr or row_at(state, lnum) and fields(state, row_at(state, lnum))
    if not row then
      error("csvkit: put the cursor on a row", 0)
    end
    vim.ui.input({ prompt = "Cell: ", default = row[col] or "" }, guarded(function(text)
      if text ~= nil then
        M.set_cell(vbuf, lnum, col, text)
      end
    end))
  end, "edit the cell under the cursor (staged)")
  -- a hidden view follows the source only once shown again (state.behind)
  local function later()
    state.timer:start(M.DEBOUNCE, 0, vim.schedule_wrap(function()
      if M.states[vbuf] ~= state then
        return
      elseif #vim.fn.win_findbuf(vbuf) == 0 then
        state.behind = true
      else
        refresh(state)
      end
    end))
  end
  api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    buffer = vbuf,
    callback = function()
      set_options(api.nvim_get_current_win())
      if M.states[vbuf] == state and state.behind then
        state.behind = nil
        refresh(state)
      end
    end,
  })
  local attached
  local function attach()
    attached = true
    api.nvim_buf_attach(buf, false, {
      on_lines = function(_, _, _, first, _, new_last)
        if M.states[vbuf] ~= state then
          return true
        end
        -- what did not change since the source was read: its first and last lines
        state.lead = math.min(state.lead, first)
        state.trail = math.min(state.trail, api.nvim_buf_line_count(buf) - new_last)
        later()
      end,
      on_reload = function()
        if M.states[vbuf] == state then
          state.lead, state.trail = 0, 0 -- every line may have changed
          later()
        end
      end,
      on_changedtick = function(_, _, tick) -- the tick moved, the text did not
        if M.states[vbuf] ~= state then
          return true
        elseif state.lead == math.huge then -- read since the last text change
          state.t.tick = tick
        end
      end,
      on_detach = function() -- :e! or an unload; BufReadPost attaches again
        attached, state.lead, state.trail = false, 0, 0
      end,
    })
  end
  attach()
  local reread = api.nvim_create_autocmd("BufReadPost", {
    group = group,
    buffer = buf,
    callback = function()
      if M.states[vbuf] == state and not attached then
        attach()
        later()
      end
    end,
  })
  api.nvim_create_autocmd("BufUnload", { -- :bdelete as well as :bwipeout
    group = group,
    buffer = vbuf,
    callback = function()
      M.states[vbuf] = nil
      pcall(api.nvim_del_autocmd, reread)
      if not state.timer:is_closing() then
        state.timer:stop()
        state.timer:close()
      end
    end,
  })
end

return M
