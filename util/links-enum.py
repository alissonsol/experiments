#!/usr/bin/env python3
"""
Script to enumerate all files in the repository and extract links from HTML files.
Outputs results to links-list.json

Copyright (c) 2025 Alisson Sol. All rights reserved.
"""

import os
import json
import re
from pathlib import Path


def extract_links_from_html(filepath):
    """
    Extract all href links from an HTML file.

    Args:
        filepath: Path to the HTML file

    Returns:
        List of links found in the file
    """
    links = []
    try:
        with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()
            # Find all href attributes in HTML tags
            # Matches href="..." and href='...'
            href_pattern = r'href=["\'](.*?)["\']'
            links = re.findall(href_pattern, content, re.IGNORECASE)

            # Also check for src attributes in images, scripts, etc.
            src_pattern = r'src=["\'](.*?)["\']'
            src_links = re.findall(src_pattern, content, re.IGNORECASE)
            links.extend(src_links)

            # Remove duplicates while preserving order
            seen = set()
            unique_links = []
            for link in links:
                if link not in seen:
                    seen.add(link)
                    unique_links.append(link)
            links = unique_links

    except Exception as e:
        print(f"Error reading {filepath}: {e}")

    return links


def scan_repository(root_path='.'):
    """
    Scan all files in the repository and extract links.
    Tracks unique links across all pages and only lists each link destination
    the first time it appears.

    Args:
        root_path: Root directory to start scanning from

    Returns:
        Dictionary with file information and links
    """
    result = {"files": []}
    global_seen_links = set()  # Track all unique link destinations across all files

    # Walk through all directories
    for root, dirs, files in os.walk(root_path):
        # Skip .git directory and other hidden directories
        dirs[:] = [d for d in dirs if not d.startswith('.')]

        for filename in files:
            # Skip hidden files and the script itself
            if filename.startswith('.') or filename == 'links-enum.py':
                continue

            filepath = os.path.join(root, filename)
            # Convert to relative path with forward slashes for consistency
            relative_path = os.path.relpath(filepath, root_path).replace('\\', '/')

            all_links = []
            new_links = []      # Links appearing for the first time
            repeated_links = []  # Links that were already seen in previous files

            # Check if file is HTML
            if filename.endswith(('.htm', '.html')):
                all_links = extract_links_from_html(filepath)

                # Separate links into new and repeated
                for link in all_links:
                    if link not in global_seen_links:
                        new_links.append(link)
                        global_seen_links.add(link)
                    else:
                        repeated_links.append(link)

            # Add file entry
            file_entry = {
                "path": relative_path,
                "links": new_links,
                "link_count": len(new_links),
                "repeated_links": repeated_links,
                "repeated_count": len(repeated_links),
                "total_links_in_file": len(all_links)
            }
            result["files"].append(file_entry)

    # Sort files by path for consistent output
    result["files"].sort(key=lambda x: x["path"])

    return result


def main():
    """Main function to run the script."""
    print("Scanning repository for files and links...")

    # Get the current working directory
    script_dir = os.getcwd()

    # Scan the repository
    data = scan_repository(script_dir)

    # Write to JSON file
    output_file = os.path.join(script_dir, 'links-list.json')
    with open(output_file, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)

    print(f"Found {len(data['files'])} files")

    # Calculate statistics
    unique_links = sum(file_entry['link_count'] for file_entry in data['files'])
    repeated_links = sum(file_entry.get('repeated_count', 0) for file_entry in data['files'])
    total_links = sum(file_entry.get('total_links_in_file', 0) for file_entry in data['files'])

    print(f"Extracted {total_links} total link occurrences")
    print(f"  - {unique_links} unique links (listed in output)")
    print(f"  - {repeated_links} repeated links (suppressed)")
    print(f"Results saved to: {output_file}")


if __name__ == "__main__":
    main()
