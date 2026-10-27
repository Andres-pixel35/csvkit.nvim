-- The copy of a file as it was opened, and :Csvkit restore.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.cmd.runtime("plugin/csvkit.lua")

local ORIGINAL = { "name,age", "Ana,30", "Luis,25", "Mia,40", "Tom,35" }

local ERROR, WARN = vim.log.levels.ERROR, vim.log.levels.WARN
local OCT = function(s)
  return tonumber(s, 8)
end

-- Writes lines to a new .csv file (in dir, default the temp folder) and edits
-- it; returns the buffer.
local function open_file(lines, flags, dir)
  local file = (dir and dir .. "/a" or vim.fn.tempname()) .. ".csv"
  vim.fn.writefile(lines, file, flags or "")
  vim.cmd.edit(file)
  return vim.api.nvim_get_current_buf()
end

-- A new empty folder, so a test can list or lock what it holds.
local function new_dir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir)
  return dir
end

-- Runs fn; returns the vim.notify messages as { msg, level }.
local function capture(fn)
  local msgs, notify = {}, vim.notify
  vim.notify = function(msg, level)
    msgs[#msgs + 1] = { msg, level }
  end
  local ok, err = pcall(fn)
  vim.notify = notify
  assert(ok, err)
  return msgs
end

-- Runs fn with vim.fn.confirm answering answer (1 = first choice, 2 = cancel);
-- returns the questions asked.
local function confirming(answer, fn)
  local asked, confirm = {}, vim.fn.confirm
  vim.fn.confirm = function(msg)
    asked[#asked + 1] = msg
    return answer
  end
  local ok, err = pcall(fn)
  vim.fn.confirm = confirm
  assert(ok, err)
  return asked
end

-- Runs fn with vim.uv.fs_copyfile failing as a full disk does: after writing
-- part of its target.
local function no_space(fn)
  local copyfile = vim.uv.fs_copyfile
  vim.uv.fs_copyfile = function(_, dest)
    vim.fn.writefile({ "partial" }, dest)
    return nil, "ENOSPC: no space left on device"
  end
  local ok, err = pcall(fn)
  vim.uv.fs_copyfile = copyfile
  assert(ok, err)
end

local function lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

local function backup_of(buf)
  return (require("csvkit.backup").get(buf) or {}).path
end

-- Runs :Csvkit args; returns the vim.notify messages as { msg, level }.
local function csvkit(args)
  local msgs, notify = {}, vim.notify
  vim.notify = function(msg, level)
    msgs[#msgs + 1] = { msg, level }
  end
  local ok, err = pcall(vim.cmd, "Csvkit " .. args)
  vim.notify = notify
  assert(ok, err)
  return msgs
end

-- Starts a fresh `nvim --clean` with the repo on 'runtimepath', edits file,
-- runs the Lua chunk code, quits, and returns what the chunk wrote to stdout.
local function nvim(file, code)
  local r = vim.system({
    vim.v.progpath, "--headless", "--clean", "--cmd", "set rtp^=" .. root,
    "-c", "lua " .. code, "-c", "qa!", file,
  }):wait()
  assert(r.code == 0, r.stderr)
  return r.stdout
end

return {
  ["opening a file copies it; restore brings it back after edits and :w"] = function()
    local buf = open_file(ORIGINAL)
    local file = vim.api.nvim_buf_get_name(buf)
    eq(vim.fn.readfile(backup_of(buf)), ORIGINAL)
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "Eva,22" })
    vim.cmd("silent write")
    csvkit("sort age")
    vim.cmd("silent write")
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "new,1" })
    local before = lines()
    vim.o.undolevels = vim.o.undolevels
    eq(csvkit("restore"), {})
    eq(lines(), ORIGINAL)
    eq(vim.fn.readfile(file)[2], "Eva,22") -- the file is as last written until :w
    vim.cmd("silent undo") -- one step
    eq(lines(), before)
  end,

  ["restore writes only the lines that differ, nothing when none do"] = function()
    local buf = open_file(ORIGINAL)
    local changes = {}
    vim.api.nvim_buf_attach(buf, false, {
      on_lines = function(_, _, _, first, last, new_last)
        changes[#changes + 1] = { first, last, new_last }
      end,
    })
    local tick = vim.b.changedtick
    csvkit("restore")
    eq(vim.b.changedtick, tick)
    vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "x,1", "y,2" }) -- line 3 becomes two
    changes = {}
    csvkit("restore")
    eq(lines(), ORIGINAL)
    eq(changes, { { 2, 4, 3 } })
  end,

  [":e! and a restored :w keep the first copy"] = function()
    local buf = open_file(ORIGINAL)
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "Eva,22" })
    vim.cmd("silent write")
    vim.cmd("silent edit!")
    eq(lines()[2], "Eva,22")
    csvkit("restore")
    eq(lines(), ORIGINAL)
  end,

  ["restore after random edits, undos and reloads"] = function()
    math.randomseed(4)
    local original = {}
    for i = 1, 30 do
      original[i] = "r" .. i .. ",x"
    end
    for _ = 1, 200 do
      local buf = open_file(original)
      for _ = 1, math.random(1, 8) do
        local n, r = vim.api.nvim_buf_line_count(buf), math.random()
        local first = math.random(0, n)
        local last = math.min(n, first + math.random(0, 3))
        if r < 0.15 then
          vim.cmd("silent undo")
        elseif r < 0.2 then
          vim.cmd("silent edit!") -- unsaved changes go: the buffer is the file again
        elseif r < 0.25 then
          vim.cmd("silent write")
        else
          local new = {}
          for k = 1, math.random(0, 3) do
            new[k] = "new" .. k
          end
          vim.api.nvim_buf_set_lines(buf, first, last, false, new)
          vim.go.undolevels = vim.go.undolevels
        end
      end
      csvkit("restore")
      eq(lines(), original)
      vim.cmd("bwipeout! " .. buf)
    end
  end,

  ["restore after the buffer was unloaded, or changed before it was attached"] = function()
    local buf = open_file(ORIGINAL)
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "Eva,22" })
    vim.cmd("silent write | bunload") -- unloaded (as :q with 'nohidden'), copy kept
    vim.cmd("buffer " .. buf)
    vim.api.nvim_buf_set_lines(buf, 3, 4, false, { "x,1" })
    csvkit("restore")
    eq(lines(), ORIGINAL)
    -- changed before attach (setup() attaches loaded buffers): the copy is the file
    local file = vim.fn.tempname() .. ".csv"
    vim.fn.writefile(ORIGINAL, file)
    vim.cmd("noautocmd edit " .. file)
    vim.api.nvim_buf_set_lines(0, 1, 2, false, { "Eva,22" })
    require("csvkit").attach(vim.api.nvim_get_current_buf())
    vim.api.nvim_buf_set_lines(0, 3, 4, false, { "x,1" })
    csvkit("restore")
    eq(lines(), ORIGINAL)
  end,

  ["restore after the file changed outside and was reloaded"] = function()
    local buf = open_file(ORIGINAL)
    local file = vim.api.nvim_buf_get_name(buf)
    vim.bo[buf].autoread = true
    vim.uv.sleep(1100) -- so the file's mtime changes
    vim.fn.writefile({ "name,age", "Zoe,1" }, file)
    vim.cmd("checktime")
    eq(lines(), { "name,age", "Zoe,1" })
    csvkit("restore")
    eq(lines(), ORIGINAL)
  end,

  ["line endings and encoding come back as Neovim read them"] = function()
    local buf = open_file({ "a,b\r", "caf\233,2\r", "" }, "b") -- CRLF and Latin-1
    eq({ vim.bo[buf].fileformat, vim.bo[buf].fileencoding }, { "dos", "latin1" })
    eq(lines(), { "a,b", "café,2" })
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "3,4" })
    csvkit("restore")
    eq(lines(), { "a,b", "café,2" })
  end,

  [":bdelete and :bwipeout delete the copy"] = function()
    for _, cmd in ipairs({ "bdelete", "bwipeout" }) do
      local buf = open_file(ORIGINAL)
      local copy = backup_of(buf)
      eq(vim.fn.filereadable(copy), 1)
      vim.cmd(cmd .. " " .. buf)
      eq(vim.fn.filereadable(copy), 0)
      eq(backup_of(buf), nil)
    end
  end,

  ["quitting deletes the copies; a later Neovim deletes a crashed one's"] = function()
    local file = vim.fn.tempname() .. ".csv"
    vim.fn.writefile(ORIGINAL, file)
    local copy = nvim(file, [[io.stdout:write(require("csvkit.backup").get(0).path)]])
    eq(vim.fn.filereadable(copy), 0)
    eq(vim.fn.isdirectory(vim.fs.dirname(copy)), 0)
    -- the folder of a Neovim that is gone (no such pid), and of one running (this one)
    local dirs = vim.fn.stdpath("state") .. "/csvkit/backup/"
    vim.fn.mkdir(dirs .. "999999999", "p")
    vim.fn.writefile({ "x" }, dirs .. "999999999/1.orig")
    open_file(ORIGINAL) -- keeps this Neovim's folder alive
    nvim(file, "")
    eq(vim.fn.isdirectory(dirs .. "999999999"), 0)
    eq(vim.fn.isdirectory(dirs .. vim.fn.getpid()), 1)
  end,

  ["no copy: a new file, or a buffer with no file"] = function()
    vim.cmd.edit(vim.fn.tempname() .. ".csv") -- new file
    eq(backup_of(0), nil)
    eq(csvkit("restore"), { { "csvkit: no copy of this buffer's file as it was opened", vim.log.levels.ERROR } })
    eq(csvkit("restore now"), { { "csvkit: usage: restore [buffer|file]", ERROR } })
    eq(csvkit("restore file now"), { { "csvkit: usage: restore [buffer|file]", ERROR } })
  end,

  ["restore says so when the copy is gone or was changed, and edits nothing"] = function()
    for _, damage in ipairs({ "deleted", "truncated" }) do
      local buf = open_file(ORIGINAL)
      vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "Eva,22" })
      if damage == "deleted" then
        vim.uv.fs_unlink(backup_of(buf))
      else
        vim.fn.writefile({ "x" }, backup_of(buf))
      end
      local msg = ("csvkit: the copy of %s is missing or changed; can't restore"):format(vim.api.nvim_buf_get_name(buf))
      eq(csvkit("restore"), { { msg, ERROR } })
      eq(csvkit("restore file"), { { msg, ERROR } })
      eq(lines()[2], "Eva,22")
    end
  end,

  ["opening works when the state folder can't be written; one warning per file"] = function()
    local state, dir = vim.env.XDG_STATE_HOME, new_dir()
    vim.uv.fs_chmod(dir, OCT("555"))
    vim.env.XDG_STATE_HOME = dir
    local file = vim.fn.tempname() .. ".csv"
    vim.fn.writefile(ORIGINAL, file)
    local ok, msgs = pcall(capture, function()
      vim.cmd.edit(file)
      vim.cmd("silent edit!")
    end)
    vim.env.XDG_STATE_HOME = state
    vim.uv.fs_chmod(dir, OCT("755"))
    assert(ok, msgs)
    eq(lines(), ORIGINAL)
    eq(backup_of(0), nil)
    eq(#msgs, 1)
    eq(msgs[1][2], WARN)
    assert(vim.startswith(msgs[1][1], "csvkit: no copy of " .. file .. ": "), msgs[1][1])
    assert(msgs[1][1]:find("restore won't work for it", 1, true), msgs[1][1])
  end,

  ["a full disk while copying leaves no partial copy and a warning"] = function()
    local file = vim.fn.tempname() .. ".csv"
    vim.fn.writefile(ORIGINAL, file)
    local msgs
    no_space(function()
      msgs = capture(function()
        vim.cmd.edit(file)
      end)
    end)
    eq(lines(), ORIGINAL)
    eq(backup_of(0), nil)
    eq(#msgs, 1)
    assert(msgs[1][1]:find("ENOSPC", 1, true), msgs[1][1])
    local own = vim.fn.stdpath("state") .. "/csvkit/backup/" .. vim.fn.getpid() .. "/" .. vim.api.nvim_get_current_buf() .. ".orig"
    eq(vim.fn.filereadable(own), 0)
  end,

  ["no copy, no warning, no hang: a file that can't be read"] = function()
    local file = vim.fn.tempname() .. ".csv"
    vim.fn.writefile(ORIGINAL, file)
    vim.uv.fs_chmod(file, 0)
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, file)
    eq(capture(function()
      require("csvkit.backup").save(buf)
    end), {})
    eq(backup_of(buf), nil)
    vim.uv.fs_chmod(file, OCT("644"))
  end,

  ["no copy, a warning and no hang: a FIFO or a device"] = function()
    local fifo = vim.fn.tempname() .. ".csv"
    local paths = { "/dev/null" }
    if vim.fn.executable("mkfifo") == 1 then
      vim.system({ "mkfifo", fifo }):wait()
      paths[2] = fifo
    end
    for _, path in ipairs(paths) do
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buf, path)
      local msgs = capture(function()
        require("csvkit.backup").save(buf)
      end)
      eq(backup_of(buf), nil)
      eq(#msgs, 1)
      assert(msgs[1][1]:find("not a regular file", 1, true), msgs[1][1])
    end
  end,

  ["restore loads the copy with the encoding and format the file was opened with"] = function()
    local file = vim.fn.tempname() .. ".csv"
    vim.fn.writefile({ "name,n", "café,1" }, file) -- UTF-8, but read as Latin-1 below
    vim.cmd("edit ++enc=latin1 " .. vim.fn.fnameescape(file))
    local original = lines()
    eq(original[2], "cafÃ©,1")
    vim.api.nvim_buf_set_lines(0, 1, 2, false, { "x,2" })
    csvkit("restore")
    eq(lines(), original)
  end,

  ["restore file: the copy goes over the file (mode kept) and the buffer reloads"] = function()
    local buf = open_file(ORIGINAL)
    local file = vim.api.nvim_buf_get_name(buf)
    vim.uv.fs_chmod(file, OCT("640"))
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "Eva,22" })
    vim.cmd("silent write")
    csvkit("sort age")
    vim.cmd("silent write")
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "new,1" }) -- unsaved
    local asked = confirming(1, function()
      eq(csvkit("restore file"), {})
    end)
    eq(#asked, 1)
    assert(asked[1]:find("unsaved changes", 1, true), asked[1])
    eq(vim.fn.readfile(file), ORIGINAL)
    eq(vim.fn.readfile(file), vim.fn.readfile(backup_of(buf)))
    eq(vim.uv.fs_stat(file).mode % 4096, OCT("640"))
    eq(lines(), ORIGINAL)
    eq(vim.bo[buf].modified, false)
    eq(vim.fn.glob(file .. "*", false, true), { file }) -- no temp file left
    -- the change tracking is back, with nothing changed
    local copy = require("csvkit.backup").get(buf)
    eq({ copy.head, copy.tail }, { math.huge, math.huge })
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "Eva,22" })
    csvkit("restore")
    eq(lines(), ORIGINAL)
  end,

  ["restore runs no command hidden in the file's encoding name (a modeline can set it)"] = function()
    local file = vim.fn.tempname() .. ".csv"
    vim.fn.writefile(ORIGINAL, file)
    vim.cmd("noautocmd edit " .. file)
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].fileencoding = 'latin1|let g:csvkit_pwned = 1|"'
    require("csvkit").attach(buf) -- as setup() does for a buffer read before it
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "Eva,22" })
    local msgs = csvkit("restore")
    eq(vim.g.csvkit_pwned, nil)
    eq(#msgs, 1)
    eq(msgs[1][2], ERROR)
    assert(msgs[1][1]:find("encoding", 1, true), msgs[1][1])
    eq(lines()[2], "Eva,22")
  end,

  ["restore file writes through no link planted at its temp file's name"] = function()
    local dir = new_dir()
    local buf = open_file(ORIGINAL, nil, dir)
    local file = vim.api.nvim_buf_get_name(buf)
    local victim = new_dir() .. "/victim"
    vim.fn.writefile({ "keep" }, victim)
    vim.uv.fs_symlink(victim, ("%s/.a.csv.csvkit-%d.tmp"):format(dir, vim.fn.getpid()))
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "Eva,22" })
    vim.cmd("silent write")
    confirming(1, function()
      eq(csvkit("restore file"), {})
    end)
    eq(vim.fn.readfile(victim), { "keep" })
    eq(vim.uv.fs_stat(victim).mode % 4096, OCT("644"))
    eq(vim.fn.readfile(file), ORIGINAL)
    eq(vim.uv.fs_lstat(file).type, "file")
    eq(vim.fn.readdir(dir), { "a.csv" })
  end,

  ["the copies' folder is private to the user"] = function()
    local root_dir = vim.fn.stdpath("state") .. "/csvkit/backup"
    vim.fn.mkdir(root_dir, "p")
    vim.uv.fs_chmod(root_dir, OCT("755")) -- as an older version made it
    package.loaded["csvkit.backup"] = nil -- a fresh module starts over
    local ok, err = pcall(function()
      open_file(ORIGINAL)
      eq(vim.uv.fs_stat(root_dir).mode % 4096, OCT("700"))
    end)
    package.loaded["csvkit.backup"] = nil
    assert(ok, err)
  end,

  ["restore file: cancelling the question changes nothing; no question when nothing is lost"] = function()
    local buf = open_file(ORIGINAL)
    local file = vim.api.nvim_buf_get_name(buf)
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "Eva,22" })
    confirming(2, function()
      eq(csvkit("restore file"), {})
    end)
    eq(lines()[2], "Eva,22")
    eq(vim.bo[buf].modified, true)
    eq(vim.fn.readfile(file), ORIGINAL)
    vim.cmd("silent write") -- saved: nothing unsaved, and the history is small
    local asked = confirming(1, function()
      csvkit("restore file")
    end)
    eq(asked, {})
    eq(lines(), ORIGINAL)
    eq(vim.fn.readfile(file), ORIGINAL)
    -- nothing changed since: the file is not even touched
    local tick, stat = vim.b.changedtick, vim.uv.fs_stat(file)
    vim.uv.sleep(20)
    csvkit("restore file")
    eq(vim.b.changedtick, tick)
    eq(vim.uv.fs_stat(file).mtime, stat.mtime)
  end,

  ["restore file: asks before dropping the undo history, which a big reload loses"] = function()
    local undoreload = vim.o.undoreload
    vim.o.undoreload = 3 -- the 5-line buffer counts as big
    local buf = open_file(ORIGINAL)
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "Eva,22" })
    vim.cmd("silent write")
    local asked = confirming(1, function()
      csvkit("restore file")
    end)
    vim.o.undoreload = undoreload
    eq(#asked, 1)
    assert(asked[1]:find("undo history", 1, true), asked[1])
    assert(not asked[1]:find("unsaved", 1, true), asked[1])
    eq(lines(), ORIGINAL)
    eq(#vim.fn.undotree().entries, 0)
  end,

  ["restore file: warns before overwriting a file another program changed; recreates a deleted one"] = function()
    local buf = open_file(ORIGINAL)
    local file = vim.api.nvim_buf_get_name(buf)
    vim.fn.writefile({ "name,age", "Zoe,1,extra" }, file)
    local asked = confirming(2, function()
      csvkit("restore file")
    end)
    eq(#asked, 1)
    assert(asked[1]:find("another program", 1, true), asked[1])
    eq(vim.fn.readfile(file)[2], "Zoe,1,extra")
    confirming(1, function()
      csvkit("restore file")
    end)
    eq(vim.fn.readfile(file), ORIGINAL)
    vim.uv.fs_unlink(file)
    asked = confirming(1, function()
      csvkit("restore file")
    end)
    eq(asked, {})
    eq(vim.fn.readfile(file), ORIGINAL)
  end,

  ["restore file: a failed write leaves the file and the buffer as they were"] = function()
    local dir = new_dir()
    local buf = open_file(ORIGINAL, nil, dir)
    local file = vim.api.nvim_buf_get_name(buf)
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "Eva,22" })
    vim.cmd("silent write")
    vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "Max,9" }) -- unsaved
    local before = lines()
    local function fails(kind)
      local msgs
      confirming(1, function()
        msgs = csvkit("restore file")
      end)
      eq(#msgs, 1)
      eq(msgs[1][2], ERROR)
      assert(msgs[1][1]:find(kind, 1, true), msgs[1][1])
      eq(vim.fn.readfile(file)[2], "Eva,22")
      eq(lines(), before)
      eq(vim.bo[buf].modified, true)
      eq(vim.fn.readdir(dir), { "a.csv" }) -- no temp file left
    end
    no_space(function()
      fails("csvkit: can't restore " .. file .. ": ENOSPC")
    end)
    vim.uv.fs_chmod(dir, OCT("555")) -- no new file in it
    local ok, err = pcall(fails, "can't restore")
    vim.uv.fs_chmod(dir, OCT("755"))
    assert(ok, err)
    vim.uv.fs_chmod(file, OCT("444")) -- read-only: :w would refuse too
    ok, err = pcall(fails, "is read-only")
    vim.uv.fs_chmod(file, OCT("644"))
    assert(ok, err)
  end,

  ["restore file: a symlink stays a symlink"] = function()
    local dir = new_dir()
    local real, link = dir .. "/real.csv", dir .. "/link.csv"
    vim.fn.writefile(ORIGINAL, real)
    vim.uv.fs_symlink(real, link)
    vim.cmd.edit(link)
    vim.api.nvim_buf_set_lines(0, 1, 2, false, { "Eva,22" })
    vim.cmd("silent write")
    confirming(1, function()
      eq(csvkit("restore file"), {})
    end)
    eq(vim.uv.fs_lstat(link).type, "link")
    eq(vim.fn.readfile(real), ORIGINAL)
    eq(lines(), ORIGINAL)
  end,

  ["restore file works on a buffer that is not modifiable"] = function()
    local buf = open_file(ORIGINAL)
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "Eva,22" })
    vim.cmd("silent write")
    vim.bo[buf].modifiable = false
    eq(csvkit("restore file"), {})
    eq(lines(), ORIGINAL)
    vim.bo[buf].modifiable = true
  end,

  ["a renamed buffer: restore file refuses, restore buffer works"] = function()
    local buf = open_file(ORIGINAL)
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "Eva,22" })
    vim.cmd("file " .. vim.fn.fnameescape(vim.fn.tempname() .. ".csv"))
    local msg = "csvkit: the buffer was renamed since its copy was made; use :Csvkit restore buffer"
    eq(csvkit("restore file"), { { msg, ERROR } })
    eq(lines()[2], "Eva,22")
    eq(csvkit("restore buffer"), {})
    eq(lines(), ORIGINAL)
  end,

  ["restore.mode picks the default, and is checked"] = function()
    local buf = open_file(ORIGINAL)
    local file = vim.api.nvim_buf_get_name(buf)
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "Eva,22" })
    vim.cmd("silent write")
    vim.b.csvkit = { restore = { mode = "file" } }
    confirming(1, function()
      csvkit("restore")
    end)
    eq(vim.fn.readfile(file), ORIGINAL) -- the file itself was replaced
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "Eva,22" })
    vim.cmd("silent write")
    csvkit("restore buffer") -- the argument wins
    eq(vim.fn.readfile(file)[2], "Eva,22")
    eq(lines(), ORIGINAL)
    vim.b.csvkit = { restore = { mode = "disk" } }
    eq(csvkit("restore"), { { 'csvkit: restore.mode must be "buffer" or "file", not "disk"', ERROR } })
    vim.b.csvkit = nil
  end,

  ["restore completes its two modes"] = function()
    eq(vim.fn.getcompletion("Csvkit restore ", "cmdline"), { "buffer", "file" })
    eq(vim.fn.getcompletion("Csvkit restore f", "cmdline"), { "file" })
    eq(vim.fn.getcompletion("Csvkit restore file ", "cmdline"), {})
  end,

  ["deleting a copy that is already gone raises nothing"] = function()
    local buf = open_file(ORIGINAL)
    vim.uv.fs_unlink(backup_of(buf))
    vim.cmd("bwipeout " .. buf)
    eq(backup_of(buf), nil)
  end,

  ["restore loads the copy with the line format the file was opened with"] = function()
    local file = vim.fn.tempname() .. ".csv"
    vim.fn.writefile({ "a,b\r", "1,2\r", "" }, file, "b") -- CRLF, but read as unix below
    vim.cmd("edit ++ff=unix " .. vim.fn.fnameescape(file))
    local original = lines()
    eq(original, { "a,b\r", "1,2\r" })
    vim.api.nvim_buf_set_lines(0, 1, 2, false, { "3,4" })
    csvkit("restore")
    eq(lines(), original)
  end,

  ["restore leaves no scratch buffer behind"] = function()
    local buf = open_file(ORIGINAL)
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "Eva,22" })
    local before = #vim.api.nvim_list_bufs()
    csvkit("restore")
    eq(lines(), ORIGINAL)
    eq(#vim.api.nvim_list_bufs(), before)
  end,

  ["a recent folder whose pid can't be signalled (EPERM: pid 1) stays"] = function()
    local file = vim.fn.tempname() .. ".csv"
    vim.fn.writefile(ORIGINAL, file)
    local dir = vim.fn.stdpath("state") .. "/csvkit/backup/1"
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "x" }, dir .. "/1.orig")
    nvim(file, "")
    eq(vim.fn.isdirectory(dir), 1)
    vim.fn.delete(dir, "rf")
  end,

  ["restore.backup = false makes no copy; restore says there is none"] = function()
    require("csvkit").setup({ restore = { backup = false } })
    local buf = open_file(ORIGINAL)
    local copy = backup_of(buf)
    local msgs = csvkit("restore")
    require("csvkit").setup({})
    eq(copy, nil)
    eq(msgs, { { "csvkit: no copy of this buffer's file as it was opened (restore.backup is off)", ERROR } })
  end,

  ["a folder older than 30 days goes even when its pid runs; a recent one stays"] = function()
    local file = vim.fn.tempname() .. ".csv"
    vim.fn.writefile(ORIGINAL, file)
    local dirs = vim.fn.stdpath("state") .. "/csvkit/backup/"
    local alive = { vim.system({ "sleep", "30" }), vim.system({ "sleep", "30" }) } -- pids that run
    local old, recent = dirs .. alive[1].pid, dirs .. alive[2].pid
    for _, dir in ipairs({ old, recent }) do
      vim.fn.mkdir(dir, "p")
      vim.fn.writefile({ "x" }, dir .. "/1.orig")
    end
    local long_ago = os.time() - 31 * 86400
    vim.uv.fs_utime(old, long_ago, long_ago)
    nvim(file, "")
    for _, p in ipairs(alive) do
      p:kill(15)
    end
    eq({ vim.fn.isdirectory(old), vim.fn.isdirectory(recent) }, { 0, 1 })
  end,
}
