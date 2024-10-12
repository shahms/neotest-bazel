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
    java_test = {
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

local function find_file_test_locations(file_path)
  local parent = file_path:parent().filename
  local query = bazel.compose_query("tests", "file", make_relative(file_path.filename, parent))
  local results = bazel.run_query(parent, query,
    { "--output=streamed_jsonproto", "--noproto:rule_inputs_and_outputs", "--proto:output_rule_attrs=" })
  if not results then
    return nil
  end
  return vim.iter(ipairs(results)):map(function(_, line)
    local entry = vim.json.decode(line)
    local rule = entry and entry.type == "RULE" and entry.rule
    if not rule then
      return nil
    end
    local path, row, col = unpack(vim.split(rule.location or "", ":"))
    if not (path and row and col) then
      return nil
    end
    if not rule.ruleClass then
      return nil
    end
    if not rule.name then
      return nil
    end
    return {
      path = path,
      row = tonumber(row) - 1,
      column = tonumber(col) - 1,
      kind = rule.ruleClass,
      name = rule.name,
    }
  end):totable()
end

local function discover_build_target_positions(file_path, locations)
  local positions = {
    {
      type = "file",
      name = make_relative(file_path.filename, file_path:parent().filename),
      path = file_path.filename,
      -- neotest ranges are zero-based row, col pairs
      range = { 0, 0, #lib.files.read_lines(file_path.filename), 0 },
    },
  }
  for _, entry in ipairs(locations) do
    -- TODO(shahms): augment these positions with tree-sitter information to use the name attribute, if present
    -- and extend the end location to the final line of the function call. bazel query location is the open parenthesis.
    assert(entry.path == file_path.filename)
    table.insert(positions, {
      type = "test",
      name = entry.name:sub(entry.name:find(":") or 0),
      path = file_path.filename,
      range = { entry.row, entry.column, entry.row, entry.column },
      bazel_targets = { entry.name, },
    })
    -- The enclosing file is a package; shortcut target finding.
    -- We do this here to simplify finding the package name.
    if not positions[1].bazel_targets then
      positions[1].bazel_targets = { entry.name:sub(0, entry.name:find(":")) .. "all" }
    end
  end
  table.sort(positions, function(a, b) return a.range[1] < b.range[1] end)
  return lib.positions.parse_tree(positions)
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
    -- TODO(shahms): Support multiple matches.
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
      file_path = Path:new(file_path)
      local locations = find_file_test_locations(file_path)
      if not locations or #locations == 0 then
        return nil
      end

      local discovered = {}
      for _, entry in ipairs(locations) do
        if entry.path == file_path.filename then
          -- The file_path provided was a BUILD file or equivalent.
          -- The locations are within the file itself.
          return discover_build_target_positions(file_path, locations)
        elseif discovered[entry.kind] then
          -- Don't rediscover file tests for the same rule kind.
          -- TODO(shahms): add to the file's bazel_targets.
        else
          -- The file_path is a file with corresponding test targets.
          -- Defer to any matching rule adapters for locations.
          local adapter = find_rule_adapter(config, entry.kind)
          if (adapter
                and (not adapter.is_test_file or adapter.is_test_file(file_path.filename))
                and adapter.discover_positions) then
            local result = adapter.discover_positions(file_path.filename)
            if result then
              -- TODO(shahms): Support merging results from multiple targets/adapters
              -- TODO(shahms): Support enclosing results in a namespace with the same name as the test target.
              return result
            end
          end
        end
      end
      return nil
    end,
    build_spec = function(args)
      local position = args.tree:data()
      local workspace, package, _ = split_valid_bazel_file(position.path)
      if not (workspace and package) then
        return nil
      end
      -- If there are resolved bazel targets already in the position, use them.
      local targets = position.bazel_targets
      if not targets then
        if position.type == types.PositionType.file then
          -- TODO(shahms): handle more than just BUILD files.
          targets = { ("//%s:all"):format(package) }
        elseif position.type == types.PositionType.test then
          -- TODO(shahms): handle more than just BUILD files.
          targets = position.bazel_targets
        else
          LOG.info("Unhandled position:", position)
          -- TODO(shahms): handle "dir" "namespace" "test"
          return nil
        end
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
      local results = {}
      for _, line in ipairs(lib.files.read_lines(run_spec.context.bes_path)) do
        local label, status, logs = parse_test_result(line)
        if label and status and logs then
          -- TODO(shahms): this is only correct for BUILD files
          results[tree:data().id .. "::" .. label:sub(label:find(":") or 0)] = {
            status = status,
            -- TODO(shahms): This is generally more readable output,
            -- but the actual test output is logs.log.
            output = result.output,
          }
        end
      end
      return results
    end,
  }
end
