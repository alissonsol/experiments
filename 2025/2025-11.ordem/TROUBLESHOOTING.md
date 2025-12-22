# Ordem - Troubleshooting Guide

This guide consolidates all troubleshooting information for the Ordem service. If you encounter issues, start here for solutions and diagnostics.

Source: [gibhub.com/alissonsol](https://github.com/alissonsol)  
Copyright (c) 2025, Alisson Sol - All rights reserved.

## Table of Contents

- [Quick Diagnostics](#quick-diagnostics)
- [Common Issues](#common-issues)
  - [Build Issues](#build-issues)
  - [Runtime Issues](#runtime-issues)
  - [Service Issues](#service-issues)
  - [UI Issues](#ui-issues)
- [Startup Diagnostics](#startup-diagnostics)
- [Runtime Dependencies](#runtime-dependencies)
- [Port Conflicts](#port-conflicts)
- [Permission Issues](#permission-issues)
- [Configuration Issues](#configuration-issues)
- [Advanced Troubleshooting](#advanced-troubleshooting)

---

## Quick Diagnostics

The Ordem service includes comprehensive built-in diagnostics. Simply run the service to see detailed startup checks:

```powershell
.\run-ordem.ps1
```

Or run the executable directly:

```powershell
.\dist\backend\ordem_service.exe
```

The service performs **6 critical startup checks** and will clearly report any issues.

---

## Common Issues

### Build Issues

#### Antivirus Blocking Build

**Symptoms:**
- Build fails or hangs
- `build-script-build.exe` files are quarantined
- Slow build times

**Solution:**
Add an antivirus exclusion for the build directory:

```powershell
# Windows Defender exclusion
Add-MpPreference -ExclusionPath "C:\path\to\your\project\services\retrieve\target"
```

See [README.md - Antivirus Configuration](README.md#antivirus-configuration-important) for details.

#### Cargo Not Found

**Symptoms:**
```
cargo not found in PATH
```

**Solution:**
Install Rust toolchain:

```powershell
.\scripts\install-dependencies.ps1
```

Or manually from https://rustup.rs/

#### Build Fails with Symlink Errors (Bazel)

**Symptoms:**
- Bazel build fails with symlink creation errors
- `rules_rust` symlink issues

**Solution:**
Use Cargo instead (default), or enable Windows Developer Mode for Bazel support.

#### Connectivity issues

**Symptoms:**
- Errors during build because network access is blocked to sites with dependencies
  - `npm error code 403 Forbidden - GET https://registry.npmjs.org/esbuild`
  - `warning: spurious network error (3 tries remaining): [35] SSL connect error (schannel: next InitializeSecurityContext failed: CRYPT_E_NO_REVOCATION_CHECK (0x80092012) - The revocation function was unable to check revocation for the certificate.)`
  - `failed to download from 'https://index.crates.io/config.json'`
  
**Solution:**
- Most times this happens due to firewall blocking. If possible, unblock access to the blocked sites.
- Some companies use projects like [JFrog Artifactory](https://jfrog.com/artifactory/) to have internal vetted copies of dependencies. In this case, change the `npm` and Rust `cargo` to look for dependencies in those internal mirrors using environment variables.
  - `npm config set registry https://artifactory.mirror.companyname.com/artifactory/api/npm-internalfacing`
  - `$env:CARGO_HTTP_CHECK_REVOKE = "false"`
  - `$env:CARGO_REGISTRIES_MY_MIRROR_INDEX = "https://artifactory.mirror.companyname.com/artifactory/api/cargo/remote-repos/"`
  - `$env:CARGO_SOURCE_CRATES_IO_REPLACE_WITH = "my-mirror"`

#### Rust toolchain default

**Symptoms:**
- These scripts assume use of the Rust MSVC [toolchain](https://rust-lang.github.io/rustup/concepts/toolchains.html).
- Error messages may show up indicating build failures with the "gnu" tools or dependencies.

**Solution:**
- `rustup show` will show the default toolchain.
- Install the MSVC toolchain if needed (should be installed by the `install-dependencies.ps1` script).
- Change the MSVC toolchain to be the default: `rustup default stable-msvc`

---

### Runtime Issues

#### vcruntime140.dll Missing

**Symptoms:**
```
The code execution cannot proceed because vcruntime140.dll was not found.
Reinstalling the program may fix this problem.
```

**Automatic Fix:**
The `run-ordem.ps1` script automatically detects and installs this dependency.

**Manual Fix:**
```powershell
# Using winget
winget install --id Microsoft.VCRedist.2015+.x64 --exact --accept-package-agreements --accept-source-agreements

# Or download directly
# Visit: https://aka.ms/vs/17/release/vc_redist.x64.exe
```

**Why This Happens:**
Rust executables on Windows depend on the Visual C++ Runtime libraries. Many systems have this pre-installed from other software, but clean Windows installations may need it.

**Detection Logic:**
The launcher checks for `vcruntime140.dll` in:
- `C:\Windows\System32\vcruntime140.dll`
- `C:\Windows\SysWOW64\vcruntime140.dll`

#### Service Exits Silently

**Symptoms:**
- Service starts and immediately exits
- No error message displayed

**Solution:**
Run with the launcher script to see diagnostic output:

```powershell
.\run-ordem.ps1
```

The service now includes comprehensive startup diagnostics that will show exactly what failed.

---

### Service Issues

#### Cannot Query Windows Services

**Symptoms:**
```
[CHECK 3/6] Windows service query test... FAILED

ERROR: Cannot query Windows services
```

**Possible Causes:**
1. Insufficient permissions to query WMI
2. PowerShell execution policy restrictions
3. WMI service not running

**Solutions:**

**1. Run as Administrator:**
```powershell
# Right-click PowerShell and select "Run as Administrator"
.\run-ordem.ps1
```

**2. Check PowerShell Execution Policy:**
```powershell
Get-ExecutionPolicy

# If restricted, change it:
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

**3. Verify WMI Service:**
```powershell
Get-Service -Name Winmgmt
# Should show Status: Running

# If stopped, start it:
Start-Service -Name Winmgmt
```

#### PowerShell Not Found

**Symptoms:**
```
[CHECK 2/6] PowerShell availability... FAILED

ERROR: PowerShell is required but not found
```

**Solution:**
Install PowerShell:

```powershell
winget install --id Microsoft.PowerShell --source winget
```

Or download from: https://github.com/PowerShell/PowerShell/releases

**Note:** Windows 10/11 usually include Windows PowerShell 5.x by default. This error is rare but can occur on minimal Windows installations.

---

### UI Issues

#### Frontend Not Found

**Symptoms:**
```
Backend:  http://127.0.0.1:4000
Frontend: NOT FOUND
Mode:     API-only (no UI)
```

**Solution:**
Build the UI first:

```powershell
.\scripts\build-all.ps1
```

The service searches for UI in these locations:
- `dist/ui` (standard build output)
- `../dist/ui` (when running from subdirectory)
- `../../dist/ui` (nested subdirectory)
- `ui/dist` (alternative location)
- `../ui/dist` (UI as sibling)

#### UI Loads But Shows Errors

**Symptoms:**
- UI loads but cannot fetch services
- Network errors in browser console
- CORS errors

**Solutions:**

**1. Verify Backend is Running:**
```powershell
# Check if server is listening
netstat -ano | findstr :4000
```

**2. Check Browser Console:**
Press F12 in browser and look for error messages

**3. Verify API Endpoint:**
Visit http://127.0.0.1:4000/api/services directly to test the API

---

## Startup Diagnostics

The service performs **6 critical startup checks** in sequence:

### 1. Platform Verification

**What it checks:** Ensures the service is running on Windows

**Success:**
```
[CHECK 1/6] Platform verification... OK (Windows)
```

**Failure:**
```
[CHECK 1/6] Platform verification... FAILED

ERROR: This service requires Windows OS
Current platform is not Windows.
```

**Solution:** Ordem requires Windows for WMI service queries. It cannot run on Linux or macOS.

---

### 2. PowerShell Availability

**What it checks:** Verifies PowerShell (pwsh or powershell) is installed and accessible

**Checks for:**
- PowerShell 7+ (pwsh)
- Windows PowerShell 5.x (powershell)

**Success:**
```
[CHECK 2/6] PowerShell availability... OK (pwsh found)
```

**Failure:**
```
[CHECK 2/6] PowerShell availability... FAILED

ERROR: PowerShell is required but not found
```

**Solution:** See [PowerShell Not Found](#powershell-not-found) above.

---

### 3. Windows Service Query Test

**What it checks:** Verifies the service can query Windows services via WMI

**Tests:**
- WMI access permissions
- PowerShell execution policy
- Actual service enumeration

**Success:**
```
[CHECK 3/6] Windows service query test... OK (247 services found)
```

**Failure:**
```
[CHECK 3/6] Windows service query test... FAILED

ERROR: Cannot query Windows services
Details: Failed to run PowerShell to query services

This may indicate:
  - Insufficient permissions to query WMI
  - PowerShell execution policy restrictions
  - WMI service is not running
```

**Solution:** See [Cannot Query Windows Services](#cannot-query-windows-services) above.

---

### 4. Configuration Directory

**What it checks:** Verifies environment variables needed for config file location

**Checks:**
- `LOCALAPPDATA` environment variable
- Fallback to `USERPROFILE\AppData\Local`

**Success:**
```
[CHECK 4/6] Configuration directory... OK
              Path: C:\Users\username\AppData\Local\Ordem\ordem.target.xml
```

**Failure:**
```
[CHECK 4/6] Configuration directory... FAILED

ERROR: Cannot determine configuration file path
Missing environment variables: LOCALAPPDATA or USERPROFILE
```

**Solution:**
This is extremely rare. Verify environment variables:

```powershell
echo $env:LOCALAPPDATA
echo $env:USERPROFILE
```

If missing, your Windows user profile may be corrupted. Try creating a new user account.

---

### 5. Configuration Write Test

**What it checks:** Verifies write permissions to the configuration directory

**Tests:**
- Directory creation if needed
- Write permission by creating a test file
- Disk space availability

**Success:**
```
[CHECK 5/6] Configuration write test... OK (writable)
```

**Failure:**
```
[CHECK 5/6] Configuration write test... FAILED

ERROR: Cannot write to configuration directory
Path: C:\Users\username\AppData\Local\Ordem
Details: Access is denied. (os error 5)

Check folder permissions and disk space.
```

**Solutions:**

**1. Check Disk Space:**
```powershell
Get-PSDrive C | Select-Object Used,Free
```

**2. Check Folder Permissions:**
```powershell
# Navigate to parent directory
cd $env:LOCALAPPDATA

# Check if Ordem folder exists and its permissions
Get-Acl Ordem | Format-List
```

**3. Try Creating Directory Manually:**
```powershell
New-Item -ItemType Directory -Path "$env:LOCALAPPDATA\Ordem" -Force
```

**4. Run as Administrator** (if permissions issue persists)

---

### 6. Port Availability

**What it checks:** Verifies port 4000 is available for binding

**Tests:**
- Whether port 4000 is already in use
- Socket binding permissions
- Firewall restrictions

**Success:**
```
[CHECK 6/6] Port availability (127.0.0.1:4000)... OK (available)
```

**Failure:**
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

**Solution:** See [Port Conflicts](#port-conflicts) below.

---

## Runtime Dependencies

### Microsoft Visual C++ Redistributable

**Required For:** All Rust executables on Windows

**Auto-Detection:** The `run-ordem.ps1` script automatically checks and installs if missing

**Manual Check:**
```powershell
# Check if vcruntime140.dll exists
Test-Path "$env:SystemRoot\System32\vcruntime140.dll"
Test-Path "$env:SystemRoot\SysWOW64\vcruntime140.dll"
```

**Manual Installation:**

**Option 1: Using winget (Recommended)**
```powershell
winget install --id Microsoft.VCRedist.2015+.x64 --exact --accept-package-agreements --accept-source-agreements
```

**Option 2: Direct Download**
- x64 (64-bit): https://aka.ms/vs/17/release/vc_redist.x64.exe
- x86 (32-bit): https://aka.ms/vs/17/release/vc_redist.x86.exe

**Option 3: Using Chocolatey**
```powershell
choco install vcredist140
```

**Why This is Required:**
Rust uses the MSVC toolchain on Windows, which produces executables that link against VC++ runtime libraries. These DLLs are not included with Windows by default.

**winget Exit Codes:**
| Exit Code | Meaning | Action |
|-----------|---------|--------|
| 0 | Success | Continue normally |
| -1978335189 | Already installed | Continue normally |
| Other | Installation issue | Show warning but continue |

---

## Port Conflicts

### Finding What's Using Port 4000

```powershell
# Show all processes using port 4000
netstat -ano | findstr :4000

# Example output:
#   TCP    127.0.0.1:4000    0.0.0.0:0    LISTENING    12345
#                                                       ^^^^^ This is the PID
```

### Killing the Process

```powershell
# Using PID from netstat output
Stop-Process -Id 12345 -Force

# Or if it's another ordem_service instance
Get-Process -Name "ordem_service" | Stop-Process -Force
```

### Changing the Port

If you need to use a different port, edit `services/retrieve/src/main.rs`:

```rust
let bind = "127.0.0.1:4000";  // Change 4000 to your desired port
```

Then rebuild:
```powershell
.\scripts\build-all.ps1
```

**Note:** You'll also need to update the UI configuration if changing the port.

---

## Permission Issues

### Running as Administrator

Some operations may require administrator privileges:

```powershell
# Right-click PowerShell and select "Run as Administrator"
# Then run the service
.\run-ordem.ps1
```

### WMI Access Denied

If you get WMI access errors even as administrator:

```powershell
# Check WMI permissions
Get-WmiObject -Class Win32_Service -ComputerName localhost

# Restart WMI service
Restart-Service -Name Winmgmt
```

### User Account Control (UAC)

If UAC is blocking operations:

1. Temporarily disable UAC (not recommended for production)
2. Run PowerShell as Administrator
3. Add the service to UAC whitelist

---

## Configuration Issues

### Configuration File Location

Default location:
```
%LOCALAPPDATA%\Ordem\ordem.target.xml
```

Which typically resolves to:
```
C:\Users\YourUsername\AppData\Local\Ordem\ordem.target.xml
```

### Viewing Configuration

```powershell
# View current configuration
Get-Content "$env:LOCALAPPDATA\Ordem\ordem.target.xml"
```

### Resetting Configuration

```powershell
# Delete configuration file (will be regenerated on next run)
Remove-Item "$env:LOCALAPPDATA\Ordem\ordem.target.xml" -Force
```

### Configuration Corruption

If the XML file is corrupted:

1. Stop the service
2. Delete the configuration file (see above)
3. Restart the service - it will regenerate from current system services

---

## Advanced Troubleshooting

### Enable Detailed Logging

Set the `RUST_LOG` environment variable:

```powershell
$env:RUST_LOG = "debug"
.\dist\backend\ordem_service.exe
```

Log levels:
- `error` - Only errors
- `warn` - Warnings and errors
- `info` - Info, warnings, and errors
- `debug` - Debug info and above
- `trace` - Everything (very verbose)

### Network Diagnostics

```powershell
# Test if port is accessible
Test-NetConnection -ComputerName 127.0.0.1 -Port 4000

# Check firewall rules
Get-NetFirewallRule | Where-Object {$_.DisplayName -like "*4000*"}

# Check if localhost resolves correctly
ping 127.0.0.1
```

### Process Diagnostics

```powershell
# Find ordem_service processes
Get-Process -Name "ordem_service" -ErrorAction SilentlyContinue

# See detailed process info
Get-Process -Name "ordem_service" | Format-List *

# Check CPU/Memory usage
Get-Process -Name "ordem_service" | Select-Object CPU, WorkingSet, StartTime
```

### Clean Reinstall

```powershell
# 1. Stop all instances
Get-Process -Name "ordem_service" -ErrorAction SilentlyContinue | Stop-Process -Force

# 2. Clean build
.\scripts\clean-all.ps1

# 3. Remove configuration
Remove-Item "$env:LOCALAPPDATA\Ordem" -Recurse -Force -ErrorAction SilentlyContinue

# 4. Rebuild
.\scripts\build-all.ps1

# 5. Run
.\run-ordem.ps1
```

---

## Getting Help

If you've tried all troubleshooting steps and still have issues:

1. **Check the diagnostic output** - Run `.\run-ordem.ps1` and note which check fails
2. **Collect information:**
   - Windows version: `winver`
   - PowerShell version: `$PSVersionTable.PSVersion`
   - Ordem version: Check README.md
   - Error messages: Copy the exact error text
3. **Review logs** if detailed logging was enabled
4. **Report the issue** with all collected information

---

## Related Documentation

- [README.md](README.md) - Main documentation
