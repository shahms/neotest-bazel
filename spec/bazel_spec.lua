local bazel = require("neotest-bazel.bazel")
local Path = require("plenary.path")
local a = require("nio").tests

local root = "spec/testdata/simple_repo"

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
    assert.are.same(bazel.run_query(root, query), { "//java:trivial_test" })
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
    assert.are.same(bazel.find_file_test_locations(root .. "/java/BUILD"), {
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
