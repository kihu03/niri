--!nonstrict
-- Synthetic.new quota in the Noctalia bar.
--
-- Reads the API key out of the Hermes .env file, polls
-- GET https://api.synthetic.new/v2/quotas and renders the weekly credit level
-- as a small fill gauge (declarative ui.* tree: coin glyph + ui.progress).
-- The number returns only below warn_below. The endpoint does not count
-- against the subscription.
--
--   noctalia msg plugin kihu/synthetic-usage:usage focused refresh

local URL = "https://api.synthetic.new/v2/quotas"
local TICK_MS = 30000

local envPath     = noctalia.getConfig("env_file") or "/home/kinh/.hermes/.env"
local keyVar      = noctalia.getConfig("key_var") or "HERMES_CUSTOM_API_SYNTHETIC_NEW_API_KEY"
local intervalMin = tonumber(noctalia.getConfig("interval_minutes")) or 5
local warnBelow   = tonumber(noctalia.getConfig("warn_below")) or 15
local showWindow  = noctalia.getConfig("show_window") == true

local quota      = nil   -- decoded /v2/quotas body
local lastFetch  = 0     -- epoch seconds of the last attempt
local lastError  = nil
local inFlight   = false

--------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------

local function nowSec()
  if os and os.time then return os.time() end
  if noctalia.nowMs then return math.floor(noctalia.nowMs() / 1000) end
  return 0
end

local function readKey()
  local raw, err = noctalia.readFile(envPath)
  if not raw then return nil, "env file unreadable" end

  for line in raw:gmatch("[^\r\n]+") do
    local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if k == keyVar then
      v = v:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
      if v ~= "" then return v end
    end
  end
  return nil, "key not in env file"
end

-- ISO-8601 UTC ("2026-11-07T20:31:36.000Z") to epoch seconds.
local function daysFromCivil(y, m, d)
  if m <= 2 then y -= 1 end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

local function isoToEpoch(s)
  if type(s) ~= "string" then return nil end
  local y, mo, d, h, mi, se = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)")
  if not y then return nil end
  return daysFromCivil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
      + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(se)
end

local function humanDelta(targetEpoch)
  if not targetEpoch then return "" end
  local secs = targetEpoch - nowSec()
  if secs <= 0 then return "now" end
  if secs < 60 then return "<1m" end
  local d = math.floor(secs / 86400)
  local h = math.floor((secs % 86400) / 3600)
  local m = math.floor((secs % 3600) / 60)
  if d > 0 then return string.format("%dd%dh", d, h) end
  if h > 0 then return string.format("%dh%02dm", h, m) end
  return string.format("%dm", m)
end

--------------------------------------------------------------------------
-- dial artwork
--
-- The declarative bar UI has no arc/ring primitive, so the open ring is an SVG
-- written to the plugin's data dir and drawn with ui.image. The stroke colour
-- comes from the live palette (noctalia.getColor), so it follows the theme and
-- turns error-coloured when the quota is low. Full quota = closed circle; as
-- credits are spent the gap opens at 12 o'clock.
--------------------------------------------------------------------------

local DIAL_R = 40
local DIAL_STROKE = 14

local function dialSvg(pct, colorHex)
  local f = math.max(0, math.min(1, pct / 100))
  local head = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">'
  if f >= 0.995 then
    return string.format(
      '%s<circle cx="50" cy="50" r="%d" fill="none" stroke="%s" stroke-width="%d"/></svg>',
      head, DIAL_R, colorHex, DIAL_STROKE)
  end

  -- Anchor the stroke at 12 o'clock and run it one way only (clockwise), so the
  -- gap is a single opening whose end sits at the top rather than two symmetric
  -- slices either side of it.
  local sweep = 360 * f
  local startDeg = -90
  local endDeg = startDeg + sweep
  local function pt(deg)
    local rad = deg * math.pi / 180
    return 50 + DIAL_R * math.cos(rad), 50 + DIAL_R * math.sin(rad)
  end
  local x0, y0 = pt(startDeg)
  local x1, y1 = pt(endDeg)
  local large = sweep > 180 and 1 or 0

  return string.format(
    '%s<path d="M %.2f %.2f A %d %d 0 %d 1 %.2f %.2f" fill="none" stroke="%s" ' ..
    'stroke-width="%d" stroke-linecap="round" opacity="%s"/></svg>',
    head, x0, y0, DIAL_R, DIAL_R, large, x1, y1, colorHex, DIAL_STROKE,
    f < 0.02 and "0.3" or "1")
end

-- Binned fallback for the day pluginDataDir/writeFile are unavailable.
local DIAL_STEPS = { 0, 10, 20, 25, 30, 33, 40, 50, 60, 66, 70, 75, 80, 90, 100 }
local function fallbackDial(pct)
  local best, bestDelta = 0, 1e9
  for _, step in ipairs(DIAL_STEPS) do
    local delta = math.abs(step - pct)
    if delta < bestDelta then best, bestDelta = step, delta end
  end
  return "percentage-" .. tostring(best)
end

local dialCache = {}
local dialDir = nil

local function prepareDialDir()
  if dialDir ~= nil then return dialDir end
  dialDir = false
  if not (noctalia.pluginDataDir and noctalia.writeFile) then return false end
  local ok, dir = pcall(noctalia.pluginDataDir)
  if not ok or type(dir) ~= "string" then return false end

  -- Stale frames from a previous palette would otherwise linger forever.
  local files = noctalia.listDir and noctalia.listDir(dir)
  if type(files) == "table" then
    for _, name in ipairs(files) do
      if type(name) == "string" and name:match("^dial%-") then
        noctalia.removeFile(dir .. "/" .. name)
      end
    end
  end
  dialDir = dir
  return dialDir
end

local function dialImage(pct, role)
  local dir = prepareDialDir()
  if not dir then return nil end

  local colour = noctalia.getColor and noctalia.getColor(role) or nil
  if type(colour) ~= "string" then colour = "#e6e6e6" end

  local key = string.format("%d-%s", math.floor(pct + 0.5), (colour:gsub("#", "")))
  local cached = dialCache[key]
  if cached then return cached end

  local path = dir .. "/dial-" .. key .. ".svg"
  if not (noctalia.fileExists and noctalia.fileExists(path)) then
    local ok = noctalia.writeFile(path, dialSvg(pct, colour))
    if not ok then return nil end
  end
  dialCache[key] = path
  return path
end

--------------------------------------------------------------------------
-- rendering
--------------------------------------------------------------------------

local function render()
  local fit = barWidget.isVertical() and ui.column or ui.row

  if not quota then
    barWidget.render(fit({ gap = 6, align = "center" }, {
      ui.glyph({ name = "coin", size = 14 }),
      ui.label({ text = "--" }),
    }))
    if lastError then
      barWidget.setTooltip({ { key = "Synthetic", value = lastError } })
    else
      barWidget.setTooltip({ { key = "Synthetic", value = "Reading quota..." } })
    end
    return
  end

  local weekly = quota.planWeeklyLimit or {}
  local sub = quota.subscription or {}
  local searchHourly = (quota.search or {}).hourly or {}

  local weeklyPct = tonumber(weekly.percentRemaining)
  local low = weeklyPct ~= nil and weeklyPct <= warnBelow
  -- Same ink as the neighbouring widgets (on_surface), error only when low:
  -- the dial is meant to read as part of the bar, not as an accent.
  local role = low and "error" or "on_surface"

  -- Open ring drawn from the live percentage: a closed circle at 100, with a gap
  -- at 12 o'clock that widens as credits are spent. Tabler glyph fallback in
  -- case the SVG frame cannot be written.
  local left = weeklyPct or 0
  local art = dialImage(left, role)
  local kids
  if art then
    kids = { ui.image({ path = art, width = 15, height = 15, fit = "contain" }) }
  else
    kids = { ui.glyph({ name = fallbackDial(left), size = 15, color = role }) }
  end
  if low and weeklyPct then
    kids[#kids + 1] = ui.label({
      text = string.format("%d%%", math.floor(weeklyPct + 0.5)),
      color = "error",
    })
  end
  if showWindow and tonumber(sub.limit) and tonumber(sub.limit) > 0 then
    kids[#kids + 1] = ui.label({
      text = string.format("%d/%d", tonumber(sub.requests) or 0, tonumber(sub.limit)),
    })
  end
  barWidget.render(fit({ gap = 6, align = "center" }, kids))

  local tooltipRows = {}
  if weeklyPct then
    tooltipRows[#tooltipRows + 1] = {
      key = "Weekly",
      value = string.format("%.1f%% left", weeklyPct),
    }
    if tonumber(weekly.nextRegenPercent) then
      tooltipRows[#tooltipRows + 1] = {
        key = "Regen",
        value = string.format("+%d%% in %s",
          tonumber(weekly.nextRegenPercent), humanDelta(isoToEpoch(weekly.nextRegenAt))),
      }
    end
  end
  if tonumber(sub.limit) then
    tooltipRows[#tooltipRows + 1] = {
      key = "5h window",
      value = string.format("%d/%d - %s",
        tonumber(sub.requests) or 0, tonumber(sub.limit), humanDelta(isoToEpoch(sub.renewsAt))),
    }
  end
  if tonumber(searchHourly.limit) then
    tooltipRows[#tooltipRows + 1] = {
      key = "Search",
      value = string.format("%d/%d per h",
        tonumber(searchHourly.requests) or 0, tonumber(searchHourly.limit)),
    }
  end
  if lastError then
    tooltipRows[#tooltipRows + 1] = { key = "Error", value = lastError }
  end
  barWidget.setTooltip(tooltipRows)
end

--------------------------------------------------------------------------
-- fetching
--------------------------------------------------------------------------

local function fetch()
  if inFlight then return end

  -- Stamp the attempt BEFORE it runs. A failed key read or a request the shell
  -- rejects synchronously must not re-trigger on every 30s tick: that spams the
  -- log and re-reads .env every half minute. The HTTP callback moves the stamp
  -- forward to response time.
  lastFetch = nowSec()

  local key, err = readKey()
  if not key then
    lastError = tostring(err or "no API key available")
    render()
    noctalia.log("synthetic-usage: " .. tostring(err))
    return
  end

  inFlight = true
  local started = noctalia.http({
    url = URL,
    method = "GET",
    headers = {
      "Authorization: Bearer " .. key,
      "Accept: application/json",
    },
  }, function(res)
    inFlight = false
    lastFetch = nowSec()
    if res and res.ok and res.status == 200 then
      local data = noctalia.json.decode(res.body or "")
      if type(data) == "table" then
        quota = data
        lastError = nil
      else
        lastError = "bad JSON"
      end
    elseif res then
      lastError = "HTTP " .. tostring(res.status)
    else
      lastError = "no response"
    end
    render()
  end)

  if not started then
    inFlight = false
    lastError = "request rejected"
    render()
  end
end

--------------------------------------------------------------------------
-- lifecycle
--------------------------------------------------------------------------

function update()
  noctalia.setUpdateInterval(TICK_MS)
  if nowSec() - lastFetch >= intervalMin * 60 then fetch() end
  render()
end

function onClick()
  fetch()
end

function onIpc(event)
  if event == "refresh" then
    lastFetch = 0
    fetch()
  end
end

render()
