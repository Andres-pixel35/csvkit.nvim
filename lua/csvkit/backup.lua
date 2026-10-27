-- A copy of each attached file as it was read, for :Csvkit restore, even
-- after edits and :w. Copies live in stdpath("state")/csvkit/backup/<pid>/
-- (not /tmp, often RAM) and go with their buffer (:bdelete, :bwipeout) or
-- when Neovim exits; the folders of Neovims that died are deleted by the next
-- one that makes a copy.
local M = {}

-- buffer -> { path, file, fenc, ff, lines = its line count, head, tail, size,
-- stored, seen }: head / tail are the lines at the start / end of the buffer
-- that no change has touched since it was read (math.huge: no change yet; 0
-- when unknown), so a restore reads only the lines between them. file is the
-- name the copy was made from, fenc / ff the buffer's encoding and format
-- then. stored is the copy's own size and mtime, to notice that it was
-- changed or deleted; seen is the file's size and mtime when this Neovim last read or
-- wrote it, to notice that another program changed it.
local copies = {}
local started = false
local warned = {} -- file -> true: no copy could be made, said once
local STALE_DAYS = 30 -- a folder this old is deleted even if its pid is alive

local function root()
  return vim.fn.stdpath("state") .. "/csvkit/backup"
end

local function own_dir()
  return root() .. "/" .. vim.fn.getpid()
end

-- { size, sec, nsec } of path, or nil when it can't be read: two of them are
-- equal when the file has not changed.
local function stamp(path)
  local st = vim.uv.fs_stat(path)
  return st and { size = st.size, sec = st.mtime.sec, nsec = st.mtime.nsec }
end

-- Deletes buf's copy, if it has one.
function M.drop(buf)
  if copies[buf] then
    vim.uv.fs_unlink(copies[buf].path)
    copies[buf] = nil
  end
end

-- Narrows copy's head and tail on every change of buf. A reload of a file
-- changed outside (:checktime, on_reload) or an unload (:e!, :bunload, which
-- also detach) makes them unknown: a restore then compares every line.
local function track(buf, copy)
  local function unknown()
    copy.head, copy.tail = 0, 0
  end
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function(_, _, _, first, _, last_new)
      if copies[buf] ~= copy then
        return true -- dropped: detach
      end
      copy.head = math.min(copy.head, first)
      copy.tail = math.min(copy.tail, vim.api.nvim_buf_line_count(buf) - last_new)
    end,
    on_reload = unknown,
    on_detach = unknown,
  })
end

-- First copy of this Neovim: clean up after dead ones, delete on exit.
local function start()
  started = true
  -- the copies may be of files other users can't read where they are
  local private = tonumber("700", 8)
  vim.fn.mkdir(root(), "p", private)
  vim.uv.fs_chmod(root(), private) -- older csvkit versions made it 755
  for name, kind in vim.fs.dir(root()) do
    local pid = tonumber(name)
    if kind == "directory" and pid and pid ~= vim.fn.getpid() then
      -- kill(pid, 0) only checks the process exists, and a dead Neovim's pid
      -- may be another program's by now: an old folder goes either way. Only
      -- ESRCH means no such process (EPERM: it runs, as another user)
      local st = vim.uv.fs_stat(root() .. "/" .. name)
      local old = st and os.time() - st.mtime.sec > STALE_DAYS * 86400
      local _, _, err = vim.uv.kill(pid, 0)
      if old or err == "ESRCH" then
        vim.fn.delete(root() .. "/" .. name, "rf")
      end
    end
  end
  local group = vim.api.nvim_create_augroup("csvkit_backup", {})
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    callback = function(a)
      M.drop(a.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(a)
      local copy = copies[a.buf]
      if copy and copy.file == vim.api.nvim_buf_get_name(a.buf) then
        copy.seen = stamp(copy.file)
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      vim.fn.delete(own_dir(), "rf")
    end,
  })
end

-- Makes buf's copy of file; raises the reason when it can't.
local function make_copy(buf, file)
  local st = vim.uv.fs_stat(file)
  if not st or st.type ~= "file" then
    error("not a regular file", 0) -- a FIFO would block the copy
  end
  if not started then
    start()
  end
  vim.fn.mkdir(own_dir(), "p")
  local path = ("%s/%d.orig"):format(own_dir(), buf)
  -- copied by the kernel, never read into Lua; a free clone where the file
  -- system can (btrfs, xfs)
  local ok, err = vim.uv.fs_copyfile(file, path, { ficlone = true })
  if not ok then
    vim.uv.fs_unlink(path) -- a full disk leaves part of it
    error(err, 0)
  end
  -- changed before it was attached (setup() attaches loaded buffers): unknown
  local edge = vim.bo[buf].modified and 0 or math.huge
  local copy = {
    path = path,
    file = file,
    fenc = vim.bo[buf].fileencoding,
    ff = vim.bo[buf].fileformat,
    lines = vim.api.nvim_buf_line_count(buf),
    head = edge,
    tail = edge,
    seen = stamp(file),
  }
  copy.stored = stamp(path)
  copies[buf] = copy
  track(buf, copy)
end

-- Copies buf's file once per buffer: a re-read (:e!) keeps the first copy. A
-- new file (nothing on disk yet) or one that can't be read gets none; when a
-- copy can't be made the file is named once and opening goes on.
function M.save(buf)
  local file = vim.api.nvim_buf_get_name(buf)
  local copy = copies[buf]
  if copy then
    if copy.file == file then
      copy.seen = stamp(file) -- read again
    end
    return
  elseif file == "" or vim.fn.filereadable(file) == 0 then
    return
  end
  local ok, err = pcall(make_copy, buf, file)
  if not ok and not warned[file] then
    warned[file] = true
    local msg = "csvkit: no copy of %s: %s; :Csvkit restore won't work for it"
    vim.notify(msg:format(file, err), vim.log.levels.WARN)
  end
end

-- buf's copy (0: the current buffer) as { path, lines, head, tail, ... }, or
-- nil. Treat it as read-only.
function M.get(buf)
  return copies[buf == 0 and vim.api.nvim_get_current_buf() or buf]
end

-- Like get, but raises when there is no copy or it is gone or was changed
-- (a restore from it would corrupt the buffer).
function M.check(buf)
  local copy = M.get(buf)
  if not copy then
    local off = not require("csvkit").get_opts(buf).restore.backup and " (restore.backup is off)" or ""
    error("csvkit: no copy of this buffer's file as it was opened" .. off, 0)
  elseif not vim.deep_equal(stamp(copy.path), copy.stored) then
    error(("csvkit: the copy of %s is missing or changed; can't restore"):format(copy.file), 0)
  end
  return copy
end

-- Lines [first, last) (0-based) of buf's copy as Neovim read the file: its
-- encoding and line format are the ones the buffer was opened with.
function M.lines(buf, first, last)
  local copy = M.check(buf)
  -- it goes into an Ex command, and a modeline can set it to any text:
  -- "latin1 x|!cmd" would run cmd. Encoding names are letters, digits and -
  if not copy.fenc:match("^[%w%-]*$") then
    error(("csvkit: can't restore: the file's encoding %q is not a valid name"):format(copy.fenc), 0)
  end
  local scratch = vim.api.nvim_create_buf(false, true)
  local ok, lines = pcall(function()
    local opts = (copy.fenc ~= "" and " ++enc=" .. copy.fenc or "") .. " ++ff=" .. copy.ff
    vim.api.nvim_buf_call(scratch, function()
      vim.cmd(("silent noautocmd keepalt 0read%s %s"):format(opts, vim.fn.fnameescape(copy.path)))
    end)
    -- :read leaves the empty line the buffer started with after the text
    local n = vim.api.nvim_buf_line_count(scratch)
    return vim.api.nvim_buf_get_lines(scratch, first, math.min(last, n > 1 and n - 1 or n), false)
  end)
  vim.api.nvim_buf_delete(scratch, { force = true })
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == copy.path then
      vim.api.nvim_buf_delete(b, { force = true }) -- :read lists the file it read
    end
  end
  if not ok then
    error(lines, 0)
  end
  return lines
end

-- Puts a copy of src over target: written next to it and renamed over it, so
-- a full disk or a crash never leaves it half-written. The file's mode is
-- kept. Raises a csvkit: error and leaves target as it was when it fails.
local function replace(src, target)
  local st = vim.uv.fs_stat(target)
  if st and not vim.uv.fs_access(target, "W") then
    error(("csvkit: %s is read-only; can't restore it"):format(target), 0)
  end
  local tmp = ("%s/.%s.csvkit-%d.tmp"):format(vim.fs.dirname(target), vim.fs.basename(target), vim.fn.getpid())
  -- the name is easy to guess: in a folder others can write, a link put there
  -- would be written through, so whatever is there goes and excl makes a new file
  vim.uv.fs_unlink(tmp)
  local ok, err = vim.uv.fs_copyfile(src, tmp, { excl = true, ficlone = true })
  if ok then
    ok, err = vim.uv.fs_chmod(tmp, st and st.mode % 4096 or vim.uv.fs_stat(src).mode % 4096)
  end
  if ok then
    ok, err = vim.uv.fs_rename(tmp, target)
  end
  if not ok then
    vim.uv.fs_unlink(tmp)
    error(("csvkit: can't restore %s: %s; the file is unchanged"):format(target, err), 0)
  end
end

-- What a reload of buf now would lose, as a list of words.
local function losses(buf, changed)
  local lost = {}
  if vim.bo[buf].modified then
    lost[#lost + 1] = "unsaved changes"
  end
  -- :e! saves the buffer for undo only below 'undoreload' lines (any
  -- number when negative); above it the undo history goes
  local ur = vim.o.undoreload
  if ur >= 0 and vim.api.nvim_buf_line_count(buf) >= ur and vim.api.nvim_buf_call(buf, vim.fn.undotree).seq_last > 0 then
    lost[#lost + 1] = "the undo history"
  end
  if changed then
    lost[#lost + 1] = "the changes another program made to the file"
  end
  return lost
end

-- Puts back buf's file as it was opened by replacing the file itself with the
-- copy and reloading the buffer. Unsaved changes, the undo history (a reload
-- of more than 'undoreload' lines drops it) and another program's changes to
-- the file are asked about first. The change tracking starts again, with
-- nothing changed.
function M.restore_file(buf)
  local copy = M.check(buf)
  local file = vim.api.nvim_buf_get_name(buf)
  if file ~= copy.file then
    error("csvkit: the buffer was renamed since its copy was made; use :Csvkit restore buffer", 0)
  end
  local target = vim.uv.fs_realpath(file) or file -- a symlink stays one
  local now = stamp(target)
  local changed = now ~= nil and not vim.deep_equal(now, copy.seen)
  if now and not changed and copy.head == math.huge and not vim.bo[buf].modified then
    return -- the file is the copy
  end
  local lost = losses(buf, changed)
  local question = ("Restore %s from its copy? This discards %s."):format(file, table.concat(lost, ", "))
  if #lost > 0 and vim.fn.confirm(question, "&Restore\n&Cancel", 2) ~= 1 then
    return
  end
  replace(copy.path, target)
  local ok, err = pcall(vim.api.nvim_buf_call, buf, function()
    vim.cmd("silent edit!")
  end)
  if not ok then
    error(("csvkit: restored %s but couldn't reload the buffer: %s; use :e!"):format(file, err), 0)
  end
  copy.seen = stamp(target)
  copy.head, copy.tail, copy.lines = math.huge, math.huge, vim.api.nvim_buf_line_count(buf)
  track(buf, copy) -- the reload detached it
  require("csvkit.memory").after_edit(require("csvkit").get_opts(buf), copy.lines)
end

return M
