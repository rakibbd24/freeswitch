local api = freeswitch.API()
local destination_number = session:getVariable("sip_to_display") or session:getVariable("sip_P-Asserted-Identity") or session:getVariable("destination_number")
destination_number = destination_number:gsub("^sip:", "")
destination_number = destination_number:gsub("^%+", "")
local caller_id_number = session:getVariable("caller_id_number")
local base_url = "https://control.zedsms.com"

local function log(msg)
  freeswitch.consoleLog("INFO", "[INBOUND] " .. msg .. "\n")
end

local function json_escape(str)
  if not str then return "" end
  str = tostring(str)
  str = str:gsub("\\", "\\\\")
  str = str:gsub("\"", "\\\"")
  str = str:gsub("\n", "\\n")
  str = str:gsub("\r", "\\r")
  str = str:gsub("\t", "\\t")
  return str
end

local function parseJSON(str)
  local result = {}
  str = str:gsub("^%s*{%s*", ""):gsub("%s*}%s*$", "")
  for key, value in str:gmatch('"([^"]+)"%s*:%s*"([^"]+)"') do result[key] = value end
  for key, value in str:gmatch('"([^"]+)"%s*:%s*([%d%.]+)') do result[key] = tonumber(value) end
  for key, value in str:gmatch('"([^"]+)"%s*:%s*(true)') do result[key] = true end
  for key, value in str:gmatch('"([^"]+)"%s*:%s*(false)') do result[key] = false end
  return result
end

local function http_post_json(url, json_body)
  log("POST " .. url)
  local cmd = string.format(
    "curl -s -X POST '%s' -H 'Content-Type: application/json' -d '%s'",
    url, json_body:gsub("'", "'\\''")
  )
  local handle = io.popen(cmd)
  local response = handle:read("*a")
  handle:close()
  log("Response: " .. response)
  return response
end

local function get_details(phone_number)
  local url = base_url .. "/api/freeswitch/inbound?phone_number=" .. phone_number
  log("Fetching: " .. url)
  local handle = io.popen("curl -s '" .. url .. "'")
  local response = handle:read("*a")
  handle:close()
  log("API Response: " .. response)
  return parseJSON(response)
end

local function get_contact(username)
  if not username then return false end
  local domains = {"207.148.67.228", "sip.hgdjlive.com"}
  for _, domain in ipairs(domains) do
    local result = api:execute("sofia_contact", username .. "@" .. domain)
    if result and not result:match("error") and not result:match("^-ERR") then
      log("Found contact: " .. result)
      return result
    end
  end
  return false
end

-- ① Get routing info
local user_detail = get_details(destination_number)
local user_id = user_detail.user_id
local dest = get_contact(user_detail.sip_username)

log("Inbound: caller=" .. caller_id_number .. " dest=" .. tostring(destination_number))

-- ② Hangup hook — registered BEFORE any hangup path
function on_hangup_hook(session, what, arg)
  local uuid        = session:get_uuid()
  local hangupCause = session:getVariable("hangup_cause") or "UNKNOWN"
  local dispo       = session:getVariable("originate_disposition") or ""
  local answer_epoch = tonumber(session:getVariable("answer_epoch") or "0") or 0

  -- ✅ billsec from answer_epoch — works for no-answer (answer_epoch=0 → billsec=0)
  local billsec = 0
  if answer_epoch > 0 then
    billsec = os.time() - answer_epoch
    if billsec < 0 then billsec = 0 end
  end

  local status = "completed"
  if hangupCause == "NO_ANSWER" or dispo == "NO_ANSWER" then
    status = "no_answer"
  elseif hangupCause == "ORIGINATOR_CANCEL" then
    status = "cancelled"
  elseif hangupCause == "USER_BUSY" then
    status = "busy"
  elseif hangupCause == "CALL_REJECTED" then
    status = "failed"
  elseif hangupCause == "NORMAL_CLEARING" then
    status = "completed"
  elseif hangupCause ~= "" and hangupCause ~= "NORMAL_CLEARING" then
    status = "failed"
  end

  log("HANGUP: cause=" .. hangupCause .. " status=" .. status .. " billsec=" .. billsec)

  -- ✅ Always fires regardless of call outcome
  local json_body = string.format([[
{
  "user_id": %d,
  "call_uuid": "%s",
  "destination_number": "%s",
  "direction": "inbound",
  "billsec": %d,
  "status": "%s",
  "caller_number": "%s"
}]],
    tonumber(user_id) or 0,
    json_escape(uuid),
    json_escape(destination_number),
    billsec,
    json_escape(status),
    json_escape(caller_id_number)
  )

  http_post_json(base_url .. "/api/calls/complete", json_body)
end

-- ③ Register hook NOW — before any possible hangup
session:setHangupHook("on_hangup_hook")

-- ④ Wait for registration if needed
local max_wait = 70
local waited = 0

if not dest then
  log("Waiting for user registration...")
  while session:ready() and not dest and waited < max_wait do
    dest = get_contact(user_detail.sip_username)
    if dest then break end
    freeswitch.msleep(2000)
    waited = waited + 1
  end
end

if not dest then
  log("User not registered after " .. max_wait .. "s — hanging up")
  -- hook will fire automatically and send complete API with status=failed
  session:hangup("NO_ROUTE_DESTINATION")
  return
end

-- ⑤ Bridge
session:setVariable("hangup_after_bridge", "true")
session:setVariable("continue_on_fail", "false")
session:setVariable("bridge_answer_timeout", "60")
session:setVariable("leg_timeout", "60")

log("Bridging to: " .. dest)
session:execute("bridge", dest)

local disposition = session:getVariable("originate_disposition") or ""
local cause = session:getVariable("hangup_cause") or "UNKNOWN"
log("Bridge done -> disposition=" .. disposition .. " cause=" .. cause)
