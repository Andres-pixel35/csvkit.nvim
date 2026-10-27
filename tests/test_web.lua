-- The browser page (web/index.html): its pure logic runs under node, and the
-- page may only talk to the plugin's server.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local function page()
  local f = assert(io.open(root .. "/web/index.html", "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

return {
  ["page logic: sort and filter (node)"] = function()
    if vim.fn.executable("node") == 0 then
      return -- skipped without node
    end
    local logic = assert(page():match('<script id="logic">(.-)</script>'), "no <script id=logic>")
    local path = vim.fn.tempname() .. ".js"
    vim.fn.writefile(vim.split(logic, "\n"), path)
    local out = vim.fn.system({ "node", root .. "/tests/web_logic.js", path })
    assert(vim.v.shell_error == 0, out)
  end,

  ["page makes no request outside the server"] = function()
    local html = page()
    assert(not html:find("https?://"), "absolute URL in the page")
    assert(not html:find("//cdn"), "CDN reference")
    assert(html:find("EventSource%(", 1), "no event stream")
    assert(html:find("fetch%(", 1), "no data fetch")
    assert(html:find("prefers%-color%-scheme"), "no dark theme")
  end,
}
