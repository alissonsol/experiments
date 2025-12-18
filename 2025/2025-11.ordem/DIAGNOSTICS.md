# Ordem Service - Startup Diagnostics

## Overview

The ordem service has been enhanced with comprehensive startup diagnostics to identify and report any missing requirements or issues that prevent the service from executing properly.

## What Was Added

The service now performs **6 critical startup checks** before attempting to bind and start the HTTP server. If any check fails, the service will:
1. Display a clear error message
2. Explain what went wrong
3. Provide troubleshooting guidance
4. Exit with a non-zero code (prevents silent failures)

## Startup Checks

### 1. Platform Verification
**Purpose:** Ensures the service is running on Windows

**Error Message Example:**
```
[CHECK 1/6] Platform verification... FAILED

ERROR: This service requires Windows OS
Current platform is not Windows.
```

### 2. PowerShell Availability
**Purpose:** Verifies PowerShell (pwsh or powershell) is installed and accessible

**Checks for:**
- PowerShell 7+ (pwsh)
- Windows PowerShell 5.x (powershell)

**Error Message Example:**
```
[CHECK 2/6] PowerShell availability... FAILED

ERROR: PowerShell is required but not found
The service needs PowerShell to query Windows services.
Please ensure PowerShell is installed and in PATH.
```

### 3. Windows Service Query Test
**Purpose:** Verifies the service can query Windows services via WMI

**Tests:**
- WMI access permissions
- PowerShell execution policy
- Actual service enumeration

**Success Message Example:**
```
[CHECK 3/6] Windows service query test... OK (247 services found)
```

**Error Message Example:**
```
[CHECK 3/6] Windows service query test... FAILED

ERROR: Cannot query Windows services
Details: Failed to run PowerShell to query services

This may indicate:
  - Insufficient permissions to query WMI
  - PowerShell execution policy restrictions
  - WMI service is not running
```

### 4. Configuration Directory
**Purpose:** Verifies environment variables needed for config file location

**Checks:**
- `LOCALAPPDATA` environment variable
- Fallback to `USERPROFILE\AppData\Local`

**Success Message Example:**
```
[CHECK 4/6] Configuration directory... OK
              Path: C:\Users\username\AppData\Local\Ordem\ordem.target.xml
```

**Error Message Example:**
```
[CHECK 4/6] Configuration directory... FAILED

ERROR: Cannot determine configuration file path
Missing environment variables: LOCALAPPDATA or USERPROFILE
```

### 5. Configuration Write Test
**Purpose:** Verifies write permissions to the configuration directory

**Tests:**
- Directory creation if needed
- Write permission by creating a test file
- Disk space availability

**Success Message Example:**
```
[CHECK 5/6] Configuration write test... OK (writable)
```

**Error Message Example:**
```
[CHECK 5/6] Configuration write test... FAILED

ERROR: Cannot write to configuration directory
Path: C:\Users\username\AppData\Local\Ordem
Details: Access is denied. (os error 5)

Check folder permissions and disk space.
```

### 6. Port Availability
**Purpose:** Verifies port 4000 is available for binding

**Tests:**
- Whether port 4000 is already in use
- Socket binding permissions
- Firewall restrictions

**Success Message Example:**
```
[CHECK 6/6] Port availability (127.0.0.1:4000)... OK (available)
```

**Error Message Example:**
```
[CHECK 6/6] Port availability (127.0.0.1:4000)... FAILED

ERROR: Cannot bind to 127.0.0.1:4000
Details: Only one usage of each socket address (protocol/network address/port)
         is normally permitted. (os error 10048)

Possible causes:
  - Port 4000 is already in use by another process
  - Firewall is blocking the port
  - Another instance of ordem_service is running

To find what's using the port, run:
  netstat -ano | findstr :4000
```

## Enhanced Server Startup

After all checks pass, the service provides clear feedback during server startup:

```
[STARTUP] Binding to 127.0.0.1:4000... OK
[STARTUP] Starting HTTP server...

Server is running. Press Ctrl+C to stop.
```

If server startup fails unexpectedly:

```
[STARTUP] Binding to 127.0.0.1:4000... FAILED

ERROR: Failed to bind HTTP server to 127.0.0.1:4000
Details: [error details]

This is unexpected since port availability was verified.
Another process may have claimed the port between checks.
```

If the server stops unexpectedly during runtime:

```
========================================
ERROR: Server stopped unexpectedly
========================================
Details: [error details]
```

## Complete Startup Sequence

**Successful Startup:**
```
========================================
Ordem Service Retrieval Backend
========================================

[DIAGNOSTICS] Running startup checks...

[CHECK 1/6] Platform verification... OK (Windows)
[CHECK 2/6] PowerShell availability... OK (powershell found)
[CHECK 3/6] Windows service query test... OK (247 services found)
[CHECK 4/6] Configuration directory... OK
              Path: C:\Users\username\AppData\Local\Ordem\ordem.target.xml
[CHECK 5/6] Configuration write test... OK (writable)
[CHECK 6/6] Port availability (127.0.0.1:4000)... OK (available)

[DIAGNOSTICS] All startup checks passed!
========================================

Backend:  http://127.0.0.1:4000
Frontend: http://127.0.0.1:4000 (served from: C:\...\dist\ui)
Mode:     Integrated (single endpoint)
========================================

[STARTUP] Binding to 127.0.0.1:4000... OK
[STARTUP] Starting HTTP server...

Server is running. Press Ctrl+C to stop.
```

## Testing the Diagnostics

### Method 1: Using the Test Script
```powershell
.\test-diagnostics.ps1
```

This will:
1. Stop any running ordem_service instances
2. Start the new version with diagnostics
3. Display all startup check results

### Method 2: Direct Execution
```powershell
.\dist\backend\ordem_service.exe
```

### Method 3: Using the Launcher
```powershell
.\run-ordem.ps1
```

## Troubleshooting Guide

### Silent Exit (Before This Update)
**Problem:** Service starts and exits without any message

**Solution:** The new diagnostics will now show exactly which check failed

### Port Already in Use
**Problem:** Another process is using port 4000

**Diagnostic Output:**
```
[CHECK 6/6] Port availability (127.0.0.1:4000)... FAILED
```

**Solutions:**
- Stop the other ordem_service instance
- Find what's using the port: `netstat -ano | findstr :4000`
- Kill the process using the PID from netstat

### Cannot Query Services
**Problem:** Service can't access Windows services via WMI

**Diagnostic Output:**
```
[CHECK 3/6] Windows service query test... FAILED
```

**Solutions:**
- Run as Administrator
- Check PowerShell execution policy: `Get-ExecutionPolicy`
- Verify WMI service is running: `Get-Service -Name Winmgmt`

### Configuration Write Failure
**Problem:** Cannot write to AppData\Local\Ordem

**Diagnostic Output:**
```
[CHECK 5/6] Configuration write test... FAILED
```

**Solutions:**
- Check folder permissions
- Verify disk space availability
- Run as different user if profile is corrupted

## Runtime Dependency Check (run-ordem.ps1)

In addition to the service's built-in diagnostics, the launcher script now checks for the **Microsoft Visual C++ Redistributable**, which is required to run Rust executables on Windows.

### What It Does

Before starting the service, the script:

1. **Checks for vcruntime140.dll** in System32 and SysWOW64 directories
2. **If missing:** Attempts automatic installation via winget
3. **If winget unavailable:** Provides manual download link

### Error Handling

**If VC++ Redistributable is missing and winget is available:**
```
Checking runtime dependencies...

========================================
Missing Runtime Dependency
========================================

The Microsoft Visual C++ Redistributable is required but not found.
This is needed to run the ordem service executable.

Attempting to install it automatically using winget...

Installing Microsoft Visual C++ Redistributable 2015-2022...
✓ Microsoft Visual C++ Redistributable is now available
```

**If winget is not available:**
```
winget is not available on this system.

Please install the Microsoft Visual C++ Redistributable manually:
  1. Visit: https://aka.ms/vs/17/release/vc_redist.x64.exe
  2. Download and run the installer
  3. Restart this script
```

**If already installed:**
```
Checking runtime dependencies...
✓ Microsoft Visual C++ Redistributable found
```

## Benefits

1. **No More Silent Failures:** Service will always report why it cannot start
2. **Clear Error Messages:** Each error includes explanation and next steps
3. **Early Detection:** Problems are caught before server binding
4. **Helpful Guidance:** Error messages include troubleshooting commands
5. **Sequential Checks:** Diagnostics run in logical order
6. **Resource Verification:** All requirements checked before startup
7. **Automatic Dependency Installation:** VC++ Redistributable installed automatically if missing

## Files Modified

- [services/retrieve/src/main.rs](services/retrieve/src/main.rs) - Added diagnostic checks in `main()` function
- [run-ordem.ps1](run-ordem.ps1) - Added VC++ Redistributable detection and installation

## Implementation Details

- **Exit Codes:** Service exits with code 1 on any diagnostic failure
- **Error Output:** Uses `eprintln!` for errors (stderr) and `println!` for success (stdout)
- **Fail-Fast:** Stops at first failure to avoid cascading errors
- **Non-Intrusive:** Diagnostics only run at startup, no runtime overhead
- **Backwards Compatible:** No changes to API endpoints or configuration format
