local H = { passed = 0, failed = 0 }

function H.suite(name) print("\n" .. name) end

function H.test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    H.passed = H.passed + 1
    print("  ok    " .. name)
  else
    H.failed = H.failed + 1
    print("  FAIL  " .. name .. "\n" .. tostring(err))
  end
end

function H.eq(actual, expected, msg)
  if actual ~= expected then
    error((msg or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end

function H.near(actual, expected, tol, msg)
  if actual == nil or math.abs(actual - expected) > (tol or 1e-6) then
    error((msg or "not close") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end

function H.truthy(v, msg)
  if not v then error(msg or "expected truthy", 2) end
end

function H.finish()
  print(string.format("\n%d passed, %d failed", H.passed, H.failed))
  return H.failed == 0
end

return H
