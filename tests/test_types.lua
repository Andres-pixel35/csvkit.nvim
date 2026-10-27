local types = require("csvkit.types")

local DOT = { decimal = "." }
local DATES = { date_formats = { "%Y-%m-%d", "%Y-%m-%d %H:%M:%S", "%d/%m/%Y" } }

local function num(s, opts)
  return types.parse_number(s, opts or DOT)
end

return {
  ["number: accepts"] = function()
    eq(num("5"), 5)
    eq(num("-3.2"), -3.2)
    eq(num("1e3"), 1000)
    eq(num("2.5E-1"), 0.25)
    eq(num("+7"), 7)
    eq(num("007"), 7)
    eq(num(" 5 "), 5)
    eq(num("0.5"), 0.5)
    eq(num(".5"), 0.5)
    eq(num("-.5"), -0.5)
    eq(num("5."), 5)
    eq(num("+5."), 5)
    eq(num("5.e2"), 500)
  end,

  ["number: rejects"] = function()
    for _, s in ipairs({ "0x1A", "inf", "nan", "1.2.3", "", "  ", ".", "-", "+.", ".e5", "e5", "1e", "--1", "1,5", "5 kg", "5..", "..5", "Infinity", "-nan", "1i", "0b1", "0x1p4", "1LL", "-0x10", "+0X1", "-inf", "+0b1" }) do
      eq({ s, num(s) }, { s })
    end
  end,

  ["number: comma decimal"] = function()
    local o = { decimal = "," }
    eq(num("3,5", o), 3.5)
    eq(num("-0,25e2", o), -25)
    eq(num(",5", o), 0.5)
    eq(num("5,", o), 5)
    eq(num("-,25", o), -0.25)
    eq(num("3.5", o), nil)
    eq(num(".5", o), nil)
    eq(num("5.", o), nil)
    eq(num(",", o), nil)
  end,

  ["number: thousands '.' with comma decimal"] = function()
    local o = { decimal = ",", thousands = "." }
    eq(num("1.234,56", o), 1234.56)
    eq(num("1.234.567", o), 1234567)
    eq(num("1234,5", o), 1234.5) -- separators are optional
    eq(num("1.5", o), nil)
    eq(num("1.23,4", o), nil)
    eq(num("1234.567", o), nil) -- first group has more than 3 digits
    eq(num("1.234,", o), 1234)
    eq(num(",5", o), 0.5)
    eq(num("1.", o), nil) -- a trailing separator is an empty group
    eq(num(".5", o), nil)
  end,

  ["number: thousands ',' with dot decimal"] = function()
    local o = { decimal = ".", thousands = "," }
    eq(num("1,234.5", o), 1234.5)
    eq(num("-12,345,678", o), -12345678)
    eq(num("1,234.", o), 1234)
    eq(num(".5", o), 0.5)
    eq(num("1,23", o), nil)
    eq(num(",5", o), nil)
  end,

  ["bool"] = function()
    eq(types.parse_bool("true"), true)
    eq(types.parse_bool(" FALSE "), false)
    eq(types.parse_bool("True"), true)
    eq(types.parse_bool("yes"), nil)
    eq(types.parse_bool(""), nil)
  end,

  ["date: iso and datetime"] = function()
    eq(types.parse_date("1970-01-01", DATES), { day = 0, fmt = 1 })
    eq(types.parse_date("2000-03-01", DATES), { day = 11017, fmt = 1 })
    eq(types.parse_date(" 1970-01-02 12:00:00 ", DATES), { day = 1.5, fmt = 2 })
    eq(types.parse_date("1970-01-01 24:00:00", DATES), nil)
    eq(types.parse_date("1970-01-01T00:00:00", DATES), nil) -- not in this format list
  end,

  ["date: day/month order follows the format"] = function()
    local dmy = { date_formats = { "%d/%m/%Y" } }
    local mdy = { date_formats = { "%m/%d/%Y" } }
    eq(types.parse_date("03/04/2024", dmy).day, types.parse_date("2024-04-03", DATES).day)
    eq(types.parse_date("03/04/2024", mdy).day, types.parse_date("2024-03-04", DATES).day)
    eq(types.parse_date("13/01/2024", mdy), nil)
    eq(types.parse_date("5/3/2024", dmy).day, types.parse_date("2024-03-05", DATES).day)
  end,

  ["date: calendar validity"] = function()
    assert(types.parse_date("2024-02-29", DATES))
    assert(types.parse_date("2000-02-29", DATES)) -- divisible by 400
    eq(types.parse_date("1900-02-29", DATES), nil) -- divisible by 100
    eq(types.parse_date("2026-02-29", DATES), nil)
    eq(types.parse_date("2026-02-30", DATES), nil)
    eq(types.parse_date("2026-13-01", DATES), nil)
    eq(types.parse_date("2026-00-10", DATES), nil)
    eq(types.parse_date("2026-04-31", DATES), nil)
    eq(types.parse_date("2026-4-1x", DATES), nil)
    eq(types.parse_date("24-01-05", DATES), nil) -- %Y is exactly 4 digits
    eq(types.parse_date("12024-01-05", DATES), nil)
  end,

  ["date: far years round trip"] = function()
    eq(types.parse_date("1969-12-31", DATES).day, -1)
    for _, s in ipairs({ "0001-01-01", "1600-02-29", "1969-12-31", "2100-12-31", "2400-02-29", "9999-12-31" }) do
      eq(types.format_value(types.parse_date(s, DATES), DATES), s)
    end
  end,

  ["date: civil from days inverts days from civil"] = function()
    for day = -800000, 800000, 997 do
      local y, m, d = types.civil_from_days(day)
      eq(types.days_from_civil(y, m, d), day)
    end
  end,

  ["date: unsupported directive is an error"] = function()
    local ok, err = pcall(types.parse_date, "24", { date_formats = { "%y" } })
    assert(not ok and err:find("unsupported date directive %y", 1, true), err)
    ok, err = pcall(types.parse_date, "2024-01", { date_formats = { "%Y-%m" } })
    assert(not ok and err:find("needs %Y, %m and %d", 1, true), err)
  end,

  ["typeof"] = function()
    local o = vim.tbl_extend("force", DOT, DATES)
    eq(types.typeof("  ", o), "empty")
    eq(types.typeof("1.5", o), "number")
    eq(types.typeof("2024-01-05", o), "date")
    eq(types.typeof("TRUE", o), "bool")
    eq(types.typeof("Ana", o), "string")
  end,

  ["infer_column"] = function()
    local o = vim.tbl_extend("force", DOT, DATES)
    eq(types.infer_column({ "1", "2.5", "", "-3" }, o), "number") -- empties ignored
    eq(types.infer_column({ "x", "y", "z", "1" }, o), "string") -- mixed
    eq(types.infer_column({ "2024-01-01", " ", "05/03/2024", "2024-12-31" }, o), "date") -- mixed formats
    eq(types.infer_column({ "", "", "" }, o), "string") -- all empty
    eq(types.infer_column({ "1", "a", "", "2" }, o), "string")
    eq(types.infer_column({}, o), "string")
    eq(types.infer_column({ "1", "2024-01-01" }, o), "string") -- number + date
    eq(types.infer_column({ "true", "FALSE" }, o), "bool")
  end,

  ["date: memoized per options table, formats kept apart"] = function()
    local dmy, mdy = { date_formats = { "%d/%m/%Y" } }, { date_formats = { "%m/%d/%Y" } }
    for _ = 1, 2 do -- the second round reads the memo
      eq(types.parse_date("01/02/2024", dmy), { day = types.days_from_civil(2024, 2, 1), fmt = 1 })
      eq(types.parse_date(" 01/02/2024 ", mdy), { day = types.days_from_civil(2024, 1, 2), fmt = 1 })
      eq(types.parse_date("31/02/2024", dmy), nil)
      eq(types.parse_date("2024", dmy), nil)
    end
  end,

  ["format_value"] = function()
    eq(types.format_value(42, DOT), "42")
    eq(types.format_value(-3.0, DOT), "-3")
    eq(types.format_value(0.1 + 0.2, DOT), "0.3")
    eq(types.format_value(1 / 3, DOT), "0.333333333333333")
    eq(types.format_value(2.5, { decimal = "," }), "2,5")
    eq(types.format_value(1e20, DOT), "1e+20")
    eq(types.format_value(true, DOT), "TRUE")
    eq(types.format_value(false, DOT), "FALSE")
    eq(types.format_value("text", DOT), "text")
  end,

  ["format_value: date in its source format"] = function()
    for _, s in ipairs({ "2024-03-05", "2024-03-05 07:08:09", "05/03/2024" }) do
      eq(types.format_value(types.parse_date(s, DATES), DATES), s)
    end
    -- seconds that round up to midnight carry into the next day
    eq(types.format_value({ day = 0.99999999, fmt = 2 }, DATES), "1970-01-02 00:00:00")
  end,

  ["detect number format"] = function()
    local auto = { decimal = "auto", thousands = "auto" }
    local function detect(cells, opts)
      local rows = {}
      for i, c in ipairs(cells) do
        rows[i] = { "x", c }
      end
      return { types.detect_number_format(rows, opts or auto) }
    end
    eq(detect({ "1.5", "2.25", "3", "" }), { ".", false })
    eq(detect({ "1,5", "2,25", "3" }), { ",", false })
    eq(detect({ "1.234,56", "12,5", "7" }), { ",", "." })
    eq(detect({ "1,234.56", "12.5" }), { ".", "," })
    eq(detect({ "1 234,5", "12,5" }), { ",", " " })
    eq(detect({ "1'234.5", "3.5" }), { ".", "'" })
    eq(detect({ "1", "22", "abc" }), { ".", false }) -- no evidence: plain dot
    eq(detect({}), { ".", false })
    -- an explicit setting limits the candidates
    eq(detect({ "1,5" }, { decimal = ".", thousands = "auto" }), { ".", false })
    eq(detect({ "1.234", "5" }, { decimal = "auto", thousands = "." }), { ",", "." })
  end,
}
