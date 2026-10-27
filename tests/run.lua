-- Headless test runner: nvim --headless --clean -l tests/run.lua [pattern]
-- Each tests/test_*.lua returns { ["name"] = function() ... end }.
-- [pattern] is a Lua pattern matched against "file: name".
local root = vim.fn.fnamemodify(arg[0], ":p:h:h")
vim.opt.rtp:prepend(root)
-- tests never touch the user's stdpath("data") / stdpath("state")
vim.env.XDG_DATA_HOME = vim.fn.tempname()
vim.env.XDG_STATE_HOME = vim.fn.tempname()

function _G.eq(actual, expected)
  if not vim.deep_equal(actual, expected) then
    error(("expected %s, got %s"):format(vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local pattern = arg[1]
local files = {}
for name, type in vim.fs.dir(root .. "/tests") do
  if type == "file" and name:match("^test_.*%.lua$") then
    table.insert(files, name)
  end
end
table.sort(files)

local passed, failed = 0, 0
local function report(id, ok, err)
  if ok then
    passed = passed + 1
    io.write("PASS " .. id .. "\n")
  else
    failed = failed + 1
    io.write("FAIL " .. id .. ": " .. tostring(err) .. "\n")
  end
end

for _, file in ipairs(files) do
  local ok, tests = xpcall(dofile, debug.traceback, root .. "/tests/" .. file)
  if not ok then
    report(file, false, tests)
  else
    local names = vim.tbl_keys(tests)
    table.sort(names)
    for _, name in ipairs(names) do
      local id = file .. ": " .. name
      if not pattern or id:find(pattern) then
        report(id, xpcall(tests[name], debug.traceback))
      end
    end
  end
end

io.write(("%d passed, %d failed\n"):format(passed, failed))
os.exit(failed > 0 and 1 or 0)
