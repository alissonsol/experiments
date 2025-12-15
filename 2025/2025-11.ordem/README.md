# Ordem

Windows service ordering and startup mode management tool with a web-based interface.

Source: [gibhub.com/alissonsol](https://github.com/alissonsol)  
Copyright (c) 2025, Alisson Sol - All rights reserved.

## Features

- **Dual-Pane View**: Current system services (left) and target configuration (right)
- **Service Ordering**: Drag-and-drop to reorder target services
- **Startup Mode Management**: Configure startup modes (Automatic, Automatic Delayed, Manual, Disabled)
- **Target Persistence**: Saves target configuration to `%LOCALAPPDATA%\Ordem\ordem.target.xml`
- **Single Endpoint**: Backend serves both API and UI on `http://127.0.0.1:4000` (configured via `bind` in `services/retrieve/src/main.rs`)
- **Windows-Only**: Requires Windows OS for service management via WMI

## Quick Start

Build and run:

```powershell
.\scripts\build-all.ps1
.\scripts\run-all.ps1
```

Access the UI at `http://127.0.0.1:4000`

## Build Scripts

- `.\scripts\clean-all.ps1` - Remove all build artifacts
- `.\scripts\build-all.ps1` - Build UI and backend to `dist/`
- `.\scripts\run-all.ps1` - Build UI and run backend
- `.\scripts\dist-all.ps1` - Creates ZIP package for distribution

## API Endpoints

- `GET /api/services` - Current Windows services
- `GET /api/targets` - Saved target configuration
- `POST /api/targets` - Update target configuration
- `GET /` - UI (index.html)

## Configuration

- **Port**: `127.0.0.1:4000` (change the `bind` value in `services/retrieve/src/main.rs`)
- **Target Storage**: `%LOCALAPPDATA%\Ordem\ordem.target.xml`
- **API Base**: `http://127.0.0.1:4000` (change the `bind` value in `ui/src/main.ts`)

## Project Structure

## Architecture

**Backend** (Rust/Actix-web):

- Queries Windows services via PowerShell WMI
- REST API for service data and target management
- Serves static UI files
- Stores targets in XML format

**Frontend** (TypeScript):

- Split-pane interface with column alignment
- Drag-and-drop service reordering
- Inline startup mode editing
- Pane toggle and reset controls

## Prerequisites

- **Rust** (via [rustup](https://rustup.rs/))
- **Node.js** (includes npm)
- **Windows OS** (required for WMI service access)

## Troubleshooting

- **Services not loading**: Requires Windows with PowerShell
  - `winget install --id Microsoft.PowerShell --source winget`
- **Permission errors**: Run as Administrator if needed
- **vcruntime140.dll error**: Install Visual C++ Redistributable for Visual Studio 2015
  - `winget install --id Microsoft.VCRedist.2015+.x64 --exact --accept-package-agreements --accept-source-agreements`

## License

[The MIT License (MIT)](https://opensource.org/license/mit)

Copyright 2025 Alisson Sol

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the “Software”), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
