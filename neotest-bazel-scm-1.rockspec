rockspec_format = '3.0'
package = "neotest-bazel"
version = "scm-1"
source = {
  url = "git+https://github.com/shahms/neotest-bazel"
}
dependencies = {
  "neotest",
  "plenary.nvim",
  "lua==5.1",
  "nvim-nio",
  "tree-sitter-starlark",
}
test_dependencies = {
  "nlua",
}
build = {
  type = "builtin",
  copy_directories = {
    -- Add runtimepath directories, like
    -- 'plugin', 'ftplugin', 'doc'
    -- here. DO NOT add 'lua' or 'lib'.
  },
}
test = {
  type = "busted",
  flags = { "--helper", "spec/minimal_init.lua" }
}
