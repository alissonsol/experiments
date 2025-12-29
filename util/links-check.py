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
import argparse
import time
from pathlib import Path
from urllib.parse import urlparse, urljoin
from concurrent.futures import ThreadPoolExecutor, as_completed
from threading import Lock

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
        Tuple of (is_valid, status_code, reason, details)
        - is_valid: True if URL returns 2xx status code, False otherwise
        - status_code: HTTP status code or None if request failed
        - reason: Brief description of the error or status
        - details: Detailed explanation of the error, especially for 403 and other access issues
    """
    # Skip certain URL schemes that can't be checked via HTTP
    parsed = urlparse(url)
    if parsed.scheme in ('mailto', 'tel', 'javascript'):
        return (True, None, 'Skipped - not HTTP', 'Not an HTTP(S) link')

    # Basic headers for first attempt (faster)
    basic_headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.9',
        'Accept-Encoding': 'gzip, deflate, br',
    }

    # Enhanced headers for retry (more browser-like, includes cookies)
    def get_enhanced_headers(url):
        parsed = urlparse(url)
        return {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36',
            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7',
            'Accept-Language': 'en-US,en;q=0.9,es;q=0.8',
            'Accept-Encoding': 'gzip, deflate, br, zstd',
            'DNT': '1',
            'Connection': 'keep-alive',
            'Upgrade-Insecure-Requests': '1',
            'Sec-Fetch-Dest': 'document',
            'Sec-Fetch-Mode': 'navigate',
            'Sec-Fetch-Site': 'none',
            'Sec-Fetch-User': '?1',
            'Sec-CH-UA': '"Not A(Brand";v="99", "Google Chrome";v="121", "Chromium";v="121"',
            'Sec-CH-UA-Mobile': '?0',
            'Sec-CH-UA-Platform': '"Windows"',
            'Cache-Control': 'max-age=0',
            'Referer': f'{parsed.scheme}://{parsed.netloc}/',
        }

    try:
        # Try HEAD request first (faster, doesn't download content)
        response = requests.head(url, headers=basic_headers, timeout=timeout, allow_redirects=True)

        # Some servers don't support HEAD or return 403 for HEAD but not GET
        # Try GET if HEAD fails with certain status codes
        if response.status_code in (403, 405, 501, 503):
            response = requests.get(url, headers=basic_headers, timeout=timeout, allow_redirects=True, stream=True)
            # Close the stream to avoid downloading the entire content
            response.close()

        # If we got 403, try again with enhanced browser simulation
        if response.status_code == 403:
            time.sleep(0.5)  # Small delay to appear more human

            # Create a session to handle cookies
            session = requests.Session()
            enhanced_headers = get_enhanced_headers(url)

            try:
                # Try with enhanced headers and session (handles cookies automatically)
                retry_response = session.get(
                    url,
                    headers=enhanced_headers,
                    timeout=timeout,
                    allow_redirects=True,
                    stream=True
                )
                retry_response.close()

                if 200 <= retry_response.status_code < 400:
                    return (True, retry_response.status_code, 'OK (Enhanced retry)', 'Accessible with enhanced browser simulation')
                else:
                    response = retry_response  # Use the retry response for error reporting
            except:
                pass  # If retry fails, use original 403 response
            finally:
                session.close()

        # Check if status code is in the 2xx success range
        if 200 <= response.status_code < 300:
            return (True, response.status_code, 'OK', '')
        # Treat 3xx as success if we're allowing redirects (which we are)
        elif 300 <= response.status_code < 400:
            return (True, response.status_code, 'OK (Redirect)', '')
        else:
            # Provide detailed explanations for common HTTP error codes
            details = get_http_error_details(response.status_code, url, response)
            return (False, response.status_code, f'HTTP {response.status_code}', details)

    except requests.exceptions.SSLError as e:
        # SSL errors might indicate the site is still accessible but has cert issues
        # Try one more time without SSL verification as a fallback
        try:
            response = requests.get(url, headers=basic_headers, timeout=timeout, allow_redirects=True, stream=True, verify=False)
            response.close()
            if 200 <= response.status_code < 400:
                return (True, response.status_code, 'OK (SSL Warning)', 'SSL certificate verification failed but site is accessible')
            else:
                details = get_http_error_details(response.status_code, url, response)
                return (False, response.status_code, f'HTTP {response.status_code} (SSL Warning)', f'SSL certificate issue. {details}')
        except:
            return (False, None, f'SSL error: {str(e)[:50]}', 'SSL/TLS handshake failed. Certificate may be expired, self-signed, or domain mismatch.')
    except requests.exceptions.Timeout:
        return (False, None, 'Timeout', f'Request exceeded {timeout}s timeout. Server may be slow or unresponsive.')
    except requests.exceptions.ConnectionError as e:
        error_str = str(e).lower()
        if 'name or service not known' in error_str or 'nodename nor servname provided' in error_str:
            return (False, None, 'Connection error', 'DNS resolution failed. Domain may not exist or DNS server is unreachable.')
        elif 'connection refused' in error_str:
            return (False, None, 'Connection error', 'Connection refused. Server is not accepting connections on this port.')
        elif 'no route to host' in error_str:
            return (False, None, 'Connection error', 'No route to host. Network is unreachable or firewall is blocking the connection.')
        else:
            return (False, None, 'Connection error', f'Failed to establish connection. {str(e)[:100]}')
    except requests.exceptions.TooManyRedirects:
        return (False, None, 'Too many redirects', 'Exceeded maximum number of redirects. May indicate a redirect loop.')
    except requests.exceptions.RequestException as e:
        return (False, None, f'Request failed: {str(e)[:50]}', str(e)[:200])
    except Exception as e:
        return (False, None, f'Unexpected error: {str(e)[:50]}', str(e)[:200])


def get_http_error_details(status_code, url, response=None):
    """
    Get detailed explanation for HTTP error codes.

    Args:
        status_code: HTTP status code
        url: The URL being checked
        response: requests.Response object (optional)

    Returns:
        Detailed explanation string
    """
    parsed = urlparse(url)
    domain = parsed.netloc

    # Check response headers and content for additional context
    server_header = ''
    cloudflare_detected = False

    if response:
        server_header = response.headers.get('Server', '').lower()
        cloudflare_detected = 'cloudflare' in server_header or 'cf-ray' in response.headers

    if status_code == 403:
        details = 'Access forbidden. '
        if cloudflare_detected:
            details += 'Cloudflare protection detected - may require browser verification (captcha/challenge) or cookie acceptance. '
        details += 'Possible causes: (1) Bot detection/WAF blocking automated requests, (2) Geographic restrictions, '
        details += '(3) Requires authentication/session cookies, (4) IP-based blocking, (5) Cookie consent required. '
        details += 'Page may be accessible in a regular browser.'
        return details
    elif status_code == 401:
        return 'Authentication required. Page requires valid login credentials or API key.'
    elif status_code == 404:
        return 'Page not found. The URL does not exist on the server or has been moved/deleted.'
    elif status_code == 429:
        return 'Too many requests. Rate limiting is in effect - server is throttling requests from this client.'
    elif status_code == 500:
        return 'Internal server error. Server encountered an unexpected condition that prevented it from fulfilling the request.'
    elif status_code == 502:
        return 'Bad gateway. Server received invalid response from upstream server (gateway/proxy issue).'
    elif status_code == 503:
        return 'Service unavailable. Server is temporarily unable to handle the request (maintenance, overload).'
    elif status_code == 504:
        return 'Gateway timeout. Upstream server failed to respond in time.'
    elif status_code == 410:
        return 'Gone. Resource permanently deleted and will not be available again.'
    elif status_code == 451:
        return 'Unavailable for legal reasons. Access blocked due to legal demands (censorship, copyright, etc).'
    elif 400 <= status_code < 500:
        return f'Client error {status_code}. Issue with the request (malformed, unauthorized, or forbidden).'
    elif 500 <= status_code < 600:
        return f'Server error {status_code}. Server failed to fulfill a valid request.'
    else:
        return f'Unexpected HTTP status code {status_code}.'


def check_links(json_file, repo_root='.', csv_file=None, max_workers=32, timeout=30):
    """
    Check all links in the JSON file.

    Args:
        json_file: Path to links-list.json
        repo_root: Root directory of the repository
        csv_file: Path to output CSV file (optional, for incremental writing)
        max_workers: Maximum number of parallel workers for checking external links
        timeout: Timeout in seconds for external link checks

    Returns:
        Number of dead links found
    """
    dead_links_count = 0
    csv_lock = Lock()  # Thread-safe CSV writing

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
            fieldnames = ['source_file', 'link', 'reason', 'resolved_path', 'reason_details']
            csv_writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
            csv_writer.writeheader()
        except Exception as e:
            print(f"Warning: Could not open CSV file for writing: {e}")
            csv_writer = None

    def write_dead_link(dead_link):
        """Thread-safe function to write a dead link to CSV."""
        nonlocal dead_links_count
        with csv_lock:
            dead_links_count += 1
            if csv_writer:
                csv_writer.writerow(dead_link)
                csvfile.flush()

    def check_external_link_task(source_path, link):
        """Task wrapper for checking an external link."""
        is_valid, status_code, reason, details = check_external_link(link, timeout=timeout)
        if not is_valid:
            status_info = f" ({status_code})" if status_code else ""
            return {
                'source_file': source_path,
                'link': link,
                'reason': f'{reason}{status_info}',
                'resolved_path': link,
                'reason_details': details
            }
        return None

    # Collect all external links to check in parallel
    external_links_to_check = []

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

                # Add to parallel check queue
                external_links_to_check.append((source_path, link))
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
                    'resolved_path': os.path.relpath(target_file_abs, repo_root).replace('\\', '/'),
                    'reason_details': 'The referenced local file does not exist at the resolved path.'
                }
                write_dead_link(dead_link)
                continue

            # Check if it's a file (not a directory)
            if not os.path.isfile(target_file_abs):
                dead_link = {
                    'source_file': source_path,
                    'link': link,
                    'reason': 'Not a file (directory)',
                    'resolved_path': os.path.relpath(target_file_abs, repo_root).replace('\\', '/'),
                    'reason_details': 'The link points to a directory instead of a file.'
                }
                write_dead_link(dead_link)
                continue

            # Check file type
            expected_type = guess_expected_type(link)
            if not check_file_type(target_file_abs, expected_type):
                dead_link = {
                    'source_file': source_path,
                    'link': link,
                    'reason': 'Invalid file type',
                    'resolved_path': os.path.relpath(target_file_abs, repo_root).replace('\\', '/'),
                    'reason_details': f'File exists but has unexpected type. Expected: {expected_type}'
                }
                write_dead_link(dead_link)
                continue

    # Check external links in parallel
    if external_links_to_check:
        print(f"\nChecking {len(external_links_to_check)} external links in parallel (max {max_workers} workers)...")
        checked_count = 0

        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            # Submit all tasks
            future_to_link = {
                executor.submit(check_external_link_task, source_path, link): (source_path, link)
                for source_path, link in external_links_to_check
            }

            # Process results as they complete
            for future in as_completed(future_to_link):
                checked_count += 1
                source_path, link = future_to_link[future]

                try:
                    result = future.result()
                    if result:
                        write_dead_link(result)
                        print(f"[{checked_count}/{len(external_links_to_check)}] DEAD: {link[:80]}")
                    else:
                        print(f"[{checked_count}/{len(external_links_to_check)}] OK: {link[:80]}")
                except Exception as e:
                    # Handle unexpected errors during checking
                    dead_link = {
                        'source_file': source_path,
                        'link': link,
                        'reason': f'Check failed: {str(e)[:50]}',
                        'resolved_path': link,
                        'reason_details': f'Unexpected error during link check: {str(e)[:200]}'
                    }
                    write_dead_link(dead_link)
                    print(f"[{checked_count}/{len(external_links_to_check)}] ERROR: {link[:80]}")

    # Close CSV file if it was opened
    if csvfile:
        csvfile.close()

    print(f"\nProcessed {files_processed} files with {total_links} total links")
    print(f"Found {dead_links_count} dead or invalid links")

    return dead_links_count


def main():
    """Main function to run the script."""
    # Record start time
    start_time = time.time()

    # Parse command-line arguments
    parser = argparse.ArgumentParser(
        description='Check all links from links-list.json and identify dead or invalid links.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s                    # Use default settings (8 workers, 30s timeout)
  %(prog)s -w 32              # Use 32 parallel workers
  %(prog)s -t 15              # Use 15 second timeout
  %(prog)s -w 4 -t 20         # Use 4 workers with 20 second timeout
        """
    )
    parser.add_argument(
        '-w', '--workers',
        type=int,
        default=32,
        metavar='N',
        help='maximum number of parallel workers for checking external links (default: 8)'
    )
    parser.add_argument(
        '-t', '--timeout',
        type=int,
        default=30,
        metavar='SECONDS',
        help='timeout in seconds for external link checks (default: 30)'
    )

    args = parser.parse_args()

    # Validate arguments
    if args.workers < 1:
        print("Error: Number of workers must be at least 1")
        return
    if args.timeout < 1:
        print("Error: Timeout must be at least 1 second")
        return

    print(f"Checking links from links-list.json...")
    print(f"Configuration: {args.workers} parallel workers, {args.timeout}s timeout\n")

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
            print(f"Warning: Could not delete {os.path.basename(csv_file)} - file is locked!")
            print("The file may be open in another program. Please close it and try again.\n")
            return
        except Exception as e:
            print(f"Warning: Could not delete {os.path.basename(csv_file)}: {e}\n")
            return

    # Check all links (results written incrementally to CSV)
    dead_links_count = check_links(
        json_file,
        script_dir,
        csv_file,
        max_workers=args.workers,
        timeout=args.timeout
    )

    # Summary
    print(f"\nResults written to: {os.path.basename(csv_file)}")
    if dead_links_count:
        print(f"\nFound {dead_links_count} dead or invalid links")
        print("Check links-dead.csv for details")
    else:
        print("\nAll links are valid!")

    # Calculate and display execution time
    end_time = time.time()
    execution_time = end_time - start_time

    # Display execution summary
    print("\n" + "=" * 60)
    print("Execution Summary")
    print("=" * 60)
    print(f"Arguments used:")
    print(f"  Workers: {args.workers}")
    print(f"  Timeout: {args.timeout} seconds")
    print(f"Total execution time: {execution_time:.2f} seconds ({execution_time/60:.2f} minutes)")
    print("=" * 60)


if __name__ == "__main__":
    main()
