api = freeswitch.API()

-- Get phone number from argument
local phone_number = argv[1]

if not phone_number then
    freeswitch.consoleLog("ERROR", "Usage: luarun http.lua <phone_number>\n")
    return
end

-- Make API request - CORRECT WAY
local url = "https://control.zedsms.com/api/freeswitch/inbound?phone_number=" .. phone_number
freeswitch.consoleLog("INFO", "Calling API: " .. url .. "\n")

-- Use system curl instead of freeswitch curl
local handle = io.popen("curl -s '" .. url .. "'")
local response = handle:read("*a")
handle:close()

freeswitch.consoleLog("INFO", "Response: " .. response .. "\n")

-- Simple JSON parser
local function parseJSON(str)
    local result = {}
    
    -- Remove whitespace, { and }
    str = str:gsub("^%s*{%s*", ""):gsub("%s*}%s*$", "")
    
    -- Parse key-value pairs with quoted values
    for key, value in str:gmatch('"([^"]+)"%s*:%s*"([^"]+)"') do
        result[key] = value
    end
    
    -- Parse key-value pairs with numeric values
    for key, value in str:gmatch('"([^"]+)"%s*:%s*([%d%.]+)') do
        result[key] = tonumber(value)
    end
    
    -- Parse boolean values
    for key, value in str:gmatch('"([^"]+)"%s*:%s*(true)') do
        result[key] = true
    end
    for key, value in str:gmatch('"([^"]+)"%s*:%s*(false)') do
        result[key] = false
    end
    
    return result
end

-- Parse response
local data = parseJSON(response)

-- Check for sip_username (not username)
if data.sip_username then
    freeswitch.consoleLog("INFO", "SIP Username: " .. data.sip_username .. "\n")
    
    -- Find user contact
    local domains = {"207.148.67.228", "sip.hgdjlive.com"}
    local contact = nil
    
    for _, domain in ipairs(domains) do
        local user_domain = data.sip_username .. "@" .. domain
        local result = api:execute("sofia_contact", user_domain)
        
        if result and not result:match("error") and not result:match("^-ERR") then
            contact = result
            freeswitch.consoleLog("INFO", "Found contact: " .. contact .. "\n")
            break
        end
    end
    
    if contact then
        local action = data.action or "echo"
        local cmd = contact .. " &" .. action
        freeswitch.consoleLog("INFO", "Originating: " .. cmd .. "\n")
        
        local result = api:execute("originate", cmd)
        freeswitch.consoleLog("INFO", "Result: " .. result .. "\n")
    else
        freeswitch.consoleLog("ERROR", "User " .. data.sip_username .. " not registered\n")
    end
else
    freeswitch.consoleLog("ERROR", "No sip_username in API response\n")
    freeswitch.consoleLog("DEBUG", "Full response: " .. response .. "\n")
end
