-- Formula columns: compile(expr, header) parses an expression into an AST once,
-- eval_column(ast, ctx) computes it for every shown data row. Values are typed like
-- cells, with Python-like strict rules: a type mismatch is an error, and a row
-- with an error gets an empty cell.
--
-- Values: number = Lua number, string = Lua string, bool = boolean, date =
-- { day, fmt } (as types.parse_date), empty = "" (so the literal "" is empty too).
local types = require("csvkit.types")

local M = {}

---------------------------------------------------------------------------
-- Tokenizer and parser
---------------------------------------------------------------------------

-- Raises a compile error at a position (1-based byte offset in the expression).
local function syntax_error(msg, pos)
  error(("csvkit: %s at position %d"):format(msg, pos), 0)
end

local OPS = { "<>", "<=", ">=", "=", "<", ">", "+", "-", "*", "/", "%", "^", "(", ")", "," }

-- Splits expr into tokens { t, v, text, pos }. Kinds t: num, str, ident, op
-- (v = the operator), col (v = trimmed name for [name], the number for $N:
-- from 0, or from the end when negative), eof.
local function tokenize(expr)
  local toks, i = {}, 1
  while true do
    i = expr:find("%S", i)
    if not i then
      toks[#toks + 1] = { t = "eof", text = "end of expression", pos = #expr + 1 }
      return toks
    end
    local tok, stop = { pos = i }, nil
    local c = expr:sub(i, i)
    local num = expr:match("^%d+%.?%d*", i) or expr:match("^%.%d+", i)
    local id = expr:match("^[%a_][%w_]*", i)
    if num then
      num = num .. (expr:match("^[eE][+-]?%d+", i + #num) or "")
      tok.t, tok.v, stop = "num", tonumber(num), i + #num - 1
    elseif id then
      tok.t, tok.v, stop = "ident", id, i + #id - 1
    elseif c == "[" then
      -- names containing "]" need $N
      stop = expr:find("]", i, true) or syntax_error("unterminated [", i)
      tok.t, tok.v = "col", types.trim(expr:sub(i + 1, stop - 1))
    elseif c == "$" then
      local n = expr:match("^%$(%-?%d+)", i) or syntax_error("expected a column number after $", i)
      tok.t, tok.v, stop = "col", tonumber(n), i + #n
    elseif c == '"' then
      stop = i
      repeat
        stop = expr:find('"', stop + 1, true) or syntax_error("unterminated string", i)
        local doubled = expr:sub(stop + 1, stop + 1) == '"'
        stop = doubled and stop + 1 or stop
      until not doubled
      tok.t, tok.v = "str", (expr:sub(i + 1, stop - 1):gsub('""', '"'))
    else
      for _, op in ipairs(OPS) do
        if expr:sub(i, i + #op - 1) == op then
          tok.t, tok.v, stop = "op", op, i + #op - 1
          break
        end
      end
      if not stop then
        syntax_error(('unexpected character "%s"'):format(expr:match("^.[\128-\191]*", i)), i)
      end
    end
    tok.text = expr:sub(i, stop)
    toks[#toks + 1] = tok
    i = stop + 1
  end
end

local MANY = math.huge
local FUNCS = { -- name -> { min args, max args }
  SUM = { 1, 1 },
  AVG = { 1, 1 },
  COUNT = { 1, 1 },
  MIN = { 1, MANY },
  MAX = { 1, MANY },
  CONCAT = { 0, MANY },
  UPPER = { 1, 1 },
  LOWER = { 1, 1 },
  LEN = { 1, 1 },
  IF = { 3, 3 },
  PREV = { 1, 2 },
  AND = { 1, MANY },
  OR = { 1, MANY },
  NOT = { 1, 1 },
  ROUND = { 2, 2 },
  ABS = { 1, 1 },
  DATE = { 3, 3 },
  TODAY = { 0, 0 },
  YEAR = { 1, 1 },
  MONTH = { 1, 1 },
  DAY = { 1, 1 },
}
local AGGREGATES = { SUM = true, AVG = true, COUNT = true, MIN = true, MAX = true }

-- Binary operators by precedence, lowest first; all left-associative. Above
-- them: ^ (right-associative), then unary minus, so -2^2 is 4.
local LEVELS = {
  { ["="] = true, ["<>"] = true, ["<"] = true, [">"] = true, ["<="] = true, [">="] = true },
  { ["+"] = true, ["-"] = true },
  { ["*"] = true, ["/"] = true, ["%"] = true },
}

-- Parses expr into an AST; raises "csvkit: <what> at position N" on a syntax
-- error, an unknown column or function, or a wrong argument count. header is
-- the list of column names, or nil/false when the file has none (then only $N
-- works, and ncols is the number of columns $-N counts back from). Names match
-- trimmed, case-sensitively; function names and TRUE/FALSE ignore case.
-- AST nodes: { k = "lit", v }, { k = "col", col }, { k = "neg", a },
-- { k = "op", op, a, b }, { k = "call", name, args }, { k = "agg", name, col }.
function M.compile(expr, header, ncols)
  local cols = {} -- trimmed name -> index, false when it is not unique
  for i, name in ipairs(header or {}) do
    name = types.trim(name)
    cols[name] = cols[name] == nil and i
  end

  local toks, p = tokenize(expr), 1
  local function take()
    p = p + 1
    return toks[p - 1]
  end
  local function is_op(v)
    return toks[p].t == "op" and toks[p].v == v
  end
  local function unexpected(tok)
    syntax_error(tok.t == "eof" and "unexpected end of expression" or ('unexpected "%s"'):format(tok.text), tok.pos)
  end
  local function expect(v)
    if not is_op(v) then
      unexpected(toks[p])
    end
    p = p + 1
  end

  local function resolve(tok)
    local i
    if type(tok.v) == "number" then
      i = tok.v < 0 and (header and #header or ncols or 0) + tok.v + 1 or tok.v + 1
      i = i >= 1 and (not header or i <= #header) and i
    else
      i = cols[tok.v]
      if i == false then
        syntax_error(('ambiguous column "%s", use $N'):format(tok.text), tok.pos)
      end
    end
    return i or syntax_error(('unknown column "%s"'):format(tok.text), tok.pos)
  end

  local binary
  local function call(tok, name)
    local arity = FUNCS[name] or syntax_error(('unknown function "%s"'):format(tok.text), tok.pos)
    take() -- (
    local args = {}
    if not is_op(")") then
      repeat
        args[#args + 1] = binary(1)
      until not (is_op(",") and take())
    end
    expect(")")
    if #args < arity[1] or #args > arity[2] then
      syntax_error("wrong number of arguments for " .. name, tok.pos)
    end
    if AGGREGATES[name] and #args == 1 then
      if args[1].k ~= "col" then
        local alt = (name == "MIN" or name == "MAX") and " or 2+ arguments" or ""
        syntax_error(("%s needs a column%s"):format(name, alt), tok.pos)
      end
      return { k = "agg", name = name, col = args[1].col }
    end
    return { k = "call", name = name, args = args }
  end

  local function primary()
    local tok = take()
    if tok.t == "num" or tok.t == "str" then
      return { k = "lit", v = tok.v }
    elseif tok.t == "col" then
      return { k = "col", col = resolve(tok) }
    elseif tok.t == "op" and tok.v == "(" then
      local node = binary(1)
      expect(")")
      return node
    elseif tok.t == "ident" then
      local name = tok.v:upper()
      if is_op("(") then
        return call(tok, name)
      elseif name == "TRUE" or name == "FALSE" then
        return { k = "lit", v = name == "TRUE" }
      end
      return { k = "col", col = resolve(tok) }
    end
    unexpected(tok)
  end

  local function unary()
    if is_op("-") then
      take()
      return { k = "neg", a = unary() }
    end
    return primary()
  end

  local function power()
    local base = unary()
    if is_op("^") then
      take()
      return { k = "op", op = "^", a = base, b = power() }
    end
    return base
  end

  function binary(level)
    if level > #LEVELS then
      return power()
    end
    local node = binary(level + 1)
    while toks[p].t == "op" and LEVELS[level][toks[p].v] do
      node = { k = "op", op = take().v, a = node, b = binary(level + 1) }
    end
    return node
  end

  local ast = binary(1)
  if toks[p].t ~= "eof" then
    unexpected(toks[p])
  end
  return ast
end

-- The set of column indices ast reads ({ [index] = true }); out is for the
-- recursion.
function M.columns(ast, out)
  out = out or {}
  if ast.k == "col" or ast.k == "agg" then
    out[ast.col] = true
  end
  for _, child in ipairs(ast.args or { ast.a, ast.b }) do
    M.columns(child, out)
  end
  return out
end

---------------------------------------------------------------------------
-- Evaluator
---------------------------------------------------------------------------

-- A row error: a table, so eval_column can tell it from a bug in this module.
local function fail(msg)
  error({ msg = msg }, 0)
end

-- "empty" | "number" | "date" | "bool" | "string"
local function typ(v)
  local t = type(v)
  if t == "string" then
    return v == "" and "empty" or "string"
  elseif t == "table" then
    return "date"
  elseif t == "boolean" then
    return "bool"
  end
  return "number"
end

local function want(v, t, name)
  if typ(v) ~= t then
    fail(("%s: expected %s, got %s"):format(name, t, typ(v)))
  end
  return v
end

local function want_int(v, name)
  want(v, "number", name)
  if v ~= math.floor(v) then
    fail(name .. ": expected a whole number")
  end
  return v
end

local function finite(v)
  if v ~= v or v == math.huge or v == -math.huge then
    fail("result is not a finite number")
  end
  return v
end

-- The typed value of a cell (nil = missing field = empty).
local function value_of(s, opts)
  s = types.trim(s or "")
  if s == "" then
    return ""
  end
  local v = types.parse_number(s, opts) or types.parse_date(s, opts)
  if v then
    return v
  end
  v = types.parse_bool(s)
  if v ~= nil then
    return v
  end
  return s
end

-- formula.prev_default as a value: a number, or a text typed like a cell.
local function prev_default(opts)
  local d = opts.formula.prev_default
  if type(d) == "number" then
    return d
  elseif type(d) ~= "string" then
    error(("csvkit: formula.prev_default must be a number or a text, not %s"):format(vim.inspect(d)), 0)
  end
  return value_of(d, opts)
end

local MATH = {
  ["+"] = function(a, b)
    return a + b
  end,
  ["-"] = function(a, b)
    return a - b
  end,
  ["*"] = function(a, b)
    return a * b
  end,
  ["/"] = function(a, b)
    return a / b
  end,
  ["%"] = function(a, b)
    return a % b
  end,
  ["^"] = function(a, b)
    return a ^ b
  end,
}

local function arith(op, a, b)
  local ta, tb = typ(a), typ(b)
  if ta == "number" and tb == "number" then
    if b == 0 and (op == "/" or op == "%") then
      fail("division by zero")
    end
    return finite(MATH[op](a, b))
  elseif op == "+" and ta == "string" and tb == "string" then
    return a .. b
  elseif ta == "date" and tb == "number" and (op == "+" or op == "-") then
    return { day = finite(MATH[op](a.day, b)), fmt = a.fmt }
  elseif ta == "number" and tb == "date" and op == "+" then
    return { day = finite(a + b.day), fmt = b.fmt }
  elseif ta == "date" and tb == "date" and op == "-" then
    return a.day - b.day
  end
  fail(("cannot apply %s to %s and %s"):format(op, ta, tb))
end

-- What a value compares by: a date by its day, a bool as 0 / 1.
local function key(v, t)
  if t == "date" then
    return v.day
  elseif t == "bool" then
    return v and 1 or 0
  end
  return v
end

local ORDER = {
  ["<"] = function(a, b)
    return a < b
  end,
  [">"] = function(a, b)
    return a > b
  end,
  ["<="] = function(a, b)
    return a <= b
  end,
  [">="] = function(a, b)
    return a >= b
  end,
}

-- = and <> take any types (different types are not equal); the others need
-- two non-empty values of the same type.
local function compare(op, a, b)
  local ta, tb = typ(a), typ(b)
  if op == "=" or op == "<>" then
    return (ta == tb and key(a, ta) == key(b, tb)) == (op == "=")
  elseif ta ~= tb or ta == "empty" then
    fail(("cannot compare %s and %s"):format(ta, tb))
  end
  return ORDER[op](key(a, ta), key(b, tb))
end

-- The smallest (MIN) or largest (MAX) of vals, which are all numbers or all dates.
local function extreme(name, vals)
  local best, best_key, best_type
  for _, v in ipairs(vals) do
    local t = typ(v)
    if (t ~= "number" and t ~= "date") or (best_type and t ~= best_type) then
      fail(("%s: expected all numbers or all dates, got %s"):format(name, t))
    end
    local k = key(v, t)
    if not best_key or (name == "MIN" and k < best_key) or (name == "MAX" and k > best_key) then
      best, best_key, best_type = v, k, t
    end
  end
  if best == nil then
    fail(name .. " of an empty column")
  end
  return best
end

-- SUM / AVG / COUNT / MIN / MAX over the non-empty cells of column col, on
-- the shown rows.
local function aggregate(name, col, env)
  local vals, cells, shown = {}, env.cols[col], env.shown
  for p = 1, shown and #shown or env.n do
    local v = value_of(cells[shown and shown[p] or p], env.opts)
    if v ~= "" then
      vals[#vals + 1] = v
    end
  end
  if name == "COUNT" then
    return #vals
  elseif name == "MIN" or name == "MAX" then
    return extreme(name, vals)
  end
  local sum = 0
  for _, v in ipairs(vals) do
    sum = sum + want(v, "number", name)
  end
  if name == "AVG" then
    if #vals == 0 then
      fail("AVG of an empty column")
    end
    sum = sum / #vals
  end
  return finite(sum)
end

local function civil(v, name)
  return types.civil_from_days(math.floor(want(v, "date", name).day))
end

-- Functions that get their arguments evaluated: (values, env) -> value.
local FN = {
  MIN = function(a)
    return extreme("MIN", a)
  end,
  MAX = function(a)
    return extreme("MAX", a)
  end,
  CONCAT = function(a, env)
    local parts = {}
    for i, v in ipairs(a) do
      parts[i] = types.format_value(v, env.opts)
    end
    return table.concat(parts)
  end,
  UPPER = function(a)
    return vim.fn.toupper(want(a[1], "string", "UPPER")) -- string.upper is ASCII only
  end,
  LOWER = function(a)
    return vim.fn.tolower(want(a[1], "string", "LOWER"))
  end,
  LEN = function(a)
    return vim.fn.strchars(want(a[1], "string", "LEN")) -- code points, like Python's len
  end,
  NOT = function(a)
    return not want(a[1], "bool", "NOT")
  end,
  ABS = function(a)
    return math.abs(want(a[1], "number", "ABS"))
  end,
  -- Half away from zero, to n decimals (n < 0: tens, hundreds, ...). The scaled
  -- value goes through %.15g first, so ROUND(1.005, 2) is 1.01 as written, not
  -- 1 as its binary value 1.00499... would give.
  ROUND = function(a)
    local x, n = want(a[1], "number", "ROUND"), want_int(a[2], "ROUND")
    local p = 10 ^ math.abs(n) -- exact up to 1e22, so * and / round correctly
    local scaled = n >= 0 and math.abs(x) * p or math.abs(x) / p
    local r = math.floor(finite(tonumber(("%.15g"):format(scaled))) + 0.5)
    r = n >= 0 and r / p or r * p
    return finite(x < 0 and r ~= 0 and -r or r)
  end,
  DATE = function(a)
    local y, m, d = want_int(a[1], "DATE"), want_int(a[2], "DATE"), want_int(a[3], "DATE")
    local day = types.days_from_civil(y, m, d)
    local y2, m2, d2 = types.civil_from_days(day)
    if y2 ~= y or m2 ~= m or d2 ~= d then
      fail(("DATE: %d-%d-%d is not a real date"):format(y, m, d))
    end
    return { day = day, fmt = 1 }
  end,
  TODAY = function(_, env)
    if not env.today then -- once per run, so every row agrees across midnight
      local t = os.date("*t")
      env.today = { day = types.days_from_civil(t.year, t.month, t.day), fmt = 1 }
    end
    return env.today
  end,
  YEAR = function(a)
    local y = civil(a[1], "YEAR")
    return y
  end,
  MONTH = function(a)
    local _, m = civil(a[1], "MONTH")
    return m
  end,
  DAY = function(a)
    local _, _, d = civil(a[1], "DAY")
    return d
  end,
}

local EVAL = {}

local function eval(node, env)
  return EVAL[node.k](node, env)
end

-- Functions that evaluate only the arguments they need: (arg nodes, env) -> value.
local LAZY = {
  IF = function(args, env)
    return eval(args[want(eval(args[1], env), "bool", "IF") and 2 or 3], env)
  end,
  AND = function(args, env)
    for _, arg in ipairs(args) do
      if not want(eval(arg, env), "bool", "AND") then
        return false
      end
    end
    return true
  end,
  OR = function(args, env)
    for _, arg in ipairs(args) do
      if want(eval(arg, env), "bool", "OR") then
        return true
      end
    end
    return false
  end,
  -- x on the n-th shown row before this one (env.p is this one's place);
  -- formula.prev_default when that is empty or there is no such row.
  PREV = function(args, env)
    local n = args[2] and want_int(eval(args[2], env), "PREV") or 1
    if n < 1 then
      fail("PREV: n must be 1 or more")
    end
    local i, p, v = env.i, env.p, ""
    if p - n >= 1 then
      env.p = p - n
      env.i = env.shown and env.shown[env.p] or env.p
      v = eval(args[1], env)
      env.i, env.p = i, p
    end
    return v == "" and prev_default(env.opts) or v
  end,
}

function EVAL.lit(node)
  return node.v
end

function EVAL.col(node, env)
  return value_of(env.cols[node.col][env.i], env.opts)
end

function EVAL.neg(node, env)
  return -want(eval(node.a, env), "number", "-")
end

function EVAL.op(node, env)
  local a, b = eval(node.a, env), eval(node.b, env)
  if MATH[node.op] then
    return arith(node.op, a, b)
  end
  return compare(node.op, a, b)
end

function EVAL.call(node, env)
  if LAZY[node.name] then
    return LAZY[node.name](node.args, env)
  end
  local vals = {}
  for i, arg in ipairs(node.args) do
    vals[i] = eval(arg, env)
  end
  return FN[node.name](vals, env)
end

-- Computed on first use and cached for the run, errors included.
function EVAL.agg(node, env)
  local id = node.name .. ":" .. node.col
  local hit = env.cache[id]
  if not hit then
    local ok, v = pcall(aggregate, node.name, node.col, env)
    if not ok and type(v) ~= "table" then
      error(v, 0)
    end
    hit = { ok, v }
    env.cache[id] = hit
  end
  if not hit[1] then
    error(hit[2], 0)
  end
  return hit[2]
end

-- The result of a row; a bare 1e999 (literal or cell) is caught here.
local function row_value(ast, env)
  local v = eval(ast, env)
  return type(v) == "number" and finite(v) or v
end

-- Evaluates ast with the resolved ctx.opts on the data rows ctx.shown lists,
-- in its order (default: rows 1 to ctx.n); the others are not evaluated, and
-- aggregates and PREV do not see them. ctx.cols[c] holds the data cells (no
-- header) of every column in columns(ast); a nil cell is a missing field.
-- Calls each(i, value) per row, or each(i, nil, message) where the row failed.
local function each_row(ast, ctx, each)
  local shown = ctx.shown
  local env = { cols = ctx.cols, n = ctx.n, opts = ctx.opts, cache = {}, shown = shown }
  for p = 1, shown and #shown or ctx.n do
    local i = shown and shown[p] or p
    env.i, env.p = i, p
    local ok, v = pcall(row_value, ast, env)
    if ok then
      each(i, v)
    elseif type(v) == "table" then
      each(i, nil, v.msg)
    else
      error(v, 0) -- a bug, not a row error
    end
  end
end

-- Evaluates ast as each_row does. Returns the formatted values (one string
-- per row evaluated, "" where it failed; nil for a row not shown), the failing
-- row indices in the order shown, and the first failure's message.
function M.eval_column(ast, ctx)
  local values, failures, first_err = {}, {}, nil
  each_row(ast, ctx, function(i, v, msg)
    if msg then
      values[i], failures[#failures + 1] = "", i
      first_err = first_err or msg
    else
      values[i] = types.format_value(v, ctx.opts)
    end
  end)
  return values, failures, first_err
end

-- ast, when a filter can use it; raises if it uses PREV, whose rows are the
-- visible ones, which a filter decides.
function M.filterable(ast)
  if ast.k == "call" and ast.name == "PREV" then
    error("csvkit: PREV works in addcol and setcol, not in filters", 0)
  end
  for _, child in ipairs(ast.args or { ast.a, ast.b }) do
    M.filterable(child)
  end
  return ast
end

-- For a filter, evaluates ast as each_row does: pass[i] is true where row i
-- gives TRUE (a row that fails or gives no bool is false; nil if not shown). Also returns, when
-- no row gave TRUE or FALSE, the first row's reason. Raises on PREV.
function M.matches(ast, ctx)
  M.filterable(ast)
  local pass, err, some = {}, nil, false
  each_row(ast, ctx, function(i, v, msg)
    pass[i] = v == true
    if type(v) == "boolean" then
      some = true
    elseif not err then
      err = msg or ("expected TRUE or FALSE, got %s"):format(typ(v))
    end
  end)
  return pass, not some and err or nil
end

return M
