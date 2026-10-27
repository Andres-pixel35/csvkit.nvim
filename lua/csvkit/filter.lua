-- Excel-like filter: per column, the set of values that stay visible, ANDed
-- across columns and with an optional expression (a formula that is TRUE on
-- the rows to show). View-only: the rows that do not match are folded (manual
-- folds, one per run of hidden rows) and the buffer text is never touched.
local csv = require("csvkit.csv")
local edit = require("csvkit.edit")
local types = require("csvkit.types")

local M = {}

M.states = {} -- buf -> { cols = {col -> set of allowed values}, expr, runs, rows, saved = {win -> options} }

local api = vim.api
local group = api.nvim_create_augroup("csvkit_filter", { clear = false })
local FOLDTEXT = "v:lua.require'csvkit.filter'.foldtext()"
local OPTIONS = { "foldmethod", "foldtext", "foldminlines", "foldlevel", "foldenable" }

-- The distinct trimmed values of column col, as { value, count } sorted by
-- count (most first) then value. Blank cells are the value "".
function M.values(t, col)
  return M.counts(csv.column(t, col, t.h + 1))
end

-- Like values, for a list of cells.
function M.counts(cells)
  local counts = {}
  for _, cell in ipairs(cells) do
    cell = types.trim(cell)
    counts[cell] = (counts[cell] or 0) + 1
  end
  -- grouped by count, so the values sort with the plain table.sort (no
  -- comparator function: ~10x faster on a column of unique ids)
  local groups, sizes = {}, {}
  for value, count in pairs(counts) do
    local group = groups[count]
    if not group then
      group = {}
      groups[count], sizes[#sizes + 1] = group, count
    end
    group[#group + 1] = value
  end
  table.sort(sizes, function(a, b)
    return a > b
  end)
  local out = {}
  for _, count in ipairs(sizes) do
    local group = groups[count]
    table.sort(group)
    for _, value in ipairs(group) do
      out[#out + 1] = { value = value, count = count }
    end
  end
  return out
end

-- The data rows that fail some column's filter or the expression, as a set.
-- Also returns why no row could be evaluated with the expression, if so;
-- raises when it does not compile.
local function hidden(t, state)
  local hide, err = {}, nil
  for c, allowed in pairs(state.cols) do
    for i, cell in ipairs(csv.column(t, c, t.h + 1)) do
      if not allowed[types.trim(cell)] then
        hide[i] = true
      end
    end
  end
  if state.expr then
    local pass
    pass, err = edit.formula_matches(t, state.expr)
    for i = 1, t.n do
      if not pass[i] then
        hide[i] = true
      end
    end
  end
  return hide, err
end

-- The data rows of buf (read as t) that its filters hide, as a set; nil when
-- it has no filter.
function M.hidden(buf, t)
  local state = M.states[buf]
  return state and (hidden(t, state))
end

-- The runs of lines to hide: { first line, last line, rows } for each stretch
-- of hidden data rows (a record is hidden whole), and hidden's error.
local function runs(t, state)
  local hide, err = hidden(t, state)
  local out = {}
  for i = 1, t.n do
    if hide[i] then
      local r = i + t.h
      local from, to = t.line_of[r], edit.last_line(t, r)
      local run = out[#out]
      if run and run[2] + 1 == from then
        run[2], run[3] = to, run[3] + 1
      else
        out[#out + 1] = { from, to, 1 }
      end
    end
  end
  return out, err
end

-- Tells that the filter expression expr was removed because it no longer
-- compiles (err: a "csvkit: " compile error; any other error is raised).
function M.dropped(expr, err)
  if type(err) ~= "string" or not err:find("^csvkit: ") then
    error(err, 0)
  end
  vim.notify(("csvkit: filter %s removed: %s"):format(expr, err:sub(9)), vim.log.levels.WARN)
end

-- Fold text of the fold being drawn: how many rows it hides. A fold that has
-- moved since the last refresh (an edit) falls back to its line count.
function M.foldtext()
  local state = M.states[api.nvim_get_current_buf()]
  local start, stop = vim.v.foldstart, vim.v.foldend
  local run = state and state.rows[start]
  local n = run and run[1] == stop and run[2] or stop - start + 1
  return ("⋯ %d hidden row%s"):format(n, n == 1 and "" or "s")
end

-- Folds win's hidden runs, keeping the window's fold options to put back.
local function fold(state, win)
  api.nvim_win_call(win, function()
    local wo = vim.wo[win]
    if not state.saved[win] then
      -- a window split from a filtered one already has the filter's options
      local _, saved = next(state.saved)
      if not (saved and wo.foldtext == FOLDTEXT) then
        saved = {}
        for _, name in ipairs(OPTIONS) do
          saved[name] = wo[name]
        end
      end
      state.saved[win] = saved
    end
    wo.foldmethod, wo.foldtext, wo.foldminlines, wo.foldlevel, wo.foldenable = "manual", FOLDTEXT, 0, 0, true
    vim.cmd.normal({ "zE", bang = true })
    for _, run in ipairs(state.runs) do
      vim.cmd.fold({ range = { run[1], run[2] } })
    end
  end)
end

-- Removes the folds from win and puts its options back, if it still shows
-- the buffer. The saved options stay: the window may show the buffer again.
local function unfold(state, win)
  local saved = state.saved[win]
  if saved and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == state.buf then
    api.nvim_win_call(win, function()
      vim.cmd.normal({ "zE", bang = true })
      for name, value in pairs(saved) do
        vim.wo[win][name] = value
      end
    end)
  end
end

-- The overlay skips the lines inside closed folds, so it redraws after them.
local function redraw_overlay(buf)
  local overlay = package.loaded["csvkit.overlay"]
  if overlay then
    overlay.redraw(buf)
  end
end

-- Removes every filter of buf.
function M.clear(buf)
  buf = buf == 0 and api.nvim_get_current_buf() or buf
  local state = M.states[buf]
  if not state then
    return
  end
  M.states[buf] = nil
  api.nvim_clear_autocmds({ group = group, buffer = buf })
  for win in pairs(state.saved) do
    unfold(state, win)
  end
  redraw_overlay(buf)
end

-- Reads buf again and folds what its filters hide in every window showing it.
-- A buffer whose columns changed (addcol) cannot keep column numbers, so its
-- filters go; an expression that no longer compiles (a renamed column) goes.
-- t: edit.read's table for buf, used when buf has not changed since (the
-- picker's), so the buffer is not read twice. strict: raise, before anything
-- is folded, when the expression does not compile or no row can be evaluated.
local function refresh(state, t, strict)
  local buf = state.buf
  local ok = true
  if not (t and t.tick == vim.b[buf].changedtick) then
    ok, t = pcall(edit.read, buf)
  end
  if not ok or (state.ncols and state.ncols ~= #t.first) then
    M.clear(buf)
    local why = ok and "the number of columns changed" or t:gsub("^csvkit: ", "")
    return vim.notify("csvkit: filters cleared: " .. why, vim.log.levels.WARN)
  end
  local ok_runs, out, err = pcall(runs, t, state)
  if strict and not ok_runs then
    error(out, 0)
  elseif strict and err then
    error("csvkit: filter: " .. err, 0)
  elseif not ok_runs then
    M.dropped(state.expr, out)
    state.expr = nil
    if next(state.cols) == nil then
      return M.clear(buf)
    end
    out = runs(t, state)
  end
  state.ncols, state.tick = #t.first, t.tick
  state.runs, state.rows = out, {}
  for _, run in ipairs(state.runs) do
    state.rows[run[1]] = { run[2], run[3] }
  end
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    fold(state, win)
  end
  redraw_overlay(buf)
end

-- The filters follow the rows when the text changes (a sort, an insert, an
-- undo); typing in insert mode waits for InsertLeave.
local function track(state)
  local buf = state.buf
  api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
    group = group,
    buffer = buf,
    callback = function()
      if vim.b[buf].changedtick ~= state.tick then
        refresh(state)
      end
    end,
  })
  -- WinEnter too: a :split shows the buffer in a new window without BufWinEnter
  api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
    group = group,
    buffer = buf,
    callback = function(a)
      local win = api.nvim_get_current_win()
      if state.runs and (a.event == "BufWinEnter" or not state.saved[win]) then
        fold(state, win)
      end
    end,
  })
  api.nvim_create_autocmd("BufWinLeave", {
    group = group,
    buffer = buf,
    callback = function()
      unfold(state, api.nvim_get_current_win())
    end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function()
      M.states[buf] = nil
    end,
  })
end

-- buf's state, made on first use.
local function state_of(buf)
  local state = M.states[buf]
  if not state then
    state = { buf = buf, cols = {}, saved = {} }
    M.states[buf] = state
    track(state)
  end
  return state
end

-- Sets the values of column col that stay visible (a set { [value] = true }),
-- or removes the column's filter when allowed is nil. t (optional): a read of
-- buf to use if buf has not changed since.
function M.set(buf, col, allowed, t)
  buf = buf == 0 and api.nvim_get_current_buf() or buf
  if not M.states[buf] and allowed == nil then
    return
  end
  local state = state_of(buf)
  state.cols[col] = allowed
  if next(state.cols) == nil and not state.expr then
    return M.clear(buf)
  end
  refresh(state, t)
end

-- Sets the filter expression of buf: a formula, TRUE on the rows that stay
-- visible (a row where it fails is hidden), ANDed with the column filters; nil
-- removes it. Raises, leaving the filters as they were, when it does not
-- compile or no row gives TRUE or FALSE. t: as in set.
function M.where(buf, expr, t)
  buf = buf == 0 and api.nvim_get_current_buf() or buf
  if not M.states[buf] and expr == nil then
    return
  end
  local state = state_of(buf)
  local old = state.expr
  state.expr = expr
  if next(state.cols) == nil and not expr then
    return M.clear(buf)
  end
  local ok, err = pcall(refresh, state, t, true)
  if not ok then
    state.expr = old
    if next(state.cols) == nil and not old then
      M.clear(buf)
    end
    error(err, 0)
  end
end

-- Opens a float listing the values of column col with a checkbox each; <CR>
-- applies the checked ones. t is edit.read's table for the buffer. target is
-- { current, cells, name, apply(col, allowed) } for a filter kept elsewhere (the
-- view buffer, whose cells may be staged edits); by default the buffer's folds.
function M.pick(t, col, target)
  local values = target and M.counts(target.cells) or M.values(t, col)
  if #values == 0 then
    error(("csvkit: no values to filter in column %d"):format(col - 1), 0)
  end
  local state = M.states[t.buf]
  local current
  if target then
    current = target.current
  else
    current = state and state.cols[col]
  end
  local checked, width = {}, 0
  for i, v in ipairs(values) do
    checked[i] = current == nil or current[v.value] == true
  end
  -- plain concatenation, which LuaJIT compiles (string.format and gsub it
  -- does not); no text is kept per value, which cost memory at 1M values
  local function line(i)
    local v = values[i]
    local text = v.value == "" and "(empty)" or v.value
    if text:find("\n", 1, true) then
      text = text:gsub("\n", "⏎")
    end
    return (checked[i] and "[x] " or "[ ] ") .. text .. " (" .. v.count .. ")"
  end
  local lines = {}
  for i = 1, #values do
    lines[i] = line(i)
    width = math.max(width, lines[i]:find("[\t\128-\255]") and vim.fn.strdisplaywidth(lines[i]) or #lines[i])
  end
  local name = target and target.name or t.h == 1 and types.trim(t.first[col] or "") or tostring(col - 1)
  local title = (" Filter: %s "):format(name)
  -- at least 1 x 1: a tiny terminal would make them 0 or less, and the float fail
  width = math.max(1, math.min(math.max(width, vim.fn.strdisplaywidth(title)), vim.o.columns - 4))
  local height = math.max(1, math.min(#values, vim.o.lines - 6))
  local pbuf = api.nvim_create_buf(false, true)
  vim.bo[pbuf].bufhidden = "wipe"
  local function put(first, last, text)
    vim.bo[pbuf].modifiable = true
    api.nvim_buf_set_lines(pbuf, first, last, false, text)
    vim.bo[pbuf].modifiable = false
  end
  put(0, -1, lines)
  local win = api.nvim_open_win(pbuf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
  })
  vim.wo[win].cursorline = true
  local function close()
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
  end
  local function map(keys, fn)
    vim.keymap.set("n", keys, fn, { buffer = pbuf, nowait = true })
  end
  local function toggle()
    local i = api.nvim_win_get_cursor(win)[1]
    checked[i] = not checked[i]
    put(i - 1, i, { line(i) })
  end
  map("<Space>", toggle)
  map("<Tab>", toggle)
  map("a", function()
    local all, all_lines = not vim.tbl_contains(checked, false), {}
    for i = 1, #values do
      checked[i] = not all
      all_lines[i] = line(i)
    end
    put(0, -1, all_lines)
  end)
  map("<CR>", function()
    local allowed, all = {}, true
    for i, v in ipairs(values) do
      if checked[i] then
        allowed[v.value] = true
      else
        all = false
      end
    end
    close()
    local apply = target and target.apply or function(c, a)
      M.set(t.buf, c, a, t)
    end
    apply(col, not all and allowed or nil)
  end)
  map("q", close)
  map("<Esc>", close)
end

return M
