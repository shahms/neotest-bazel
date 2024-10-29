local Path = require("plenary.path")
local types = require("neotest.types")
local lib = require("neotest.lib")
local nio = require("nio")

local bazel = require("neotest-bazel.bazel")
local LOG = require("neotest.logging")


local default_config = {
  rules = {
    -- <rule_pattern> = {
    --   adapter = require("subadapter")
    --   test_filter = function(position) end,
    --   test_args = function(position) end,
    -- }
  }
}


-- TODO: support discovery (querying individual directories is really slow)
--   It might make sense to support a bazel query 'kind("source file", deps(tests(//...), 1))'
--   to find all direct source file dependencies on test targets and use those as "test files",
--   rather than allowing neotest to do the discovery. Even that is problematic in large repos,
--   though.

local build_files = {
  ["BUILD"] = true,
  ["BUILD.bazel"] = true,
}

local get_root = lib.files.match_root_pattern("WORKSPACE", "WORKSPACE.bazel", "MODULE.bazel")
local get_package = lib.files.match_root_pattern(unpack(vim.tbl_keys(build_files)))

--- Return path relative to root, returning the empty string if they're equal.
local function make_relative(path, root)
  path = Path:new(path):make_relative(root)
  if path == "." then
    return ""
  end
  return path
end

local function parse_test_result(line)
  -- TODO(shahms): Get workspace from "started" message?
  local entry = vim.json.decode(line)
  if not entry then
    return nil
  end
  local label = ((entry.id or {}).testResult or {}).label
  if not label then
    return nil
  end
  local result = entry.testResult
  local logs = {}
  for _, log in ipairs(result.testActionOutput or {}) do
    if log.name == "test.xml" then
      logs.xml = log.uri
    elseif log.name == "test.log" then
      logs.log = log.uri
    end
  end
  local status_map = {
    NO_STATUS = types.ResultStatus.skipped,
    PASSED = types.ResultStatus.passed,
    FLAKY = types.ResultStatus.failed,
    TIMEOUT = types.ResultStatus.failed,
    INCOMPLETE = types.ResultStatus.skipped,
    REMOTE_FAILURE = types.ResultStatus.failed,
    FAILED_TO_BUILD = types.ResultStatus.failed,
    TOOL_HALTED_BEFORE_TESTING = types.ResultStatus.skipped,
  }
  return label, status_map[result.status] or types.ResultStatus.skipped, logs
end

--- Split the path into { workspace, package, target } parts.
local function split_target_path(path)
  local package = get_package(path)
  if not package then
    return nil
  end
  local workspace = get_root(package)
  if not workspace then
    return nil
  end
  path = make_relative(path, package)
  package = make_relative(package, workspace)
  return workspace, package, path
end

local function maybe_read_lines(path)
  local status, result = pcall(function() return lib.files.read_lines(path) end)
  if status then
    return result
  end
  if not result:match("ENOENT:") then
    LOG.info("read_lines failed with:", result)
  end
  return {}
end

local function split_valid_bazel_file(path)
  local workspace, package, target = split_target_path(path)
  if not workspace then
    return nil
  end
  if not package then
    return nil
  end
  -- When present, filtering paths via ".bazelignore" is faster than querying bazel.
  -- TODO(shahms): cache this
  for _, line in ipairs(maybe_read_lines(tostring(Path:new(workspace, ".bazelignore")))) do
    local ignore = Path:new(workspace, line)
    if path:make_relative(ignore) ~= path then
      -- If we succeed in making `path` relative to an ignored directory, it should be ignored.
      return nil
    end
  end
  return workspace, package, target
end

local function query_test_file(file_path)
  -- neotest is far too eager in checking arbitrary files
  -- and bazel can be lethargic when executing queries, so
  -- save time and check for a WORKSPACE and other marker files ourselves.
  local workspace, package, target = split_valid_bazel_file(file_path)
  if not (workspace and package) then
    return false
  end
  local query = bazel.queries.file(Path:new(package, target).filename)
  local targets = bazel.run_query(workspace, bazel.compose_query("exists", "tests", query))
  return targets and #targets ~= 0
end

local function query_test_dir(_, rel_path, root)
  local workspace, package, target = split_valid_bazel_file(Path:new(root, rel_path).filename)
  if not (workspace and package) then
    return false
  end
  local query = bazel.compose_query("exists", "tests", "directory", { package, target })
  local targets = bazel.run_query(workspace, query)
  -- Skip discovery if there are no test targets.
  return targets and #targets ~= 0
end

local strategy = {
  single_file = {
    root = function() end,
    filter_dir = function() end,
    is_test_file = query_test_file,
  },
  files_only = {
    root = get_root,
    filter_dir = function(_, rel_path, root)
      return split_valid_bazel_file(Path:new(rel_path, root).filename) ~= nil
    end,
    is_test_file = function(path)
      local workspace, package, target = split_valid_bazel_file(path)
      if not (workspace and package) then
        return false
      end
      -- This only works until we support non-BUILD files as well.
      return build_files[target]
    end,
    -- is_test_file, beneath workspace, not in .bazelignore, is BUILD file
  },
  lazy_query = {
    root = bazel.root,
    filter_dir = query_test_dir,
    is_test_file = query_test_file,
  },
}

local function find_rule_adapter(config, kind)
  local rules = config.rules
  if not rules then return nil end

  -- If there is an exact match, use that.
  if rules[kind] then
    return rules[kind].adapter
  end
  for key, value in pairs(rules) do
    -- TODO(shahms): Support multiple matches or at least log an error.
    if kind:match(key) then
      return value.adapter
    end
  end
  return nil
end

return function(user_config)
  local config = vim.tbl_extend("force", default_config, user_config or {})
  return {
    name = "neotest-bazel",
    root = strategy.single_file.root,
    filter_dir = strategy.single_file.filter_dir,
    is_test_file = strategy.single_file.is_test_file,
    discover_positions = function(file_path)
      local locations = bazel.discover_locations(file_path)
      if not locations or #locations == 0 then
        return nil
      end

      local discovered = {}
      for _, entry in ipairs(locations) do
        if entry.path == file_path then
          -- The file_path provided was a BUILD file or equivalent.
          -- The locations are within the file itself.
          return bazel.map_positions(file_path, locations)
        elseif discovered[entry.kind] then
          -- Don't rediscover file tests for the same rule kind.
          local tree = discovered[entry.kind].tree
          if tree then
            local pos = tree:data()
            -- Add the current target to the list of bazel targets for the file.
            pos.bazel_targets = vim.list_extend(pos.bazel_targets or {}, { entry.name })
          end
        else
          -- The file_path is a file with corresponding test targets.
          -- Defer to any matching rule adapters for locations.
          local adapter = find_rule_adapter(config, entry.kind)
          if (adapter
                and (not adapter.is_test_file or adapter.is_test_file(file_path))
                and adapter.discover_positions) then
            local result = adapter.discover_positions(file_path)
            discovered[entry.kind] = { tree = result }
            if result then
              local pos = result:data()
              pos.bazel_targets = { entry.name }
              pos.bazel_build_file = entry.path
            end
          end
        end
      end
      for _, result in pairs(discovered) do
        -- TODO(shahms): Support merging results from multiple targets/adapters
        return result.tree
      end
      return nil
    end,
    build_spec = function(args)
      local position = args.tree:data()
      local cwd = (function()
        if position.type == types.PositionType.dir then
          return position.path
        end
        return Path:new(position.path):parent().filename
      end)()
      -- TODO(shahms): This currently only works for "file", "test", and "namespace"
      -- which will have had positions discovered above.
      -- Directories are more complicated and we'll need to query targets ourselves.
      local targets = args.tree:closest_value_for("bazel_targets")
      if targets and #targets > 0 then
        LOG.debug("Found targets:", targets)
      else
        LOG.info("No bazel_targets found for:", position)
        return nil
      end
      local bes_path = nio.fn.tempname()
      return {
        command = vim.list_extend({
            "bazel",
            "test",
            -- TODO(shahms): test_filter, test_arg
            "--build_event_json_file=" .. bes_path,
          },
          targets),
        cwd = cwd,
        context = { bes_path = bes_path },
        -- stream = function() end,
      }
    end,
    results = function(run_spec, result, tree)
      -- We need to cover all of the following:
      -- 1. Testing an entire BUILD file (type == "file")
      -- 2. Test a single test from a BUILD file (type == "test")
      -- 3. Directories (type == "dir")
      -- 4. Testing an entire test file (type == "file")
      -- 5. Testing all tests within a namespace (type == "namespace")
      -- 6. Testing a single test within a test file (type == "test")
      --
      -- To cover 1, 2, and 4 we need to map all result targets to:
      -- 1. "test" nodes beneath a BUILD file (w/ bazel_targets)
      -- 2. "file" nodes with corresponding bazel_targets
      -- To cover 5 and 6 we need to parse the xml logs.
      -- We can't really use the sub-adapters because they often rely on context from the build_spec.

      -- Contains a map from target to nodes with that target in bazel_targets.
      -- Restricted to the same package.
      local target_map = {}
      -- The path of the directory containing this package's BUILD file.
      local package_path = tree:closest_value_for("bazel_build_file")
      -- The path of the directory containing this package's BUILD file.
      local package_dir = Path:new(package_path):parent().filename
      -- The node with the same path as package_root.
      local package_node = (function()
        for node in tree:iter_parents() do
          -- TODO(shahms): Do I need to normalize `node:data().path`?
          if node:data().path == package_dir then
            return node
          end
        end
      end)()
      LOG.debug("Found package", package_node, "for", tree:data())
      local function continue(node)
        local pos = node:data()
        if pos.type == types.PositionType.dir then
          -- TODO(shahms): check if this directory is a package root for a different package.
          return true
        end
        if pos.type == types.PositionType.file and pos.path == pos.bazel_build_file then
          return true
        end
        return false
      end
      for _, node in package_node:parent():iter_nodes({ continue = continue }) do
        -- TODO(shahms): Skip the BUILD file itself, but still include its tests.
        local pos = node:data()
        -- Either a child of the package file
        if (pos.path == package_path
              -- Or within the package defined by it.
              or pos.bazel_build_file == package_path) and pos.bazel_targets then
          for _, target in ipairs(pos.bazel_targets) do
            -- Add this node to each of the targets which use it.
            target_map[target] = vim.list_extend(target_map[target] or {}, { node })
          end
        end
      end
      LOG.debug("Found corresponding targets:", target_map)

      local results = {}
      for _, line in ipairs(lib.files.read_lines(run_spec.context.bes_path)) do
        local label, status, logs = parse_test_result(line)
        if label and status and logs then
          LOG.error("Found", label, status, logs, "for", tree:data().id)
          for _, node in ipairs(target_map[label] or {}) do
            -- TODO(shahms): This only works for BUILD tests and test files.
            --   We need to parse the xml output for individual tests.
            --   For a quick sampling of languages:
            --   java_test: testsuite name is Java class name, testcase name is regular name
            --   cc_test: testsuite name is just name, testcase includes filename
            --   py_test: testsuite name is just name, testcase name is just name
            --   go_test: not much relevant output
            results[node:data().id] = {
              status = status,
              -- TODO(shahms): This is generally more readable output from
              -- bazel, but the actual test output is logs.log.
              output = result.output,
            }
          end
        end
      end
      return results
    end,
  }
end
