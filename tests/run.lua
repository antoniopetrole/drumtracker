-- Dependency-free test runner: lua tests/run.lua (from the repository root).
local here = arg and arg[0] and arg[0]:match("^(.*)[/\\][^/\\]*$") or "tests"
package.path = here .. "/?.lua;" .. here .. "/../lua/?.lua;" .. package.path

local t = require("harness")
for _, name in ipairs({
  "test_timing", "test_patterns", "test_matcher", "test_metrics",
  "test_protocol", "test_session", "test_config", "test_remote",
}) do
  t.suite(name)
  require(name)
end
os.exit(t.finish() and 0 or 1)
