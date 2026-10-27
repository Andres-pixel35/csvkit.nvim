-- In-buffer alignment. Extmarks on the visible lines pad each field to the
-- widest cell of its column (measured over the whole file) and show the
-- delimiter as align.separator; the buffer text is never changed. A winbar
-- shows the header row, so it stays in view. Lines do not wrap: a wrapped line
-- puts its last columns under its first ones.
local csvkit = require("csvkit")

local M = {}

M.DEBOUNCE = 100 -- ms after the last edit before the widths are measured again
M.SLICE = 8 -- ms of the width scan per slice, so the editor stays responsive
M.CHUNK = 5000 -- lines read at a time by the width scan
M.INCREMENTAL = 1000 -- an in-place edit of up to this many lines grows the widths at once

M.states = {} -- buf -> state, for the buffers with the overlay on

local api, find, byte, sub, rep = vim.api, string.find, string.byte, string.sub, string.rep
local ns = api.nvim_create_namespace("csvkit_align")
local group = api.nvim_create_augroup("csvkit_align", { clear = false })
local WINBAR = "%{%v:lua.require'csvkit.overlay'.winbar()%}"
local QUOTE = 34 -- '"'

-- Finds the fields of one line from byte pos (default 1), as in csv.lua (a quote
-- only opens a field when it starts one). Fills out with the first and last byte
-- of each field, and returns the length of that list, or nil when a quoted field
-- does not close on this line (the record goes on in the next one).
local function split(line, delim, out, pos)
  local n, dlen = 0, #delim
  pos = pos or 1
  while true do
    local from = pos
    if byte(line, pos) == QUOTE then
      local q = pos
      while true do
        q = find(line, '"', q + 1, true)
        if not q then
          return nil
        elseif byte(line, q + 1) ~= QUOTE then
          break
        end
        q = q + 1
      end
      from = q + 1
    end
    local d = find(line, delim, from, true)
    out[n + 1], out[n + 2] = pos, (d or #line + 1) - 1
    n = n + 2
    if not d then
      return n
    end
    pos = d + dlen
  end
end

-- Whether the record ends on a line that starts inside a quoted field: the field
-- closes, and no later field opens a quote it does not close.
local function closes(line, delim, out)
  local q = 0
  while true do
    q = find(line, '"', q + 1, true)
    if not q then
      return false
    elseif byte(line, q + 1) ~= QUOTE then
      break
    end
    q = q + 1
  end
  local d = find(line, delim, q + 1, true)
  return not d or split(line, delim, out, d + #delim) ~= nil
end

-- The display width of the field out[k]..out[k + 1] of line.
local function width(line, out, k, wide)
  if wide then
    return api.nvim_strwidth(sub(line, out[k], out[k + 1]))
  end
  return out[k + 1] - out[k] + 1
end

-- Reads lines (the buffer's lines from lnum first) into ctx = { widths, opens,
-- delim, sticky }: widths[c] grows to the widest field of column c, and
-- opens[l] is true when line l is inside a record that goes on in the next
-- line. The lines of such a record are left out of the widths. With sticky,
-- a header field counts with its index ("0 name"), as the winbar shows it.
local function scan(ctx, first, lines)
  local widths, opens, delim, out = ctx.widths, ctx.opens, ctx.delim, {}
  local cont = opens[first - 1] or false
  local index = ctx.sticky and first == 1 -- the header line is lines[1]
  for i, line in ipairs(lines) do
    if cont then
      cont = not closes(line, delim, out)
    else
      local n = split(line, delim, out)
      cont = n == nil
      if n then
        local wide = find(line, "[\128-\255]")
        for k = 1, n, 2 do
          local c, w = (k + 1) / 2, width(line, out, k, wide)
          if index and i == 1 then
            w = w + #tostring(c - 1) + 1
          end
          if w > (widths[c] or 0) then
            widths[c] = w
          end
        end
      end
    end
    opens[first + i - 1] = cont or nil
  end
end

-- Pads and separators of lines top..bot of state's buffer (not those in seen).
local function draw(state, range, seen)
  local buf, widths, opens, delim, out = state.buf, state.widths, state.opens, state.delim, {}
  local dlen = #delim
  for i, line in ipairs(api.nvim_buf_get_lines(buf, range[1] - 1, range[2], false)) do
    local l = range[1] + i - 1
    if not seen[l] and not (opens[l - 1] or opens[l]) then
      seen[l] = true
      local n = split(line, delim, out)
      local wide = n and find(line, "[\128-\255]")
      -- every field but the last is followed by a delimiter
      for k = 1, (n or 0) - 2, 2 do
        local w = width(line, out, k, wide)
        local pad = (widths[(k + 1) / 2] or w) - w
        local col = out[k + 1] -- the delimiter, 0-based
        api.nvim_buf_set_extmark(buf, ns, l - 1, col, {
          end_col = col + dlen,
          conceal = state.sep,
          virt_text = { { rep(" ", pad + 1) } },
          virt_text_pos = "inline",
        })
        api.nvim_buf_set_extmark(buf, ns, l - 1, col + dlen, { virt_text = { { " " } }, virt_text_pos = "inline" })
      end
    end
  end
end

-- The line ranges win shows, from its top line down for as many screen lines
-- as it is high. A closed fold takes one screen line and its lines are left
-- out (a filter folds thousands of them).
local function shown(win, total)
  local info = vim.fn.getwininfo(win)[1]
  local ranges, l = {}, info.topline
  api.nvim_win_call(win, function()
    for _ = 1, info.height do
      if l > total then
        break
      end
      local stop = vim.fn.foldclosedend(l)
      if stop ~= -1 then
        l = stop
      elseif ranges[#ranges] and ranges[#ranges][2] == l - 1 then
        ranges[#ranges][2] = l
      else
        ranges[#ranges + 1] = { l, l }
      end
      l = l + 1
    end
  end)
  return ranges
end

local function signature(ranges)
  local flat = {}
  for _, r in ipairs(ranges) do
    flat[#flat + 1] = r[1] .. "-" .. r[2]
  end
  return table.concat(flat, ",")
end

-- Draws the visible lines of every window showing buf, and nothing else.
function M.redraw(buf)
  local state = M.states[buf]
  if not state then
    return
  end
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local total, seen = api.nvim_buf_line_count(buf), {}
  state.sig = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local ranges = shown(win, total)
    state.sig[win] = signature(ranges)
    for _, range in ipairs(ranges) do
      draw(state, range, seen)
    end
  end
  vim.cmd.redrawstatus({ bang = true }) -- the winbar
end

-- Redraws the buffers whose windows show other lines than at the last redraw:
-- a fold opened or closed (zo, zc, zR) moves no cursor and scrolls nothing.
function M.moved()
  for buf, state in pairs(M.states) do
    local total = api.nvim_buf_line_count(buf)
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      if state.sig and state.sig[win] ~= signature(shown(win, total)) then
        return M.redraw(buf)
      end
    end
  end
end

-- The header row, aligned, for the winbar of window vim.g.statusline_winid.
function M.winbar()
  local win = vim.g.statusline_winid or api.nvim_get_current_win() -- unset when nothing is drawn
  local buf = api.nvim_win_get_buf(win)
  local state = M.states[buf]
  if not state or not state.sticky then
    return ""
  end
  local line, out, cells = api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "", {}, {}
  local n = split(line, state.delim, out)
  if not n then -- a header spanning lines
    return ""
  end
  local wide = find(line, "[\128-\255]")
  for k = 1, n, 2 do
    local idx = tostring((k - 1) / 2) .. " "
    local w = width(line, out, k, wide) + #idx
    cells[#cells + 1] = idx .. sub(line, out[k], out[k + 1])
    if k < n - 1 then
      cells[#cells] = cells[#cells] .. rep(" ", (state.widths[(k + 1) / 2] or w) - w + 1) .. state.sep .. " "
    end
  end
  -- the scroll is counted in characters, so wide ones shift the header
  -- cut to the window width: past 4096 bytes Neovim drops the trailing %<
  local info = vim.fn.getwininfo(win)[1]
  local text = vim.fn.strcharpart(table.concat(cells), state.leftcol[win] or 0, info.width)
  -- %< at the end: too wide for the window, it is cut on the right, so it
  -- stays over its columns (the default cuts it on the left)
  return rep(" ", info.textoff) .. text:gsub("%%", "%%%%") .. "%<"
end

-- The window options the overlay changes.
local function set_options(state, win)
  local wo = vim.wo[win]
  wo.conceallevel, wo.concealcursor, wo.wrap = 2, "nvic", false
  if state.sticky then
    wo.winbar = WINBAR
  end
end

-- Sets the overlay's window options on win, keeping the ones to put back.
-- A window split from one that has them already is told by its options.
local function apply(state, win)
  if state.saved[win] then
    return
  end
  local wo = vim.wo[win]
  local inherited = state.orig and wo.conceallevel == 2 and wo.concealcursor == "nvic" and (not state.sticky or wo.winbar == WINBAR)
  state.saved[win] = inherited and state.orig
    or { conceallevel = wo.conceallevel, concealcursor = wo.concealcursor, winbar = wo.winbar, wrap = wo.wrap }
  state.orig = state.orig or state.saved[win]
  set_options(state, win)
end

local function restore(state, win)
  local saved = state.saved[win]
  state.saved[win] = nil
  if saved and api.nvim_win_is_valid(win) then
    for name, value in pairs(saved) do
      vim.wo[win][name] = value
    end
  end
end

-- Measures every line of the buffer, in slices of M.SLICE ms. Widths replace
-- the old ones only when the scan ends (at once the first time, so the first
-- screen is aligned early). An edit cancels a scan that is running.
local function measure(state)
  local buf = state.buf
  state.gen = state.gen + 1
  local gen = state.gen
  local ctx = { widths = {}, opens = {}, delim = state.delim, sticky = state.sticky }
  local total, from = api.nvim_buf_line_count(buf), 1
  state.busy = true
  if not state.ready then
    state.widths, state.opens = ctx.widths, ctx.opens
  end
  local function slice()
    if M.states[buf] ~= state or state.gen ~= gen then
      return
    end
    local t0 = vim.uv.hrtime()
    repeat
      local last = math.min(from + M.CHUNK - 1, total)
      scan(ctx, from, api.nvim_buf_get_lines(buf, from - 1, last, false))
      from = last + 1
    until from > total or (vim.uv.hrtime() - t0) / 1e6 > M.SLICE
    local done = from > total
    if done then
      state.widths, state.opens, state.ready, state.busy = ctx.widths, ctx.opens, true, false
    else
      vim.schedule(slice)
    end
    if done or not state.ready then
      M.redraw(buf)
    end
  end
  slice()
end

-- After the debounce: an edit in place of a few lines first grows the widths
-- with just those lines, then every line is measured again (widths shrink too).
local function idle(state)
  if M.states[state.buf] ~= state then
    return
  end
  local dirty = state.dirty
  state.dirty = nil
  if type(dirty) == "table" then
    scan(state, dirty[1], api.nvim_buf_get_lines(state.buf, dirty[1] - 1, dirty[2], false))
    M.redraw(state.buf)
  end
  measure(state)
end

-- Follows the lines [first, last) of the buffer (0-based) replaced by
-- [first, new_last): moves the record marks below them and notes what changed.
local function changed(state, first, last, new_last)
  state.gen = state.gen + 1 -- a scan that is running is out of date
  state.busy = true
  local delta = new_last - last
  if delta == 0 and last - first <= M.INCREMENTAL then
    -- in place (typing): only the edited lines' marks go, nothing moves
    for l = first + 1, last do
      state.opens[l] = nil
    end
  elseif next(state.opens) then
    local moved = {}
    for l in pairs(state.opens) do
      if l <= first then
        moved[l] = true
      elseif l > last then
        moved[l + delta] = true
      end
    end
    state.opens = moved
  end
  local dirty = state.dirty
  if delta ~= 0 or new_last - first > M.INCREMENTAL or dirty == "all" then
    state.dirty = "all"
  elseif dirty then
    state.dirty = { math.min(dirty[1], first + 1), math.max(dirty[2], new_last) }
  else
    state.dirty = { first + 1, new_last }
  end
  state.timer:start(M.DEBOUNCE, 0, vim.schedule_wrap(function()
    idle(state)
  end))
end

local function close_timer(state)
  if not state.timer:is_closing() then
    state.timer:stop()
    state.timer:close()
  end
end

local function scrolled()
  for buf, state in pairs(M.states) do
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      api.nvim_win_call(win, function()
        state.leftcol[win] = vim.fn.winsaveview().leftcol
      end)
    end
    M.redraw(buf)
  end
end

-- Turns the overlay on for buf (a no-op when it is on).
function M.enable(buf)
  if M.states[buf] then
    return
  end
  -- a reload or unload detaches without disable(): drop the old state's autocmds
  api.nvim_clear_autocmds({ group = group, buffer = buf })
  local opts = csvkit.get_opts(buf)
  local state = {
    buf = buf,
    delim = opts.delimiter,
    sep = opts.align.separator,
    sticky = opts.align.sticky_header and opts.header,
    widths = {},
    opens = {},
    saved = {},
    leftcol = {},
    gen = 0,
    ready = false,
    timer = vim.uv.new_timer(),
  }
  M.states[buf] = state
  api.nvim_buf_attach(buf, false, {
    on_lines = function(_, _, _, first, last, new_last)
      if M.states[buf] ~= state then
        return true
      end
      changed(state, first, last, new_last)
    end,
    on_reload = function()
      if M.states[buf] == state then
        changed(state, 0, api.nvim_buf_line_count(buf), 0)
      end
    end,
    on_detach = function()
      if M.states[buf] == state then
        M.states[buf] = nil
      end
      close_timer(state)
    end,
  })
  -- WinEnter too: a :split shows the buffer in a new window without BufWinEnter.
  -- Floats are left alone: nvim_open_win enters one (stats, a prompt) while it
  -- still shows this buffer, and a winbar there takes a line it may not have.
  api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
    group = group,
    buffer = buf,
    callback = function()
      local win = api.nvim_get_current_win()
      if api.nvim_win_get_config(win).relative == "" then
        apply(state, win)
      end
      M.redraw(buf)
    end,
  })
  api.nvim_create_autocmd("BufWinLeave", {
    group = group,
    buffer = buf,
    callback = function()
      restore(state, api.nvim_get_current_win())
    end,
  })
  if not vim.g.csvkit_align_scroll then
    vim.g.csvkit_align_scroll = true
    api.nvim_create_autocmd({ "WinScrolled", "WinResized" }, { group = group, callback = scrolled })
    api.nvim_create_autocmd("SafeState", { group = group, callback = M.moved })
  end
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    apply(state, win)
  end
  measure(state)
end

-- Turns it off: the marks go and the windows get their options back.
function M.disable(buf)
  local state = M.states[buf]
  if not state then
    return
  end
  M.states[buf] = nil
  close_timer(state)
  api.nvim_clear_autocmds({ group = group, buffer = buf })
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for win in pairs(state.saved) do
    restore(state, win)
  end
  vim.cmd.redrawstatus({ bang = true })
end

return M
