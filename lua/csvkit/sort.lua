-- Sort engine shared by the buffer sort and the view: returns a permutation of
-- row indices and never moves the rows themselves.
local types = require("csvkit.types")

local M = {}

-- Sort key of a non-empty trimmed cell for a column type, or nil when the cell
-- does not have that type. "string" has none: every cell sorts as text.
local KEY = {
  number = types.parse_number,
  date = function(s, opts)
    local d = types.parse_date(s, opts)
    return d and d.day
  end,
  bool = function(s)
    local b = types.parse_bool(s)
    if b ~= nil then
      return b and 1 or 0
    end
  end,
}

-- The sort key of a text: its first 6 bytes, ASCII letters lowercased, as one
-- number (0 past the end). Numbers order like the lowercased texts as far as
-- those bytes go, and compare without reading the strings, which are spread
-- over memory: sorting 1M distinct texts by their strings is ~5x slower.
local function prefix(text)
  local key = 0
  for i = 1, 6 do
    local b = text:byte(i) or 0
    key = key * 256 + ((b >= 65 and b <= 90) and b + 32 or b)
  end
  return key
end

-- The lowercased text of row r, for a sort state s (see before), made once.
local function lower_of(s, r)
  local low = s.low[r]
  if not low then
    low = s.text[r]:lower()
    s.low[r] = low
  end
  return low
end

-- Whether position a sorts strictly before position b, for a sort state s =
-- { keys, rows, desc, text, low } (keys and rows: the lists being merged). By
-- key; for text (s.text[row]: the trimmed text, s.low: lower_of's cache), keys
-- are prefixes, then the lowercased texts, then the texts break ties.
-- Module-level with its state as an argument: a LuaJIT trace keeps the
-- function it was recorded with, so a per-sort closure would keep the sort's
-- tables.
local function before(s, a, b)
  local ka, kb = s.keys[a], s.keys[b]
  if ka == kb and s.text then
    local ra, rb = s.rows[a], s.rows[b]
    ka, kb = lower_of(s, ra), lower_of(s, rb)
    if ka == kb then
      ka, kb = s.text[ra], s.text[rb]
    end
  end
  if ka == kb then
    return false
  elseif s.desc then
    return ka > kb
  end
  return ka < kb
end

local RUN = 16 -- rows insertion-sorted before the merges start

-- Stable sort of rows by their parallel list keys (both reordered in place),
-- for s = { desc, text, low } (see before); returns the sorted rows (rows
-- itself or a new table). A bottom-up merge sort in plain Lua, so LuaJIT
-- compiles it with the comparator (table.sort calls it from C, which LuaJIT
-- can't). The keys move with the rows: reading them in order is ~5x faster
-- than looking each one up by row.
local function merge_sort(rows, keys, s)
  local n = #rows
  s.keys, s.rows = keys, rows
  for lo = 1, n, RUN do
    for k = lo + 1, math.min(lo + RUN - 1, n) do
      local j = k
      while j > lo and before(s, j, j - 1) do
        keys[j], keys[j - 1], rows[j], rows[j - 1] = keys[j - 1], keys[j], rows[j - 1], rows[j]
        j = j - 1
      end
    end
  end
  local k1, r1, k2, r2, width = keys, rows, {}, {}, RUN
  while width < n do
    s.keys, s.rows = k1, r1
    for lo = 1, n, 2 * width do
      local mid, hi = math.min(lo + width, n + 1), math.min(lo + 2 * width, n + 1)
      if mid < hi and before(s, mid, mid - 1) then
        local i, j = lo, mid
        for k = lo, hi - 1 do
          if j < hi and (i >= mid or before(s, j, i)) then
            k2[k], r2[k], j = k1[j], r1[j], j + 1
          else
            k2[k], r2[k], i = k1[i], r1[i], i + 1
          end
        end
      else -- the two runs are already in order
        for k = lo, hi - 1 do
          k2[k], r2[k] = k1[k], r1[k]
        end
      end
    end
    k1, r1, k2, r2, width = k2, r2, k1, r1, width * 2
  end
  return r1
end

-- sort_group for keys that repeat: the distinct keys are sorted once, then
-- the rows are placed by a counting sort. Returns the sorted rows.
local function rank_sort(rows, keys, s)
  local id_of, values, ids, u = {}, {}, {}, 0
  for k = 1, #rows do
    local id = id_of[keys[k]]
    if not id then
      u = u + 1
      id, values[u], id_of[keys[k]] = u, keys[k], u
    end
    ids[k] = id
  end
  -- order the distinct values (merge_sort's rows are their ids)
  local order, order_keys = {}, {}
  for id = 1, u do
    order[id], order_keys[id] = id, s.fold and prefix(values[id]) or values[id]
  end
  order = merge_sort(order, order_keys, { desc = s.desc, text = s.fold and values, low = {} })
  -- at[id]: the next position for a row with value id
  local at, pos = {}, 1
  for id = 1, u do
    at[id] = 0
  end
  for k = 1, #rows do
    at[ids[k]] = at[ids[k]] + 1
  end
  for p = 1, u do
    local id = order[p]
    at[id], pos = pos, pos + at[id]
  end
  local out = {}
  for k = 1, #rows do
    local id = ids[k]
    out[at[id]], at[id] = rows[k], at[id] + 1
  end
  return out
end

local SAMPLE = 1000 -- rows whose distinct keys choose how sort_group sorts

-- Sorts rows by their parallel keys, stably, for s = { desc, fold }; with
-- fold the keys are text, compared lowercased, then as they are. A column with
-- few distinct values (names, dates) goes to rank_sort, ~5x faster there; one
-- with mostly distinct values is merged row by row, where ranking is slower.
local function sort_group(rows, keys, s)
  local seen, u, n = {}, 0, math.min(#rows, SAMPLE)
  for k = 1, n do
    if not seen[keys[k]] then
      seen[keys[k]], u = true, u + 1
    end
  end
  if u <= n / 2 then
    return rank_sort(rows, keys, s)
  end
  local text = s.fold and {}
  if text then
    for k = 1, #rows do
      text[rows[k]], keys[k] = keys[k], prefix(keys[k])
    end
  end
  return merge_sort(rows, keys, { desc = s.desc, text = text, low = {} })
end

-- Splits the rows of cells into { typed, typed_keys, text, text_keys, empty }
-- by key_of (nil: every non-empty cell is text, keyed by its trimmed text).
-- With strict, returns nil at the first non-empty cell key_of rejects.
local function split(cells, key_of, opts, strict)
  local p = { typed = {}, typed_keys = {}, text = {}, text_keys = {}, empty = {} }
  local typed, text, empty = 0, 0, 0
  for i, cell in ipairs(cells) do
    local s = types.trim(cell)
    local k = s ~= "" and key_of and key_of(s, opts)
    if s == "" then
      empty = empty + 1
      p.empty[empty] = i
    elseif k then
      typed = typed + 1
      p.typed[typed], p.typed_keys[typed] = i, k
    elseif strict then
      return nil
    else
      text = text + 1
      p.text[text], p.text_keys[text] = i, s
    end
  end
  return p
end

-- Returns the row indices of cells (one column's data cells, no header) in
-- sorted order. spec = { desc, type }; type is "number" | "date" | "bool" |
-- "string" and defaults to types.infer_column. Order: cells of the type, then
-- other non-empty cells as text (both follow desc), then empty cells, which
-- always come last. Text compares case-insensitively, then case-sensitively;
-- any remaining tie keeps the original order.
function M.sort_rows(cells, spec, opts)
  -- a column whose non-empty cells all read as numbers is what infer_column
  -- calls a number column, so that is tried first: one pass instead of two
  local p = not spec.type and split(cells, KEY.number, opts, true)
    or split(cells, KEY[spec.type or types.infer_column(cells, opts)], opts)
  local rows = sort_group(p.typed, p.typed_keys, { desc = spec.desc })
  vim.list_extend(rows, sort_group(p.text, p.text_keys, { desc = spec.desc, fold = true }))
  return vim.list_extend(rows, p.empty)
end

return M
