-- When run via luarocks test, plenary can't find its data directory so
-- we have to manually register the relevant file types here.
require("plenary.filetype").add_table({ file_name = { ["build"] = [[bzl]] } })
-- When run via luarocks test, this parser is installed in lua's cpath, not vim's runtimepath.
vim.treesitter.language.add("starlark", { path = package.searchpath("parser.starlark", package.cpath) })
-- When installed via luarocks, neovim doesn't register this filetype mapping.
vim.treesitter.language.register("starlark", "bzl")
