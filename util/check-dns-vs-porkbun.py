import requests
import dns.resolver
import json
import os
import sys
import time
import warnings

warnings.filterwarnings("ignore", category=DeprecationWarning)

# --- CONFIGURATION ---
DOMAIN = "belohorizonte.com"

# Load Porkbun credentials from porkbun.json
creds_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), "porkbun.json")
if not os.path.exists(creds_file):
    print(f"Credentials file not found: {creds_file}")
    sys.exit(1)

with open(creds_file, 'r') as f:
    creds = json.load(f)

PORKBUN_API_KEY = creds.get('apikey')
PORKBUN_SECRET_KEY = creds.get('secretapikey')

def get_porkbun_records():
    url = f"https://api.porkbun.com/api/json/v3/dns/retrieve/{DOMAIN}"
    payload = {"apikey": PORKBUN_API_KEY, "secretapikey": PORKBUN_SECRET_KEY}
    try:
        response = requests.post(url, json=payload)
        response.raise_for_status()
        return response.json().get('records', [])
    except Exception as e:
        print(f"❌ Porkbun API Error: {e}")
        return []

def query_public_dns(record_type, host):
    """Queries the current public DNS (Google 8.8.8.8) instead of SS directly."""
    resolver = dns.resolver.Resolver(configure=False)
    resolver.nameservers = ['8.8.8.8', '8.8.4.4']
    resolver.timeout = 5.0
    resolver.lifetime = 5.0
    
    target = DOMAIN if host == '@' else f"{host}.{DOMAIN}"
    try:
        answers = resolver.resolve(target, record_type)
        # Normalize: lowercase, strip quotes, and remove trailing dots
        return {str(rdata).strip('"').lower().rstrip('.') for rdata in answers}
    except (dns.resolver.NoAnswer, dns.resolver.NXDOMAIN):
        return set()
    except Exception as e:
        print(f"   ⚠️  Public DNS error for {host} {record_type}: {e}")
        return set()

def compare_dns():
    print(f"--- Public vs. Porkbun Audit: {DOMAIN} ---")
    porkbun_records = get_porkbun_records()
    
    # Define what we care about for a healthy transfer
    checks = [
        {'type': 'MX', 'host': '@'},
        {'type': 'TXT', 'host': '@'},
        {'type': 'TXT', 'host': 'google._domainkey'},
        {'type': 'CNAME', 'host': 'www'},
        {'type': 'A', 'host': '@'}
    ]
    
    for check in checks:
        r_type = check['type']
        sub = check['host']
        
        print(f"\n[ {r_type} ] for {sub}...")
        current_live_values = query_public_dns(r_type, sub)
        
        pb_values = set()
        target_host = DOMAIN if sub == '@' else f"{sub}.{DOMAIN}"
        
        for r in porkbun_records:
            if r['name'] == target_host and r['type'] == r_type:
                # Normalize Porkbun data to match public DNS format
                val = r['content'].strip('"').lower().rstrip('.')
                
                # Special handling for MX: Porkbun API often separates priority
                if r_type == 'MX' and ' ' not in val:
                    val = f"{r['prio']} {val}"
                
                pb_values.add(val)

        # Result Logic
        matches = current_live_values.intersection(pb_values)
        missing_in_pb = current_live_values - pb_values
        extra_in_pb = pb_values - current_live_values

        for m in sorted(matches):
            print(f"  ✅ MATCH: {m}")
        for m in sorted(missing_in_pb):
            print(f"  ❌ MISSING IN PORKBUN: {m}")
        for e in sorted(extra_in_pb):
            print(f"  ⚠️  STAGED IN PORKBUN ONLY: {e}")

if __name__ == "__main__":
    compare_dns()