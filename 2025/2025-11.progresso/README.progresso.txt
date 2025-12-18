# Progresso

A Windows service for monitoring and tracking the progress of Windows services based on target configurations.

Source: [github.com/alissonsol](https://github.com/alissonsol)
Copyright (c) 2025, Alisson Sol - All rights reserved.

## Quick Start

1. Extract this ZIP file to a folder on your Windows computer
2. Ensure you have an `ordem.target.xml` file in `dist/backend/` or in `%LOCALAPPDATA%\Ordem\`
3. Open PowerShell in the extracted folder
4. Run: `.\run-progresso.ps1`

The service will process the services defined in `ordem.target.xml` and create a timestamped progress file.

## Requirements

- Windows operating system
- PowerShell (included with Windows)
- An `ordem.target.xml` configuration file (can be generated using the Ordem tool)

## What's Included

- `dist/backend/` - Backend service executable
- `run-progresso.ps1` - Launcher script

## How It Works

The Progresso service:
1. Reads service configurations from `ordem.target.xml`
2. Starts or stops services based on their target `end_mode` configuration
3. Monitors CPU usage, waiting for it to drop below a threshold before proceeding
4. Creates a timestamped progress file (e.g., `progresso.20251215.143022.xml`) tracking the execution

## Troubleshooting

If you get a PowerShell execution policy error, run:
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

If the `ordem.target.xml` file is missing, the service will look for it in:
1. `dist\backend\ordem.target.xml` (distribution folder)
2. `%LOCALAPPDATA%\Ordem\ordem.target.xml` (user's local application data)
