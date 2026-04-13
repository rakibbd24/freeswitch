-- Create API object first
api = freeswitch.API()

-- Usage: luarun test.lua username [application]
local username = argv[1]
local app = argv[2] or "echo"

if not username then
    freeswitch.consoleLog("ERROR", "Usage: luarun test.lua <username> [application]\n")
    return
end

-- Try different domains
local domains = {"207.148.67.228", "sip.hgdjlive.com"}
local contact = nil

-- First, try to get contact from sofia registration
for _, domain in ipairs(domains) do
    local user_domain = username .. "@" .. domain
    local result = api:execute("sofia_contact", user_domain)
    
    if result and not result:match("error") and not result:match("^-ERR") then
        contact = result
        freeswitch.consoleLog("INFO", "Found contact for " .. user_domain .. ": " .. contact .. "\n")
        break
    end
end

if contact then
    -- Originate using the found contact
    local cmd = "originate " .. contact .. " &" .. app
    freeswitch.consoleLog("INFO", "Executing: " .. cmd .. contact .. "\n")
    
    local result = api:execute("originate", contact .. " &" .. app)
    freeswitch.consoleLog("INFO", "Result: " .. result .. "\n")
else
    freeswitch.consoleLog("ERROR", "User " .. username .. " not found in any domain\n")
end
