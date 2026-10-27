-- HTTP + SSE server on vim.uv, bound to 127.0.0.1. Every path starts with a
-- random token (/TOKEN/...); any other path is a 404. The server only parses
-- requests: handle(path, buf, query) runs in vim.schedule (never nvim_* in a uv
-- callback) and answers status, content type, body. status 200 with the type
-- "sse" keeps the connection open for broadcast(buf).
local uv = vim.uv

local M = {}

local REASON = {
  [200] = "OK",
  [404] = "Not Found",
  [405] = "Method Not Allowed",
  [431] = "Request Header Fields Too Large",
  [500] = "Internal Server Error",
}
local MAX_REQUEST = 16384
local SSE_HEAD = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: keep-alive\r\n\r\n: csvkit\n\n"

local s -- the running server: { tcp, port, token, handle, clients = { buf -> { sock -> true } } }

local function close(sock)
  if not sock:is_closing() then
    sock:close()
  end
end

local function respond(sock, status, ctype, body)
  if sock:is_closing() then
    return
  end
  local head = ("HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"):format(
    status,
    REASON[status],
    ctype,
    #body
  )
  sock:write({ head, body }, function()
    close(sock)
  end)
end

local function add_client(sock, buf)
  s.clients[buf] = s.clients[buf] or {}
  s.clients[buf][sock] = true
  sock:write(SSE_HEAD)
  sock:read_start(function(err, chunk) -- only to notice that the client left
    if err or not chunk then
      s.clients[buf][sock] = nil
      close(sock)
    end
  end)
end

local function dispatch(sock, head)
  local method, target = head:match("^(%u+) (%S+) HTTP/1%.[01]")
  if method ~= "GET" then
    return respond(sock, method and 405 or 404, "text/plain", "")
  end
  local path, query = target:match("^([^?]*)%??(.*)$")
  local rest = path:match("^/" .. s.token .. "(/.*)$")
  if not rest then
    return respond(sock, 404, "text/plain", "")
  end
  local buf = tonumber(query:match("buf=(%d+)"))
  vim.schedule(function()
    if not s or sock:is_closing() then
      return
    end
    -- an error is answered with its message: unanswered, the page would wait forever
    local ok, status, ctype, body = pcall(s.handle, rest, buf, query)
    if not ok then
      status, ctype, body = 500, "text/plain; charset=utf-8", (tostring(status):gsub("^csvkit: ", ""))
    end
    if ctype == "sse" then
      add_client(sock, buf)
    else
      respond(sock, status, ctype, body)
    end
  end)
end

local function serve(sock)
  local request = ""
  sock:read_start(function(err, chunk)
    if err or not chunk then
      return close(sock)
    end
    request = request .. chunk
    local stop = request:find("\r\n\r\n", 1, true)
    if stop or #request > MAX_REQUEST then
      sock:read_stop()
      if not s then
        close(sock)
      elseif stop then
        dispatch(sock, request:sub(1, stop - 1))
      else
        respond(sock, 431, "text/plain", "")
      end
    end
  end)
end

local function random_token()
  return (uv.random(16):gsub(".", function(c)
    return ("%02x"):format(c:byte())
  end))
end

-- Starts the server unless it runs: o = { port (0 = any free port), handle }.
-- Returns the port.
function M.start(o)
  if s then
    return s.port
  end
  local tcp = uv.new_tcp()
  local ok, err = tcp:bind("127.0.0.1", o.port or 0)
  if ok then
    ok, err = tcp:listen(128, function(lerr)
      if not lerr then
        local sock = uv.new_tcp()
        tcp:accept(sock)
        serve(sock)
      end
    end)
  end
  if not ok then
    tcp:close()
    error(("csvkit: can't listen on port %d: %s"):format(o.port or 0, err), 0)
  end
  s = { tcp = tcp, port = tcp:getsockname().port, token = random_token(), handle = o.handle, clients = {} }
  return s.port
end

-- "http://127.0.0.1:PORT/TOKEN", or nil when the server is not running.
function M.base()
  return s and ("http://127.0.0.1:%d/%s"):format(s.port, s.token)
end

-- Sends "changed" to the event streams of buf.
function M.broadcast(buf)
  for sock in pairs(s and s.clients[buf] or {}) do
    if sock:is_closing() then
      s.clients[buf][sock] = nil
    else
      sock:write("event: changed\ndata: 1\n\n")
    end
  end
end

-- Sends "closed" to the event streams of buf, then closes them.
function M.drop(buf)
  for sock in pairs(s and s.clients[buf] or {}) do
    if not sock:is_closing() then
      sock:write("event: closed\ndata: 1\n\n", function()
        close(sock)
      end)
    end
  end
  if s then
    s.clients[buf] = nil
  end
end

-- Closes the clients and the port.
function M.stop()
  if not s then
    return
  end
  for buf in pairs(s.clients) do
    M.drop(buf)
  end
  close(s.tcp)
  s = nil
end

return M
