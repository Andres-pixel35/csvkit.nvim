local formula = require("csvkit.formula")
local types = require("csvkit.types")

local OPTS = {
  decimal = ".",
  thousands = false,
  date_formats = { "%Y-%m-%d", "%d/%m/%Y", "%Y-%m-%d %H:%M:%S" },
  formula = { prev_default = 0 },
}
local HEADER = { "price", "qty", "name", "unit price", "day", "flag", "note" }

-- Values, failures and first error of expr over rows.
local function run(expr, rows, ctx)
  ctx = ctx or {}
  local header = ctx.header -- false = no header
  if header == nil then
    header = HEADER
  end
  local ast = formula.compile(expr, header, ctx.ncols)
  -- column-wise, as edit passes them: only the columns the expression reads
  local cols = {}
  for c in pairs(formula.columns(ast)) do
    cols[c] = {}
    for i, row in ipairs(rows) do
      cols[c][i] = row[c] -- nil for a missing field
    end
  end
  return formula.eval_column(ast, { cols = cols, n = #rows, opts = ctx.opts or OPTS, shown = ctx.shown })
end

-- The value of expr on one row; the test fails if the row fails.
local function val(expr, row, ctx)
  local values, failures, err = run(expr, { row or {} }, ctx)
  assert(#failures == 0, ("%s failed: %s"):format(expr, err))
  return values[1]
end

-- Checks that expr fails on one row (written empty) and returns the message.
local function fails(expr, row, ctx)
  local values, failures, err = run(expr, { row or {} }, ctx)
  eq({ values, failures }, { { "" }, { 1 } })
  return err
end

-- The compile error message of expr.
local function compile_error(expr, header)
  if header == nil then
    header = HEADER
  end
  local ok, err = pcall(formula.compile, expr, header)
  assert(not ok, expr .. " compiled")
  return err
end

local ROW = { "10", "4", " Ana ", "2,5", "2024-02-28", "true", "" }

return {
  ["operators and precedence"] = function()
    eq(val("2+3*4"), "14")
    eq(val("(2+3)*4"), "20")
    eq(val("10-4-3"), "3")
    eq(val("2*3^2"), "18")
    eq(val("-2^2"), "4") -- unary minus binds tighter than ^
    eq(val("2^3^2"), "512") -- ^ is right-associative
    eq(val("2^-1"), "0.5")
    eq(val("2*-3"), "-6")
    eq(val("7/2"), "3.5")
    eq(val("7%3"), "1")
    eq(val("-7%3"), "2") -- floored, like Python
    eq(val("1+2=3"), "TRUE")
    eq(val("1+2<>3"), "FALSE")
    eq(val("1<2"), "TRUE")
    eq(val("2<=2"), "TRUE")
    eq(val("3>=4"), "FALSE")
    eq(val("3>2"), "TRUE")
    eq(val("  1 +\t2 "), "3")
    eq(val(".5 + 5. + 1e3 + 2.5E-1"), "1005.75")
  end,

  ["type rules: numbers and strings"] = function()
    eq(val('"a" + "b"'), "ab")
    fails('"a" + 1')
    fails('1 + "a"')
    fails('"a" * 2')
    fails('"a" - "b"')
    fails("TRUE + 1")
    fails('-"a"')
    fails("1 / 0")
    fails("1 % 0")
    fails("10 ^ 400") -- not finite
    fails("1e999")
    fails("price", { "1e999" })
    eq(val("0.1 + 0.2"), "0.3")
  end,

  ["type rules: dates"] = function()
    eq(val("day + 1", ROW), "2024-02-29")
    eq(val("1 + day", ROW), "2024-02-29")
    eq(val("day - 59", ROW), "2023-12-31")
    eq(val("day - DATE(2024, 1, 1)", ROW), "58")
    fails("DATE(2024, 1, 1) - day", { "", "", "", "", "x" }) -- a string, not a date
    fails("1 - day", ROW)
    fails("day * 2", ROW)
    fails("day + day", ROW)
  end,

  ["type rules: empty in arithmetic"] = function()
    fails("price + 1", { "" })
    fails("price * qty", { "", "" })
    fails('note + "x"', ROW)
    fails('"" + "x"') -- a "" literal is the empty value
  end,

  ["type rules: = and <> take any types"] = function()
    eq(val('1 = "1"'), "FALSE")
    eq(val('1 <> "1"'), "TRUE")
    eq(val("TRUE = 1"), "FALSE")
    eq(val('"a" = "a"'), "TRUE")
    eq(val('"a" = "A"'), "FALSE")
    eq(val('note = ""', ROW), "TRUE")
    eq(val("note = note", ROW), "TRUE")
    eq(val('name = "Ana"', ROW), "TRUE") -- cells are trimmed
    eq(val("price = 10", ROW), "TRUE")
    eq(val("flag = TRUE", ROW), "TRUE")
    -- dates compare by day, whatever their format
    eq(val("day = DATE(2024, 2, 28)", ROW), "TRUE")
    eq(val("day = DATE(2024, 2, 28)", { [5] = "28/02/2024" }), "TRUE")
  end,

  ["type rules: < > <= >= need the same type"] = function()
    eq(val('"a" < "b"'), "TRUE")
    eq(val('"B" < "a"'), "TRUE") -- by bytes
    eq(val("DATE(2024, 1, 1) < DATE(2024, 1, 2)"), "TRUE")
    eq(val("FALSE < TRUE"), "TRUE")
    fails('1 < "2"')
    fails("day > 1", ROW)
    fails("note < 1", ROW)
    fails("note < note", ROW)
  end,

  ["aggregates over all rows, empties skipped"] = function()
    local rows = { { "10", "2" }, { "", "3" }, { "5", "" }, { "1,5", "x" } }
    local o = { opts = vim.tbl_extend("force", OPTS, { decimal = "," }) }
    eq(run("SUM(price)", rows, o), { "16,5", "16,5", "16,5", "16,5" })
    eq(run("AVG(price)", rows, o), { "5,5", "5,5", "5,5", "5,5" })
    eq(run("MIN(price)", rows, o), { "1,5", "1,5", "1,5", "1,5" })
    eq(run("MAX(price)", rows, o), { "10", "10", "10", "10" })
    eq(run("COUNT(qty)", rows, o), { "3", "3", "3", "3" }) -- counts any non-empty cell
    eq(run("price / SUM(price) * 33", rows, o), { "20", "", "10", "3" })
    -- a non-number in the column fails every row that uses the aggregate
    local values, failures, err = run("SUM(qty)", rows)
    eq({ values, failures }, { { "", "", "", "" }, { 1, 2, 3, 4 } })
    assert(err:find("SUM"), err)
    eq(select(2, run("price + 0 * SUM(qty)", rows)), { 1, 2, 3, 4 })
  end,

  ["aggregates: empty column, dates, bools"] = function()
    local rows = { { "", "2024-03-01" }, { "", "01/01/2024" }, { "", "" } }
    eq(run("SUM(price)", rows), { "0", "0", "0" })
    eq(select(2, run("AVG(price)", rows)), { 1, 2, 3 })
    eq(select(2, run("MIN(price)", rows)), { 1, 2, 3 })
    eq(run("COUNT(price)", rows), { "0", "0", "0" })
    -- dates are allowed in MIN/MAX and keep their own format
    eq(run("MIN($1)", rows), { "01/01/2024", "01/01/2024", "01/01/2024" })
    eq(run("MAX($1)", rows), { "2024-03-01", "2024-03-01", "2024-03-01" })
    eq(select(2, run("SUM($1)", rows)), { 1, 2, 3 })
    eq(select(2, run("MAX(price)", { { "1" }, { "2024-01-01" } })), { 1, 2 }) -- number and date
    eq(select(2, run("SUM(flag)", { { [6] = "true" } })), { 1 })
  end,

  ["aggregates are computed once per run"] = function()
    local parse_number, calls = types.parse_number, 0
    types.parse_number = function(...)
      calls = calls + 1
      return parse_number(...)
    end
    local ok, err = pcall(function()
      local rows = { { "1", "1" }, { "2", "1" }, { "3", "1" } }
      eq(run("SUM(price) + SUM(price)", rows), { "12", "12", "12" })
      eq(calls, 3)
      calls = 0
      eq(run("SUM(price) + SUM(qty) - MAX(price)", rows), { "6", "6", "6" })
      eq(calls, 9)
    end)
    types.parse_number = parse_number
    assert(ok, err)
  end,

  ["row-wise MIN and MAX"] = function()
    local row = { "10", "4", "", "", "2024-01-05" }
    eq(val("MIN(price, qty)", row), "4")
    eq(val("MAX(price, qty, 12.5)", row), "12.5")
    eq(val("MIN(day, DATE(2024, 1, 1))", row), "2024-01-01")
    eq(val("MAX(day, DATE(2024, 1, 1))", row), "2024-01-05")
    fails("MIN(price, note)", row) -- empty
    fails('MAX(price, "a")', row)
    fails("MAX(price, day)", row)
  end,

  ["text functions"] = function()
    eq(val('CONCAT(name, "-", price, note, flag, day, 0.5)', ROW), "Ana-10TRUE2024-02-280.5")
    eq(val("CONCAT()"), "")
    eq(val("CONCAT(note)", ROW), "")
    eq(val("CONCAT(note) = note", ROW), "TRUE")
    eq(val("CONCAT(2.5)", {}, { opts = vim.tbl_extend("force", OPTS, { decimal = "," }) }), "2,5")
    eq(val('UPPER("ñandú ok")'), "ÑANDÚ OK")
    eq(val('LOWER("ÑANDÚ OK")'), "ñandú ok")
    eq(val('LEN("ñandú")'), "5")
    eq(val("LEN(name)", ROW), "3")
    fails("UPPER(price)", ROW)
    fails("LEN(note)", ROW) -- empty is not a string
    fails("LOWER(flag)", ROW)
  end,

  ["conditionals"] = function()
    eq(val('IF(qty > 1, "many", "one")', ROW), "many")
    eq(val('IF(qty > 9, "many", "one")', ROW), "one")
    eq(val('IF(TRUE, note, "x")', ROW), "")
    fails('IF(1, "a", "b")')
    fails('IF(note, "a", "b")', ROW)
    -- only the chosen branch is evaluated
    eq(val("IF(qty = 0, 0, price / qty)", { "10", "0" }), "0")
    eq(val("AND(TRUE, 1 < 2)"), "TRUE")
    eq(val("AND(TRUE, FALSE)"), "FALSE")
    eq(val("OR(FALSE, flag)", ROW), "TRUE")
    eq(val("OR(FALSE, FALSE)"), "FALSE")
    eq(val("OR(TRUE, 1 / 0)"), "TRUE") -- short-circuits
    eq(val("AND(FALSE, 1 / 0)"), "FALSE")
    fails("AND(TRUE, 1)")
    fails("OR(FALSE, 1)")
    eq(val("NOT(flag)", ROW), "FALSE")
    eq(val("NOT(1 > 2)"), "TRUE")
    fails("NOT(1)")
    eq(val("true = TRUE"), "TRUE") -- literals and function names ignore case
    eq(val("not(false)"), "TRUE")
  end,

  ["math functions"] = function()
    eq(val("ROUND(3.14159, 2)"), "3.14")
    eq(val("ROUND(2.5, 0)"), "3") -- half away from zero
    eq(val("ROUND(-2.5, 0)"), "-3")
    eq(val("ROUND(1.005, 2)"), "1.01") -- as written, not as its binary value
    eq(val("ROUND(1234.5, -2)"), "1200")
    eq(val("ROUND(-0.4, 0)"), "0")
    eq(val("ROUND(0.1 + 0.2, 20)"), "0.3")
    fails("ROUND(1, 0.5)")
    fails('ROUND("a", 1)')
    eq(val("ABS(-3.5)"), "3.5")
    eq(val("ABS(qty - price)", ROW), "6")
    fails('ABS("a")')
  end,

  ["date functions"] = function()
    eq(val("DATE(2024, 2, 29)"), "2024-02-29")
    eq(val("DATE(1600, 1, 1) - DATE(1599, 12, 31)"), "1")
    fails("DATE(2026, 2, 29)")
    fails("DATE(2026, 13, 1)")
    fails("DATE(2024.5, 1, 1)")
    fails('DATE("2024", 1, 1)')
    eq(val("YEAR(day)", ROW), "2024")
    eq(val("MONTH(day)", ROW), "2")
    eq(val("DAY(day)", ROW), "28")
    eq(val("DAY(day)", { [5] = "2024-01-01 23:59:59" }), "1")
    fails("YEAR(1)")
    fails("MONTH(note)", ROW)
    eq(val("TODAY()"), os.date("%Y-%m-%d"))
    eq(val("TODAY() - TODAY()"), "0")
  end,

  ["date arithmetic keeps the format of the first date"] = function()
    eq(val("day + 30", { [5] = "05/03/2024" }), "04/04/2024")
    eq(val("MAX(day, DATE(2000, 1, 1))", { [5] = "05/03/2024" }), "05/03/2024")
    eq(val("day + 0.5", { [5] = "2024-01-01 12:00:00" }), "2024-01-02 00:00:00")
    eq(val("day - DATE(2024, 1, 1)", { [5] = "2024-01-01 12:00:00" }), "0.5")
    eq(val("DATE(2024, 1, 31) + 1"), "2024-02-01") -- DATE uses date_formats[1]
  end,

  ["column references"] = function()
    local row = { "1", "2", "", "3" }
    eq(val("price + qty", row), "3")
    eq(val("[unit price] * 2", row), "6")
    eq(val("[ unit price ]", row), "3")
    eq(val("$1 + $3", row), "5") -- $N counts from 0
    eq(val("$0", row), "1")
    eq(val("note", { "1" }), "") -- a missing field is empty
    eq(val("qty", { "x", " 2 " }, { header = { " price ", " qty" } }), "2") -- headers are trimmed
    eq(val("$0 + $2", { "1", "x", "2" }, { header = false }), "3")
    eq(val("$8", {}, { header = false }), "")
    assert(compile_error("price", false):find('unknown column "price"'))
    assert(compile_error("$7"):find('unknown column "$7"'))
    assert(compile_error("unit"):find('unknown column "unit"'))
    assert(compile_error("[nope]"):find('unknown column "%[nope%]"'))
    assert(compile_error("a", { "a", "b", "a" }):find('ambiguous column "a"'))
    eq(val("$0", { "x" }, { header = { "a", "a" } }), "x")
    -- negative: from the end, -1 the last (the header's, or ncols without one)
    eq(val("$-4 + $-7", row), "4")
    eq(val("$1-1", row), "1") -- $1 minus 1
    assert(compile_error("$-8"):find('unknown column "$-8"', 1, true))
    eq(val("$-1", { "1", "2", "3" }, { header = false, ncols = 3 }), "3")
    eq(val("$-0", { "1", "2" }, { header = false, ncols = 2 }), "1")
    assert(compile_error("$-1", false):find('unknown column "$-1"', 1, true))
  end,

  ["strings and escapes"] = function()
    eq(val('"say ""hi"""'), 'say "hi"')
    eq(val('"a,b"'), "a,b")
    eq(val('""""'), '"')
    eq(val('"  padded "'), "  padded ") -- literals are not trimmed
  end,

  ["comma-decimal data with .-decimal literals"] = function()
    local o = { opts = vim.tbl_extend("force", OPTS, { decimal = ",", thousands = "." }) }
    eq(val("price * 2", { "1.234,5" }, o), "2469")
    eq(val("price + 0.25", { "1.234,5" }, o), "1234,75")
    eq(val("ROUND(price, 0)", { "2,5" }, o), "3")
    eq(val("price = 1.5", { "1,5" }, o), "TRUE")
  end,

  ["division by zero: empty cell and its row in failures"] = function()
    local values, failures, err = run("price / qty", { { "10", "2" }, { "1", "0" }, { "10", "4" }, { "1", "0" } })
    eq(values, { "5", "", "2.5", "" })
    eq(failures, { 2, 4 })
    assert(err:find("division by zero"), err)
  end,

  ["shown: only those rows are evaluated, failures and aggregates included"] = function()
    local rows = { { "10", "0" }, { "1", "2" }, { "abc", "1" }, { "4", "4" } }
    local values, failures, err = run("price / qty", rows, { shown = { 4, 2 } })
    eq({ values, failures, err }, { { nil, "0.5", nil, "1" }, {}, nil }) -- rows 1 and 3 would fail
    eq(run("price / qty", rows, { shown = { 3, 1 } }), { "", nil, "" }) -- in the order shown
    eq({ select(2, run("price / qty", rows, { shown = { 3, 1 } })) }, { { 3, 1 }, "cannot apply / to string and number" })
    eq(run("SUM(price) + COUNT(qty)", rows, { shown = { 2, 4 } }), { nil, "7", nil, "7" })
    eq(run("MAX(price)", rows, { shown = {} }), {})
    -- matches too: a hidden row is not TRUE
    local ast = formula.compile("price > AVG(price)", HEADER)
    local pass = formula.matches(ast, { cols = { { "10", "1", "abc", "4" } }, n = 4, opts = OPTS, shown = { 2, 4 } })
    eq(pass, { [2] = false, [4] = true })
  end,

  ["compile errors name the bad token and position"] = function()
    eq(compile_error("price * )"), 'csvkit: unexpected ")" at position 9')
    eq(compile_error("price +"), "csvkit: unexpected end of expression at position 8")
    eq(compile_error("price qty"), 'csvkit: unexpected "qty" at position 7')
    eq(compile_error("(1 + 2"), "csvkit: unexpected end of expression at position 7")
    eq(compile_error("foo + 1"), 'csvkit: unknown column "foo" at position 1')
    eq(compile_error("1 + FOO(1)"), 'csvkit: unknown function "FOO" at position 5')
    eq(compile_error('"abc'), "csvkit: unterminated string at position 1")
    eq(compile_error("[abc"), "csvkit: unterminated [ at position 1")
    eq(compile_error("1 # 2"), 'csvkit: unexpected character "#" at position 3')
    eq(compile_error("1 + é"), 'csvkit: unexpected character "é" at position 5')
    eq(compile_error("$x"), "csvkit: expected a column number after $ at position 1")
    eq(compile_error("1.2.3"), 'csvkit: unexpected ".3" at position 4')
    eq(compile_error("ROUND(1)"), "csvkit: wrong number of arguments for ROUND at position 1")
    eq(compile_error("TODAY(1)"), "csvkit: wrong number of arguments for TODAY at position 1")
    eq(compile_error("SUM(price * 2)"), "csvkit: SUM needs a column at position 1")
    eq(compile_error("MIN(1)"), "csvkit: MIN needs a column or 2+ arguments at position 1")
    eq(compile_error("SUM(price, qty)"), "csvkit: wrong number of arguments for SUM at position 1")
    eq(compile_error(""), "csvkit: unexpected end of expression at position 1")
  end,

  ["evaluator bugs are raised, not counted as failures"] = function()
    local ok = pcall(formula.eval_column, { k = "bogus" }, { cols = {}, n = 1, opts = OPTS })
    assert(not ok)
  end,

  ["matches: TRUE rows pass; FALSE, failing and non-bool rows do not"] = function()
    local rows = { { "10" }, { "3" }, { "" }, { "abc" }, { "12" } }
    local function matches(expr)
      local ast = formula.compile(expr, HEADER)
      local cells = {}
      for i, row in ipairs(rows) do
        cells[i] = row[1]
      end
      return formula.matches(ast, { cols = { cells }, n = #rows, opts = OPTS })
    end
    eq({ matches("price > 5") }, { { true, false, false, false, true } }) -- "" and "abc" fail: hidden, no error
    eq({ matches("AND(price >= 3, price <= 10)") }, { { true, true, false, false, false } })
    eq({ matches('OR(price = "", price = "abc")') }, { { false, false, true, true, false } })
    -- no row gives TRUE or FALSE: the first row's reason
    eq({ matches("price + 1") }, { { false, false, false, false, false }, "expected TRUE or FALSE, got number" })
    eq({ matches("price > TRUE") }, { { false, false, false, false, false }, "cannot compare number and bool" })
    eq({ formula.matches(formula.compile("price > 1", HEADER), { cols = { {} }, n = 0, opts = OPTS }) }, { {} })
    -- PREV needs the order of the visible rows, which a filter decides
    local ok, err = pcall(matches, "IF(price > 5, PREV(price) > 1, FALSE)")
    eq({ ok, err }, { false, "csvkit: PREV works in addcol and setcol, not in filters" })
    eq(select(2, pcall(formula.filterable, formula.compile("PREV(price)", HEADER))), "csvkit: PREV works in addcol and setcol, not in filters")
    eq(formula.filterable(formula.compile("price > 1", HEADER)).k, "op")
  end,

  ["PREV: the value n visible rows up, in the current order"] = function()
    local rows = { { "100" }, { "110" }, { "121" }, { "" } }
    eq(run("PREV(price)", rows), { "0", "100", "110", "121" }) -- nothing above the first: the default, 0
    eq(run("PREV(price, 2)", rows), { "0", "0", "100", "110" })
    eq(run("PREV(price * 2) + 1", { { "1" }, { "5" } }), { "1", "3" })
    local values, failures, err = run("(price - PREV(price)) / PREV(price)", rows)
    eq({ values, failures, err }, { { "", "0.1", "0.1", "" }, { 1, 4 }, "division by zero" })
    -- an empty cell on the row read is the default too, as is a nested PREV's
    eq(run("PREV(price)", { { "1" }, { "" }, { "3" } }), { "0", "1", "0" })
    eq(run("PREV(PREV(price))", rows), { "0", "0", "100", "110" })
    -- only the rows in shown, in its order (a sort): each reads the shown row
    -- before it; a hidden row is not evaluated (nil)
    rows = { { "1" }, { "2" }, { "3" }, { "4" } }
    local ctx = { shown = { 3, 4, 2 } }
    eq(run("PREV(price)", rows, ctx), { nil, "4", "0", "3" })
    eq(run("PREV(price, 2)", rows, ctx), { nil, "3", "0", "0" })
    eq(run("PREV(PREV(price))", rows, ctx), { nil, "3", "0", "0" })
    -- n is a whole number from 1
    eq(fails("PREV(price, 0)", { "1" }), "PREV: n must be 1 or more")
    eq(fails("PREV(price, 1.5)", { "1" }), "PREV: expected a whole number")
    assert(compile_error("PREV()"):find("wrong number of arguments for PREV"))
    assert(compile_error("PREV(price, 1, 2)"):find("wrong number of arguments for PREV"))
  end,

  ["PREV's default for an empty or missing row comes from formula.prev_default"] = function()
    local rows = { { "1" }, { "" }, { "3" } }
    local function with(default)
      return { opts = vim.tbl_extend("force", OPTS, { formula = { prev_default = default } }) }
    end
    eq(run("PREV(price)", rows, with(-1)), { "-1", "1", "-1" })
    eq(run("PREV(price)", rows, with(0.5)), { "0.5", "1", "0.5" })
    -- a text is typed like a cell: "-1" is a number, "" empty, anything else text
    eq(run("PREV(price) + 1", rows, with("-1")), { "0", "2", "0" })
    eq(run("CONCAT(PREV(price), \"!\")", rows, with("好")), { "好!", "1!", "好!" })
    eq(run("PREV(price)", rows, with("")), { "", "1", "" })
    eq(run("PREV(price, 2)", rows, with("2026-01-31")), { "2026-01-31", "2026-01-31", "1" })
    local ok, err = pcall(run, "PREV(price)", rows, with(true))
    eq({ ok, err }, { false, "csvkit: formula.prev_default must be a number or a text, not true" })
  end,

  ["columns: the columns an expression reads"] = function()
    local ast = formula.compile("price * $1 + SUM(price) + IF(flag, LEN([unit price]), -MAX(day, day))", HEADER)
    eq(formula.columns(ast), { [1] = true, [2] = true, [4] = true, [5] = true, [6] = true })
    eq(formula.columns(formula.compile("1 + TODAY() - TODAY()", HEADER)), {})
  end,
}
