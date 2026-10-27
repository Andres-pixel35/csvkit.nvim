return {
  ["repo is first on runtimepath"] = function()
    local first = vim.api.nvim_list_runtime_paths()[1]
    eq(vim.fn.filereadable(first .. "/tests/run.lua"), 1)
  end,
}
