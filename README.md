# ZedSMS FreeSWITCH — Complete Documentation
**Server:** Vultr VPS · `207.148.67.228`  
**Backend:** `https://control.zedsms.com`  
**Date:** April 2026  
**Author:** Generated from live session audit

---

## Table of Contents
1. [System Overview](#1-system-overview)
2. [Architecture](#2-architecture)
3. [Server & Software Versions](#3-server--software-versions)
4. [Directory Structure](#4-directory-structure)
5. [SIP Profiles](#5-sip-profiles)
6. [Dialplan](#6-dialplan)
7. [Lua Scripts](#7-lua-scripts)
8. [API Reference](#8-api-reference)
9. [Call Flows](#9-call-flows)
10. [Laravel Backend](#10-laravel-backend)
11. [After Restart Procedure](#11-after-restart-procedure)
12. [Monitoring Commands](#12-monitoring-commands)
13. [Backup Procedure](#13-backup-procedure)
14. [Common Issues & Fixes](#14-common-issues--fixes)
15. [Known Limitations](#15-known-limitations)
16. [Changelog](#16-changelog)

---

## 1. System Overview

ZedSMS is a calling platform that allows users to make and receive calls via WebRTC using UK virtual numbers. The system has three main layers:

- **Clients** — Flutter mobile app / browser WebRTC connecting via SIP over WSS
- **FreeSWITCH** — SIP server handling all call routing, bridging, and media
- **Laravel backend** — handles authentication, billing, balance management, and routing decisions

All outbound calls go through the **Cloudnumbering** SIP trunk. Inbound calls arrive from Cloudnumbering and are routed to the correct registered user by looking up their virtual number in the Laravel backend.

---

## 2. Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                          CLIENTS                                │
│                                                                 │
│   ┌──────────────────┐     ┌──────────────────┐               │
│   │   WebRTC App     │     │   Mobile App     │               │
│   │ Flutter/Browser  │     │  SIP over WSS    │               │
│   └────────┬─────────┘     └────────┬─────────┘               │
└────────────┼──────────────────────── ┼───────────────────────── ┘
             │ WSS port 7050           │ WSS port 7050
             │                         │
┌────────────▼─────────────────────────▼───────────────────────── ┐
│                    FREESWITCH  207.148.67.228                    │
│                                                                  │
│  ┌─────────────────┐ ┌──────────────────┐ ┌─────────────────┐  │
│  │ Internal Profile│ │Cloudnumbering    │ │External Profile │  │
│  │   Port 7050     │ │Profile Port 6070 │ │   Port 7051     │  │
│  └────────┬────────┘ └────────┬─────────┘ └────────┬────────┘  │
│           │                   │                     │           │
│  ┌────────▼──────────────────────────────────────── ▼────────┐  │
│  │                    DIALPLAN (default.xml)                  │  │
│  │    regex: ^\+?[1-9]\d{7,20}$ → outbound_mananger.lua     │  │
│  │    context: cloudnumbering   → inbound_mananger.lua       │  │
│  └───────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌──────────────────────────┐  ┌──────────────────────────┐    │
│  │  outbound_mananger.lua   │  │  inbound_mananger.lua    │    │
│  │  1. POST /authorize      │  │  1. GET /inbound         │    │
│  │  2. Bridge to gateway    │  │  2. Find SIP contact     │    │
│  │  3. POST /complete       │  │  3. Bridge to user       │    │
│  └──────────┬───────────────┘  └──────────┬───────────────┘    │
└─────────────┼────────────────────────────── ┼────────────────── ┘
              │ outbound calls                 │ API calls
              ▼                               ▼
┌─────────────────────────┐   ┌──────────────────────────────────┐
│     CLOUDNUMBERING      │   │    LARAVEL BACKEND               │
│  sip.cloudnumbering.com │   │    control.zedsms.com            │
│  UK virtual numbers     │   │                                  │
│  PSTN termination       │   │  POST /api/calls/authorize       │
│                         │   │  POST /api/calls/complete        │
│  Inbound: port 6070     │   │  GET  /api/freeswitch/inbound    │
│  Outbound: port 7051    │   │                                  │
└─────────────────────────┘   └──────────────────────────────────┘
```

---

## 3. Server & Software Versions

| Component | Version / Detail |
|-----------|-----------------|
| OS | Ubuntu 24 |
| FreeSWITCH | 1.10.12 release |
| Lua | 5.1 |
| SIP Trunk | Cloudnumbering.com |
| Backend | Laravel (PHP) |
| Hosting | Vultr VPS |
| Server IP | 207.148.67.228 |

---

## 4. Directory Structure

```
/etc/freeswitch/
├── vars.xml                          # Global variables (domain, codecs)
├── freeswitch.xml                    # Main config entry point
├── autoload_configs/
│   └── modules.conf.xml              # Module autoload list
├── dialplan/
│   ├── default.xml                   # Main outbound dialplan
│   ├── cloudnumbering.xml            # Inbound context for DID calls
│   └── public/
│       └── cloudnumbering.xml        # Public inbound routing
├── sip_profiles/
│   ├── internal.xml                  # Internal profile (port 7050, WSS)
│   ├── external.xml                  # External profile (port 7051)
│   └── external/
│       └── cloudnumbering.xml        # Cloudnumbering gateway config
└── directory/
    └── default/                      # User directory (via mod_xml_curl)

/usr/share/freeswitch/scripts/
├── outbound_mananger.lua             # Outbound call handler
├── outbound_mananger.lua.bak         # Backup (original)
├── inbound_mananger.lua              # Inbound call handler
├── inbound_mananger.lua.bak          # Backup (original)
├── inbound_mananger.lua.bak2         # Backup (post-fix v1)
└── http.lua                          # Utility script
```

---

## 5. SIP Profiles

### 5.1 Internal Profile (port 7050)
- **Purpose:** WebRTC clients connect here via WSS (Secure WebSocket)
- **Port:** 7050 (SIP), 5061 (TLS)
- **Auth:** Via `mod_xml_curl` → Laravel backend returns SIP credentials
- **Context:** `default`

### 5.2 Cloudnumbering Profile (port 6070)
- **Purpose:** Receives inbound calls from Cloudnumbering carrier
- **Port:** 6070
- **Context:** `cloudnumbering`
- **ACL:** Only Cloudnumbering IPs allowed

### 5.3 External Profile (port 7051)
- **Purpose:** Sends outbound calls to Cloudnumbering gateway
- **Port:** 7051
- **Auth:** IP-based (no registration required)

### 5.4 Gateway Config
**File:** `/etc/freeswitch/sip_profiles/external/cloudnumbering.xml`

```xml
<gateway name="cloudnumbering">
  <param name="proxy" value="sip.cloudnumbering.com"/>
  <param name="realm" value="sip.cloudnumbering.com"/>
  <param name="register" value="false"/>
  <param name="codec-prefs" value="PCMA"/>
  <param name="caller-id-in-from" value="true"/>
  <param name="sip-cid-type" value="pid"/>
  <param name="from-domain" value="sip.cloudnumbering.com"/>
  <param name="transport" value="udp"/>
</gateway>
```

> **Note:** `register=false` because Cloudnumbering uses IP-based authentication.
> Your server IP `207.148.67.228` must be whitelisted in your Cloudnumbering account.

---

## 6. Dialplan

### 6.1 Outbound Extension
**File:** `/etc/freeswitch/dialplan/default.xml`

```xml
<extension name="test_extention">
  <condition field="destination_number" expression="^\+?[1-9]\d{7,20}$">
    <action application="lua" data="outbound_mananger.lua"/>
  </condition>
</extension>
```

> **Important:** Regex was updated from `{7,14}` to `{7,20}` to support longer destination numbers used internally by the system.

### 6.2 Inbound Context
**File:** `/etc/freeswitch/dialplan/cloudnumbering.xml`

```xml
<context name="cloudnumbering">
  <extension name="cloud_test">
    <condition field="destination_number" expression="^.+$">
      <action application="lua" data="inbound_mananger.lua"/>
    </condition>
  </extension>
</context>
```

---

## 7. Lua Scripts

### 7.1 outbound_mananger.lua
**Location:** `/usr/share/freeswitch/scripts/outbound_mananger.lua`

**Purpose:** Handles all outbound calls end to end.

**Flow:**
1. Read `X-USER-ID` and `X-VIRTUAL-NUMBER-ID` from SIP headers
2. POST to `/api/calls/authorize` — check balance, lock funds
3. If `status=false` → POST `/api/calls/complete` with `billsec=0` then hangup
4. Register `on_hangup_hook` before bridge
5. Set caller ID, codecs, max duration
6. Bridge call via `sofia/gateway/cloudnumbering/{destination}`
7. On hangup hook fires → calculate `billsec` from `answer_epoch`
8. POST `/api/calls/complete` with `status` and `billsec`

**Key variables read from session:**
| Variable | Purpose |
|----------|---------|
| `sip_h_X-USER-ID` | User ID from app SIP header |
| `sip_h_X-VIRTUAL-NUMBER-ID` | Virtual number ID from app SIP header |
| `sip_call_id` | Unique call identifier |
| `destination_number` | Number being dialled |
| `answer_epoch` | Unix timestamp when call was answered (0 if not answered) |
| `hangup_cause` | FreeSWITCH hangup cause code |

---

### 7.2 inbound_mananger.lua
**Location:** `/usr/share/freeswitch/scripts/inbound_mananger.lua`

**Purpose:** Handles all inbound calls from Cloudnumbering.

**Flow:**
1. Read destination number from `sip_to_display` (fixed — was incorrectly reading `destination_number` which returned `"sip"`)
2. Strip `sip:` prefix and `+` prefix from number
3. GET `/api/freeswitch/inbound?phone_number={number}` → get `sip_username` and `domain`
4. Register `on_hangup_hook`
5. Look up SIP contact via `sofia_contact` API
6. If user not registered → wait up to 70 seconds (push notification sent by Laravel)
7. Bridge call to registered WebRTC user
8. On hangup → POST `/api/calls/complete`

**Key fix applied:**
```lua
-- BEFORE (broken - returned "sip" as destination)
local destination_number = session:getVariable("destination_number")

-- AFTER (correct - reads actual UK number from SIP display header)
local destination_number = session:getVariable("sip_to_display")
                        or session:getVariable("sip_P-Asserted-Identity")
                        or session:getVariable("destination_number")
destination_number = destination_number:gsub("^sip:", "")
destination_number = destination_number:gsub("^%+", "")
```

---

## 8. API Reference

### 8.1 POST /api/calls/authorize
Called before every outbound call to check balance and lock funds.

**Request:**
```json
{
  "user_id": 34,
  "virtual_number_id": 7,
  "call_uuid": "8z5441ag9f86jzlj2g39",
  "destination_number": "8801786794530"
}
```

**Success Response:**
```json
{
  "status": true,
  "max_call_sec": 253951,
  "caller_number": "+447456375616"
}
```

**Failure Response:**
```json
{
  "status": false,
  "reason": "Insufficient balance"
}
```

> On `status=false`, FreeSWITCH immediately calls `/complete` with `billsec=0` and hangs up.

---

### 8.2 POST /api/calls/complete
Called at the end of every call regardless of outcome. Releases balance lock.

**Request:**
```json
{
  "user_id": 34,
  "call_uuid": "8z5441ag9f86jzlj2g39",
  "destination_number": "+8801786794530",
  "direction": "outbound",
  "billsec": 60,
  "status": "completed"
}
```

**Status values:**

| Status | Meaning |
|--------|---------|
| `completed` | Call answered and ended normally |
| `no_answer` | Rang but nobody picked up |
| `cancelled` | Caller hung up before answer |
| `busy` | Destination was busy |
| `failed` | Any other failure (bad number, gateway error, etc.) |

**Response:**
```json
{ "status": true }
```

---

### 8.3 GET /api/freeswitch/inbound
Called for every inbound call to find which user owns the dialled UK number.

**Request:**
```
GET /api/freeswitch/inbound?phone_number=447478025876
```

**Response (SIP registered — route directly):**
```json
{
  "status": true,
  "sip_username": "smjasim24",
  "sip_domain": "207.148.67.228",
  "user_id": 34,
  "route_type": "sip"
}
```

**Response (SIP not registered — send push notification):**
```json
{
  "status": true,
  "sip_username": "smjasim24",
  "sip_domain": "207.148.67.228",
  "user_id": 34,
  "route_type": "push",
  "message": "Call push notification sent to user device"
}
```

> When `route_type=push`, FreeSWITCH waits up to 70 seconds for the user to register after receiving the push notification, then bridges the call.

---

## 9. Call Flows

### 9.1 Outbound Call Flow

```
User App                FreeSWITCH              Laravel Backend         Cloudnumbering
   │                        │                          │                      │
   │──── INVITE (WSS) ─────▶│                          │                      │
   │                        │                          │                      │
   │                        │──── POST /authorize ────▶│                      │
   │                        │◀─── {status:true} ───────│                      │
   │                        │                          │                      │
   │                        │ [set caller ID, codecs]  │                      │
   │                        │ [register hangup hook]   │                      │
   │                        │                          │                      │
   │                        │──── INVITE ─────────────────────────────────── ▶│
   │                        │◀─── 100 Trying ─────────────────────────────── │
   │                        │◀─── 180 Ringing ────────────────────────────── │
   │◀── 180 Ringing ────────│                          │                      │
   │                        │◀─── 200 OK (answered) ─────────────────────── │
   │◀── 200 OK ─────────────│                          │                      │
   │──── ACK ───────────────│─────────────────────────────────────────────── ▶│
   │                        │                          │                      │
   │         [call in progress - audio flowing]        │                      │
   │                        │                          │                      │
   │──── BYE ───────────────│                          │                      │
   │                        │──── BYE ────────────────────────────────────── ▶│
   │                        │                          │                      │
   │                        │ [hangup hook fires]      │                      │
   │                        │──── POST /complete ─────▶│                      │
   │                        │◀─── {status:true} ───────│                      │
```

### 9.2 Inbound Call Flow

```
PSTN Caller         Cloudnumbering        FreeSWITCH            Laravel           User App
    │                     │                   │                    │                  │
    │──── call ──────────▶│                   │                    │                  │
    │                     │──── INVITE ──────▶│                    │                  │
    │                     │                   │                    │                  │
    │                     │                   │──GET /inbound ────▶│                  │
    │                     │                   │◀─{sip_username} ───│                  │
    │                     │                   │                    │                  │
    │                     │                   │ [sofia_contact      │                  │
    │                     │                   │  lookup]           │                  │
    │                     │                   │                    │                  │
    │                     │                   │──── INVITE ──────────────────────── ▶│
    │                     │                   │◀─── 180 Ringing ─────────────────── │
    │◀── ringing ─────────│◀── 180 ───────────│                    │                  │
    │                     │                   │◀─── 200 OK ──────────────────────── │
    │◀── answered ────────│◀── 200 ───────────│                    │                  │
    │                     │                   │                    │                  │
    │      [call in progress - audio flowing] │                    │                  │
    │                     │                   │                    │                  │
    │──── hangup ─────────│──── BYE ─────────▶│                    │                  │
    │                     │                   │ [hangup hook]      │                  │
    │                     │                   │──POST /complete ──▶│                  │
    │                     │                   │◀─{status:true} ────│                  │
```

### 9.3 Failed Call Flow (No Answer / Auth Denied)

```
FreeSWITCH                    Laravel
    │                             │
    │──── POST /authorize ───────▶│
    │◀─── {status:false} ─────────│
    │                             │
    │──── POST /complete ─────────▶│  ← billsec=0, status=failed
    │◀─── {status:true} ───────────│
    │                             │
    │ [hangup immediately]        │
```

---

## 10. Laravel Backend

### 10.1 Key Controller
**File:** `/home/zedsms/control.zedsms.com/app/Http/Controllers/FreeSwitch/DirectoryController.php`

**Methods:**
| Method | Route | Purpose |
|--------|-------|---------|
| `__invoke` | `mod_xml_curl` | Returns SIP user XML for authentication |
| `checksInboundCall` | `GET /api/freeswitch/inbound` | Routes inbound calls to correct SIP user |

### 10.2 Bug Fixed in Session
**Problem:** Missing `use Illuminate\Support\Facades\Log;` import caused 500 error on all inbound calls.

**Fix applied:**
```bash
sed -i 's/use Illuminate\\Http\\Request;/use Illuminate\\Http\\Request;\nuse Illuminate\\Support\\Facades\\Log;/' \
  /home/zedsms/control.zedsms.com/app/Http/Controllers/FreeSwitch/DirectoryController.php
```

### 10.3 mod_xml_curl Authentication Flow
1. WebRTC client sends SIP REGISTER with username/password
2. FreeSWITCH calls Laravel via `mod_xml_curl` with `section=directory`
3. Laravel looks up `SipCredential` table for matching username/domain
4. Returns XML with password for FreeSWITCH to verify
5. FreeSWITCH authenticates the client

---

## 11. After Restart Procedure

`mod_xml_curl` now loads automatically via `modules.conf.xml`. After any server restart FreeSWITCH should recover on its own.

**If SIP authentication is still not working after restart:**
```bash
fs_cli -x "reloadxml"
fs_cli -x "reloadacl"
```

**Full reload sequence (only if needed):**
```bash
fs_cli -x "reloadxml"
fs_cli -x "reloadacl"
fs_cli -x "reload mod_lua"
fs_cli -x "reload mod_curl"
fs_cli -x "reload mod_xml_curl"
fs_cli -x "sofia profile internal rescan"
fs_cli -x "sofia profile external rescan"
fs_cli -x "sofia profile cloudnumbering rescan"
```

**Why this was needed:** `mod_xml_curl` was commented out in `modules.conf.xml`. Without it FreeSWITCH cannot call Laravel for SIP directory lookups, so all SIP auth fails. Fixed by uncommenting:
```xml
<!-- BEFORE -->
<!-- <load module="mod_xml_curl"/> -->

<!-- AFTER -->
<load module="mod_xml_curl"/>
```

---

## 12. Monitoring Commands

### Watch all call activity in real time
```bash
tail -f /var/log/freeswitch/freeswitch.log | grep -E "\[OUTBOUND\]|\[INBOUND\]|calls/complete|calls/authorize|HANGUP|status"
```

### Watch only API calls
```bash
tail -f /var/log/freeswitch/freeswitch.log | grep -E "POST|GET|Response|authorize|complete"
```

### Check gateway status
```bash
fs_cli -x "sofia status gateway cloudnumbering"
```

### Check all SIP profiles
```bash
fs_cli -x "sofia status"
```

### Check active calls
```bash
fs_cli -x "show calls"
```

### Check registered users
```bash
fs_cli -x "show registrations"
```

### Reload Lua scripts after changes
```bash
fs_cli -x "reload mod_lua"
```

### Test inbound API manually
```bash
curl -s "https://control.zedsms.com/api/freeswitch/inbound?phone_number=447478025876"
```

### Check FreeSWITCH logs for errors
```bash
tail -100 /var/log/freeswitch/freeswitch.log | grep -E "ERROR|WARN|CRIT"
```

### Check Laravel logs for errors
```bash
tail -100 /home/zedsms/control.zedsms.com/storage/logs/laravel.log
```

---

## 13. Backup Procedure

### Manual Backup
Run this on the FreeSWITCH server:
```bash
BACKUP_DIR="/root/freeswitch-backup-$(date +%Y%m%d)"
mkdir -p $BACKUP_DIR

cp -r /etc/freeswitch $BACKUP_DIR/etc-freeswitch
cp -r /usr/share/freeswitch/scripts $BACKUP_DIR/scripts
cp /home/zedsms/control.zedsms.com/app/Http/Controllers/FreeSwitch/DirectoryController.php \
   $BACKUP_DIR/DirectoryController.php

tar -czf /root/freeswitch-backup-$(date +%Y%m%d).tar.gz $BACKUP_DIR/
echo "Backup saved: /root/freeswitch-backup-$(date +%Y%m%d).tar.gz"
```

### Existing Backups (created during session)
| File | Description |
|------|-------------|
| `/usr/share/freeswitch/scripts/outbound_mananger.lua.bak` | Original outbound script |
| `/usr/share/freeswitch/scripts/inbound_mananger.lua.bak` | Original inbound script |
| `/usr/share/freeswitch/scripts/inbound_mananger.lua.bak2` | Inbound script after first fix |

### Automated Daily Backup (recommended)
Add to crontab (`crontab -e`):
```bash
0 2 * * * tar -czf /root/freeswitch-backup-$(date +\%Y\%m\%d).tar.gz /etc/freeswitch /usr/share/freeswitch/scripts 2>/dev/null
```

---

## 14. Common Issues & Fixes

### Issue 1: SIP auth fails after restart
**Symptom:** Users cannot register, `mod_xml_curl` not found in logs  
**Cause:** `mod_xml_curl` not loaded  
**Fix:**
```bash
fs_cli -x "reloadxml"
fs_cli -x "reloadacl"
```
**Permanent fix:** Uncomment `mod_xml_curl` in `/etc/freeswitch/autoload_configs/modules.conf.xml` ✅ (already done)

---

### Issue 2: Inbound calls return destination as "sip"
**Symptom:** Inbound API called with `phone_number=sip`, Laravel returns 500  
**Cause:** `destination_number` variable in Lua was reading the SIP request URI user (`sip`) instead of the actual phone number  
**Fix:** Use `sip_to_display` variable instead ✅ (already done)

---

### Issue 3: complete API not called on failed calls
**Symptom:** Balance stays locked after no-answer or failed calls  
**Cause:** Complete API was only called inside `if answered` block  
**Fix:** Register `on_hangup_hook` before bridge — fires for ALL outcomes ✅ (already done)

---

### Issue 4: ACL rejecting inbound calls after restart
**Symptom:** `IP X.X.X.X Rejected by acl "cloudnumbering"` in logs  
**Cause:** ACL not reloaded after restart  
**Fix:**
```bash
fs_cli -x "reloadacl"
```

---

### Issue 5: Calls fail with UNALLOCATED_NUMBER
**Symptom:** All outbound calls fail immediately  
**Cause:** Cloudnumbering gateway returning 404 — number not supported or account issue  
**Fix:** Check Cloudnumbering account — ensure international routing is enabled for the destination country

---

### Issue 6: Dialplan not matching destination number
**Symptom:** Long destination numbers not matching outbound extension  
**Cause:** Regex `{7,14}` was too short for numbers like `75007421312304286`  
**Fix:** Updated to `{7,20}` in `default.xml` ✅ (already done)

---

### Issue 7: Laravel 500 error on inbound API
**Symptom:** `Class "App\Http\Controllers\FreeSwitch\Log" not found`  
**Cause:** Missing `use Illuminate\Support\Facades\Log;` import  
**Fix:** Added import to `DirectoryController.php` ✅ (already done)

---

## 15. Known Limitations

| # | Issue | Impact | Priority |
|---|-------|--------|---------|
| 1 | `billsec=0` for answered calls | Call duration not recorded correctly | High |
| 2 | `cause=UNKNOWN` on hangups | Hangup reason not precise | Medium |
| 3 | No API retry if complete fails | Balance could stay locked | High |
| 4 | Default password `1234` in vars.xml | Security risk | High |
| 5 | No automated daily backup | Data loss risk | Medium |
| 6 | No health monitoring / alerting | Silent failures possible | Medium |
| 7 | Push notification wait is 70s max | Long wait if app is slow to start | Low |

---

## 16. Changelog

### April 2026 — Live Session Fixes

| # | Change | File | Impact |
|---|--------|------|--------|
| 1 | Fixed complete API not called on no-answer/failed calls | `outbound_mananger.lua` | Balance correctly released |
| 2 | Fixed complete API not called on inbound failures | `inbound_mananger.lua` | Balance correctly released |
| 3 | Fixed `destination_number` returning `"sip"` for inbound | `inbound_mananger.lua` | Inbound routing now works |
| 4 | Fixed missing `Log` import causing 500 on inbound API | `DirectoryController.php` | Inbound API now returns JSON |
| 5 | Uncommented `mod_xml_curl` in autoload | `modules.conf.xml` | SIP auth works after restart |
| 6 | Updated dialplan regex from `{7,14}` to `{7,20}` | `default.xml` | Long numbers now route correctly |
| 7 | Added `on_hangup_hook` before bridge in both scripts | Both Lua scripts | Complete API fires for all outcomes |

---

*Document generated from live audit session — April 2026*  
*FreeSWITCH Server: 207.148.67.228 · Backend: control.zedsms.com*
