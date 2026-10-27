-- Preview server and payload (server.lua, preview.lua).
vim.cmd.runtime("plugin/csvkit.lua")
local preview = require("csvkit.preview")
local server = require("csvkit.server")

local PEOPLE = {
  "name,city,age,born",
  "Ana,Bogota,30,2000-01-05", -- 2
  "Luis,Madrid,,1999-12-31", -- 3
  "Mia,Paris,9,2010-06-30", -- 4
}

local opened -- URLs given to vim.ui.open
vim.ui.open = function(url)
  opened[#opened + 1] = url
end

-- A fresh buffer holding lines, previewed with preview options o. Returns the buffer.
local function open(lines, o)
  preview.stop()
  opened = {}
  require("csvkit").setup({ preview = o or { debounce_ms = 20 } })
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  preview.start(buf)
  return buf
end

local function port()
  return tonumber(server.base():match(":(%d+)/"))
end

-- A connected client; sock:data is everything received, sock:eof when the
-- server closed it.
local function connect(path)
  local sock = vim.uv.new_tcp()
  local c = { data = "", eof = false, sock = sock }
  local done, err
  sock:connect("127.0.0.1", port(), function(e)
    err = e or false
    if not e then
      sock:read_start(function(_, chunk)
        if chunk then
          c.data = c.data .. chunk
        else
          c.eof = true
        end
      end)
      sock:write(("GET %s HTTP/1.1\r\nHost: x\r\n\r\n"):format(path))
    end
  end)
  vim.wait(2000, function()
    return err ~= nil
  end)
  assert(err == false, "connect failed: " .. tostring(err))
  return c
end

-- GET path; returns the status and the body.
local function get(path)
  local c = connect(path)
  vim.wait(2000, function()
    return c.eof
  end)
  c.sock:close()
  return tonumber(c.data:match("^HTTP/1.1 (%d+)")), c.data:match("\r\n\r\n(.*)$")
end

local function wait_for(c, text)
  return vim.wait(1000, function()
    return c.data:find(text, 1, true) ~= nil
  end)
end

local function path_of(buf, rest)
  return server.base():match("^http://[^/]+(.*)$") .. rest .. "?buf=" .. buf
end

return {
  ["payload: columns, types, rows, lines and sort keys"] = function()
    local buf = open(PEOPLE)
    local p = preview.payload(buf)
    eq(p.delimiter, ",")
    eq(p.cols, {
      { name = "name", type = "string" },
      { name = "city", type = "string" },
      { name = "age", type = "number" },
      { name = "born", type = "date" },
    })
    eq({ p.cells[1][2], p.cells[2][2], p.cells[3][2], p.cells[4][2] }, { "Luis", "Madrid", "", "1999-12-31" })
    eq({ p.n, #p.cells[1] }, { 3, 3 })
    eq({ p.first_line, p.line_of }, { 2, nil }) -- one line per record: no list
    eq(p.keys["3"], { 30, vim.NIL, 9 })
    eq(p.keys["4"][1] < p.keys["4"][3], true)
    eq(p.keys["1"], nil)
  end,

  ["payload: no header, multiline records and ragged rows"] = function()
    local buf = open({ '"a', 'b",1', "x,2,3", "", "y" })
    vim.b[buf].csvkit = { header = false }
    local p = preview.payload(buf)
    eq(p.cols[3], { name = "2", type = "number" })
    eq(p.cells, { { "a\nb", "x", "", "y" }, { "1", "2", "", "" }, { "", "3", "", "" } })
    eq({ p.n, p.line_of, p.first_line }, { 4, { 1, 3, 4, 5 }, nil })
  end,

  ["payload: a header name past every row's fields gets a blank column"] = function()
    local buf = open({ "a,b,c", "1", "2,x" })
    local p = preview.payload(buf)
    eq(p.cells, { { "1", "2" }, { "", "x" }, { "", "" } })
    eq(p.cols[3], { name = "c", type = "string" })
  end,

  ["payload: types and keys are infer_column's and the sort's parse (random)"] = function()
    local types = require("csvkit.types")
    math.randomseed(9)
    local words = { "1", " 2.5 ", "-3", "", "  ", "x", "2024-01-31", "true", "1e3", "0x10", "7." }
    for _ = 1, 40 do
      local lines = { "a,b,c" }
      for r = 1, math.random(1, 12) do
        local row = {}
        for c = 1, 3 do
          row[c] = words[math.random(#words)]
          if math.random(3) == 1 then -- a column of one kind
            row[c] = words[(r % 3) + 1]
          end
        end
        lines[#lines + 1] = table.concat(row, ",")
      end
      local buf = open(lines)
      local p = preview.payload(buf)
      local opts = require("csvkit").get_opts(buf)
      for c = 1, 3 do
        local kind = types.infer_column(p.cells[c], opts)
        eq(p.cols[c].type, kind)
        local want = nil
        if kind == "number" or kind == "date" then
          want = {}
          for i, s in ipairs(p.cells[c]) do
            local v = kind == "number" and types.parse_number(s, opts) or types.parse_date(s, opts)
            want[i] = v and (kind == "date" and v.day or v) or vim.NIL
          end
        end
        eq(p.keys[tostring(c)], want)
      end
    end
  end,

  ["payload: an empty buffer"] = function()
    local buf = open({ "" })
    local p = preview.payload(buf)
    eq({ p.cols, p.cells, p.n }, { {}, {}, 0 })
  end,

  ["/data returns the payload as JSON"] = function()
    local buf = open(PEOPLE)
    local status, body = get(path_of(buf, "/data"))
    eq(status, 200)
    local d = vim.json.decode(body)
    eq({ d.cells[1][3], d.cells[2][3], d.cells[3][3], d.cells[4][3], d.n }, { "Mia", "Paris", "9", "2010-06-30", 3 })
    eq(vim.json.decode(body).keys["3"][2], vim.NIL)
  end,

  ["payload: max_width is view.max_col_width (0, the default, is none)"] = function()
    local buf = open(PEOPLE)
    eq(require("csvkit").get_opts(buf).view.max_col_width, 0)
    eq(preview.payload(buf).max_width, nil)
    vim.b[buf].csvkit = { view = { max_col_width = 30 } }
    eq(preview.payload(buf).max_width, 30)
  end,

  ["an invalid view.max_col_width: preview refuses to start, /data answers the reason"] = function()
    local buf = open(PEOPLE)
    vim.b[buf].csvkit = { view = { max_col_width = -1 } } -- set after the preview started
    local status, body = get(path_of(buf, "/data"))
    eq(status, 500)
    assert(body:find("view.max_col_width must be 0", 1, true), body)
    preview.stop()
    local ok, err = pcall(preview.start, buf)
    eq(ok, false)
    assert(err:find("view.max_col_width must be 0", 1, true), err)
    eq(server.base(), nil) -- no server left running
  end,

  ["/match: a filter expression's mask over the data rows, or why it can't be used"] = function()
    local buf = open(PEOPLE) -- ages 30, blank, 9
    local function match(expr)
      local status, body = get(path_of(buf, "/match") .. "&q=" .. vim.uri_encode(expr, "rfc2396"))
      eq(status, 200)
      return vim.json.decode(body)
    end
    eq(match("age > 10"), { n = 3, mask = "100" }) -- the blank fails: hidden
    eq(match('OR(city = "Paris", born < DATE(2000, 1, 1))'), { n = 3, mask = "011" })
    eq(match("nope"), { error = 'unknown column "nope" at position 1' })
    eq(match("age + 1"), { error = "filter: expected TRUE or FALSE, got number" })
    eq(match("PREV(age) > 1"), { error = "PREV works in addcol and setcol, not in filters" })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
    eq(match("age > 10"), { error = "the buffer has no rows" })
  end,

  ["/ returns the page"] = function()
    local buf = open(PEOPLE)
    local status, body = get(path_of(buf, "/"))
    eq(status, 200)
    assert(body:find("<title>", 1, true))
  end,

  ["/ is csvkit's page even when another web/index.html is earlier on 'runtimepath'"] = function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/web", "p")
    vim.fn.writefile({ "not csvkit" }, dir .. "/web/index.html")
    local rtp = vim.o.runtimepath
    vim.opt.runtimepath:prepend(dir)
    local buf = open(PEOPLE)
    local _, body = get(path_of(buf, "/"))
    vim.o.runtimepath = rtp
    vim.fn.delete(dir, "rf")
    assert(body:find("<title>csvkit preview</title>", 1, true), body)
  end,

  ["a wrong token, a wrong path, an unknown buffer and a POST are refused"] = function()
    local buf = open(PEOPLE)
    eq((get("/nope/data?buf=" .. buf)), 404)
    eq((get("/" .. ("0"):rep(32) .. "/data?buf=" .. buf)), 404)
    eq((get("/data?buf=" .. buf)), 404)
    eq((get(path_of(buf, "/other"))), 404)
    eq((get(path_of(buf + 100, "/data"))), 404)
    local p = vim.uv.new_tcp()
    local resp = ""
    p:connect("127.0.0.1", port(), function()
      p:read_start(function(_, chunk)
        resp = resp .. (chunk or "")
      end)
      p:write("POST / HTTP/1.1\r\n\r\n")
    end)
    vim.wait(1000, function()
      return resp:find("405", 1, true) ~= nil
    end)
    p:close()
    assert(resp:find("405", 1, true), resp)
  end,

  ["an oversized request is refused"] = function()
    open(PEOPLE)
    local p = vim.uv.new_tcp()
    local resp = ""
    p:connect("127.0.0.1", port(), function()
      p:read_start(function(_, chunk)
        resp = resp .. (chunk or "")
      end)
      p:write("GET /" .. ("a"):rep(20000))
    end)
    vim.wait(1000, function()
      return resp:find("431", 1, true) ~= nil
    end)
    p:close()
    assert(resp:find("431", 1, true), resp)
  end,

  ["start opens the URL with the token and the buffer"] = function()
    local buf = open(PEOPLE)
    eq(opened, { ("%s/?buf=%d"):format(server.base(), buf) })
    assert(server.base():find("^http://127.0.0.1:%d+/%x+$"))
    eq(#server.base():match("/(%x+)$"), 32)
  end,

  ["an event stream gets 'changed' after an edit, once for a burst"] = function()
    local buf = open(PEOPLE)
    local c = connect(path_of(buf, "/events"))
    assert(wait_for(c, ": csvkit"), c.data)
    assert(c.data:find("text/event-stream", 1, true))
    for i = 1, 5 do
      vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "x," .. i })
    end
    assert(wait_for(c, "event: changed"), c.data)
    vim.wait(100)
    eq(select(2, c.data:gsub("event: changed", "")), 1)
    c.sock:close()
  end,

  ["after :e! the page is told, and edits after it still notify"] = function()
    preview.stop()
    opened = {}
    require("csvkit").setup({ preview = { debounce_ms = 20 } })
    local file = vim.fn.tempname() .. ".csv"
    vim.fn.writefile(PEOPLE, file)
    vim.cmd.edit(file)
    local buf = vim.api.nvim_get_current_buf()
    preview.start(buf)
    local c = connect(path_of(buf, "/events"))
    assert(wait_for(c, ": csvkit"), c.data)
    local function changes()
      return select(2, c.data:gsub("event: changed", ""))
    end
    vim.fn.writefile({ "name,city,age", "Zoe,Rome,1" }, file) -- changed outside
    vim.cmd("silent edit!") -- detaches every nvim_buf_attach of the buffer
    assert(vim.wait(2000, function()
      return changes() == 1
    end), "no notice for the reload: " .. c.data)
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "Ann,Lima,2" })
    assert(vim.wait(2000, function()
      return changes() == 2
    end), "no notice for an edit after the reload: " .. c.data)
    c.sock:close()
  end,

  ["a buffer that was not previewed has no event stream"] = function()
    local buf = open(PEOPLE)
    eq((get(path_of(buf + 100, "/events"))), 404)
  end,

  ["stop closes the port and the clients"] = function()
    local buf = open(PEOPLE)
    local c = connect(path_of(buf, "/events"))
    assert(wait_for(c, ": csvkit"))
    local n = port()
    preview.stop()
    assert(vim.wait(1000, function()
      return c.eof
    end), "client still open")
    assert(c.data:find("event: closed\n", 1, true), "no closed event")
    c.sock:close()
    local err
    local s = vim.uv.new_tcp()
    s:connect("127.0.0.1", n, function(e)
      err = e or false
    end)
    vim.wait(1000, function()
      return err ~= nil
    end)
    s:close()
    assert(err, "port still open")
    eq(server.base(), nil)
    eq(next(preview.states), nil)
  end,

  ["wiping the buffer drops its stream, the last one stops the server"] = function()
    local buf = open(PEOPLE)
    local c = connect(path_of(buf, "/events"))
    assert(wait_for(c, ": csvkit"))
    vim.api.nvim_buf_delete(buf, { force = true })
    assert(vim.wait(1000, function()
      return c.eof
    end), "client still open")
    assert(c.data:find("event: closed\n", 1, true), "no closed event")
    c.sock:close()
    eq(server.base(), nil)
  end,

  ["one server serves two buffers; wiping one keeps the other"] = function()
    local a = open(PEOPLE)
    local base = server.base()
    local b = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "x,y", "1,2" })
    preview.start(b)
    eq(server.base(), base)
    vim.api.nvim_buf_delete(a, { force = true })
    eq(server.base(), base)
    eq({ get(path_of(a, "/data")) }, { 404, "this buffer is no longer previewed" })
    eq((get(path_of(b, "/data"))), 200)
  end,

  ["big-file mode: no notice on edit, one on write"] = function()
    local buf = open(PEOPLE, { debounce_ms = 20, live_update_max_mb = 0.00001 }) -- 10 bytes
    local file = vim.fn.tempname() .. ".csv"
    vim.api.nvim_buf_set_name(buf, file)
    local c = connect(path_of(buf, "/events"))
    assert(wait_for(c, ": csvkit"))
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "z,z,1,2020-01-01" })
    vim.wait(200)
    assert(not c.data:find("changed", 1, true), c.data)
    vim.cmd("silent write")
    assert(wait_for(c, "event: changed"), c.data)
    c.sock:close()
    vim.fn.delete(file)
  end,

  ["a small file under the limit still notifies on edit and not on write"] = function()
    local buf = open(PEOPLE, { debounce_ms = 20, live_update_max_mb = 5 })
    local file = vim.fn.tempname() .. ".csv"
    vim.api.nvim_buf_set_name(buf, file)
    local c = connect(path_of(buf, "/events"))
    assert(wait_for(c, ": csvkit"))
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "z,z,1,2020-01-01" })
    assert(wait_for(c, "event: changed"), c.data)
    vim.wait(100)
    vim.cmd("silent write")
    vim.wait(150)
    eq(select(2, c.data:gsub("event: changed", "")), 1)
    c.sock:close()
    vim.fn.delete(file)
  end,

  ["the default limit for live updates is 2 MB"] = function()
    require("csvkit").setup({})
    eq(require("csvkit").get_opts(vim.api.nvim_create_buf(true, false)).preview.live_update_max_mb, 2)
  end,

  [":Csvkit preview starts and 'preview stop' stops"] = function()
    preview.stop()
    opened = {}
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    vim.cmd("Csvkit preview")
    assert(server.base())
    eq(#opened, 1)
    local msg
    local notify = vim.notify
    vim.notify = function(m)
      msg = m
    end
    vim.cmd("Csvkit preview stop")
    eq(server.base(), nil)
    eq(msg, "csvkit: preview stopped")
    vim.cmd("Csvkit preview stop")
    eq(msg, "csvkit: no preview is running")
    vim.cmd("Csvkit preview now")
    vim.notify = notify
    eq(msg, "csvkit: usage: preview [stop]")
  end,

  ["preview from a :Csvkit view previews its source file"] = function()
    preview.stop()
    opened = {}
    local src = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(src)
    vim.api.nvim_buf_set_lines(src, 0, -1, false, PEOPLE)
    vim.cmd("Csvkit view")
    local vbuf = vim.api.nvim_get_current_buf()
    assert(vbuf ~= src)
    vim.cmd("Csvkit preview")
    eq(opened[1]:match("buf=(%d+)$"), tostring(src))
    vim.api.nvim_buf_delete(vbuf, { force = true })
  end,
}
