"""
Porkbun API domain report generator.
Fetches domain information and generates a CSV report.

Copyright (c) 2025 Alisson Sol. All rights reserved.
"""

import requests
import json
import csv
import os
import sys

def get_porkbun_data(endpoint, api_key, secret_key, domain=None):
    url = f"https://api.porkbun.com/api/json/v3/{endpoint}"
    if domain:
        url += f"/{domain}"
    
    payload = {
        "apikey": api_key,
        "secretapikey": secret_key
    }
    
    try:
        response = requests.post(url, json=payload)
        response.raise_for_status()
        return response.json()
    except Exception as e:
        print(f"Error calling {endpoint}: {e}")
        return None

def main():
    # Check if output file exists or is locked
    output_file = "porkbun_domain_report.csv"

    if os.path.exists(output_file):
        # Check if file is locked by trying to open it for writing
        try:
            with open(output_file, 'a'):
                pass
            print(f"ERROR: Output file '{output_file}' already exists.")
            print("Please remove or rename the existing file before running this script.")
            sys.exit(1)
        except (IOError, PermissionError):
            print(f"ERROR: Output file '{output_file}' is locked or inaccessible.")
            print("The file may be open in another program. Please close it and try again.")
            sys.exit(1)

    # 1. Ask for account info file
    file_path = input("Enter the path to your credentials file (e.g., keys.json): ").strip()
    
    if not os.path.exists(file_path):
        print("File not found!")
        return

    with open(file_path, 'r') as f:
        creds = json.load(f)
    
    api_key = creds.get('apikey')
    secret_key = creds.get('secretapikey')

    print("Fetching account data...")

    # 2. Get Global Renewal Pricing
    # Pricing is non-authenticated but we use the same base helper
    pricing_data = requests.get("https://api.porkbun.com/api/json/v3/pricing/get").json()
    prices = pricing_data.get('pricing', {})

    # 3. Get All Domains
    domains_resp = get_porkbun_data("domain/listAll", api_key, secret_key)
    if not domains_resp or domains_resp.get('status') != 'SUCCESS':
        print("Failed to retrieve domain list.")
        return

    domain_list = domains_resp.get('domains', [])
    report_data = []

    print(f"Processing {len(domain_list)} domains...")

    for d in domain_list:
        name = d['domain']
        tld = d['tld']
        expiry = d['expireDate']
        
        # Get Forwarding Site
        forward_url = "None"
        fwd_resp = get_porkbun_data("domain/getUrlForwarding", api_key, secret_key, name)
        if fwd_resp and fwd_resp.get('forwards'):
            # Grab the first forwarding rule
            forward_url = fwd_resp['forwards'][0].get('location', "None")

        # Get Email Count
        email_count = 0
        email_resp = get_porkbun_data("email/retrieve", api_key, secret_key, name)
        if email_resp and email_resp.get('emails'):
            email_count = len(email_resp['emails'])

        # Get Renewal Cost (Lookup by TLD)
        renewal_cost = prices.get(tld, {}).get('renewal', "Unknown")

        report_data.append({
            "domain name": name,
            "expiration date": expiry,
            "forward site": forward_url,
            "emails count": email_count,
            "renewal cost": renewal_cost
        })
        print(f" - Scanned {name}")

    # 4. Save to CSV
    keys = report_data[0].keys() if report_data else []
    
    with open(output_file, 'w', newline='') as f:
        dict_writer = csv.DictWriter(f, fieldnames=keys)
        dict_writer.writeheader()
        dict_writer.writerows(report_data)

    print(f"\nReport generated successfully: {output_file}")

if __name__ == "__main__":
    main()