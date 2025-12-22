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

### 1. Install Dependencies

```powershell
.\scripts\install-dependencies.ps1
```

This will automatically install:
- **Node.js** v23.5.0 (for building the TypeScript frontend)
- **Rust** v1.84.0 (for building the backend API)
- **Bazel** (optional build system)

**Note**: After installation, restart your terminal to refresh the PATH.

### 2. Build and Run

```powershell
.\scripts\build-all.ps1
```

Access the UI at `http://127.0.0.1:4000`

## Build Scripts

- `.\scripts\install-dependencies.ps1` - Install all required dependencies (Node.js, Rust, Bazel)
- `.\scripts\clean-all.ps1` - Remove all build artifacts
- `.\scripts\build-all.ps1` - Build UI and backend to `dist/`, then run backend
- `.\scripts\dist-all.ps1` - Creates ZIP package for distribution

### Antivirus Configuration (Important)

During the build process, Rust's Cargo build system generates temporary executables called `build-script-build.exe` for dependency compilation. These are **legitimate build artifacts** but may trigger false positives in some antivirus software.

To avoid build interruptions:

1. **Add an antivirus exclusion** for the build directory:
   ```
   [project-root]\services\retrieve\target\
   ```

2. **Windows Defender exclusion** (Run PowerShell as Administrator):
   ```powershell
   Add-MpPreference -ExclusionPath "C:\path\to\your\project\services\retrieve\target"
   ```

3. **Alternative**: Configure your antivirus to allow Cargo build processes

These build scripts are:
- Generated only during compilation
- Never distributed or executed at runtime
- Automatically cleaned with `.\scripts\clean-all.ps1`
- Excluded from version control via `.gitignore`

If you cannot add exclusions, you may experience slower builds as the antivirus scans each generated file.

## API Endpoints

- `GET /api/services` - Current Windows services
- `GET /api/targets` - Saved target configuration
- `POST /api/targets` - Update target configuration
- `POST /api/targets-pruned` - Save only services where End Mode differs from Startup Mode
- `GET /` - UI (index.html)

## Configuration

- **Port**: `127.0.0.1:4000` (change `BIND_ADDRESS` in both `services/retrieve/src/main.rs` and `ui/src/main.ts`)
- **Target Storage**: `%LOCALAPPDATA%\Ordem\ordem.target.xml`

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

## Key Features Explained

### Prune Output

Saves only services where End Mode differs from Startup Mode, reducing clutter in your configuration file.

**Usage:**
1. Modify End Mode values in the right pane
2. Click "Prune Output" in the toolbar
3. Confirm to save only modified services

**Important:** Subsequent changes will save all entries until you prune again.

### Button Comparison

| Button | Purpose | Effect |
|--------|---------|--------|
| **Prune Output** | Export only changes | Saves services where `end_mode ≠ start_mode` |
| **Reset Target** | Revert to defaults | Sets all `end_mode = start_mode` |
| **Manual Startup** | Set all to Manual | Sets all `start_mode = "Manual"` |

## Prerequisites

### Automated Installation (Recommended)

Use the provided installation script to automatically install all dependencies:

```powershell
.\scripts\install-dependencies.ps1
```

This script uses `winget` and requires:
- Windows 10 version 1809 or later
- Administrative privileges may be required

### Manual Installation

If you prefer manual installation:

- **Node.js** v23.5.0+ (via [nodejs.org](https://nodejs.org/) or [rustup](https://rustup.rs/))
- **Rust** v1.84.0+ (via [rustup.rs](https://rustup.rs/))
- **Bazel** (optional, via [bazel.build](https://bazel.build/))
- **Windows OS** (required for WMI service access)

## Troubleshooting

Having issues? See the comprehensive **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)** guide for detailed solutions.

**Quick Fixes:**
- **Services not loading**: Requires Windows with PowerShell → Run as Administrator
- **vcruntime140.dll error**: Run `.\run-ordem.ps1` (auto-installs VC++ Redistributable)
- **Port 4000 in use**: Check `netstat -ano | findstr :4000` to find the conflicting process
- **Silent exit**: Run `.\run-ordem.ps1` to see diagnostic output

For comprehensive troubleshooting, startup diagnostics, and advanced solutions, see **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)**.

## License

[The MIT License (MIT)](https://opensource.org/license/mit)

Copyright 2025 Alisson Sol

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the “Software”), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
