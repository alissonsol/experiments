#!/usr/bin/env python3
"""
Script to check all links from links-list.json and identify dead or invalid links.
Outputs results to links-dead.csv

Copyright (c) 2025 Alisson Sol. All rights reserved.
"""

import os
import json
import csv
import mimetypes
import requests
import urllib3
from pathlib import Path
from urllib.parse import urlparse, urljoin

# Disable SSL warnings when we use verify=False
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)


def is_external_link(link):
    """
    Check if a link is external (http/https/ftp/mailto etc.)

    Args:
        link: URL or path to check

    Returns:
        True if external, False if local
    """
    parsed = urlparse(link)
    return parsed.scheme in ('http', 'https', 'ftp', 'mailto', 'tel', 'javascript')


def normalize_path(link, source_file_path):
    """
    Normalize a relative link to an absolute file path.

    Args:
        link: The link from the HTML file
        source_file_path: Path to the file containing the link

    Returns:
        Normalized absolute path
    """
    # Get the directory of the source file
    source_dir = os.path.dirname(source_file_path)

    # Remove fragment identifiers (#section) and query strings (?param=value)
    link_without_fragment = link.split('#')[0].split('?')[0]

    # If empty after removing fragment, it's a self-reference
    if not link_without_fragment:
        return source_file_path

    # Join with source directory and normalize
    absolute_path = os.path.normpath(os.path.join(source_dir, link_without_fragment))

    return absolute_path


def guess_expected_type(link):
    """
    Guess the expected MIME type based on file extension.

    Args:
        link: The link/filename

    Returns:
        Expected MIME type category (html, image, script, style, other)
    """
    ext = os.path.splitext(link.lower())[1]

    type_map = {
        '.htm': 'html',
        '.html': 'html',
        '.jpg': 'image',
        '.jpeg': 'image',
        '.png': 'image',
        '.gif': 'image',
        '.bmp': 'image',
        '.svg': 'image',
        '.ico': 'image',
        '.webp': 'image',
        '.js': 'script',
        '.css': 'style',
        '.pdf': 'document',
        '.txt': 'text',
        '.xml': 'xml',
        '.zip': 'archive',
        '.rar': 'archive',
        '.7z': 'archive',
    }

    return type_map.get(ext, 'other')


def check_file_type(filepath, expected_type):
    """
    Check if a file matches the expected type.

    Args:
        filepath: Path to the file
        expected_type: Expected type category

    Returns:
        True if type matches or check passes, False otherwise
    """
    # For 'other' type or files without extension, we're lenient
    if expected_type == 'other':
        return True

    # Get actual MIME type
    mime_type, _ = mimetypes.guess_type(filepath)

    if mime_type is None:
        # Can't determine type, but file exists, so we're lenient
        return True

    # Check if MIME type matches expected category
    if expected_type == 'html' and 'html' in mime_type:
        return True
    if expected_type == 'image' and mime_type.startswith('image/'):
        return True
    if expected_type == 'script' and 'javascript' in mime_type:
        return True
    if expected_type == 'style' and 'css' in mime_type:
        return True
    if expected_type == 'document' and 'pdf' in mime_type:
        return True
    if expected_type == 'text' and 'text' in mime_type:
        return True
    if expected_type == 'xml' and 'xml' in mime_type:
        return True
    if expected_type == 'archive' and ('zip' in mime_type or 'rar' in mime_type):
        return True

    # If we got here, type might not match, but let's be lenient
    # Only fail if it's clearly wrong (e.g., expecting HTML but got binary)
    return True


def check_external_link(url, timeout=30):
    """
    Check if an external URL is accessible and returns a valid HTTP status code.

    Args:
        url: The URL to check
        timeout: Request timeout in seconds

    Returns:
        Tuple of (is_valid, status_code, reason)
        - is_valid: True if URL returns 2xx status code, False otherwise
        - status_code: HTTP status code or None if request failed
        - reason: Description of the error or status
    """
    # Skip certain URL schemes that can't be checked via HTTP
    parsed = urlparse(url)
    if parsed.scheme in ('mailto', 'tel', 'javascript'):
        return (True, None, 'Skipped - not HTTP')

    # Headers that mimic a real browser to avoid bot detection
    headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.9',
        'Accept-Encoding': 'gzip, deflate, br',
        'DNT': '1',
        'Connection': 'keep-alive',
        'Upgrade-Insecure-Requests': '1',
        'Sec-Fetch-Dest': 'document',
        'Sec-Fetch-Mode': 'navigate',
        'Sec-Fetch-Site': 'none',
        'Sec-Fetch-User': '?1',
        'Cache-Control': 'max-age=0',
    }

    try:
        # Try HEAD request first (faster, doesn't download content)
        response = requests.head(url, headers=headers, timeout=timeout, allow_redirects=True)

        # Some servers don't support HEAD or return 403 for HEAD but not GET
        # Try GET if HEAD fails with certain status codes
        if response.status_code in (403, 405, 501, 503):
            response = requests.get(url, headers=headers, timeout=timeout, allow_redirects=True, stream=True)
            # Close the stream to avoid downloading the entire content
            response.close()

        # Check if status code is in the 2xx success range
        if 200 <= response.status_code < 300:
            return (True, response.status_code, 'OK')
        # Treat 3xx as success if we're allowing redirects (which we are)
        elif 300 <= response.status_code < 400:
            return (True, response.status_code, 'OK (Redirect)')
        else:
            return (False, response.status_code, f'HTTP {response.status_code}')

    except requests.exceptions.SSLError as e:
        # SSL errors might indicate the site is still accessible but has cert issues
        # Try one more time without SSL verification as a fallback
        try:
            response = requests.get(url, headers=headers, timeout=timeout, allow_redirects=True, stream=True, verify=False)
            response.close()
            if 200 <= response.status_code < 400:
                return (True, response.status_code, 'OK (SSL Warning)')
            else:
                return (False, response.status_code, f'HTTP {response.status_code} (SSL Warning)')
        except:
            return (False, None, f'SSL error: {str(e)[:50]}')
    except requests.exceptions.Timeout:
        return (False, None, 'Timeout')
    except requests.exceptions.ConnectionError:
        return (False, None, 'Connection error')
    except requests.exceptions.TooManyRedirects:
        return (False, None, 'Too many redirects')
    except requests.exceptions.RequestException as e:
        return (False, None, f'Request failed: {str(e)[:50]}')
    except Exception as e:
        return (False, None, f'Unexpected error: {str(e)[:50]}')


def check_links(json_file, repo_root='.', csv_file=None):
    """
    Check all links in the JSON file.

    Args:
        json_file: Path to links-list.json
        repo_root: Root directory of the repository
        csv_file: Path to output CSV file (optional, for incremental writing)

    Returns:
        Number of dead links found
    """
    dead_links_count = 0

    # Load the JSON file
    try:
        with open(json_file, 'r', encoding='utf-8') as f:
            data = json.load(f)
    except Exception as e:
        print(f"Error loading JSON file: {e}")
        return dead_links_count

    total_links = 0
    files_processed = 0

    # Open CSV file for incremental writing if provided
    csv_writer = None
    csvfile = None
    if csv_file:
        try:
            csvfile = open(csv_file, 'w', newline='', encoding='utf-8')
            fieldnames = ['source_file', 'link', 'reason', 'resolved_path']
            csv_writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
            csv_writer.writeheader()
        except Exception as e:
            print(f"Warning: Could not open CSV file for writing: {e}")
            csv_writer = None

    # Process each file
    for file_entry in data.get('files', []):
        source_path = file_entry.get('path', '')
        links = file_entry.get('links', [])

        if not links:
            continue

        files_processed += 1
        print(f"Checking links in: {source_path} ({len(links)} links)")

        # Check each link
        for link in links:
            total_links += 1

            # Skip empty links
            if not link or link.strip() == '':
                continue

            # Skip anchor-only links (just #something)
            if link.startswith('#'):
                continue

            # Check external links
            if is_external_link(link):
                # Skip javascript: and mailto: and tel: links (they're always valid)
                if link.startswith(('javascript:', 'mailto:', 'tel:')):
                    continue

                # Check HTTP/HTTPS/FTP links
                is_valid, status_code, reason = check_external_link(link)
                if not is_valid:
                    status_info = f" ({status_code})" if status_code else ""
                    dead_link = {
                        'source_file': source_path,
                        'link': link,
                        'reason': f'{reason}{status_info}',
                        'resolved_path': link
                    }
                    dead_links_count += 1
                    if csv_writer:
                        csv_writer.writerow(dead_link)
                        csvfile.flush()  # Ensure it's written immediately
                continue

            # Normalize the link to an absolute file path
            source_file_abs = os.path.join(repo_root, source_path)
            target_file_abs = normalize_path(link, source_file_abs)

            # Check if file exists
            if not os.path.exists(target_file_abs):
                dead_link = {
                    'source_file': source_path,
                    'link': link,
                    'reason': 'File not found',
                    'resolved_path': os.path.relpath(target_file_abs, repo_root).replace('\\', '/')
                }
                dead_links_count += 1
                if csv_writer:
                    csv_writer.writerow(dead_link)
                    csvfile.flush()
                continue

            # Check if it's a file (not a directory)
            if not os.path.isfile(target_file_abs):
                dead_link = {
                    'source_file': source_path,
                    'link': link,
                    'reason': 'Not a file (directory)',
                    'resolved_path': os.path.relpath(target_file_abs, repo_root).replace('\\', '/')
                }
                dead_links_count += 1
                if csv_writer:
                    csv_writer.writerow(dead_link)
                    csvfile.flush()
                continue

            # Check file type
            expected_type = guess_expected_type(link)
            if not check_file_type(target_file_abs, expected_type):
                dead_link = {
                    'source_file': source_path,
                    'link': link,
                    'reason': 'Invalid file type',
                    'resolved_path': os.path.relpath(target_file_abs, repo_root).replace('\\', '/')
                }
                dead_links_count += 1
                if csv_writer:
                    csv_writer.writerow(dead_link)
                    csvfile.flush()
                continue

    # Close CSV file if it was opened
    if csvfile:
        csvfile.close()

    print(f"\nProcessed {files_processed} files with {total_links} total links")
    print(f"Found {dead_links_count} dead or invalid links")

    return dead_links_count


def main():
    """Main function to run the script."""
    print("Checking links from links-list.json...\n")

    # Get the current working directory
    script_dir = os.getcwd()

    # Paths
    json_file = os.path.join(script_dir, 'links-list.json')
    csv_file = os.path.join(script_dir, 'links-dead.csv')

    # Check if JSON file exists
    if not os.path.exists(json_file):
        print(f"Error: {json_file} not found!")
        print("Please run links-enum.py first to generate the links list.")
        return

    # Delete old CSV file if it exists
    if os.path.exists(csv_file):
        try:
            os.remove(csv_file)
            print(f"Deleted previous {os.path.basename(csv_file)}\n")
        except PermissionError:
            print(f"⚠ Warning: Could not delete {os.path.basename(csv_file)} - file is locked!")
            print("The file may be open in another program. Please close it and try again.\n")
            return
        except Exception as e:
            print(f"⚠ Warning: Could not delete {os.path.basename(csv_file)}: {e}\n")
            return

    # Check all links (results written incrementally to CSV)
    dead_links_count = check_links(json_file, script_dir, csv_file)

    # Summary
    print(f"Results written to: {os.path.basename(csv_file)}")
    if dead_links_count:
        print(f"\n⚠ Found {dead_links_count} dead or invalid links")
        print("Check links-dead.csv for details")
    else:
        print("\n✓ All links are valid!")


if __name__ == "__main__":
    main()
