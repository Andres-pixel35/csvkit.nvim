-- Writes .bench/NxC.csv, N data rows plus a header and C columns, for
-- tests/bench/run.lua and overlay.lua:
--   nvim --headless --clean -l tests/bench/gen.lua 1000000 [C]     (C defaults to 10)
-- The columns repeat the 10 kinds below, with fresh values and a number after
-- the name from the second round on (id, qty, ..., memo, id2, qty2, ...). C = 5
-- keeps id, qty, price, dmy and name. Fixed seed, so the same N and C give the
-- same file.
local root = vim.fn.fnamemodify(arg[0], ":p:h:h:h")
vim.opt.rtp:prepend(root)
local csv = require("csvkit.csv")
local types = require("csvkit.types")

local n = tonumber(arg[1]) or error("usage: gen.lua N [C]")
local ncols = tonumber(arg[2]) or 10
local KINDS = { "id", "qty", "price", "eu", "iso", "dmy", "flag", "name", "city", "memo" }
-- the kinds a file with fewer than 10 columns keeps
local KEEP = { [5] = { 1, 2, 3, 6, 8 } }
-- column j (1-based) is kind spec[j].kind of round spec[j].round
local spec = {}
for j = 1, ncols do
  local kind = KEEP[ncols] and KEEP[ncols][j] or (j - 1) % 10 + 1
  assert(kind, "C must be 5 or at least 10")
  spec[j] = { kind = kind, round = KEEP[ncols] and 1 or math.floor((j - 1) / 10) + 1 }
end
local NAMES = { "Ana", "Bo", "Carla", "Dmitri", "Eve", "Femi", "Gus", "Hana", "Ivo", "Jun" }
local CITIES = { "Lima, PE", "Paris, FR", "Oslo, NO", "Cusco, PE", "Lyon, FR" }
local START = types.days_from_civil(2000, 1, 1)
math.randomseed(42)

local function row(i)
  local y, m, d = types.civil_from_days(START + math.random(0, 9000))
  local cents = math.random(0, 999999)
  return {
    tostring(i), -- id: int
    i % 37 == 0 and "" or tostring(math.random(1, 100)), -- qty: int with empties
    ("%d.%02d"):format(math.floor(cents / 100), cents % 100), -- price: float
    ("%d,%02d"):format(math.floor(cents / 100), cents % 100), -- eu: comma-decimal text (quoted)
    ("%04d-%02d-%02d"):format(y, m, d), -- iso date
    ("%02d/%02d/%04d"):format(d, m, y), -- dmy date
    math.random() < 0.5 and "true" or "false", -- flag: bool
    NAMES[math.random(#NAMES)], -- name: short string
    'from "' .. CITIES[math.random(#CITIES)] .. '"', -- city: quoted, commas and quotes
    i % 1000 == 0 and "line one\nline two" or (i % 3 == 0 and "" or "ok"), -- memo: occasional multiline
  }
end

-- one row: a fresh set of the 10 kinds for each round, then the columns of spec
local function wide_row(i)
  local rounds, fields = {}, {}
  for j, c in ipairs(spec) do
    rounds[c.round] = rounds[c.round] or row(i)
    fields[j] = rounds[c.round][c.kind]
  end
  return fields
end

local names = {}
for j, c in ipairs(spec) do
  names[j] = KINDS[c.kind] .. (c.round > 1 and c.round or "")
end

vim.fn.mkdir(root .. "/.bench", "p")
local path = ("%s/.bench/%dx%d.csv"):format(root, n, ncols)
local f = assert(io.open(path, "w"))
local out = { table.concat(names, ",") }
for i = 1, n do
  out[#out + 1] = csv.serialize_row(wide_row(i), ",", false)
  if #out == 10000 then
    f:write(table.concat(out, "\n"), "\n")
    out = {}
  end
end
f:write(table.concat(out, "\n"), #out > 0 and "\n" or "")
f:close()

-- self-check: the first 2000 lines parse into rows of ncols fields (reading a
-- file of hundreds of MB back would take as much memory as the benchmark)
local t = csv.parse(vim.fn.readfile(path, "", 2000), ",")
assert(#t.rows >= 1000 and #t.rows[1] == ncols and #t.rows[2] == ncols and #t.rows[#t.rows - 1] == ncols)
io.write(("wrote %s (%.1f MB)\n"):format(path, vim.fn.getfsize(path) / 1e6))
