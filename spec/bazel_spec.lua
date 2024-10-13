local bazel = require("neotest-bazel.bazel")
local Path = require("plenary.path")
local a = require("nio").tests

local root = "spec/testdata/simple_repo"

-- Fetching and starting bazel can take longer than the nio default of 2000ms
vim.env.PLENARY_TEST_TIMEOUT = 50000

describe("Bazel workspace", function()
  a.it("Finds directory root", function()
    assert.are.same(bazel.root(root), Path:new(root):absolute())
  end)
  a.it("Finds subdirectory root", function()
    assert.are.same(bazel.root(root .. "/java"), Path:new(root):absolute())
  end)
end)

describe("Bazel queries", function()
  it("Compose composes queries", function()
    assert.are.same(bazel.compose_query("exists", "tests", "file"),
      "some(tests(file), 1)")
  end)
  a.it("File query finds targets", function()
    local query = bazel.compose_query("tests", "file", "java/TrivialTest.java")
    assert.are.same(bazel.run_query(root, query), { "//java:trivial_test" })
  end)
  a.it("Directory query finds targets", function()
    local query = bazel.compose_query("tests", "directory", "java")
    local targets = bazel.run_query(root, query)
    assert.are.not_nil(targets)
    table.sort(targets or {})
    assert.are.same(targets, {
      "//java:another_test",
      "//java:trivial_test",
    })
  end)
  a.it("Find test file targets", function()
    assert.are.same(bazel.find_file_test_locations(root .. "/java/TrivialTest.java"), {
      {
        name = "//java:trivial_test",
        row = 0,
        column = 9,
        path = Path:new(root, "java/BUILD"):absolute(),
        kind = "java_test",
      }
    })
  end)
  a.it("Find BUILD file targets", function()
    local locations = bazel.find_file_test_locations(root .. "/java/BUILD")
    assert.are.not_nil(locations)
    table.sort(locations or {}, function(l, r) return l.row < r.row end)
    assert.are.same(locations, {
      {
        name = "//java:trivial_test",
        row = 0,
        column = 9,
        path = Path:new(root, "java/BUILD"):absolute(),
        kind = "java_test",
      },
      {
        name = "//java:another_test",
        row = 5,
        column = 9,
        path = Path:new(root, "java/BUILD"):absolute(),
        kind = "java_test",
      }
    })
  end)
end)
