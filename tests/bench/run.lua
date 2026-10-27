-- Times the core stages and the commands on .bench/NxC.csv (make it with gen.lua):
--   nvim --headless --clean -l tests/bench/run.lua 1000000x10 [core | open | "<command>"]
-- core (default): every stage in one process. Each stage starts after a full GC;
--   its time includes the GC it causes. "kept" is the Lua heap its result holds.
--   A stage that fails (out of memory) prints FAILED and the run goes on with
--   what does not need its result.
-- open: only opens the buffer.
-- "<command>" (e.g. "sort price"): opens the buffer, runs :Csvkit <command> once
--   with the cursor in the middle. Run each in its own process, so the memory
--   numbers are that command's.
-- Every mode ends with the process's memory ("rss" now, "peak" = VmHWM).
-- The overlay is off here; tests/bench/overlay.lua measures it.
local root = vim.fn.fnamemodify(arg[0], ":p:h:h:h")
vim.opt.rtp:prepend(root)
local csv = require("csvkit.csv")
local csvkit = require("csvkit")
local formula = require("csvkit.formula")
local sort = require("csvkit.sort")
local types = require("csvkit.types")

local shape = arg[1] or error("usage: run.lua NxC [core | open | command]")
local mode = arg[2] or "core"
local n = tonumber(shape:match("^(%d+)x")) or error("shape must look like 1000000x10")
local path = ("%s/.bench/%s.csv"):format(root, shape)
assert(vim.fn.filereadable(path) == 1, path .. " missing; run tests/bench/gen.lua")

-- Resident memory now and at its peak, in MB, from /proc.
local function memory()
  local status = table.concat(vim.fn.readfile("/proc/self/status"), "\n")
  return tonumber(status:match("VmRSS:%s+(%d+)")) / 1024, tonumber(status:match("VmHWM:%s+(%d+)")) / 1024
end

local function report_memory()
  local rss, peak = memory()
  io.write(("MEMORY rss %.0f MB peak %.0f MB\n"):format(rss, peak))
end

local function stage(name, fn)
  collectgarbage()
  local heap = collectgarbage("count")
  local t0 = vim.uv.hrtime()
  local ok, r = pcall(fn)
  local ms = (vim.uv.hrtime() - t0) / 1e6
  if not ok then
    io.write(("%-34s %8.0f ms  FAILED: %s\n"):format(name, ms, tostring(r):sub(1, 80)))
    collectgarbage()
    return nil
  end
  collectgarbage()
  io.write(("%-34s %8.0f ms  kept %6.1f MB\n"):format(name, ms, (collectgarbage("count") - heap) / 1024))
  return r
end

-- dmy is a date column only with %d/%m/%Y added
csvkit.setup({ date_formats = { "%Y-%m-%d", "%d/%m/%Y" }, align = { enabled = false } })
vim.o.swapfile = false
stage("open buffer (:edit)", function()
  vim.cmd("silent edit " .. vim.fn.fnameescape(path))
end)

if mode == "open" then
  collectgarbage()
  return report_memory()
elseif mode ~= "core" then
  -- the commands as a user runs them
  vim.cmd("runtime plugin/csvkit.lua")
  vim.notify = function() end -- the formula warns about the empty qty cells
  collectgarbage()
  local before = memory()
  io.write(("rss after open %.0f MB\n"):format(before))
  vim.api.nvim_win_set_cursor(0, { math.floor(n / 2), 0 })
  stage(":Csvkit " .. mode, function()
    vim.cmd("Csvkit " .. mode)
  end)
  return report_memory()
end

local lines = stage("nvim_buf_get_lines", function()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end)
if not lines then
  return report_memory()
end
local opts = stage("get_opts (auto detect)", function()
  return csvkit.get_opts(0)
end)
stage("csv.parse (every field, as rows)", function()
  return csv.parse(lines, opts.delimiter)
end)
local t = stage("csv.index (no fields)", function()
  return csv.index(lines, opts.delimiter)
end)
local header = csv.record(t, 1)
local ncols = #header
local function col(name)
  local i = vim.fn.index(header, name) + 1
  return i > 0 and i or error("no column " .. name)
end
stage("csv.column (price, unique)", function()
  return csv.column(t, col("price"), 2)
end)
stage("csv.column (last column)", function()
  return csv.column(t, ncols, 2)
end)
local cols = stage("csv.column (all columns)", function()
  local out = {}
  for c = 1, ncols do
    out[c] = csv.column(t, c, 2)
  end
  return out
end)

-- The columns the stages below use; when all of them do not fit in memory,
-- these few are read on their own (not timed).
local needed = {}
local function cells(name)
  local c = col(name)
  needed[c] = needed[c] or (cols and cols[c]) or csv.column(t, c, 2)
  return needed[c]
end

local col_types
if cols then
  col_types = stage("infer all columns", function()
    local out = {}
    for c = 1, ncols do
      out[c] = types.infer_column(cols[c], opts)
    end
    return out
  end)
else
  stage("infer all columns (streamed)", function()
    for c = 1, ncols do
      types.infer_column(csv.column(t, c, 2), opts)
    end
  end)
end

stage("sort number (price, inferred)", function()
  return sort.sort_rows(cells("price"), {}, opts)
end)
stage("sort number (price, typed)", function()
  return sort.sort_rows(cells("price"), { type = "number" }, opts)
end)
stage("sort string (name, inferred)", function()
  return sort.sort_rows(cells("name"), {}, opts)
end)
stage("sort string (id as text, unique)", function()
  return sort.sort_rows(cells("id"), { type = "string" }, opts)
end)
stage("sort date (dmy, inferred)", function()
  return sort.sort_rows(cells("dmy"), {}, opts)
end)
cells("qty")
for _, expr in ipairs({ "price * qty + 1", "price / SUM(price)" }) do
  stage("formula " .. expr, function()
    local ast = formula.compile(expr, header)
    return formula.eval_column(ast, { cols = needed, n = #needed[col("price")], opts = opts })
  end)
end

-- the browser preview's payload, column-wise: Lua-computed sort keys for number / date columns
local payload = cols and col_types and stage("payload keys", function()
  local meta, keys = {}, {}
  for c, name in ipairs(header) do
    meta[c] = { name = name, type = col_types[c] }
    if col_types[c] == "number" or col_types[c] == "date" then
      local k = {}
      for i, s in ipairs(cols[c]) do
        local v = col_types[c] == "number" and types.parse_number(s, opts) or types.parse_date(s, opts)
        k[i] = v and (type(v) == "table" and v.day or v) or vim.NIL
      end
      keys[tostring(c)] = k
    end
  end
  return { name = path, delimiter = opts.delimiter, cols = meta, cells = cols, keys = keys, line_of = t.line_of }
end)
if payload then
  local json = stage("vim.json.encode payload", function()
    return vim.json.encode(payload)
  end)
  io.write(("  %.1f MB of JSON\n"):format(json and #json / 1e6 or 0))
  json, payload = nil, nil
else
  io.write("payload keys / json                SKIPPED (the columns do not fit in memory)\n")
end

for _, name in ipairs({ "name", "id" }) do
  stage("unique values (" .. name .. ")", function()
    local counts = {}
    for _, s in ipairs(cells(name)) do
      counts[s] = (counts[s] or 0) + 1
    end
    return counts
  end)
end
report_memory()
