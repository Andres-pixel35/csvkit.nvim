-- Figures of one column for :Csvkit stats (stats.lua).
local stats = require("csvkit.stats")

local OPTS = { decimal = ".", thousands = false, date_formats = { "%Y-%m-%d", "%d/%m/%Y" } }

-- The float's lines and what <CR> copies on each (false: nothing). spec is
-- { n, only } (default: n = 2, every figure).
local function entries(cells, spec, opts)
  local texts, copies = {}, {}
  for i, e in ipairs(stats.entries(cells, opts or OPTS, spec or { n = 2 })) do
    texts[i], copies[i] = e[1], e[2] or false
  end
  return texts, copies
end

-- The error of entries.
local function refused(cells, only)
  local ok, err = pcall(stats.entries, cells, OPTS, { n = 5, only = only })
  assert(not ok, "no error")
  return err
end

return {
  ["numbers: counts, min, max, sum, average, largest and smallest, every value"] = function()
    local texts, copies = entries({ "3", " 10 ", "", "2.5", "3", "-1" })
    eq(texts, {
      "type         number",
      "rows         6",
      "empty        1",
      "unique       4",
      "most common  3 (2 times)",
      "min          -1",
      "max          10",
      "sum          17.5",
      "average      3.5",
      "",
      "largest 2",
      "  10",
      "  3",
      "smallest 2",
      "  -1",
      "  2.5",
      "",
      "values",
      "  count  value",
      "      2  3",
      "      1  (empty)",
      "      1  -1",
      "      1  10",
      "      1  2.5",
    })
    eq(copies, {
      "number", "6", "1", "4", "3", "-1", "10", "17.5", "3.5", false,
      false, "10", "3", false, "-1", "2.5", false,
      false, false, "3", "", "-1", "10", "2.5",
    })
  end,

  ["dates: oldest and newest by date, each written as in the file"] = function()
    local texts, copies = entries({ "2024-02-01", "15/01/2024", "2023-12-31" }, { n = 1 })
    eq(vim.list_slice(texts, 1, 13), {
      "type         date",
      "rows         3",
      "empty        0",
      "unique       3",
      "most common  15/01/2024 (1 time)",
      "oldest       2023-12-31",
      "newest       2024-02-01",
      "",
      "newest 1",
      "  2024-02-01",
      "oldest 1",
      "  2023-12-31",
      "",
    })
    eq(copies[7], "2024-02-01")
  end,

  ["text: no min, max or sums; a newline shows as ⏎ and is copied as is"] = function()
    local texts, copies = entries({ "b", "a\nz", "b", "" })
    eq(texts, {
      "type         string",
      "rows         4",
      "empty        1",
      "unique       2",
      "most common  b (2 times)",
      "",
      "values",
      "  count  value",
      "      2  b",
      "      1  (empty)",
      "      1  a⏎z",
    })
    eq(copies[11], "a\nz")
    -- no rows, or only empty ones: nothing is most common
    eq(entries({}), { "type         string", "rows         0", "empty        0", "unique       0", "", "values", "  count  value" })
    eq(entries({ "" })[5], "")
    -- a count wider than the header pushes the values right
    local many = {}
    for i = 1, 123456 do
      many[i] = "x"
    end
    eq(vim.list_slice(entries(many), 7, 9), { "values", "   count  value", "  123456  x" })
  end,

  ["sum and average use the file's decimal comma"] = function()
    local opts = { decimal = ",", thousands = ".", date_formats = {} }
    local texts = entries({ "1.000,5", "2" }, { n = 1 }, opts)
    eq(vim.list_slice(texts, 6, 9), { "min          2", "max          1.000,5", "sum          1002,5", "average      501,25" })
  end,

  ["only: just the figures asked for, in the float's order"] = function()
    local cells = { "3", "10", "", "2.5", "3" }
    eq(entries(cells, { n = 5, only = { max = true, sum = true } }), { "max          10", "sum          18.5" })
    eq(entries(cells, { n = 2, only = { largest = true, common = true } }), {
      "most common  3 (2 times)",
      "largest 2",
      "  10",
      "  3",
    })
    eq(entries({ "a", "b", "a" }, { n = 5, only = { values = true } }), { "values", "  count  value", "      2  a", "      1  b" })
    -- oldest / newest are min / max of a date column
    eq(entries({ "2024-02-01", "2023-12-31" }, { n = 5, only = { newest = true } }), { "newest       2024-02-01" })
    eq(entries({ "2024-02-01", "2023-12-31" }, { n = 5, only = { min = true } }), { "oldest       2023-12-31" })
  end,

  ["only: a figure the column's type has not is refused"] = function()
    eq(refused({ "a", "b" }, { sum = true }), "csvkit: stats: sum needs a number column, and this one is string")
    eq(refused({ "a", "b" }, { min = true }), "csvkit: stats: min needs a number or date column, and this one is string")
    eq(refused({ "true", "false" }, { largest = true }), "csvkit: stats: largest needs a number or date column, and this one is bool")
    eq(refused({ "2024-01-01" }, { average = true }), "csvkit: stats: average needs a number column, and this one is date")
    eq(refused({ "1", "2" }, { newest = true }), "csvkit: stats: newest needs a date column, and this one is number")
    -- one number among text makes the column text
    eq(refused({ "1", "x" }, { max = true }), "csvkit: stats: max needs a number or date column, and this one is string")
  end,
}
