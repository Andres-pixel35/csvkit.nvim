local sort = require("csvkit.sort")

local OPTS = { decimal = ".", thousands = false, date_formats = { "%Y-%m-%d", "%Y-%m-%d %H:%M:%S", "%d/%m/%Y" } }

-- Sorts the cells and returns them in sorted order.
local function sorted(cells, spec, opts)
  local out = {}
  for i, r in ipairs(sort.sort_rows(cells, spec, opts or OPTS)) do
    out[i] = cells[r]
  end
  return out
end

return {
  ["numbers sort by value, strings by text"] = function()
    eq(sorted({ "10", "9", "100", "-1.5" }, {}), { "-1.5", "9", "10", "100" })
    eq(sorted({ "10", "9", "100" }, { type = "string" }), { "10", "100", "9" })
  end,

  ["desc"] = function()
    eq(sorted({ "10", "9", "100" }, { desc = true }), { "100", "10", "9" })
    eq(sorted({ "b", "c", "a" }, { desc = true }), { "c", "b", "a" })
  end,

  ["returns a permutation and does not mutate the cells"] = function()
    local cells = { "3", "1", "2" }
    eq(sort.sort_rows(cells, {}, OPTS), { 2, 3, 1 })
    eq(cells, { "3", "1", "2" })
  end,

  ["stable on ties, both directions"] = function()
    local cells = { "1", "2", "1", "2", "1" }
    eq(sort.sort_rows(cells, {}, OPTS), { 1, 3, 5, 2, 4 })
    eq(sort.sort_rows(cells, { desc = true }, OPTS), { 2, 4, 1, 3, 5 })
    -- equal numbers written differently are ties too
    eq(sorted({ "1.0", "1", "01", "0" }, {}), { "0", "1.0", "1", "01" })
  end,

  ["empties last, both directions"] = function()
    -- "" and whitespace are both empty and keep their order
    local cells = { "", "2", "  ", "\t", "1" }
    eq(sort.sort_rows(cells, {}, OPTS), { 5, 2, 1, 3, 4 })
    eq(sort.sort_rows(cells, { desc = true }, OPTS), { 2, 5, 1, 3, 4 })
    eq(sorted({ "", "b", "a" }, { desc = true }), { "b", "a", "" })
  end,

  ["mixed column: inferred string, forced number puts non-numbers before empties"] = function()
    local values = { "b", "3", "", "1", "a", "10" }
    eq(sorted(values, {}), { "1", "10", "3", "a", "b", "" })
    eq(sorted(values, { type = "number" }), { "1", "3", "10", "a", "b", "" })
    eq(sorted(values, { type = "number", desc = true }), { "10", "3", "1", "b", "a", "" })
  end,

  ["string compare: case-insensitive, then case-sensitive"] = function()
    eq(sorted({ "b", "B", "a", "A", "c" }, {}), { "A", "a", "B", "b", "c" })
    eq(sorted({ "b", "B", "a", "A", "c" }, { desc = true }), { "c", "b", "B", "a", "A" })
    eq(sorted({ "apple", "Banana", "cherry" }, {}), { "apple", "Banana", "cherry" })
    eq(sorted({ " b", "a" }, {}), { "a", " b" }) -- compared on the trimmed text
  end,

  ["dates: ISO, day-first and datetimes compare as days"] = function()
    eq(sorted({ "2024-03-01", "2023-12-31", "2024-01-15" }, {}), { "2023-12-31", "2024-01-15", "2024-03-01" })
    -- as text, 01/02 (1 Feb) would come before 02/01 (2 Jan)
    eq(sorted({ "01/02/2024", "02/01/2024", "31/12/2023" }, {}), { "31/12/2023", "02/01/2024", "01/02/2024" })
    eq(
      sorted({ "2024-01-02", "2024-01-01 12:00:00", "01/01/2024", "2024-01-01 06:30:00" }, {}),
      { "01/01/2024", "2024-01-01 06:30:00", "2024-01-01 12:00:00", "2024-01-02" }
    )
    eq(sorted({ "2024-01-01", "soon", "2023-01-01" }, { type = "date" }), { "2023-01-01", "2024-01-01", "soon" })
  end,

  ["comma decimals"] = function()
    local o = vim.tbl_extend("force", OPTS, { decimal = ",", thousands = "." })
    eq(sorted({ "1.234,5", "10", "2,25", "-0,5" }, {}, o), { "-0,5", "2,25", "10", "1.234,5" })
  end,

  ["bools: false before true"] = function()
    eq(sorted({ "TRUE", "false", "", "True", "FALSE" }, {}), { "false", "FALSE", "TRUE", "True", "" })
  end,

  ["many cells: ordered, stable, empties last"] = function()
    math.randomseed(1)
    for _, n in ipairs({ 2, 3, 17, 1000 }) do
      local cells = {}
      for i = 1, n do
        cells[i] = math.random() < 0.1 and "" or tostring(math.random(0, 20))
      end
      for _, desc in ipairs({ false, true }) do
        local perm = sort.sort_rows(cells, { desc = desc }, OPTS)
        local seen = {}
        for k = 1, n do
          seen[perm[k]] = true
          if k > 1 then
            local a, b = perm[k - 1], perm[k]
            local va, vb = tonumber(cells[a]), tonumber(cells[b])
            local ok = not vb or (va and (va == vb and a < b or (desc and va > vb) or (not desc and va < vb)))
            if not va then -- empties: only empties follow, in their order
              ok = not vb and a < b
            end
            assert(ok, ("n=%d desc=%s: %s (%d) before %s (%d)"):format(n, desc, cells[a], a, cells[b], b))
          end
        end
        eq(vim.tbl_count(seen), n)
      end
    end
  end,

  ["many cells: numbers, text and empties match a reference sort"] = function()
    -- reference: table.sort on (group, key, tie, row); group 1 = number, 2 = text, 3 = empty
    local function reference(cells, desc)
      local rank = {}
      for i, c in ipairs(cells) do
        local s = vim.trim(c)
        local v = tonumber(s)
        rank[i] = s == "" and { 3 } or v and { 1, v, 0 } or { 2, s:lower(), s }
      end
      local rows = {}
      for i = 1, #cells do
        rows[i] = i
      end
      table.sort(rows, function(a, b)
        local x, y = rank[a], rank[b]
        if x[1] ~= y[1] then
          return x[1] < y[1]
        end
        for k = 2, #x do
          if x[k] ~= y[k] then
            return (x[k] < y[k]) ~= (desc == true)
          end
        end
        return a < b
      end)
      return rows
    end
    math.randomseed(2)
    local words = { "b", "B", "a", "A", " ab", "Ab", "aB", "c" }
    local function word() -- one of ~140k: mostly distinct
      local w = ""
      for _ = 1, math.random(1, 3) do
        w = w .. string.char(math.random(0, 1) == 0 and math.random(65, 90) or math.random(97, 122))
      end
      return w
    end
    -- few distinct values (sorted by rank) and mostly distinct ones (merged)
    local cases = {}
    for _, n in ipairs({ 15, 16, 17, 33, 1000, 3000 }) do
      local few, many = {}, {}
      for i = 1, n do
        local r = math.random()
        few[i] = r < 0.1 and "" or r < 0.4 and words[math.random(#words)] or tostring(math.random(0, 50))
        -- texts that share their first bytes compare past them
        local long = math.random() < 0.5 and "Same Start " .. word() or "same start" .. word()
        many[i] = r < 0.1 and "" or r < 0.3 and word() or r < 0.45 and long or tostring(math.random(0, 1e6))
      end
      vim.list_extend(cases, { few, many })
    end
    for _, cells in ipairs(cases) do
      local sorted_cells = {}
      for k, i in ipairs(reference(cells, false)) do
        sorted_cells[k] = cells[i]
      end
      local inputs = { cells, sorted_cells, vim.fn.reverse(vim.deepcopy(sorted_cells)) }
      for _, input in ipairs(inputs) do
        for _, desc in ipairs({ false, true }) do
          eq(sort.sort_rows(input, { desc = desc, type = "number" }, OPTS), reference(input, desc))
        end
      end
    end
  end,

  ["inferred number column: same order as the forced type"] = function()
    local cells = { "3", "", "1.5", " 2 ", "-1" }
    eq(sort.sort_rows(cells, {}, OPTS), sort.sort_rows(cells, { type = "number" }, OPTS))
    eq(sort.sort_rows(cells, {}, OPTS), { 5, 3, 4, 1, 2 })
    -- one text cell makes the column text
    eq(sorted({ "10", "9", "x" }, {}), { "10", "9", "x" })
  end,

  ["1-row and 0-row tables"] = function()
    eq(sort.sort_rows({ "x" }, {}, OPTS), { 1 })
    eq(sort.sort_rows({}, {}, OPTS), {})
    eq(sort.sort_rows({}, { type = "number" }, OPTS), {})
  end,
}
