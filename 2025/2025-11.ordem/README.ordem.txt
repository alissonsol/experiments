# Ordem

Windows service ordering and startup mode management tool with a web-based interface.

Source: [github.com/alissonsol](https://github.com/alissonsol)
Copyright (c) 2025, Alisson Sol - All rights reserved.

## Quick Start

1. Extract this ZIP file to a folder on your Windows computer
2. Open PowerShell in the extracted folder
3. Run: `.\run-ordem.ps1`
4. Open your browser to: http://127.0.0.1:4000

## Requirements

- Windows operating system
- PowerShell (included with Windows)
- No additional runtime dependencies required

## What's Included

- `dist/backend/` - Backend server executable
- `dist/ui/` - Web UI files (HTML, CSS, JavaScript)
- `run-ordem.ps1` - Launcher script

## Usage

The application allows you to:
- View current Windows services and their startup modes
- Define target startup configurations
- Reorder services for startup sequence
- Set different end types for services

## Troubleshooting

If you get a PowerShell execution policy error, run:
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

## Support

For issues or questions, refer to the project documentation.
