-- Cell value types: number / date / bool / string / empty. Detection works on the
-- trimmed text; dates are day numbers (days since 1970-01-01, plus a fraction).
local M = {}

-- vim.trim without its argument validation, which costs ~40% per cell. Most
-- cells have no space at either end, so they are returned without a match.
local function trim(s)
  local a, b = s:byte(1), s:byte(-1)
  if a and a > 32 and b > 32 then
    return s
  end
  return s:match("^%s*(.*%S)") or ""
end
M.trim = trim

-- Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's
-- days_from_civil). Any year, no timezone, no os.time.
function M.days_from_civil(y, m, d)
  if m <= 2 then
    y = y - 1
  end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (m > 2 and m - 3 or m + 9) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

-- Inverse of days_from_civil: returns y, m, d.
function M.civil_from_days(z)
  z = z + 719468
  local era = math.floor(z / 146097)
  local doe = z - era * 146097
  local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local d = doy - math.floor((153 * mp + 2) / 5) + 1
  local m = mp < 10 and mp + 3 or mp - 9
  return yoe + era * 400 + (m <= 2 and 1 or 0), m, d
end

-- Parses the trimmed text as [+-] digits [decimal digits] [e[+-]digits], where
-- either side of the decimal may be empty but not both (".5", "5." and "0.5" are
-- numbers). Not tonumber, which takes hex, inf and nan. With opts.thousands set,
-- the integer part may be grouped, and then every group after the first has 3
-- digits. Separators are escaped as "%" .. sep (valid for any punctuation or
-- space; far cheaper per cell than vim.pesc).
local INT = {} -- thousands separator (false: none) -> pattern of the integer part
local FRAC = {} -- decimal separator -> pattern of the fraction and what follows

-- The digits of an integer part grouped by th, or nil unless the first group
-- has 1-3 digits and every later one exactly 3.
local function ungroup(int, th)
  local p = int:find(th, 1, true)
  if p > 4 then
    return nil
  end
  while p do
    local next_p = int:find(th, p + 1, true)
    if (next_p or #int + 1) - p ~= 4 then
      return nil
    end
    p = next_p
  end
  return (int:gsub("%" .. th, ""))
end

-- Whether byte b is a letter other than e / E.
local function letter(b)
  return b ~= nil and b ~= 69 and b ~= 101 and (b >= 65 and b <= 90 or b >= 97 and b <= 122)
end

function M.parse_number(s, opts)
  local th, dec = opts.thousands or false, opts.decimal
  s = trim(s)
  -- fast path: with "." decimals and no separator in the text, tonumber reads
  -- the same grammar, apart from hex (0x1), binary (0b1), inf, nan and suffixes
  -- (1LL, 1i). Each has a letter after the sign, one byte later, or at the end;
  -- checking those bytes is ~8x cheaper than a pattern over the text.
  if dec == "." and not (th and s:find(th, 1, true)) then
    local v = tonumber(s)
    if not v then
      return nil
    end
    local o = (s:byte(1) == 43 or s:byte(1) == 45) and 1 or 0 -- a sign
    if letter(s:byte(o + 1)) or letter(s:byte(o + 2)) or letter(s:byte(-1)) then
      return nil
    end
    return v
  end
  local sign, rest = s:match("^([+-]?)(.*)$")
  INT[th] = INT[th] or "^%d[%d" .. (th and "%" .. th or "") .. "]*"
  local int = rest:match(INT[th]) or ""
  rest = rest:sub(#int + 1)
  if th and int:find(th, 1, true) then
    int = ungroup(int, th)
    if not int then
      return nil
    end
  end
  FRAC[dec] = FRAC[dec] or "^%" .. dec .. "(%d*)(.*)$"
  local frac, exp = rest:match(FRAC[dec])
  if not frac then
    frac, exp = "", rest
  end
  if (int == "" and frac == "") or (exp ~= "" and not exp:match("^[eE][+-]?%d+$")) then
    return nil
  end
  return tonumber(sign .. "0" .. int .. "." .. frac .. "0" .. exp) -- the zeros fill an empty side
end

-- (decimal, thousands) pairs tried by detect_number_format; earlier wins a tie.
local NUMBER_FORMATS = {
  { ".", false },
  { ",", false },
  { ".", "," },
  { ",", "." },
  { ",", " " },
  { ".", " " },
  { ".", "'" },
  { ",", "'" },
}

-- Returns the decimal and thousands separators that read the most cells of rows
-- as numbers. Only an "auto" opts.decimal / opts.thousands is detected; any
-- other value is kept. No numeric evidence gives ".", false.
function M.detect_number_format(rows, opts)
  local best, best_count = nil, -1
  for _, f in ipairs(NUMBER_FORMATS) do
    local o = { decimal = opts.decimal, thousands = opts.thousands }
    if o.decimal == "auto" then
      o.decimal = f[1]
    end
    if o.thousands == "auto" then
      o.thousands = f[2] -- may be false, so not `and f[2] or`
    end
    if o.decimal ~= o.thousands then
      local count = 0
      for _, row in ipairs(rows) do
        for _, cell in ipairs(row) do
          if M.parse_number(cell, o) then
            count = count + 1
          end
        end
      end
      if count > best_count then
        best, best_count = o, count
      end
    end
  end
  return best.decimal, best.thousands
end

local FIELDS = { Y = "(%d%d%d%d)", m = "(%d%d?)", d = "(%d%d?)", H = "(%d%d?)", M = "(%d%d?)", S = "(%d%d?)" }
local compiled = {} -- format string -> { pat, at = directive -> capture index, min, max length }

-- Compiles a date format into an anchored Lua pattern. Kept apart from
-- compile(): a closure in a function stops LuaJIT compiling its callers.
local function build(fmt)
  local at, n, min, max = {}, 0, 0, 0
  local pat = vim.pesc(fmt):gsub("%%%%(.)", function(k)
    n, at[k] = n + 1, n + 1
    min, max = min + (k == "Y" and 4 or 1), max + (k == "Y" and 4 or 2)
    return FIELDS[k] or error(("csvkit: unsupported date directive %%%s in %q"):format(k, fmt), 0)
  end)
  if not (at.Y and at.m and at.d) then
    error(("csvkit: date format %q needs %%Y, %%m and %%d"):format(fmt), 0)
  end
  local literal = #fmt - 2 * n
  compiled[fmt] = { pat = "^" .. pat .. "$", at = at, min = min + literal, max = max + literal }
  return compiled[fmt]
end

local function compile(fmt)
  return compiled[fmt] or build(fmt)
end

local MONTH_DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function days_in_month(y, m)
  if m == 2 and y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0) then
    return 29
  end
  return MONTH_DAYS[m]
end

-- The number captured for directive k (0 when the format has none).
local function cap(at, k, ...)
  return at[k] and tonumber((select(at[k], ...))) or 0
end

-- The date value of the captures of format c (index i), or nil when nothing
-- matched or the captures are not a real date and time.
local function date_of(c, i, first, ...)
  if not first then
    return nil
  end
  local at = c.at
  local y, m, d = cap(at, "Y", first, ...), cap(at, "m", first, ...), cap(at, "d", first, ...)
  local hh, mm, ss = cap(at, "H", first, ...), cap(at, "M", first, ...), cap(at, "S", first, ...)
  if m >= 1 and m <= 12 and d >= 1 and d <= days_in_month(y, m) and hh < 24 and mm < 60 and ss < 60 then
    return { day = M.days_from_civil(y, m, d) + (hh * 3600 + mm * 60 + ss) / 86400, fmt = i }
  end
end

local function parse_date(s, formats)
  s = trim(s)
  for i, fmt in ipairs(formats) do
    local c = compile(fmt)
    if #s >= c.min and #s <= c.max then
      local v = date_of(c, i, s:match(c.pat))
      if v then
        return v
      end
    end
  end
  return nil
end

-- opts table -> { size, v = text -> date or false }. Dates repeat a lot in a
-- column, so this saves most of the parsing. Keyed by opts, not by its
-- date_formats (which get_opts shares with the setup() table), and with weak
-- keys, so a memo lives as long as one command's options.
local memos = setmetatable({}, { __mode = "k" })
local MEMO_MAX = 100000

-- Returns { day = days since 1970-01-01 (+ fraction of a day), fmt = index in
-- opts.date_formats } for the first format that matches a real calendar date.
-- The table may be shared with other calls: don't modify it.
function M.parse_date(s, opts)
  local memo = memos[opts]
  if not memo then
    memo = { size = 0, v = {} }
    memos[opts] = memo
  end
  local hit = memo.v[s]
  if hit ~= nil then
    return hit or nil
  end
  local v = parse_date(s, opts.date_formats)
  if memo.size < MEMO_MAX then
    memo.v[s], memo.size = v or false, memo.size + 1
  end
  return v
end

local BOOLS = { ["true"] = true, ["false"] = false }

-- true / false (any case), else nil.
function M.parse_bool(s)
  return BOOLS[trim(s):lower()]
end

-- "empty" | "number" | "date" | "bool" | "string"
function M.typeof(s, opts)
  s = trim(s)
  if s == "" then
    return "empty"
  elseif M.parse_number(s, opts) then
    return "number"
  elseif M.parse_date(s, opts) then
    return "date"
  elseif M.parse_bool(s) ~= nil then
    return "bool"
  end
  return "string"
end

-- The type shared by every non-empty cell, else "string". cells are one
-- column's data cells (no header).
function M.infer_column(cells, opts)
  local found
  for _, s in ipairs(cells) do
    local t = M.typeof(s, opts)
    if t ~= "empty" then
      if t == "string" or (found and t ~= found) then
        return "string"
      end
      found = t
    end
  end
  return found or "string"
end

-- A date value written in its date format.
local function format_date(v, opts)
  local secs = math.floor(v.day * 86400 + 0.5) -- rounding may carry into the next day
  local day = math.floor(secs / 86400)
  secs = secs - day * 86400
  local y, m, d = M.civil_from_days(day)
  local f = { Y = y, m = m, d = d, H = math.floor(secs / 3600), M = math.floor(secs % 3600 / 60), S = secs % 60 }
  return (opts.date_formats[v.fmt]:gsub("%%(%a)", function(k)
    return (k == "Y" and "%04d" or "%02d"):format(f[k])
  end))
end

-- Text for a value: integers as %d, other numbers as %.15g with opts.decimal,
-- bools as TRUE/FALSE, dates ({ day, fmt }) in their format, strings as is.
function M.format_value(v, opts)
  if type(v) == "number" then
    if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
      return ("%d"):format(v)
    end
    local text = ("%.15g"):format(v)
    return opts.decimal == "." and text or (text:gsub("%.", opts.decimal))
  elseif type(v) == "boolean" then
    return v and "TRUE" or "FALSE"
  elseif type(v) == "table" then
    return format_date(v, opts)
  end
  return v
end

return M
