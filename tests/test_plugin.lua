-- plugin/csvkit.lua, setup() and attach().
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

-- Starts a fresh `nvim --clean` with the repo on 'runtimepath' (so
-- plugin/csvkit.lua loads as for a user), edits file, runs the Lua chunk code,
-- and returns what it writes to stdout.
local function nvim(file, code)
  local r = vim.system({
    vim.v.progpath, "--headless", "--clean", "--cmd", "set rtp^=" .. root,
    "-c", "lua " .. code, "-c", "qa!", file,
  }):wait()
  assert(r.code == 0, r.stderr)
  return r.stdout
end

local REPORT = [[io.stdout:write(vim.inspect({ csvkit = package.loaded.csvkit ~= nil,
  formula = package.loaded["csvkit.formula"] ~= nil, attached = vim.b.csvkit_attached,
  command = vim.fn.exists(":Csvkit") }))]]

return {
  ["a .csv is attached without loading the formula engine"] = function()
    local out = nvim(root .. "/tests/fixtures/simple.csv", REPORT)
    eq(out, vim.inspect({ csvkit = true, formula = false, attached = true, command = 2 }))
  end,

  ["a .txt loads nothing"] = function()
    local out = nvim(vim.fn.tempname() .. ".txt", REPORT)
    eq(out, vim.inspect({ csvkit = false, formula = false, command = 2 }))
  end,

  ["the plugin file loads once"] = function()
    local out = nvim(vim.fn.tempname() .. ".txt", [[
      vim.cmd.runtime("plugin/csvkit.lua")
      io.stdout:write(#vim.api.nvim_get_autocmds({ group = "csvkit" }))]])
    eq(out, "2") -- BufReadPost + BufNewFile, not doubled
  end,

  ["setup attaches open buffers and follows extensions"] = function()
    local csvkit = require("csvkit")
    local tsv = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(tsv, vim.fn.tempname() .. ".tsv")
    local unloaded = vim.fn.bufadd(vim.fn.tempname() .. ".tsv") -- listed, not loaded
    csvkit.setup({ extensions = { "tsv" } })
    eq(vim.b[tsv].csvkit_attached, true)
    eq(vim.b[unloaded].csvkit_attached, nil)

    vim.cmd.edit(vim.fn.tempname() .. ".tsv")
    eq(vim.b.csvkit_attached, true)
    vim.cmd.edit(vim.fn.tempname() .. ".csv")
    eq(vim.b.csvkit_attached, nil)

    csvkit.setup({})
    vim.cmd.edit(vim.fn.tempname() .. ".csv")
    eq(vim.b.csvkit_attached, true)
    vim.cmd.edit(vim.fn.tempname() .. ".tsv")
    eq(vim.b.csvkit_attached, nil)
  end,
}
