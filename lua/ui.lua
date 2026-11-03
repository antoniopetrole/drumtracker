-- ui.lua: the ReaImGui dashboard. Draws state; holds no timing logic.

local Timing = require("timing")
local Patterns = require("patterns")
local Config = require("config")
local Bridge = require("bridge")
local Remote = require("remote")
local Library = require("library")

local UI = {}
UI.__index = UI

local TITLE = "Live Drum Groove Monitor"

local C_DIM = 0x8A8F98FF
local C_TEXT = 0xE6E8ECFF
local C_OK = 0x63D471FF
local C_WARN = 0xF2B84BFF
local C_BAD = 0xF0605AFF
local C_BG = 0x16181CFF
local C_GRID = 0x3A3F47FF
local C_BAND = 0x63D47128
local C_STEP_OFF = 0x2C3036FF
local C_STEP_OFF_BEAT = 0x3B4149FF

local function with_alpha(color, alpha)
  return (color & 0xFFFFFF00) | (alpha & 0xFF)
end

local function fmt_ms(v, decimals)
  if v == nil then return "--" end
  return Timing.format_ms(v, decimals or 1)
end

local function fmt_unsigned_ms(v)
  if v == nil then return "--" end
  return string.format("%.1f ms", v)
end

local function fmt_pct(v)
  if v == nil then return "--" end
  return string.format("%.0f%%", v)
end

local function db(linear)
  if not linear or linear < 1e-7 then return -math.huge end
  return 20 * math.log(linear, 10)
end

local function fmt_db(linear)
  local v = db(linear)
  if v == -math.huge then return "-inf dB" end
  return string.format("%.1f dB", v)
end

-- app: session, config, status (project/transport/detectors), and callbacks
function UI.new(ImGui, app)
  local self = setmetatable({}, UI)
  self.ImGui = ImGui
  self.app = app
  self.ctx = ImGui.CreateContext(TITLE)
  self.preset_name = "my-kit"
  self.groove_name = "My groove"
  self.message = nil
  self.flash = {}
  self.seen_triggers = {}
  self.cycle_tabs = os.getenv("LDGM_CYCLE_TABS") == "1" -- automated UI test
  return self
end

function UI:visible_lanes()
  return Remote.visible_lanes(self.app.session, self.app.config)
end

function UI:lane_state(lane)
  return Remote.lane_state(lane, self.app.status.detectors[lane.index], self.app.status.transport.playing)
end

-- Status bar ----------------------------------------------------------------

function UI:status_bar()
  local ImGui, ctx = self.ImGui, self.ctx
  local st = self.app.status
  local tr = st.transport

  local live, wanted = 0, 0
  for _, lane in ipairs(self:visible_lanes()) do
    wanted = wanted + 1
    if lane.alive then live = live + 1 end
  end
  ImGui.TextColored(ctx, live == wanted and C_OK or (live > 0 and C_WARN or C_BAD),
    string.format("Detectors %d/%d", live, wanted))

  ImGui.SameLine(ctx, 0, 16)
  ImGui.TextColored(ctx, tr.playing and C_OK or C_DIM, tr.label)
  ImGui.SameLine(ctx, 0, 16)
  ImGui.Text(ctx, string.format("%.1f BPM  4/4", st.bpm or 0))
  ImGui.SameLine(ctx, 0, 16)
  ImGui.Text(ctx, string.format("Bar %d  beat %.2f", tr.bar, tr.beat))
  ImGui.SameLine(ctx, 0, 16)
  ImGui.TextColored(ctx, tr.metronome and C_OK or C_WARN, tr.metronome and "Click on" or "Click OFF")

  local monitored = 0
  for i = 1, 8 do
    local inst = st.detectors[i][1]
    if inst and inst.armed and inst.monitor > 0 then monitored = monitored + 1 end
  end
  ImGui.SameLine(ctx, 0, 16)
  ImGui.TextColored(ctx, monitored > 0 and C_OK or C_WARN,
    string.format("Monitoring %d track%s", monitored, monitored == 1 and "" or "s"))

  local newest
  for _, lane in ipairs(self.app.session.lanes) do
    if lane.last_event_at and (not newest or lane.last_event_at > newest) then newest = lane.last_event_at end
  end
  ImGui.SameLine(ctx, 0, 16)
  if newest then
    ImGui.TextColored(ctx, C_DIM, string.format("Last hit %.1fs ago", self.app.now() - newest))
  else
    ImGui.TextColored(ctx, C_DIM, "No hits yet")
  end

  self:banners()
end

function UI:banners()
  local ImGui, ctx = self.ImGui, self.ctx
  local app, st = self.app, self.app.status
  if st.protocol_mismatch then
    ImGui.TextColored(ctx, C_BAD, "Detector and script versions differ. Reinstall both, then restart REAPER.")
  end
  if not st.project_ok then
    ImGui.TextColored(ctx, C_BAD, "NOT SCORING: " .. tostring(st.project_reason))
  end
  if not app.config.scoring_enabled then
    ImGui.TextColored(ctx, C_WARN, "Scoring is off: hits are detected but not scored.")
  end
  local uncal, selftest = {}, {}
  for _, lane in ipairs(self:visible_lanes()) do
    local lc = app.config.lanes[lane.index]
    if lane.alive and not lc.calibrated then uncal[#uncal + 1] = lc.name end
    if lane.alive and lane.status and lane.status.selftest > 0 then selftest[#selftest + 1] = lc.name end
  end
  if #selftest > 0 then
    ImGui.TextColored(ctx, C_WARN, "SELF-TEST ACTIVE, not real hits: " .. table.concat(selftest, ", "))
  end
  if #uncal > 0 then
    ImGui.TextColored(ctx, C_WARN, "UNCALIBRATED (bias includes latency): " .. table.concat(uncal, ", ")
      .. ". Spread is still valid. See the Calibrate tab.")
  end
  if self.message then ImGui.TextColored(ctx, C_DIM, self.message) end
end

-- Scatter -------------------------------------------------------------------

function UI:scatter()
  local ImGui, ctx = self.ImGui, self.ctx
  local cfg = self.app.config
  local session = self.app.session
  local lanes = self:visible_lanes()

  local avail_w = ImGui.GetContentRegionAvail(ctx)
  local row_h = 34
  local label_w = 70
  local axis_h = 20
  local h = row_h * #lanes + axis_h
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  ImGui.Dummy(ctx, avail_w, h)

  local plot_l, plot_r = x0 + label_w, x0 + avail_w - 14
  local range = math.max(50, cfg.tolerance_ms * 2.5)
  local function x_of(ms)
    local v = math.max(-range, math.min(range, ms))
    return plot_l + (v + range) / (2 * range) * (plot_r - plot_l)
  end
  local plot_b = y0 + row_h * #lanes

  ImGui.DrawList_AddRectFilled(dl, plot_l, y0, plot_r, plot_b, C_BG)
  ImGui.DrawList_AddRectFilled(dl, x_of(-cfg.tolerance_ms), y0, x_of(cfg.tolerance_ms), plot_b, C_BAND)

  local tick = 10
  if range > 60 then tick = 20 end
  for v = -math.floor(range / tick) * tick, range, tick do
    local x = x_of(v)
    ImGui.DrawList_AddLine(dl, x, y0, x, plot_b, v == 0 and C_TEXT or C_GRID, v == 0 and 2 or 1)
    if v % (tick * 2) == 0 then
      local label = v == 0 and "0" or string.format("%+d", v)
      local tw = ImGui.CalcTextSize(ctx, label)
      ImGui.DrawList_AddText(dl, x - tw / 2, plot_b + 3, C_DIM, label)
    end
  end
  ImGui.DrawList_AddText(dl, x0, plot_b + 3, C_DIM, "early  ms")
  local late = "late"
  ImGui.DrawList_AddText(dl, plot_r - ImGui.CalcTextSize(ctx, late), plot_b + 3, C_DIM, late)

  for row, lane in ipairs(lanes) do
    local lc = cfg.lanes[lane.index]
    local y = y0 + (row - 1) * row_h
    local mid = y + row_h / 2
    ImGui.DrawList_AddText(dl, x0, mid - 8, lane.alive and lc.color or C_DIM, lc.name)
    if row > 1 then ImGui.DrawList_AddLine(dl, plot_l, y, plot_r, y, C_GRID) end

    -- Spread bar and bias tick: read these as two different things.
    local stats = session:stats(lane)
    if stats.mean and stats.sd then
      ImGui.DrawList_AddRectFilled(dl, x_of(stats.mean - stats.sd), mid - 3,
        x_of(stats.mean + stats.sd), mid + 3, with_alpha(lc.color, 0x48), 2)
    end
    if stats.mean then
      local mx = x_of(stats.mean)
      ImGui.DrawList_AddLine(dl, mx, y + 3, mx, y + row_h - 3, lc.color, 2)
    end

    local points = self.app.latest_hits(lane, 32)
    for i, e in ipairs(points) do
      local alpha = math.floor(50 + 170 * i / #points)
      local px = x_of(e.corrected_ms)
      local offscale = math.abs(e.corrected_ms) > range
      local radius = i == #points and 5 or 3
      ImGui.DrawList_AddCircleFilled(dl, px, mid, radius, offscale and with_alpha(C_BAD, alpha) or with_alpha(lc.color, alpha))
    end
    if #points == 0 then
      local state, text = self:lane_state(lane)
      if state == "live" then text = lc.scoring and "Waiting for hits" or "Not in this pattern" end
      if text then ImGui.DrawList_AddText(dl, plot_l + 8, mid - 8, C_DIM, text) end
    end
  end
  ImGui.DrawList_AddRect(dl, plot_l, y0, plot_r, plot_b, C_GRID)
end

-- Lane cards ----------------------------------------------------------------

function UI:meter(lane, width)
  local ImGui, ctx = self.ImGui, self.ctx
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local h = 12
  local dl = ImGui.GetWindowDrawList(ctx)
  ImGui.Dummy(ctx, width, h)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + width, y + h, C_BG)
  local function x_of(linear)
    local v = db(linear)
    if v == -math.huge then return x end
    return x + width * math.max(0, math.min(1, (v + 70) / 70))
  end
  local s = lane.status
  if lane.alive and s then
    local total = s.trigger_total
    if self.seen_triggers[lane.index] ~= total then
      self.seen_triggers[lane.index] = total
      self.flash[lane.index] = self.app.now()
    end
    local flash = self.flash[lane.index]
    local hot = flash and self.app.now() - flash < 0.12
    ImGui.DrawList_AddRectFilled(dl, x, y, x_of(s.level), y + h, hot and C_WARN or C_OK)
    local tx = x_of(s.threshold)
    ImGui.DrawList_AddLine(dl, tx, y - 2, tx, y + h + 2, C_BAD, 2)
  end
end

function UI:lane_card(lane, width)
  local ImGui, ctx = self.ImGui, self.ctx
  local lc = self.app.config.lanes[lane.index]
  ImGui.TextColored(ctx, lc.color, lc.name)
  if not lc.scoring then
    ImGui.SameLine(ctx)
    ImGui.TextColored(ctx, C_DIM, "(muted)")
  end
  self:meter(lane, width - 16)

  local state, text = self:lane_state(lane)
  ImGui.PushFont(ctx, nil, 26)
  if lane.latest then
    local v = lane.latest.corrected_ms
    local word = Timing.classify(v, self.app.config.on_time_ms)
    local color = word == "ON TIME" and C_OK or (math.abs(v) > self.app.config.tolerance_ms and C_BAD or C_WARN)
    ImGui.TextColored(ctx, color, Timing.format_ms(v))
    ImGui.PopFont(ctx)
    ImGui.SameLine(ctx)
    ImGui.TextColored(ctx, color, word)
  else
    ImGui.TextColored(ctx, C_DIM, "--")
    ImGui.PopFont(ctx)
  end

  if state ~= "live" then
    ImGui.TextColored(ctx, state == "bad" and C_BAD or C_DIM, text)
  elseif not lc.scoring then
    ImGui.TextColored(ctx, C_DIM, "Not in this pattern")
  elseif not lane.latest then
    ImGui.TextColored(ctx, C_DIM, lane.counts.detected > 0 and "Hits arriving, none on pattern yet" or "Waiting for hits")
  else
    local recent = self.app.latest_hits(lane, 6)
    local parts = {}
    for i = #recent, 1, -1 do parts[#parts + 1] = string.format("%+.0f", recent[i].corrected_ms) end
    ImGui.TextColored(ctx, C_DIM, table.concat(parts, " "))
  end
  local c = lane.counts
  ImGui.Text(ctx, string.format("Det %d  Hit %d  Miss %d  Extra %d", c.detected, c.hits, c.misses, c.extras))
end

function UI:lane_cards()
  local ImGui, ctx = self.ImGui, self.ctx
  local lanes = self:visible_lanes()
  local flags = ImGui.TableFlags_BordersInnerV | ImGui.TableFlags_SizingStretchSame
  if ImGui.BeginTable(ctx, "cards", math.min(#lanes, 4), flags) then
    for i, lane in ipairs(lanes) do
      if (i - 1) % 4 == 0 then ImGui.TableNextRow(ctx) end
      ImGui.TableNextColumn(ctx)
      local width = ImGui.GetContentRegionAvail(ctx)
      self:lane_card(lane, width)
    end
    ImGui.EndTable(ctx)
  end
end

-- Stats ---------------------------------------------------------------------

function UI:stats_table()
  local ImGui, ctx = self.ImGui, self.ctx
  local flags = ImGui.TableFlags_RowBg | ImGui.TableFlags_BordersInnerH
  if not ImGui.BeginTable(ctx, "stats", 10, flags) then return end
  for _, name in ipairs({ "Lane", "In window", "Bias (mean)", "Spread (SD)", "Avg |err|", "in 10ms", "in 20ms", "Scored", "Miss", "Extra" }) do
    ImGui.TableSetupColumn(ctx, name)
  end
  ImGui.TableHeadersRow(ctx)
  for _, lane in ipairs(self:visible_lanes()) do
    local lc = self.app.config.lanes[lane.index]
    local s = self.app.session:stats(lane)
    ImGui.TableNextRow(ctx)
    ImGui.TableNextColumn(ctx)
    ImGui.TextColored(ctx, lc.color, lc.name)
    local cells = {
      tostring(s.n), fmt_ms(s.mean), fmt_unsigned_ms(s.sd), fmt_unsigned_ms(s.mae),
      fmt_pct(s.pct10), fmt_pct(s.pct20),
      tostring(lane.counts.hits), tostring(lane.counts.misses), tostring(lane.counts.extras),
    }
    for _, text in ipairs(cells) do
      ImGui.TableNextColumn(ctx)
      ImGui.Text(ctx, text)
    end
  end
  ImGui.EndTable(ctx)
  ImGui.TextColored(ctx, C_DIM, "Bias: consistently early (-) or late (+). Spread: how tightly hits cluster. A steady laid-back snare has high bias and low spread.")
end

-- Dynamics -------------------------------------------------------------------

local function fmt_db_value(v)
  if v == nil then return "--" end
  return string.format("%.1f dB", v)
end

local function fmt_sd_db(v)
  if v == nil then return "--" end
  return string.format("%.1f dB", v)
end

function UI:dynamics_table()
  local ImGui, ctx = self.ImGui, self.ctx
  local rows = {}
  for _, lane in ipairs(self:visible_lanes()) do
    local dyn = self.app.session:dynamics(lane)
    if dyn then rows[#rows + 1] = { lane = lane, dyn = dyn } end
  end
  if #rows == 0 then return end

  local flags = ImGui.TableFlags_RowBg | ImGui.TableFlags_BordersInnerH
  if not ImGui.BeginTable(ctx, "dynamics", 8, flags) then return end
  for _, name in ipairs({ "Dynamics", "Accent-ghost gap", "Accent level", "Accent spread", "Ghost level", "Ghost spread", "Ghosts missed", "Clipped" }) do
    ImGui.TableSetupColumn(ctx, name)
  end
  ImGui.TableHeadersRow(ctx)
  for _, row in ipairs(rows) do
    local lc = self.app.config.lanes[row.lane.index]
    ImGui.TableNextRow(ctx)
    ImGui.TableNextColumn(ctx)
    ImGui.TextColored(ctx, lc.color, lc.name)
    local cells = {
      fmt_db_value(row.dyn.gap),
      fmt_db_value(row.dyn.accent.mean), fmt_sd_db(row.dyn.accent.sd),
      fmt_db_value(row.dyn.ghost.mean), fmt_sd_db(row.dyn.ghost.sd),
      tostring(row.lane.counts.ghost_misses),
      tostring(row.dyn.accent.clipped + row.dyn.ghost.clipped),
    }
    for _, text in ipairs(cells) do
      ImGui.TableNextColumn(ctx)
      ImGui.Text(ctx, text)
    end
  end
  ImGui.EndTable(ctx)
  ImGui.TextColored(ctx, C_DIM, "Gap: how much louder accents are than ghosts at the mic. Unlike levels, it doesn't depend on mic gain.")
end

-- Pattern editor ------------------------------------------------------------

function UI:pattern_picker()
  local ImGui, ctx = self.ImGui, self.ctx
  local cfg = self.app.config
  local active = cfg.active_pattern

  ImGui.SetNextItemWidth(ctx, 280)
  local label = active.name .. (active.modified and " (edited)" or "")
  if ImGui.BeginCombo(ctx, "Pattern", label) then
    for _, group in ipairs(self.app.pattern_groups()) do
      if #group.items > 0 then
        ImGui.SeparatorText(ctx, group.title)
        for _, item in ipairs(group.items) do
          local selected = item.id == active.id and not active.modified
          if ImGui.Selectable(ctx, item.name, selected) then
            self.message = self.app.load_pattern(item.id)
          end
        end
      end
    end
    ImGui.EndCombo(ctx)
  end
  if self.app.previous_pattern then
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Undo load") then self.message = self.app.undo_pattern() end
  end
  ImGui.SameLine(ctx)
  ImGui.TextColored(ctx, C_DIM, "Loading a pattern resets the session stats.")

  ImGui.SetNextItemWidth(ctx, 200)
  local rv, name = ImGui.InputText(ctx, "##groovename", self.groove_name)
  if rv then
    self.groove_name = name
    self.confirm_save = false
  end
  ImGui.SameLine(ctx)
  local exists = self.app.has_user_groove(self.groove_name)
  if ImGui.Button(ctx, self.confirm_save and "Overwrite it?" or "Save groove") then
    if exists and not self.confirm_save then
      self.confirm_save = true
    else
      self.message = self.app.save_groove(self.groove_name)
      self.confirm_save = false
    end
  end
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, "Saves the grid below under this name. Calibration and thresholds aren't part of a groove.")
  end
  local user_name = active.id and active.id:match("^user:(.+)$")
  if user_name then
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, self.confirm_delete and "Really delete?" or "Delete groove") then
      if self.confirm_delete then
        self.message = self.app.delete_groove(user_name)
        self.confirm_delete = false
      else
        self.confirm_delete = true
      end
    end
  else
    self.confirm_delete = false
  end
end

function UI:rudiment_lane()
  local ImGui, ctx = self.ImGui, self.ctx
  local cfg = self.app.config
  local names = {}
  for i = 1, 8 do names[i] = cfg.lanes[i].name end
  ImGui.SetNextItemWidth(ctx, 130)
  local rv, lane = ImGui.Combo(ctx, "Play it on", cfg.rudiment_lane - 1, table.concat(names, "\0") .. "\0")
  if rv then self.app.set_rudiment_lane(lane + 1) end
  ImGui.SameLine(ctx)
  ImGui.TextColored(ctx, C_DIM, "Capitals are accents, lowercase are ghosts. Letters are the sticking.")
end

function UI:pattern_tab()
  local ImGui, ctx = self.ImGui, self.ctx
  local cfg = self.app.config
  self:pattern_picker()
  local sticking = cfg.active_pattern.sticking
  if cfg.active_pattern.modified then sticking = nil end
  if sticking then self:rudiment_lane() end
  ImGui.Spacing(ctx)
  local beat_names = { "1", "e", "&", "a", "2", "e", "&", "a", "3", "e", "&", "a", "4", "e", "&", "a" }
  local size, gap = 26, 3

  ImGui.Dummy(ctx, 100, 0)
  for s = 0, Patterns.STEPS - 1 do
    ImGui.SameLine(ctx, 0, s == 0 and 8 or gap + (s % 4 == 0 and 6 or 0))
    local x = ImGui.GetCursorPosX(ctx)
    local tw = ImGui.CalcTextSize(ctx, beat_names[s + 1])
    ImGui.SetCursorPosX(ctx, x + (size - tw) / 2)
    ImGui.TextColored(ctx, s % 4 == 0 and C_TEXT or C_DIM, beat_names[s + 1])
    ImGui.SameLine(ctx, 0, 0)
    ImGui.SetCursorPosX(ctx, x + size)
    ImGui.Dummy(ctx, 0, 0)
  end

  for _, lane in ipairs(self:visible_lanes()) do
    local lc = cfg.lanes[lane.index]
    local p = Patterns.from_steps(lc.steps)
    local levels = Library.level_map(lc)
    local changed = false
    ImGui.PushID(ctx, "pat" .. lane.index)
    local rv, score = ImGui.Checkbox(ctx, "##score", lc.scoring)
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Score this lane") end
    if rv then
      lc.scoring = score
      changed = true
    end
    ImGui.SameLine(ctx)
    local cx = ImGui.GetCursorPosX(ctx)
    ImGui.TextColored(ctx, lc.color, lc.name)
    ImGui.SameLine(ctx)
    ImGui.SetCursorPosX(ctx, cx + 72)
    ImGui.Dummy(ctx, 0, 0)
    for s = 0, Patterns.STEPS - 1 do
      ImGui.SameLine(ctx, 0, s == 0 and 8 or gap + (s % 4 == 0 and 6 or 0))
      local on_alpha = levels[s] == "accent" and 0xFF or (levels[s] == "ghost" and 0x48 or 0xA0)
      local base = p[s] and with_alpha(lc.color, on_alpha) or (s % 4 == 0 and C_STEP_OFF_BEAT or C_STEP_OFF)
      ImGui.PushStyleColor(ctx, ImGui.Col_Button, base)
      ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, p[s] and with_alpha(lc.color, 0xC8) or C_GRID)
      ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, lc.color)
      -- The mark says it without relying on the shade.
      local mark = ""
      if p[s] then
        if sticking then mark = sticking:sub(s + 1, s + 1)
        elseif levels[s] == "accent" then mark = ">"
        elseif levels[s] == "ghost" then mark = "g" end
      end
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, levels[s] == "ghost" and C_TEXT or 0x101114FF)
      if ImGui.Button(ctx, mark .. "##s" .. s, size, 22) then
        Library.cycle_step(lc, s)
        changed = true
      end
      ImGui.PopStyleColor(ctx, 4)
    end
    if changed then self.app.pattern_edited() end
    ImGui.PopID(ctx)
  end
  ImGui.Spacing(ctx)
  ImGui.TextColored(ctx, C_DIM, "One bar of 4/4 repeating. Click a step to cycle: on, accent (>), ghost (g), off. Editing restarts matching from now.")
end

-- Settings ------------------------------------------------------------------

function UI:settings_tab()
  local ImGui, ctx = self.ImGui, self.ctx
  local cfg = self.app.config

  if ImGui.Button(ctx, "Reset session") then self.app.session:reset() end
  ImGui.SameLine(ctx)
  local rv, v = ImGui.Checkbox(ctx, "Scoring on", cfg.scoring_enabled)
  if rv then
    cfg.scoring_enabled = v
    self.app.config_changed()
  end

  ImGui.PushItemWidth(ctx, 220)
  local current = 0
  for i, m in ipairs(Config.WINDOW_MODES) do
    if m == cfg.window_mode then current = i - 1 end
  end
  rv, v = ImGui.Combo(ctx, "Stats window", current, table.concat(Config.WINDOW_LABELS, "\0") .. "\0")
  if rv then
    cfg.window_mode = Config.WINDOW_MODES[v + 1]
    self.app.mark_dirty()
  end

  rv, v = ImGui.SliderDouble(ctx, "Match window (+/- ms)", cfg.match_window_ms, 5, 200, "%.0f")
  if rv then
    cfg.match_window_ms = v
    self.app.config_changed()
  end
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, "Automatically narrowed to half the gap between adjacent expected notes.")
  end
  rv, v = ImGui.SliderDouble(ctx, "Target band (+/- ms)", cfg.tolerance_ms, 1, 60, "%.0f")
  if rv then
    cfg.tolerance_ms = v
    self.app.mark_dirty()
  end
  rv, v = ImGui.SliderDouble(ctx, "ON TIME label (+/- ms)", cfg.on_time_ms, 0, 30, "%.0f")
  if rv then
    cfg.on_time_ms = v
    self.app.mark_dirty()
  end
  rv, v = ImGui.InputInt(ctx, "Score from bar", cfg.origin_bar)
  if rv then
    cfg.origin_bar = math.max(1, v)
    self.app.config_changed()
  end
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, "Reference bar. Earlier bars are ignored: use it to skip a count-in.")
  end
  ImGui.PopItemWidth(ctx)

  ImGui.SeparatorText(ctx, "Lanes")
  local flags = ImGui.TableFlags_SizingStretchProp
  if ImGui.BeginTable(ctx, "lanesettings", 5, flags) then
    for _, name in ipairs({ "Lane", "Name", "Threshold (dB)", "Retrigger (ms)", "Track" }) do
      ImGui.TableSetupColumn(ctx, name)
    end
    ImGui.TableHeadersRow(ctx)
    for i = 1, 8 do
      local lc = cfg.lanes[i]
      local inst = self.app.status.detectors[i][1]
      ImGui.PushID(ctx, "lane" .. i)
      ImGui.TableNextRow(ctx)
      ImGui.TableNextColumn(ctx)
      ImGui.Text(ctx, tostring(i))
      ImGui.TableNextColumn(ctx)
      ImGui.SetNextItemWidth(ctx, -1)
      rv, v = ImGui.InputText(ctx, "##name", lc.name)
      if rv and #v > 0 then
        lc.name = v:sub(1, 32)
        self.app.mark_dirty()
      end
      ImGui.TableNextColumn(ctx)
      if inst then
        ImGui.SetNextItemWidth(ctx, -1)
        rv, v = ImGui.SliderDouble(ctx, "##thr", inst.threshold_db, -70, 0, "%.1f")
        if rv then
          inst.threshold_db = v
          Bridge.set_param(inst, Bridge.PARAM_THRESHOLD, v)
        end
        ImGui.TableNextColumn(ctx)
        ImGui.SetNextItemWidth(ctx, -1)
        rv, v = ImGui.SliderDouble(ctx, "##ret", inst.retrig_ms, 5, 200, "%.0f")
        if rv then
          inst.retrig_ms = v
          Bridge.set_param(inst, Bridge.PARAM_RETRIG, v)
        end
        ImGui.TableNextColumn(ctx)
        ImGui.Text(ctx, string.format("%d: %s", inst.track_number, inst.track_name))
      else
        ImGui.TextColored(ctx, C_DIM, "--")
        ImGui.TableNextColumn(ctx)
        ImGui.TextColored(ctx, C_DIM, "--")
        ImGui.TableNextColumn(ctx)
        ImGui.TextColored(ctx, C_DIM, "no detector")
      end
      ImGui.PopID(ctx)
    end
    ImGui.EndTable(ctx)
  end
  ImGui.TextColored(ctx, C_DIM, "Filters, hysteresis, release and mask are on each detector's FX window.")

  ImGui.SeparatorText(ctx, "Presets")
  ImGui.SetNextItemWidth(ctx, 180)
  rv, v = ImGui.InputText(ctx, "Name", self.preset_name)
  if rv then self.preset_name = v end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Save preset") then self.message = self.app.save_preset(self.preset_name) end
  for _, name in ipairs(self.app.list_presets()) do
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Load " .. name) then self.message = self.app.load_preset(name) end
  end
end

-- Calibration ---------------------------------------------------------------

function UI:calibrate_tab()
  local ImGui, ctx = self.ImGui, self.ctx
  local cfg = self.app.config
  local latency, input, output = Bridge.reported_latency_ms()

  ImGui.TextWrapped(ctx, "A hit played dead on the click you hear still reads late, because the click takes time to leave the interface and the mic signal takes time to come back. Calibration subtracts that from each lane.")
  ImGui.Spacing(ctx)
  if latency and latency > 0 then
    ImGui.Text(ctx, string.format("REAPER-reported round trip: %.1f ms (input %d + output %d samples)", latency, input, output))
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Use for all lanes") then
      for _, lane in ipairs(self:visible_lanes()) do
        cfg.lanes[lane.index].calibration_ms = latency
        cfg.lanes[lane.index].calibrated = true
      end
      self.app.config_changed()
    end
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, "A driver's reported figure, not a measurement. Good start; a loopback test is better.")
    end
  else
    ImGui.TextColored(ctx, C_WARN, "REAPER is not reporting audio latency: is the audio device open?")
  end
  ImGui.TextColored(ctx, C_DIM, "Measure it properly: docs/timing-and-calibration.md describes the loopback test. During a test, 'Use measured bias' adds the rolling bias to the calibration.")

  ImGui.Spacing(ctx)
  local flags = ImGui.TableFlags_SizingStretchProp | ImGui.TableFlags_RowBg
  if ImGui.BeginTable(ctx, "cal", 5, flags) then
    for _, name in ipairs({ "Lane", "Calibration (ms)", "Bias now", "", "" }) do
      ImGui.TableSetupColumn(ctx, name)
    end
    ImGui.TableHeadersRow(ctx)
    for _, lane in ipairs(self:visible_lanes()) do
      local lc = cfg.lanes[lane.index]
      local stats = self.app.session:stats(lane)
      ImGui.PushID(ctx, "cal" .. lane.index)
      ImGui.TableNextRow(ctx)
      ImGui.TableNextColumn(ctx)
      ImGui.TextColored(ctx, lc.color, lc.name)
      ImGui.TableNextColumn(ctx)
      ImGui.SetNextItemWidth(ctx, -1)
      local rv, v = ImGui.InputDouble(ctx, "##ms", lc.calibration_ms, 0.1, 1, "%.2f")
      if rv then
        lc.calibration_ms = math.max(-500, math.min(500, v))
        lc.calibrated = true
        self.app.config_changed()
      end
      ImGui.TableNextColumn(ctx)
      ImGui.Text(ctx, fmt_ms(stats.mean))
      ImGui.TableNextColumn(ctx)
      if stats.mean then
        if ImGui.Button(ctx, "Use measured bias") then
          lc.calibration_ms = lc.calibration_ms + stats.mean
          lc.calibrated = true
          self.app.calibration_applied(lane)
        end
      else
        ImGui.TextColored(ctx, C_DIM, "needs hits")
      end
      ImGui.TableNextColumn(ctx)
      if lc.calibrated then
        if ImGui.Button(ctx, "Clear") then
          lc.calibration_ms = 0
          lc.calibrated = false
          self.app.calibration_applied(lane)
        end
      else
        ImGui.TextColored(ctx, C_WARN, "uncalibrated")
      end
      ImGui.PopID(ctx)
    end
    ImGui.EndTable(ctx)
  end
end

-- Diagnostics ---------------------------------------------------------------

function UI:diagnostics_tab()
  local ImGui, ctx = self.ImGui, self.ctx
  local flags = ImGui.TableFlags_RowBg | ImGui.TableFlags_SizingStretchProp
  local rows = {
    { "Detector", function(l)
        if l.alive then return "running" end
        return #self.app.status.detectors[l.index] > 0 and "NOT RUNNING" or "none"
      end },
    { "Track", function(l)
        local i = self.app.status.detectors[l.index][1]
        return i and string.format("%d: %s", i.track_number, i.track_name) or "--"
      end },
    { "Input", function(l)
        local i = self.app.status.detectors[l.index][1]
        return i and Bridge.input_label(i.input) or "--"
      end },
    { "Armed / monitoring", function(l)
        local i = self.app.status.detectors[l.index][1]
        if not i then return "--" end
        return string.format("%s / %s", i.armed and "yes" or "NO", i.monitor > 0 and "yes" or "NO")
      end },
    { "FX slot", function(l)
        local i = self.app.status.detectors[l.index][1]
        if not i then return "--" end
        return i.fx == 0 and "1 (first)" or string.format("%d: move it first!", i.fx + 1)
      end },
    { "Instances on lane", function(l) return tostring(#self.app.status.detectors[l.index]) end },
    { "Live level", function(l) return l.status and l.alive and fmt_db(l.status.level) or "--" end },
    { "Threshold", function(l) return l.status and l.alive and fmt_db(l.status.threshold) or "--" end },
    { "Last peak", function(l) return l.status and l.alive and fmt_db(l.status.last_peak) or "--" end },
    { "Triggers (total / while stopped)", function(l)
        return l.status and string.format("%d / %d", l.status.trigger_total, l.status.idle_triggers) or "--"
      end },
    { "Last hit QN", function(l) return l.last_event and string.format("%.4f", l.last_event.hit_qn) or "--" end },
    { "Last hit seconds", function(l) return l.last_event and string.format("%.5f", l.last_event.hit_s) or "--" end },
    { "Sample offset / backdated", function(l)
        return l.last_event and string.format("%d / %d", l.last_event.sample_offset, l.last_event.backdated) or "--"
      end },
    { "Block size / sample rate", function(l)
        return l.status and l.alive and string.format("%d / %d", l.status.samplesblock, l.status.srate) or "--"
      end },
    { "Last sequence", function(l) return l.status and tostring(l.reader.consumed) or "--" end },
    { "Lost events", function(l) return tostring(l.lost_events) end },
    { "Unscored (before origin)", function(l) return tostring(l.counts.unscored) end },
    { "Suspect: bleed", function(l) return tostring(l.counts.suspect_bleed) end },
    { "Suspect: double trigger", function(l) return tostring(l.counts.suspect_double) end },
    { "Transport segment", function(l) return l.segment and tostring(l.segment) or "--" end },
  }
  local lanes = self:visible_lanes()
  if ImGui.BeginTable(ctx, "diag", #lanes + 1, flags) then
    ImGui.TableSetupColumn(ctx, "")
    for _, lane in ipairs(lanes) do
      ImGui.TableSetupColumn(ctx, self.app.config.lanes[lane.index].name)
    end
    ImGui.TableHeadersRow(ctx)
    for _, row in ipairs(rows) do
      ImGui.TableNextRow(ctx)
      ImGui.TableNextColumn(ctx)
      ImGui.TextColored(ctx, C_DIM, row[1])
      for _, lane in ipairs(lanes) do
        ImGui.TableNextColumn(ctx)
        ImGui.Text(ctx, row[2](lane))
      end
    end
    ImGui.EndTable(ctx)
  end

  ImGui.SeparatorText(ctx, "Self-test: pulses from inside the detector, placed by the transport clock")
  ImGui.TextColored(ctx, C_DIM, "Tests detection, timestamps and matching with no kit plugged in. Inaudible. Bypasses real latency, so it proves nothing about calibration.")
  for _, lane in ipairs(lanes) do
    local inst = self.app.status.detectors[lane.index][1]
    if inst then
      ImGui.PushID(ctx, "st" .. lane.index)
      local rv, on = ImGui.Checkbox(ctx, self.app.config.lanes[lane.index].name, inst.st_mode > 0)
      if rv then
        local mode = on and math.min(lane.index, 3) or 0
        inst.st_mode = mode
        Bridge.set_param(inst, Bridge.PARAM_ST_MODE, mode)
      end
      ImGui.SameLine(ctx, 120)
      ImGui.SetNextItemWidth(ctx, 240)
      local rv2, off = ImGui.SliderDouble(ctx, "offset ms", inst.st_offset, -60, 60, "%+.1f")
      if rv2 then
        inst.st_offset = off
        Bridge.set_param(inst, Bridge.PARAM_ST_OFFSET, off)
      end
      ImGui.SameLine(ctx)
      local rv3, dyn_on = ImGui.Checkbox(ctx, "accents + ghosts (18 dB gap)", inst.st_mode == 4)
      if rv3 then
        local mode = dyn_on and 4 or 0
        inst.st_mode = mode
        Bridge.set_param(inst, Bridge.PARAM_ST_MODE, mode)
      end
      ImGui.PopID(ctx)
    end
  end
end

function UI:setup_tab()
  local ImGui, ctx = self.ImGui, self.ctx
  ImGui.TextWrapped(ctx, "For each drum you need a track with one mono mic input, the detector as its first FX with the right Lane ID, record-armed with input monitoring on. Then press play: no recording needed.")
  ImGui.Spacing(ctx)
  if ImGui.Button(ctx, "Add Kick, Snare, Hi-hat tracks...") then
    self.message = self.app.create_tracks()
  end
  ImGui.TextColored(ctx, C_DIM, "Asks first. Appends new tracks on inputs 1-3, in monitoring-only record mode. Changes nothing else; undoable.")
  ImGui.Spacing(ctx)
  if ImGui.Button(ctx, "Toggle REAPER click") then Bridge.toggle_metronome() end
  ImGui.Spacing(ctx)
  ImGui.TextColored(ctx, C_DIM, "This version scores 4/4 at one constant tempo with playrate 1.0. Other projects show hits but aren't scored.")
end

-- Frame ---------------------------------------------------------------------

function UI:frame()
  local ImGui, ctx = self.ImGui, self.ctx
  ImGui.SetNextWindowSize(ctx, 1000, 760, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, TITLE, true, ImGui.WindowFlags_NoCollapse)
  if visible then
    self:status_bar()
    ImGui.Separator(ctx)
    self:scatter()
    ImGui.Spacing(ctx)
    self:lane_cards()
    ImGui.Spacing(ctx)
    self:stats_table()
    self:dynamics_table()
    ImGui.Spacing(ctx)
    if ImGui.BeginTabBar(ctx, "tabs") then
      local tabs = {
        { "Pattern", self.pattern_tab },
        { "Settings", self.settings_tab },
        { "Calibrate", self.calibrate_tab },
        { "Diagnostics", self.diagnostics_tab },
        { "Setup", self.setup_tab },
      }
      local forced = self.cycle_tabs and math.floor(self.app.now() / 2) % #tabs + 1
      for i, tab in ipairs(tabs) do
        local tab_flags = forced == i and ImGui.TabItemFlags_SetSelected or ImGui.TabItemFlags_None
        if ImGui.BeginTabItem(ctx, tab[1], nil, tab_flags) then
          tab[2](self)
          ImGui.EndTabItem(ctx)
        end
      end
      ImGui.EndTabBar(ctx)
    end
    ImGui.End(ctx)
  end
  return open
end

return UI
