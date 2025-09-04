local cosock = require "cosock"
local http = require "socket.http"
local ltn12 = require "ltn12"
local json = require "st.json"
local log = require "log"
local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local socket = require "cosock.socket"

-- Custom attributes (not standard capabilities)
local function create_custom_attribute(name, attribute_type)
  return capabilities["legendabsolute60149." .. name] or capabilities.custom_attribute(attribute_type)  -- Use custom if no namespace
end

-- Note: SmartThings doesn't support custom capabilities easily; these will be string attributes emitted as events.
-- The app may display them as text.

local function poll(device)
  local prefs = device.preferences
  if not prefs.ipAddr or not prefs.tcpPort then
    log.error("IP address or port not set")
    return
  end

  local url = "http://" .. prefs.ipAddr .. ":" .. prefs.tcpPort .. "/api/v1/production"
  local resp_body = {}
  local body, code = http.request {
    url = url,
    sink = ltn12.sink.table(resp_body),
    method = "GET",
    timeout = 5
  }

  local data
  if code == 200 then
    local response = table.concat(resp_body)
    data = json.decode(response)
    device:set_field("api_type", "JSON", {persist = true})
  else
    -- Fallback to HTML parsing for older firmware
    url = "http://" .. prefs.ipAddr .. ":" .. prefs.tcpPort .. "/"
    resp_body = {}
    body, code = http.request {
      url = url,
      sink = ltn12.sink.table(resp_body),
      method = "GET",
      timeout = 5
    }
    if code == 200 then
      local response = table.concat(resp_body)
      data = parse_html(response)
      device:set_field("api_type", "HTML", {persist = true})
    else
      log.error("Failed to fetch data: " .. (code or "unknown"))
      return
    end
  end

  if not data then return end

  -- Extract values (adjust based on API structure)
  local power = data.wNow or 0
  local whToday = data.whToday or 0
  local whLastSevenDays = data.whLastSevenDays or 0
  local whLifetime = data.whLifetime or 0

  -- Emit standard events
  device:emit_event(capabilities.powerMeter.power({value = power, unit = "W"}))
  device:emit_event(capabilities.energyMeter.energy({value = whLifetime / 1000, unit = "kWh"}))

  -- Track yesterday
  local current_date = os.date("%Y-%m-%d")
  local last_date = device:get_field("last_date") or current_date
  local last_whToday = device:get_field("last_whToday") or 0
  local energy_yesterday = device:get_field("energy_yesterday") or 0

  if current_date ~= last_date then
    energy_yesterday = last_whToday
    device:set_field("energy_yesterday", energy_yesterday, {persist = true})
  end
  device:set_field("last_whToday", whToday, {persist = true})
  device:set_field("last_date", current_date, {persist = true})

  -- System size in kW
  local system_kW = (prefs.numInverters * prefs.panelSize) / 1000
  if system_kW == 0 then system_kW = 1 end  -- Avoid division by zero

  -- Calculate efficiencies
  local eff_today = whToday / 1000 / system_kW
  local eff_yesterday = energy_yesterday / 1000 / system_kW
  local eff_7days = whLastSevenDays / 1000 / system_kW
  local eff_life = whLifetime / 1000 / system_kW

  -- Emit custom string events
  device:emit_event(create_custom_attribute("energy_str", "STRING")({value = string.format("%.2f kWh", whToday / 1000)}))
  device:emit_event(create_custom_attribute("energy_yesterday", "STRING")({value = string.format("%.2f kWh", energy_yesterday / 1000)}))
  device:emit_event(create_custom_attribute("energy_last7days", "STRING")({value = string.format("%.2f kWh", whLastSevenDays / 1000)}))
  device:emit_event(create_custom_attribute("energy_life", "STRING")({value = string.format("%.2f kWh", whLifetime / 1000)}))
  device:emit_event(create_custom_attribute("efficiency", "STRING")({value = string.format("%.2f h", eff_today)}))
  device:emit_event(create_custom_attribute("efficiency_yesterday", "STRING")({value = string.format("%.2f h", eff_yesterday)}))
  device:emit_event(create_custom_attribute("efficiency_last7days", "STRING")({value = string.format("%.2f h", eff_7days)}))
  device:emit_event(create_custom_attribute("efficiency_life", "STRING")({value = string.format("%.2f h", eff_life)}))

  -- Reschedule next poll
  device.thread:call_with_delay(prefs.pollingInterval * 60, function() poll(device) end)
end

local function parse_html(body)
  local data = {}
  -- Simple string parsing based on Groovy patterns (adjust if HTML changes)
  data.wNow = tonumber(body:match('wNow:%s*(%d+)') or 0)
  data.whToday = tonumber(body:match('whToday:%s*(%d+)') or 0)
  data.whLastSevenDays = tonumber(body:match('whLastSevenDays:%s*(%d+)') or 0)
  data.whLifetime = tonumber(body:match('whLifetime:%s*(%d+)') or 0)
  return data
end

local envoy_driver = Driver("enphase-envoy", {
  lifecycle_handlers = {
    init = function(driver, device)
      -- Start polling
      poll(device)
    end,
  },
  capability_handlers = {
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = poll,
    },
  }
})

envoy_driver:run()