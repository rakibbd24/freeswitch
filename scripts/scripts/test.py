#!/usr/bin/env python3
import requests
import sys

try:
    import greenswitch
    USE_GREENSWITCH = True
except ImportError:
    USE_GREENSWITCH = False
    try:
        from ESL import ESLconnection
    except ImportError:
        print("ERROR: Install ESL library")
        print("Run: pip3 install greenswitch")
        sys.exit(1)

def originate_call(phone_number):
    # Get user info from API
    url = f"https://control.zedsms.com/api/freeswitch/inbound?phone_number={phone_number}"
    print(f'Calling API: {url}')
    
    try:
        response = requests.get(url, timeout=10)
        data = response.json()
        print(f'API Response: {data}')
    except Exception as e:
        print(f'API Error: {e}')
        return
    
    username = data.get('sip_username')
    if not username:
        print('No username in response')
        return
    
    print(f'Username: {username}')
    
    # Connect to FreeSWITCH via ESL
    if USE_GREENSWITCH:
        # Using greenswitch
        import greenswitch as gs
        con = gs.InboundESL(host='localhost', port=8021, password='ClueCon')
    else:
        # Using python-ESL
        con = ESLconnection("localhost", "8021", "ClueCon")
        if not con.connected():
            print('ESL connection failed')
            return
    
    print('Connected to FreeSWITCH')
    
    # Find user contact
    domains = ["207.148.67.228", "sip.hgdjlive.com"]
    contact = None
    
    for domain in domains:
        user_domain = f"{username}@{domain}"
        
        if USE_GREENSWITCH:
            result = con.send(f'api sofia_contact {user_domain}')
            contact_str = result.data.decode('utf-8').strip() if hasattr(result.data, 'decode') else str(result.data).strip()
        else:
            e = con.api("sofia_contact", user_domain)
            contact_str = e.getBody().strip()
        
        print(f'Checking {user_domain}: {contact_str}')
        
        if contact_str and 'error' not in contact_str.lower() and not contact_str.startswith('-ERR'):
            contact = contact_str
            print(f'✓ Found contact: {contact}')
            break
    
    if contact:
        # Originate call
        action = data.get('action', 'echo')
        cmd = f"{contact} &{action}"
        
        print(f'Originating: {cmd}')
        
        if USE_GREENSWITCH:
            result = con.send(f'api originate {cmd}')
            print(f'Result: {result.data}')
        else:
            e = con.api("originate", cmd)
            print(f'Result: {e.getBody()}')
    else:
        print(f'✗ User {username} not registered')

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('Usage: python3 originate_call.py <phone_number>')
        print('Example: python3 originate_call.py +447915928733')
        sys.exit(1)
    
    originate_call(sys.argv[1])
