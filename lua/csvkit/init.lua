-- Public entry: setup() and per-buffer options.
local csv = require("csvkit.csv")
local types = require("csvkit.types")

local M = {}

local defaults = {
  extensions = { "csv" },
  delimiter = "auto", -- "auto" | "," | ";" | "\t" | "|"
  header = true,
  decimal = "auto", -- "auto" | "." | ","
  thousands = "auto", -- "auto" | false | "," | "." | " " | "'"
  -- tried in order; the first one is also the output format for TODAY()/DATE()
  date_formats = { "%Y-%m-%d", "%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S", "%d/%m/%Y" },
  align = { enabled = true, separator = "│", sticky_header = true },
  view = { max_col_width = 0 }, -- 0: columns as wide as their widest cell; a positive whole number cuts cells with …
  preview = { port = 0, debounce_ms = 300, live_update_max_mb = 2 },
  -- mode: :Csvkit restore with no argument, "buffer" | "file"; backup = false:
  -- no copy of the file when it is opened (no I/O, but no :Csvkit restore)
  restore = { mode = "buffer", backup = true },
  memory = { trim = false }, -- true: give memory freed by big edits back to the OS (a pause of ~0.6 s at 1M rows)
  -- prev_default: PREV's value when the row it reads is empty or missing; a
  -- number, or a text read like a cell ("" = empty)
  formula = { prev_default = 0 },
}

local SAMPLE = 100 -- lines read to detect "auto" settings

local config = defaults
local store -- file path -> options remembered for it; read on first use

local function store_path()
  return vim.fn.stdpath("data") .. "/csvkit/files.json"
end

-- A missing, unreadable or damaged store is empty.
local function read_store()
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(store_path()), "\n"))
  end)
  return ok and type(data) == "table" and data or {}
end

-- buf -> { key, delimiter, decimal, thousands }: the last detection, reused
-- while the text and the settings it started from are the same (~3 ms each)
local detected = {}

-- Replaces "auto" delimiter / decimal / thousands with what the first lines of
-- buf suggest.
local function resolve_auto(o, buf)
  if o.delimiter ~= "auto" and o.decimal ~= "auto" and o.thousands ~= "auto" then
    return o
  end
  local key = ("%d|%s|%s|%s|%s"):format(vim.b[buf].changedtick, o.delimiter, o.decimal, o.thousands, o.header)
  local d = detected[buf]
  if not (d and d.key == key) then
    d = { key = key, delimiter = o.delimiter, decimal = o.decimal, thousands = o.thousands }
    local lines = vim.api.nvim_buf_get_lines(buf, 0, SAMPLE, false)
    if d.delimiter == "auto" then
      d.delimiter = csv.detect_delimiter(lines)
    end
    if d.decimal == "auto" or d.thousands == "auto" then
      local rows = csv.parse(lines, d.delimiter).rows
      d.decimal, d.thousands = types.detect_number_format(vim.list_slice(rows, o.header and 2 or 1), d)
    end
    detected[buf] = d
  end
  o.delimiter, o.decimal, o.thousands = d.delimiter, d.decimal, d.thousands
  return o
end

-- Turns csvkit on for buf: keeps a copy of its file as read when
-- restore.backup (backup.lua) and aligns it when align.enabled (overlay.lua).
function M.attach(buf)
  vim.b[buf].csvkit_attached = true
  local opts = M.get_opts(buf)
  if opts.restore.backup then
    require("csvkit.backup").save(buf)
  end
  if opts.align.enabled then
    require("csvkit.overlay").enable(buf)
  end
end

-- Optional; merges opts over the defaults (lists such as date_formats replace).
-- Rebuilds the autocmd from `extensions` and attaches the loaded buffers that
-- match, since a lazy-loading plugin manager may run setup() after the first
-- file was read.
function M.setup(opts)
  config = vim.tbl_deep_extend("force", defaults, opts or {})
  local exts = {}
  for _, ext in ipairs(config.extensions) do
    exts[ext] = true
  end
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = vim.api.nvim_create_augroup("csvkit", {}),
    pattern = vim.tbl_map(function(ext)
      return "*." .. ext
    end, config.extensions),
    callback = function(a)
      M.attach(a.buf)
    end,
  })
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and exts[vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":e")] then
      M.attach(buf)
    end
  end
end

-- The options for buf (default: current), with no "auto" left in them. Layers,
-- last wins: setup(), the options remembered for the file, vim.b[buf].csvkit.
function M.get_opts(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  store = store or read_store()
  local file = store[vim.api.nvim_buf_get_name(buf)]
  file = type(file) == "table" and file or {}
  return resolve_auto(vim.tbl_deep_extend("force", config, file, vim.b[buf].csvkit or {}), buf)
end

-- The widest a column of the table view and the browser preview may be, from
-- opts.view.max_col_width: a number of characters, or nil for no limit (0).
-- Raises unless it is 0 or a positive whole number.
function M.max_col_width(opts)
  local w = opts.view.max_col_width
  if type(w) ~= "number" or w < 0 or w % 1 ~= 0 then
    local msg = "csvkit: view.max_col_width must be 0 (no limit) or a positive whole number, not %s"
    error(msg:format(vim.inspect(w)), 0)
  end
  return w > 0 and w or nil
end

-- Remembers opts (e.g. { decimal = "," }) for buf's file across sessions;
-- "auto" goes back to detection.
function M.remember(buf, opts)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    error("csvkit: buffer has no file name", 0)
  end
  store = read_store() -- keep what other instances saved meanwhile
  store[name] = vim.tbl_extend("force", store[name] or {}, opts)
  local ok, err = pcall(function()
    vim.fn.mkdir(vim.fs.dirname(store_path()), "p")
    vim.fn.writefile({ vim.json.encode(store) }, store_path())
  end)
  if not ok then
    error(("csvkit: can't save the options of %s: %s"):format(name, err), 0)
  end
end

return M
