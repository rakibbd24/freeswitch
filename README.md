
# FreeSWITCH Config Backup — ZedSMS

**Server:** 207.148.67.228  

**Last updated:** April 2026

## Structure

| Folder | Contents |

|--------|----------|

| configs/ | freeswitch.xml |

| dialplan/ | All dialplan XML files |

| sip_profiles/ | SIP profile configs |

| autoload/ | Module autoload config |

| scripts/ | Lua scripts (outbound/inbound handlers) |

## Sensitive files (NOT committed — kept local only)

- `configs/vars.xml` — contains default_password

- `sip_profiles/external/cloudnumbering.xml` — contains gateway credentials

## Key Scripts

- `scripts/outbound_mananger.lua` — handles all outbound calls

- `scripts/inbound_mananger.lua` — handles all inbound calls

## After any config change

```bash

cd /root/freeswitch-config-backup

cp -r /etc/freeswitch/dialplan ./dialplan/

cp -r /usr/share/freeswitch/scripts ./scripts/

git add .

git commit -m "Updated config - $(date +%Y-%m-%d)"

git push

```

