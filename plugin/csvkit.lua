-- Registers :Csvkit, the <Plug> maps and the default autocmd; every module is
-- required on first use. setup() replaces the autocmd to follow `extensions`.
if vim.g.loaded_csvkit then
  return
end
vim.g.loaded_csvkit = true

vim.api.nvim_create_user_command("Csvkit", function(o)
  require("csvkit.command").run(o.args, o.range > 0 and { o.line1, o.line2 } or nil)
end, {
  nargs = "*",
  range = true, -- only row delete and stats take one
  desc = "csvkit: align, sort, filter, row add, addcol, setcol, decimal, thousands, restore, view, preview",
  complete = function(...)
    return require("csvkit.command").complete(...)
  end,
})

for name, args in pairs({
  ["sort-asc"] = "sort asc",
  ["sort-desc"] = "sort desc",
  ["filter"] = "filter",
  ["filter-clear"] = "filter clear",
  ["row-below"] = "row add below",
  ["row-above"] = "row add above",
  ["row-delete"] = "row delete",
  ["delcol"] = "delcol",
  ["hide"] = "hide",
  ["stats"] = "stats",
  ["addcol"] = "addcol",
  ["align-toggle"] = "align",
  ["restore"] = "restore",
  ["view"] = "view",
  ["preview"] = "preview",
  ["apply"] = "apply",
  ["apply-sort"] = "apply sort",
  ["discard"] = "discard",
}) do
  vim.keymap.set("n", "<Plug>(csvkit-" .. name .. ")", "<Cmd>Csvkit " .. args .. "<CR>")
end

vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
  group = vim.api.nvim_create_augroup("csvkit", {}),
  pattern = "*.csv",
  callback = function(a)
    require("csvkit").attach(a.buf)
  end,
})
