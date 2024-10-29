-- require('nvim-treesitter.configs').setup {
--    ensure_installed = { "starlark", "python" },
-- }

-- When run via luarocks test, plenary can't find its data directory so
-- we have to manually register the relevant file types here.
require("plenary.filetype").add_table({ file_name = { ["build"] = [[bzl]] } })
-- When run via luarocks test, neovim isn't informed about this parser.
vim.treesitter.language.add("starlark", { path = package.searchpath("parser.starlark", package.cpath) })
-- Neotest defaults to using the file type as the language name, but that doesn't
-- work for starlark.
-- TODO(shahms): This should be done during setup along with "python", if there isn't already a parser for "bzl".
vim.treesitter.language.register("starlark", "bzl")
vim.opt.rtp:append(".")
