-- timing.lua: unit conversions and calibration. No matching logic here.
-- Sign convention everywhere: negative = early, positive = late, 0 = on grid.

local T = {}

-- Timestamp model used by the JSFX; mirrored here so it can be tested.
-- block_s/block_qn are play_position/beat_position, valid at the block start.
function T.hit_seconds(block_s, sample_offset, srate)
  return block_s + sample_offset / srate
end

function T.hit_qn(block_qn, sample_offset, tempo, srate)
  return block_qn + sample_offset * tempo / (60 * srate)
end

function T.signed_error_ms(hit_s, target_s)
  return (hit_s - target_s) * 1000
end

function T.corrected_error_ms(signed_ms, calibration_ms)
  return signed_ms - calibration_ms
end

-- The hit's time once measured latency is removed; matching happens on this.
function T.calibrated_time(hit_s, calibration_ms)
  return hit_s - calibration_ms / 1000
end

-- Constant-tempo QN->seconds for tests.
function T.linear_qn_to_time(bpm, offset_s)
  offset_s = offset_s or 0
  return function(qn) return offset_s + qn * 60 / bpm end
end

function T.classify(error_ms, on_time_ms)
  if error_ms < -on_time_ms then return "EARLY" end
  if error_ms > on_time_ms then return "LATE" end
  return "ON TIME"
end

-- "+14 ms" / "-9 ms" / "0 ms". Rounded for display only.
function T.format_ms(ms, decimals)
  decimals = decimals or 0
  local text = string.format("%." .. decimals .. "f", ms)
  if tonumber(text) == 0 then
    return string.format("%." .. decimals .. "f ms", 0)
  end
  return string.format("%+." .. decimals .. "f ms", tonumber(text))
end

-- Is this a project v1 can score correctly? Takes tempo-map facts from REAPER.
-- markers: array of { bpm, ts_num, ts_denom, linear } (ts_num 0 = unchanged).
-- Returns ok, reason.
function T.check_project_map(base_bpm, base_num, base_denom, markers)
  if base_num ~= 4 or base_denom ~= 4 then
    return false, string.format("Project is %d/%d; only 4/4 is supported", base_num, base_denom)
  end
  for _, m in ipairs(markers) do
    if m.ts_num ~= 0 and (m.ts_num ~= 4 or m.ts_denom ~= 4) then
      return false, string.format("Time signature change to %d/%d is not supported", m.ts_num, m.ts_denom)
    end
    if math.abs(m.bpm - base_bpm) > 1e-6 then
      return false, "Tempo changes are not supported; use one constant tempo"
    end
    if m.linear then
      return false, "Linear tempo ramps are not supported"
    end
  end
  return true
end

return T
