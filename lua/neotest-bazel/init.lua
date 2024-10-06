local Path = require("plenary.path")
local types = require("neotest.types")
local lib = require("neotest.lib")
local nio = require("nio")

local bazel = require("neotest-bazel.bazel")
local LOG = require("neotest.logging")


local default_config = {
  discovery = {
    enabled = false,
  },
  rules = {
    py = {
    }
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

return function(user_config)
  local config = vim.tbl_extend("force", default_config, user_config or {})
  return {
    name = "neotest-bazel",
    root = strategy.single_file.root,
    filter_dir = strategy.single_file.filter_dir,
    is_test_file = strategy.single_file.is_test_file,
    discover_positions = function(file_path)
      -- only called for files, not directories
      local root, package, target = split_valid_bazel_file(file_path)
      if not (root and package) then
        return nil
      end
      -- TODO(shahms): use bazel.queries.tests(file(...)) to support non-BUILD files.
      file_path = Path:new(file_path)
      if build_files[target] then
        local locations = bazel.run_query(
          root,
          bazel.compose_query("tests", "package", package),
          { output = "location" }
        )
        if not locations or #locations == 0 then
          return nil
        end

        LOG.error("Found locations:", locations)
        local positions = {
          {
            type = "file",
            name = make_relative(file_path.filename, file_path:parent().filename),
            path = tostring(file_path),
            -- neotest ranges are zero-based row, col pairs
            range = { 0, 0, #lib.files.read_lines(file_path.filename), 0 },
            bazel = {
              workspace = root,
              package = package,
            },
          },
        }
        for _, line in ipairs(locations) do
          -- TODO(shahms): augment these positions with tree-sitter information to use the name attribute, if present
          -- and extend the end location to the final line of the function call. bazel query location is the open parenthesis.
          -- TODO(shahms): Use the rule kind to discover positions for the dependent files and include that information as well.
          local loc, _, _, name = unpack(vim.split(line, " "))
          local build_path, row, col = unpack(vim.split(loc, ":"))
          if build_path ~= file_path then
            LOG.error("Huh?", build_path, "~=", file_path)
          end
          -- TODO(shahms): Support non-BUILD files.
          table.insert(positions, {
            type = "test",
            name = name:sub(name:find(":") or 0),
            path = tostring(file_path),
            range = {
              tonumber(row) - 1,
              tonumber(col) - 1,
              tonumber(row) - 1,
              tonumber(col) - 1,
            },
          })
        end
        -- TODO(shahms): can we report positions for other files?
        table.sort(positions, function(a, b) return a.range[1] < b.range[1] end)
        return lib.positions.parse_tree(positions)
      end
      return nil
    end,
    build_spec = function(args)
      local position = args.tree:data()
      LOG.error("Building spec for: ", position)
      local workspace, package, _ = split_valid_bazel_file(position.path)
      if not (workspace and package) then
        return nil
      end
      LOG.error("root:", args.tree:root().path, "workspace:", workspace)
      local query
      if position.type == types.PositionType.file then
        query = ("//%s:all"):format(package)
      else
        LOG.error("Unhandled position:", position)
        -- TODO(shahms): handle "dir" "namespace" "test"
        return nil
      end
      local targets
      if query:match("^//") then
        -- For simple queries, skip the query.
        targets = { query }
      else
        targets = bazel.run_query(workspace, query)
      end
      if not targets or #targets == 0 then
        return nil
      end
      local bes_path = nio.fn.tempname()
      return {
        command = vim.list_extend({
            "bazel",
            "test",
            "--build_event_json_file=" .. bes_path,
          },
          targets),
        cwd = workspace,
        context = { bes_path = bes_path },
        -- stream = function() end,
      }
    end,
    results = function(run_spec, result, tree)
      LOG.error("Got result:", run_spec, result, tree:data().id, tree)
      local results = {}
      for _, line in ipairs(lib.files.read_lines(run_spec.context.bes_path)) do
        local label, status, logs = parse_test_result(line)
        if label and status and logs then
          -- TODO(shahms): this is only correct when tree:data().type == "file"
          results[tree:data().id .. "::" .. label:sub(label:find(":") or 0)] = {
            status = status,
            -- TODO(shahms): This is generally more readable output,
            -- but the actual test output is logs.log.
            output = result.output,
          }
          LOG.error("Found result:", label, status, logs)
        end
      end
      return results
    end,
  }
end
