--- neotest-bazel module for constructing and executing bazel queries.
local nio = require("nio")
local LOG = require("neotest.logging")

local M = { queries = {} }

--- Bazel-reported errors which are expected.
local harmless_errors = {
  --- "some(..., N)" fails with this message if the argument is the empty set.
  --- As we are using this query to see if there are any targets, this is expected.
  "failed: argument set is empty\n$",
  --- Similarly, queries of directories which are not packages will report this error.
  "^ERROR: no targets found beneath",
}

--- Return true if any of the patterns match.
--- @param str string The string against which to match.
--- @param patterns string[] The patterns to check.
--- @return boolean true if any pattern matches.
local function match_any(str, patterns)
  for _, pat in ipairs(patterns) do
    if str:match(pat) then
      return true
    end
  end
  return false
end

--- Query for all targets beneath a directory which resides relative to the given package.
--- @param package string The directory path of the BUILD file for the package.
--- @param rel_path string The part of the target within the package. If nil, package is assume to have been unresolved.
--- @return string A bazel query which will find all targets beneath the package/directory.
function M.queries.directory(package, rel_path)
  -- TODO(shahms): It would be nice to find targets within the current "directory" if it's a package or not.
  -- "...:*" is packages beneath the current directory, which only works if that directory is itself a package.
  if rel_path == '' or rel_path == '.' then
    -- A simple path for all targets beneath the package.
    return ("//%s/..."):format(package)
  end
  local filter
  if not rel_path then
    -- Match files regardless of where the package separator is.
    filter = ("^//[:]?%s[:/]"):format(package:gsub("/", "[:/]"))
  else
    -- If we know the package path, use that instead.
    filter = ("^//%s:%s/"):format(package, rel_path)
  end

  --- All targets which depend directly on a source file beneath the requested directory.
  return ('same_pkg_direct_rdeps(filter("%s", kind("source file", //...:*)))'):format(filter)
end

function M.queries.package(rel_path)
  return ("%s:all"):format(rel_path)
end

--- Query for all targets for which this is a source file
--- and all targets defined within it if a BUILD file.
function M.queries.file(rel_path)
  return ([[
  let files = set("%s") in
  let rdeps = same_pkg_direct_rdeps($files) in
  let build = kind("rule$", siblings(buildfiles($files) intersect $files)) in
  $rdeps union $build
  ]]):format(rel_path)
end

--- Query for test targets from the subquery.
function M.queries.tests(query)
  return ("tests(%s)"):format(query)
end

--- Query which checks if there are any targets in the subquery.
function M.queries.exists(query)
  return ("some(%s, 1)"):format(query)
end

function M.queries.all_test_files()
  -- source files which are direct dependencies of tests as well as the BUILD files which define them.
  return [[
  let tests = tests(//...) in
  kind("source file", deps($tests, 1))
  union
  filter("^//", buildfiles($tests) except loadfiles($tests))
  ]]
end

--- Composes queries by applying named functions from the "queries" table.
--- compose_query("a", "b", "c") is the same as queries.a(queryies.b(c)).
function M.compose_query(...)
  local arg = { ... }
  local query
  for i = #arg, 1, -1 do
    if query then
      local func = M.queries[arg[i]]
      if type(query) == "table" and #query ~= 0 then
        query = func(unpack(query))
      else
        query = func(query)
      end
    else
      query = arg[i]
    end
  end
  return query
end

--- @async
--- @param dir string The directory whose workspace to query.
--- @return string | nil The path to the workspace root
function M.root(dir)
  local bazel, err = nio.process.run({
    cmd = "bazel",
    args = { "info", "workspace" },
    cwd = dir,
  })
  if not bazel then
    error(err)
  end
  local result = bazel.result(false)
  local stdout = bazel.stdout.read()
  bazel.close()
  if result ~= 0 or not stdout then
    return nil
  end
  return vim.trim(stdout)
end

--- @async
--- @param workspace string Path to the bazel workspace root.
--- @param query string The bazel query to execute.
--- @param opts? table Options to provide to the query.
--- @return string[] | nil
function M.run_query(workspace, query, opts)
  LOG.debug("Querying bazel (", workspace, ") for:", query)
  opts = opts or {}
  local args = {
    "query",
    "--noshow_progress",
    "--noshow_loading_progress",
    "--keep_going",
    "--order_output=no",
  }
  vim.list_extend(args, opts)
  table.insert(args, query)
  local bazel, err = nio.process.run({
    cmd = "bazel",
    args = args,
    cwd = workspace,
  })
  if not bazel then
    error(err)
  end
  local result = bazel.result(false)
  local stdout, stderr = bazel.stdout.read(), bazel.stderr.read()
  bazel.close()
  if not (vim.list_contains({ 0, 3 }, result) and stdout) then
    -- some() will harmlessly fail if there are no targets.
    if stderr and not match_any(stderr, harmless_errors) then
      LOG.warn("Error (", result, ") querying bazel:", stderr)
    end
    return nil
  end
  return vim.split(stdout, "\n", { trimempty = true })
end

return M
