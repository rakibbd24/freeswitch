local base_url = "https://control.zedsms.com"
local dest = session:getVariable("destination_number") or ""
local caller = session:getVariable("caller_id_number") or ""
local username = session:getVariable("sip_h_X-USER-ID") or ""
local virtual_number_id = session:getVariable("sip_h_X-VIRTUAL-NUMBER-ID") or 0
local sip_call_id = session:getVariable("sip_call_id")

local function log(msg)
  freeswitch.consoleLog("INFO", "[OUTBOUND] " .. msg .. "\n")
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

-- ① Authorize
local function get_details()
  local url = base_url .. "/api/calls/authorize"
  local json_body = string.format([[
{
  "user_id": %d,
  "virtual_number_id": %d,
  "call_uuid": "%s",
  "destination_number": "%s"
}]],
    tonumber(username) or 0,
    tonumber(virtual_number_id) or 0,
    json_escape(sip_call_id),
    json_escape(dest:sub(2))
  )
  local resp = http_post_json(url, json_body)
  return parseJSON(resp)
end

local detail = get_details()

if detail.status == false then
  log("Auth denied — sending complete API then hanging up")
  -- ✅ Always call complete on auth failure so balance lock is released
  http_post_json(base_url .. "/api/calls/complete", string.format([[
{
  "user_id": %d,
  "call_uuid": "%s",
  "destination_number": "%s",
  "direction": "outbound",
  "billsec": 0,
  "status": "failed"
}]], tonumber(username) or 0, json_escape(sip_call_id), json_escape(dest:sub(2))))
  session:hangup()
  return
end

local caller_id   = detail.caller_number
local max_duration = detail.max_call_sec

-- ② Hangup hook — fires for ALL outcomes (no_answer, failed, completed)
local call_start_time = os.time()

function on_hangup_hook(session, what, arg)
  local hangupCause = session:getVariable("hangup_cause") or "UNKNOWN"
  local dispo       = session:getVariable("originate_disposition") or ""
  local answer_epoch = tonumber(session:getVariable("answer_epoch") or "0") or 0
  local user_id     = tonumber(session:getVariable("sip_h_X-USER-ID") or "0") or 0
  local destination_number = session:getVariable("destination_number") or dest

  -- ✅ Calculate billsec correctly
  -- If answer_epoch > 0, call was actually answered
  local billsec = 0
  if answer_epoch > 0 then
    billsec = os.time() - answer_epoch
    if billsec < 0 then billsec = 0 end
  end

  -- ✅ Status mapping covers all cases
  local status = "completed"
  if hangupCause == "NO_ANSWER" or dispo == "NO_ANSWER" then
    status = "no_answer"
  elseif hangupCause == "ORIGINATOR_CANCEL" or hangupCause == "ORIGINATOR_CANCEL" then
    status = "cancelled"
  elseif hangupCause == "USER_BUSY" then
    status = "busy"
  elseif hangupCause == "CALL_REJECTED" or hangupCause == "INVALID_NUMBER_FORMAT" then
    status = "failed"
  elseif hangupCause == "NORMAL_CLEARING" then
    status = "completed"
  elseif hangupCause ~= "" and hangupCause ~= "NORMAL_CLEARING" then
    status = "failed"
  end

  log("HANGUP: cause=" .. hangupCause .. " status=" .. status .. " billsec=" .. billsec)

  -- ✅ complete API always fires
  local json_body = string.format([[
{
  "user_id": %d,
  "call_uuid": "%s",
  "destination_number": "%s",
  "direction": "outbound",
  "billsec": %d,
  "status": "%s"
}]],
    user_id,
    json_escape(sip_call_id),
    json_escape(destination_number),
    billsec,
    json_escape(status)
  )

  http_post_json(base_url .. "/api/calls/complete", json_body)
end

-- ③ Register hook BEFORE bridge
session:setHangupHook("on_hangup_hook")

-- ④ Set call variables
session:setVariable("effective_caller_id_number", caller_id)
session:setVariable("sip_from_user", caller_id)
session:setVariable("sip_from_host", "sip.cloudnumbering.com")
session:setVariable("sip_from_display", caller_id)
session:setVariable("absolute_codec_string", "PCMA")
session:setVariable("hangup_after_bridge", "false")
session:setVariable("ringback", "${us-ring}")
session:setVariable("transfer_ringback", "${us-ring}")
session:setVariable("bridge_early_media", "true")
session:setVariable("ignore_early_media", "false")
session:setVariable("call_timeout", "60")
session:setVariable("originate_timeout", "60")
session:setVariable("progress_timeout", "15")
session:setVariable("continue_on_fail", "true")
session:setVariable("execute_on_answer", "sched_hangup +" .. max_duration .. " normal_clearing")

log("Caller: " .. caller_id .. " | Dest: " .. dest .. " | Max: " .. max_duration .. "s")

-- ⑤ Bridge
local bridge_str = "sofia/gateway/cloudnumbering/" .. dest
log("Bridging to: " .. bridge_str)
session:execute("bridge", bridge_str)

local disposition = session:getVariable("originate_disposition") or ""
local cause = session:getVariable("hangup_cause") or "UNKNOWN"
log("Bridge done -> disposition=" .. disposition .. " cause=" .. cause)

if session:ready() then
  session:hangup()
end
