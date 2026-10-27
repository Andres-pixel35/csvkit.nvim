-- :Csvkit stats: the figures of one column over the rows shown, in a float.
-- <CR> copies the value on the cursor's line to the clipboard.
local filter = require("csvkit.filter")
local types = require("csvkit.types")

local M = {}

local api = vim.api

-- A value as a line of the float shows it.
local function shown(v)
  return v == "" and "(empty)" or (v:gsub("\n", "⏎"))
end

-- The column types a figure needs, for the figures that do not fit every column.
local NEEDS = {
  min = "number or date",
  max = "number or date",
  largest = "number or date",
  smallest = "number or date",
  sum = "number",
  average = "number",
  oldest = "date",
  newest = "date",
}

-- Every figure a :Csvkit stats word can ask for.
M.FIGURES = { "type", "rows", "empty", "unique", "common", "min", "max", "oldest", "newest", "sum", "average", "largest", "smallest", "values" }

-- The float's lines for cells (one column's): { text, value <CR> copies (nil:
-- none) }. Numbers and dates also get min, max and their spec.n largest and
-- smallest; numbers the sum and average. Every value is listed with its count.
-- spec.only (a set of FIGURES) keeps just those; a figure the column's type
-- has not raises.
function M.entries(cells, opts, spec)
  local out, filled, n, only = {}, {}, spec.n, spec.only
  local function add(key, text, copy)
    if not only or only[key] then
      out[#out + 1] = { text, copy }
    end
  end
  local function figure(key, label, value, copy)
    add(key, ("%-12s %s"):format(label, shown(value)), copy or value)
  end
  for _, cell in ipairs(cells) do
    cell = types.trim(cell)
    if cell ~= "" then
      filled[#filled + 1] = cell
    end
  end
  local counts, kind = filter.counts(cells), types.infer_column(filled, opts)
  if only then
    for f in pairs(only) do
      if NEEDS[f] and not NEEDS[f]:find(kind, 1, true) then
        error(("csvkit: stats: %s needs a %s column, and this one is %s"):format(f, NEEDS[f], kind), 0)
      end
    end
    -- a date column's min and max are its oldest and newest
    only = vim.tbl_extend("force", only, { min = only.min or only.oldest, max = only.max or only.newest })
  end
  local values = vim.tbl_filter(function(v)
    return v.value ~= ""
  end, counts)
  figure("type", "type", kind)
  figure("rows", "rows", tostring(#cells))
  figure("empty", "empty", tostring(#cells - #filled))
  figure("unique", "unique", tostring(#values))
  if values[1] then
    local count = values[1].count
    local text = ("%s (%d time%s)"):format(shown(values[1].value), count, count == 1 and "" or "s")
    figure("common", "most common", text, values[1].value)
  end
  local sorted -- { key, text } of the filled cells, smallest first
  if kind == "number" or kind == "date" then
    sorted = {}
    for i, s in ipairs(filled) do
      sorted[i] = { kind == "number" and types.parse_number(s, opts) or types.parse_date(s, opts).day, s }
    end
    table.sort(sorted, function(a, b)
      return a[1] < b[1]
    end)
    local low, high = kind == "date" and "oldest" or "min", kind == "date" and "newest" or "max"
    figure("min", low, sorted[1][2])
    figure("max", high, sorted[#sorted][2])
    if kind == "number" then
      local sum = 0
      for _, k in ipairs(sorted) do
        sum = sum + k[1]
      end
      figure("sum", "sum", types.format_value(sum, opts))
      figure("average", "average", types.format_value(sum / #sorted, opts))
    end
    add(nil, "")
    add("largest", ("%s %d"):format(high == "max" and "largest" or high, n))
    for k = #sorted, math.max(1, #sorted - n + 1), -1 do
      add("largest", "  " .. sorted[k][2], sorted[k][2])
    end
    add("smallest", ("%s %d"):format(low == "min" and "smallest" or low, n))
    for k = 1, math.min(n, #sorted) do
      add("smallest", "  " .. sorted[k][2], sorted[k][2])
    end
  end
  add(nil, "")
  add("values", "values")
  -- the counts come most first; the header says which column is which
  local width = math.max(5, counts[1] and #tostring(counts[1].count) or 0)
  add("values", ("  %" .. width .. "s  %s"):format("count", "value"))
  for _, v in ipairs(counts) do
    add("values", ("  %" .. width .. "d  %s"):format(v.count, shown(v.value)), v.value)
  end
  return out
end

-- Opens the float of entries titled with the column's name; <CR> copies the
-- value of a line to the unnamed register and the clipboard and closes it.
function M.open(name, entries)
  local lines, width = {}, 0
  for i, e in ipairs(entries) do
    lines[i] = e[1]
    width = math.max(width, vim.fn.strdisplaywidth(e[1]))
  end
  local title = (" Stats: %s "):format(name)
  -- at least 1 x 1: a tiny terminal would make them 0 or less, and the float fail
  width = math.max(1, math.min(math.max(width, vim.fn.strdisplaywidth(title)), vim.o.columns - 4))
  local height = math.max(1, math.min(#lines, vim.o.lines - 6))
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local win = api.nvim_open_win(buf, true, {
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
    vim.keymap.set("n", keys, fn, { buffer = buf, nowait = true })
  end
  map("<CR>", function()
    local value = entries[api.nvim_win_get_cursor(win)[1]][2]
    if not value then
      return
    end
    vim.fn.setreg('"', value)
    if vim.fn.has("clipboard") == 1 then
      vim.fn.setreg("+", value)
    end
    close()
    vim.notify(("csvkit: copied %s"):format(shown(value)), vim.log.levels.INFO)
  end)
  map("q", close)
  map("<Esc>", close)
  return win
end

return M
