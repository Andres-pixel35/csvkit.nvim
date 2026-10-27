-- Browser preview: the buffer as a JSON payload, change notification and the
-- lifecycle of the one server shared by all previewed buffers (server.lua).
local csv = require("csvkit.csv")
local csvkit = require("csvkit")
local edit = require("csvkit.edit")
local server = require("csvkit.server")
local types = require("csvkit.types")

local M = {}

M.states = {} -- buf -> { timer, debounce, max_bytes }; the previewed buffers

-- The browser's sort key of a date cell, from the same parsing the sort uses.
local function date_key(s, opts)
  local d = types.parse_date(s, opts)
  return d and d.day
end

-- The keys of a column whose non-empty cells are all numbers (what
-- infer_column calls a number column), else nil: the type and the keys from
-- one parse of each cell.
local function number_keys(cells, opts)
  local keys, found = {}, false
  for i, s in ipairs(cells) do
    local v = types.parse_number(s, opts)
    if v then
      keys[i], found = v, true
    elseif types.trim(s) == "" then
      keys[i] = vim.NIL
    else
      return nil
    end
  end
  return found and keys or nil
end

-- { name, delimiter, n = the number of data rows, cols = { {name, type} },
-- cells = { {each row's cell} per column } ("" where a row is shorter),
-- line_of = { buffer line of each row } only when a record spans lines (else
-- row i is on line first_line + i - 1), keys = { ["col"] = { number or null
-- per row } } for number and date columns, max_width = view.max_col_width
-- (nil: none) }. By column: one list per column
-- instead of one per row, in Lua and in the browser.
function M.payload(buf)
  local opts = csvkit.get_opts(buf)
  local t = csv.index(vim.api.nvim_buf_get_lines(buf, 0, -1, false), opts.delimiter)
  local h = opts.header and 1 or 0
  local head = h == 1 and #t.line_of > 0 and csv.record(t, 1) or {}
  local n = math.max(#t.line_of - h, 0)
  local p = {
    name = vim.fs.basename(vim.api.nvim_buf_get_name(buf)),
    delimiter = opts.delimiter,
    n = n,
    cols = {},
    cells = csv.columns(t, 1 + h),
    keys = vim.empty_dict(),
    max_width = csvkit.max_col_width(opts),
  }
  if (t.line_of[#t.line_of] or 0) == #t.line_of then -- one line per record
    p.first_line = h + 1
  else
    p.line_of = vim.list_slice(t.line_of, 1 + h)
  end
  for c = 1, math.max(#head, #p.cells) do
    local cells = p.cells[c]
    if not cells then -- a header name past every row's last field
      cells = {}
      for i = 1, n do
        cells[i] = ""
      end
      p.cells[c] = cells
    end
    local keys = number_keys(cells, opts)
    local kind = keys and "number" or types.infer_column(cells, opts)
    if kind == "date" then
      keys = {}
      for i, cell in ipairs(cells) do
        keys[i] = date_key(cell, opts) or vim.NIL
      end
    end
    p.cols[c] = { name = head[c] or tostring(c - 1), type = kind }
    p.keys[tostring(c)] = keys
  end
  return p
end

-- The page's filter expression expr on buf: { n, mask = "1" or "0" per data
-- row, whether expr is TRUE there } (filter.where's rules), or { error }.
-- Errors are answered, not raised: the page must get a response.
function M.match(buf, expr)
  local ok, t = pcall(edit.read, buf)
  local pass, err
  if ok then
    ok, pass, err = pcall(edit.formula_matches, t, expr)
  end
  if not ok then
    return { error = (tostring(pass or t):gsub("^csvkit: ", "")) }
  elseif err then
    return { error = "filter: " .. err }
  end
  local mask = {}
  for i = 1, t.n do
    mask[i] = pass[i] and "1" or "0"
  end
  return { n = t.n, mask = table.concat(mask) }
end

-- This plugin's own page: the first web/index.html on 'runtimepath' may be
-- another plugin's, and it would run with the token.
local PAGE = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h") .. "/web/index.html"

local function index_html()
  local f = io.open(PAGE, "rb")
  if not f then
    return 404, "text/plain", "web/index.html not found"
  end
  local body = f:read("*a")
  f:close()
  return 200, "text/html; charset=utf-8", body
end

-- server's handle: / is the page, /data the payload, /match?q= a filter
-- expression's rows, /events the stream.
local function handle(path, buf, query)
  if path == "/" then
    return index_html()
  elseif not (buf and M.states[buf] and vim.api.nvim_buf_is_valid(buf)) then
    return 404, "text/plain", "this buffer is no longer previewed"
  elseif path == "/data" then
    return 200, "application/json", vim.json.encode(M.payload(buf))
  elseif path == "/match" then
    local q = ("&" .. query):match("&q=([^&]*)") or ""
    return 200, "application/json", vim.json.encode(M.match(buf, vim.uri_decode(q)))
  elseif path == "/events" then
    return 200, "sse"
  end
  return 404, "text/plain", ""
end

-- Over live_update_max_mb the preview follows saves only.
local function big(buf, st)
  return st.max_bytes ~= nil
    and vim.api.nvim_buf_get_offset(buf, vim.api.nvim_buf_line_count(buf)) > st.max_bytes
end

local function watch(buf, st)
  local function changed()
    if M.states[buf] ~= st then
      return true -- detach
    end
    if not big(buf, st) then
      st.timer:start(st.debounce, 0, function() -- a new change restarts the wait
        vim.schedule(function()
          if M.states[buf] == st then
            server.broadcast(buf)
          end
        end)
      end)
    end
  end
  st.attached = true
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = changed,
    on_reload = changed,
    on_detach = function() -- :e! or an unload; BufReadPost watches again
      st.attached = false
    end,
  })
end

local function forget(buf)
  local st = M.states[buf]
  if st then
    st.timer:stop()
    st.timer:close()
    M.states[buf] = nil
  end
  server.drop(buf)
end

-- Stops the server and forgets every buffer.
function M.stop()
  for buf in pairs(M.states) do
    forget(buf)
  end
  server.stop()
  pcall(vim.api.nvim_del_augroup_by_name, "csvkit_preview")
end

local function autocmds()
  local group = vim.api.nvim_create_augroup("csvkit_preview", {})
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(a)
      forget(a.buf)
      if not next(M.states) then
        M.stop()
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = group,
    callback = function(a)
      local st = M.states[a.buf]
      if st and not st.attached then
        watch(a.buf, st)
        server.broadcast(a.buf) -- the reload may have changed every line
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(a)
      local st = M.states[a.buf]
      if st and big(a.buf, st) then
        server.broadcast(a.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = M.stop })
end

-- Starts the server if needed, previews buf (0 = current; a :Csvkit view
-- buffer previews its source) and opens the page in the browser. Returns the URL.
function M.start(buf)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local view = require("csvkit.view").states[buf]
  buf = view and view.src or buf
  local opts = csvkit.get_opts(buf)
  csvkit.max_col_width(opts) -- a bad value is reported now, not by every page load
  local o = opts.preview
  local fresh = not server.base()
  server.start({ port = o.port, handle = handle })
  if fresh then
    autocmds()
  end
  if not M.states[buf] then
    local st = {
      timer = vim.uv.new_timer(),
      debounce = o.debounce_ms,
      max_bytes = o.live_update_max_mb and o.live_update_max_mb * 1024 * 1024,
    }
    M.states[buf] = st
    watch(buf, st)
  end
  local url = ("%s/?buf=%d"):format(server.base(), buf)
  vim.notify("csvkit: preview at " .. url)
  vim.ui.open(url)
  return url
end

return M
