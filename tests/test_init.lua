local csvkit = require("csvkit")

local function buf_with(lines, name)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  if name then
    vim.api.nvim_buf_set_name(buf, name)
  end
  return buf
end

local function store_path()
  return vim.fn.stdpath("data") .. "/csvkit/files.json"
end

return {
  ["defaults and setup"] = function()
    local buf = buf_with({})
    eq(csvkit.get_opts(buf).decimal, ".")
    eq(csvkit.get_opts(buf).align.separator, "│")
    -- day first, as written in Spanish; ISO stays first (the output format)
    eq(csvkit.get_opts(buf).date_formats[1], "%Y-%m-%d")
    eq(require("csvkit.types").typeof("31/12/2024", csvkit.get_opts(buf)), "date")
    csvkit.setup({ decimal = ",", align = { enabled = false }, date_formats = { "%d/%m/%Y" } })
    local o = csvkit.get_opts(buf)
    csvkit.setup({})
    eq(o.decimal, ",")
    eq(o.align, { enabled = false, separator = "│", sticky_header = true })
    eq(o.date_formats, { "%d/%m/%Y" }) -- lists replace, never merge
    eq(csvkit.get_opts(buf).decimal, ".")
  end,

  ["per-buffer override"] = function()
    local a, b = buf_with({}), buf_with({})
    vim.b[a].csvkit = { decimal = ",", thousands = "." }
    eq(csvkit.get_opts(a).decimal, ",")
    eq(csvkit.get_opts(a).thousands, ".")
    eq(csvkit.get_opts(b).decimal, ".")
    vim.api.nvim_set_current_buf(a)
    eq(csvkit.get_opts().decimal, ",")
  end,

  ["auto settings are detected from the buffer"] = function()
    local buf = buf_with({ "name;price;qty", "a;1,5;2", "b;2.345,75;3" })
    local o = csvkit.get_opts(buf)
    eq({ o.delimiter, o.decimal, o.thousands }, { ";", ",", "." })
    -- the header row is not evidence
    buf = buf_with({ "1.5;2.5", "1,5;2,5" })
    eq(csvkit.get_opts(buf).decimal, ",")
    -- explicit settings are kept as they are
    vim.b[buf].csvkit = { delimiter = ",", decimal = "." }
    o = csvkit.get_opts(buf)
    eq({ o.delimiter, o.decimal }, { ",", "." })
  end,

  ["detection follows edits"] = function()
    local buf = buf_with({ "a,b", "1.5,2" })
    eq(csvkit.get_opts(buf).decimal, ".")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a;b", "1,5;2" })
    eq(csvkit.get_opts(buf).decimal, ",")
  end,

  ["detection runs once per change of the text"] = function()
    local csv = require("csvkit.csv")
    local detect, calls = csv.detect_delimiter, 0
    csv.detect_delimiter = function(...)
      calls = calls + 1
      return detect(...)
    end
    local a = buf_with({ "a;b", "1,5;2" })
    local b = buf_with({ "a,b", "1.5,2" })
    local ok, err = pcall(function()
      csvkit.get_opts(a)
      csvkit.get_opts(a)
      eq(calls, 1)
      vim.api.nvim_buf_set_lines(a, 0, -1, false, { "a,b", "1.5,2" })
      eq(csvkit.get_opts(a).delimiter, ",")
      eq(calls, 2)
      -- no buffer given: the current one, never the last one detected
      vim.api.nvim_set_current_buf(b)
      eq(csvkit.get_opts().delimiter, ",")
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { "a;b", "1,5;2" })
      eq(csvkit.get_opts(0).delimiter, ";")
    end)
    csv.detect_delimiter = detect
    assert(ok, err)
  end,

  ["remember is per file and survives a restart"] = function()
    local name = vim.fn.tempname() .. ".csv"
    local buf = buf_with({ "a,b", "1.5,2" }, name)
    local other = buf_with({ "a,b", "1.5,2" }, vim.fn.tempname() .. ".csv")
    csvkit.remember(buf, { decimal = ",", thousands = false })
    eq(csvkit.get_opts(buf).decimal, ",")
    eq(csvkit.get_opts(buf).thousands, false)
    eq(csvkit.get_opts(other).decimal, ".")
    eq(vim.json.decode(table.concat(vim.fn.readfile(store_path()), "\n"))[name], { decimal = ",", thousands = false })

    package.loaded["csvkit"] = nil -- a fresh module reads the store from disk
    local fresh = require("csvkit")
    package.loaded["csvkit"] = csvkit
    eq(fresh.get_opts(buf).decimal, ",")

    vim.b[buf].csvkit = { decimal = "." } -- vim.b beats the store
    eq(csvkit.get_opts(buf).decimal, ".")
    vim.b[buf].csvkit = nil

    csvkit.remember(buf, { decimal = "auto" }) -- back to detection
    eq(csvkit.get_opts(buf).decimal, ".")
    eq(csvkit.get_opts(buf).thousands, false)
  end,

  ["remember keeps entries written by another instance"] = function()
    local mine, theirs = vim.fn.tempname() .. ".csv", vim.fn.tempname() .. ".csv"
    local buf = buf_with({}, mine)
    csvkit.remember(buf, { decimal = "." }) -- loads the store into this instance
    local store = vim.json.decode(table.concat(vim.fn.readfile(store_path()), "\n"))
    store[theirs] = { decimal = "," }
    vim.fn.writefile({ vim.json.encode(store) }, store_path())
    csvkit.remember(buf, { decimal = "," })
    store = vim.json.decode(table.concat(vim.fn.readfile(store_path()), "\n"))
    eq(store[theirs], { decimal = "," })
    eq(store[mine], { decimal = "," })
  end,

  ["a damaged store counts as empty"] = function()
    local name = vim.fn.tempname() .. ".csv"
    vim.fn.mkdir(vim.fs.dirname(store_path()), "p")
    for _, text in ipairs({ "1", '"x"', vim.json.encode({ [name] = 5 }) }) do
      vim.fn.writefile({ text }, store_path())
      package.loaded["csvkit"] = nil
      local fresh = require("csvkit")
      package.loaded["csvkit"] = csvkit
      eq(fresh.get_opts(buf_with({ "a,b", "1.5,2" }, name)).decimal, ".")
      vim.cmd("bwipeout! " .. vim.fn.bufnr(name))
    end
    vim.fn.writefile({ "{}" }, store_path())
  end,

  ["remember needs a file name"] = function()
    local ok, err = pcall(csvkit.remember, buf_with({}), { decimal = "," })
    assert(not ok and err:find("no file name", 1, true), err)
  end,

  ["remember reports a data folder that can't be written"] = function()
    local data, dir = vim.env.XDG_DATA_HOME, vim.fn.tempname()
    vim.fn.mkdir(dir)
    vim.uv.fs_chmod(dir, tonumber("555", 8))
    vim.env.XDG_DATA_HOME = dir
    local file = vim.fn.tempname() .. ".csv"
    local buf = buf_with({ "a,b" }, file)
    local ok, err = pcall(csvkit.remember, buf, { decimal = "," })
    vim.env.XDG_DATA_HOME = data
    vim.uv.fs_chmod(dir, tonumber("755", 8))
    eq(ok, false)
    assert(vim.startswith(err, "csvkit: can't save the options of " .. file .. ": "), err)
    assert(not err:find("stack traceback", 1, true), err)
  end,
}
