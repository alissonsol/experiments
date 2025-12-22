# Progresso - Troubleshooting Guide

This guide consolidates all troubleshooting information for the Progresso Windows service. If you encounter issues, start here for solutions and diagnostics.

Source: [gibhub.com/alissonsol](https://github.com/alissonsol)  
Copyright (c) 2025, Alisson Sol - All rights reserved.

## Table of Contents

- [Quick Start](#quick-start)
- [Common Issues](#common-issues)
  - [Build Issues](#build-issues)
  - [Runtime Issues](#runtime-issues)
  - [Service Issues](#service-issues)
  - [Configuration Issues](#configuration-issues)
- [Windows Service Troubleshooting](#windows-service-troubleshooting)
- [File and Permission Issues](#file-and-permission-issues)
- [CPU Monitoring Issues](#cpu-monitoring-issues)
- [Advanced Troubleshooting](#advanced-troubleshooting)

---

## Quick Start

### Testing the Service

**Console Mode (Recommended for testing):**
```powershell
.\run-progresso.ps1
```

This script:
- Checks if the executable exists
- Offers to build if missing
- Ensures `ordem.target.xml` exists
- Runs in console mode with detailed logging
- Captures logs to `dist\backend\run-progresso.log`

**Direct Execution:**
```powershell
Set-Location dist\backend
.\progresso_service.exe
```

**As Windows Service:**
```powershell
Set-Location services\progresso_service\scripts
.\install-service.ps1
```

---

## Common Issues

### Build Issues

#### Project Not Built

**Symptoms:**
```
========================================
Project Not Built
========================================

The executable 'dist\backend\progresso_service.exe' was not found.
```

**Solution:**
The run script will ask if you want to build. Type `Y` to build automatically, or run:

```powershell
.\scripts\build-all.ps1
```

#### Antivirus Blocking Build

**Symptoms:**
- Build fails or hangs
- `build-script-build.exe` files are quarantined
- Slow build times
- Antivirus alerts during compilation

**Solution:**
Add an antivirus exclusion for the build directory:

```powershell
# Windows Defender exclusion (Run as Administrator)
Add-MpPreference -ExclusionPath "C:\path\to\your\project\services\progresso_service\target"
```

**Why This Happens:**
Rust's Cargo build system generates temporary executables called `build-script-build.exe` for dependency compilation. These are legitimate build artifacts but trigger false positives in some antivirus software.

See [README.md - Antivirus Configuration](README.md#antivirus-configuration-important) for details.

#### Cargo Not Found

**Symptoms:**
```
Cargo not found on PATH. Install Rust toolchain from https://rustup.rs/
```

**Solution:**
```powershell
# Automated installation
.\scripts\install-dependencies.ps1

# Or manually from https://rustup.rs/
```

After installation, **restart your terminal** to refresh the PATH.

#### Connectivity issues

**Symptoms:**
- Errors during build because network access is blocked to sites with dependencies
  - `warning: spurious network error (3 tries remaining): [35] SSL connect error (schannel: next InitializeSecurityContext failed: CRYPT_E_NO_REVOCATION_CHECK (0x80092012) - The revocation function was unable to check revocation for the certificate.)`
  - `failed to download from 'https://index.crates.io/config.json'`
  
**Solution:**
- Most times this happens due to firewall blocking. If possible, unblock access to the blocked sites.
- Some companies use projects like [JFrog Artifactory](https://jfrog.com/artifactory/) to have internal vetted copies of dependencies. In this case, change Rust `cargo` to look for dependencies in those internal mirrors using environment variables.
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

#### Missing ordem.target.xml

**Symptoms:**
```
ordem.target.xml is missing. Please provide dist\backend\ordem.target.xml
or place one in %LOCALAPPDATA%\Ordem\ordem.target.xml and re-run.
```

**Solution:**

**Option 1: Automatic Copy (if you have Ordem installed)**
The script automatically tries to copy from:
```
%LOCALAPPDATA%\Ordem\ordem.target.xml
```

**Option 2: Manual Creation**
Create `dist\backend\ordem.target.xml` with this structure:

```xml
<OrdemTargets>
  <Service>
    <name>YourServiceName</name>
    <description>Service Description</description>
    <status>Running</status>
    <start_mode>Auto</start_mode>
    <end_mode>Auto</end_mode>
    <log_on_as>LocalSystem</log_on_as>
    <path>C:\Path\To\Service.exe</path>
  </Service>
  <!-- Add more services as needed -->
</OrdemTargets>
```

**Option 3: Copy from Ordem**
```powershell
Copy-Item "$env:LOCALAPPDATA\Ordem\ordem.target.xml" "dist\backend\" -Force
```

#### Service Exits with Error

**Symptoms:**
```
progresso_service.exe exited with code 1
```

**Diagnostic Steps:**

1. **Check the log file:**
```powershell
Get-Content "dist\backend\run-progresso.log" -Tail 80
```

2. **Enable full backtrace:**
```powershell
$env:RUST_BACKTRACE = 'full'
.\dist\backend\progresso_service.exe
```

3. **Enable verbose logging:**
```powershell
$env:RUST_LOG = 'debug'
.\dist\backend\progresso_service.exe
```

---

### Service Issues

#### Service Won't Start

**Symptoms:**
- Windows service fails to start
- Event Viewer shows error codes
- Service Control Manager reports failure

**Solutions:**

**1. Check Service Account Permissions:**
```powershell
# Verify service is configured correctly
Get-Service -Name ProgressoService | Format-List *
```

**2. Check Working Directory:**
Ensure the service's working directory contains `ordem.target.xml`

**3. Review Event Logs:**
```powershell
# Check Application event log for errors
Get-EventLog -LogName Application -Source "ProgressoService" -Newest 10
```

**4. Test in Console Mode First:**
```powershell
.\run-progresso.ps1
```
Fix any errors shown in console mode before installing as a service.

#### Service Hangs on Stop

**Symptoms:**
- Service doesn't stop cleanly
- Must force-kill the process
- Stop operation times out

**Solution:**
The service implements graceful shutdown. If it hangs:

```powershell
# Force stop
Stop-Service -Name ProgressoService -Force

# Or kill the process
Get-Process -Name "progresso_service" | Stop-Process -Force
```

**Prevention:**
Ensure services being managed respond to stop commands promptly.

#### Cannot Start/Stop Windows Services

**Symptoms:**
```
[ServiceName] Processing service...
  Starting service (target: Automatic)...
  Failed to start
```

**Possible Causes:**
1. Insufficient permissions
2. Service doesn't exist
3. Service is disabled
4. Dependencies not running

**Solutions:**

**1. Run as Administrator:**
```powershell
# Right-click PowerShell and "Run as Administrator"
.\run-progresso.ps1
```

**2. Verify Service Exists:**
```powershell
Get-Service -Name "YourServiceName"
```

**3. Check Service Dependencies:**
```powershell
Get-Service -Name "YourServiceName" | Select-Object -ExpandProperty DependentServices
Get-Service -Name "YourServiceName" | Select-Object -ExpandProperty ServicesDependedOn
```

**4. Check Service Startup Type:**
```powershell
Get-WmiObject Win32_Service -Filter "Name='YourServiceName'" | Select-Object Name, StartMode
```

---

### Configuration Issues

#### Invalid XML Format

**Symptoms:**
```
Failed to serialize progress to XML
```

**Solution:**
The service reads XML but may fail if the input is malformed.

**Validate XML:**
```powershell
# Try loading the XML in PowerShell
[xml](Get-Content "dist\backend\ordem.target.xml")

# If this fails, the XML is malformed
```

**Common XML Issues:**
- Missing closing tags
- Unescaped special characters (`<`, `>`, `&`)
- Invalid UTF-8 encoding
- BOM (Byte Order Mark) issues

**Fix Encoding:**
```powershell
# Save with UTF-8 encoding
$content = Get-Content "dist\backend\ordem.target.xml" -Raw
[System.IO.File]::WriteAllText("dist\backend\ordem.target.xml", $content, [System.Text.UTF8Encoding]::new($false))
```

#### Service Name Empty or Missing

**Symptoms:**
```
Skipping service with empty name
```

**Solution:**
Ensure each `<Service>` element in `ordem.target.xml` has a non-empty `<name>` field:

```xml
<Service>
  <name>MyServiceName</name>  <!-- Must not be empty -->
  <!-- ... other fields ... -->
</Service>
```

---

## Windows Service Troubleshooting

### Installing as Windows Service

```powershell
Set-Location services\progresso_service\scripts
.\install-service.ps1
```

**Requirements:**
- Administrator privileges
- Binary must be built first
- Working directory must be accessible

### Uninstalling Windows Service

```powershell
Set-Location services\progresso_service\scripts
.\uninstall-service.ps1
```

### Service Won't Install

**Symptoms:**
- Installation script fails
- "Access Denied" errors
- Service already exists

**Solutions:**

**1. Run as Administrator** (Required)

**2. Remove Existing Service:**
```powershell
# If service already exists
sc.exe delete ProgressoService
```

**3. Check Service Name Conflicts:**
```powershell
Get-Service | Where-Object {$_.Name -like "*Progresso*"}
```

### Checking Service Status

```powershell
# Get service status
Get-Service -Name ProgressoService

# See detailed info
Get-Service -Name ProgressoService | Format-List *

# Check service in Services console
services.msc
```

### Service Logs

When running as a Windows service, logging goes to the Windows Event Log:

```powershell
# View recent logs
Get-EventLog -LogName Application -Source "ProgressoService" -Newest 20

# Filter by severity
Get-EventLog -LogName Application -Source "ProgressoService" -EntryType Error -Newest 10
```

---

## File and Permission Issues

### Cannot Write Progress File

**Symptoms:**
```
Failed to create progress file
Permission denied
```

**Solution:**

**1. Check Directory Permissions:**
```powershell
# Check permissions on working directory
Get-Acl . | Format-List
```

**2. Verify Disk Space:**
```powershell
Get-PSDrive C | Select-Object Used,Free
```

**3. Run from Writable Location:**
Ensure the working directory is not:
- Program Files (restricted)
- Windows directory (restricted)
- Network share (may have restrictions)

**4. Use Local Directory:**
```powershell
# Copy to local directory
Copy-Item "dist\backend\progresso_service.exe" "$env:USERPROFILE\progresso" -Force
Set-Location "$env:USERPROFILE\progresso"
.\progresso_service.exe
```

### Progress File Not Created

**Symptoms:**
- Service completes but no output file
- No `progresso.YYYYMMDD.HHMMSS.xml` file

**Check:**
1. Working directory (files created here)
2. Permissions (can write?)
3. Service completed successfully?

```powershell
# List recent files in current directory
Get-ChildItem -Filter "progresso.*.xml" | Sort-Object LastWriteTime -Descending | Select-Object -First 5
```

---

## CPU Monitoring Issues

### CPU Wait Timeout

**Symptoms:**
```
CPU wait timeout reached after 300 seconds (current: 75.2%)
```

**What This Means:**
The service waited 5 minutes for CPU usage to drop below 60% but it remained high.

**Solutions:**

**1. This is Normal for:**
- Heavy system load
- Background Windows updates
- Antivirus scans
- Other intensive operations

The service will continue despite high CPU.

**2. Adjust Thresholds (Advanced):**
Edit `services\progresso_service\src\main.rs`:

```rust
const CPU_WAIT_TIMEOUT: Duration = Duration::from_secs(300);  // Increase if needed
const CPU_THRESHOLD: f32 = 60.0;  // Raise threshold if needed
```

Then rebuild the service.

### CPU Monitoring Not Working

**Symptoms:**
- CPU always shows 0%
- CPU readings seem incorrect

**Solution:**
The service uses the `sysinfo` crate which requires:
- Windows performance counters enabled
- Sufficient permissions to read system info

**Check Performance Counters:**
```powershell
# Open Performance Monitor
perfmon
```

If performance counters are broken, rebuild them:
```powershell
# Run as Administrator
lodctr /R
```

---

## Advanced Troubleshooting

### Enable Full Rust Backtrace

```powershell
$env:RUST_BACKTRACE = 'full'
$env:RUST_LOG = 'trace'
.\dist\backend\progresso_service.exe 2>&1 | Tee-Object -FilePath "progresso-debug.log"
```

This creates a detailed log with full stack traces.

### Debug Service State Transitions

The service logs state transitions at the `info` level:

```powershell
$env:RUST_LOG = 'info'
.\dist\backend\progresso_service.exe
```

Look for messages like:
- `Service 'X' already running`
- `Starting 'X' (target: Automatic)`
- `Stopping 'X' (target: Manual)`

### Inspect XML Output

```powershell
# View generated progress file
$latest = Get-ChildItem -Filter "progresso.*.xml" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Get-Content $latest.FullName

# Validate XML
[xml](Get-Content $latest.FullName)
```

### Service Control Diagnostics

The service uses `sc.exe` to control Windows services. You can test manually:

```powershell
# Query service
sc.exe query ServiceName

# Start service
sc.exe start ServiceName

# Stop service
sc.exe stop ServiceName

# Check service status repeatedly
while ($true) {
    sc.exe query ServiceName | Select-String "STATE"
    Start-Sleep -Seconds 1
}
```

### Performance Profiling

To understand service performance:

```powershell
# Measure service execution time
Measure-Command {
    .\dist\backend\progresso_service.exe
}
```

**Expected Times:**
- Starting/stopping services: 1-10 seconds each
- CPU stabilization: Up to 300 seconds (5 minutes)
- File I/O: Milliseconds
- Total: Varies by number of services and system load

### Clean Reinstall

```powershell
# 1. Uninstall service (if installed)
.\services\progresso_service\scripts\uninstall-service.ps1

# 2. Clean build
.\scripts\clean-all.ps1

# 3. Rebuild
.\scripts\build-all.ps1

# 4. Test in console mode
.\run-progresso.ps1

# 5. Install as service (if desired)
.\services\progresso_service\scripts\install-service.ps1
```

---

## Diagnostic Checklist

Before reporting issues, check:

- [ ] Service built successfully
- [ ] `ordem.target.xml` exists and is valid XML
- [ ] Running with administrator privileges (if managing services)
- [ ] Windows services you're trying to manage exist
- [ ] No other instance of progresso_service is running
- [ ] Sufficient disk space in working directory
- [ ] Check `dist\backend\run-progresso.log` for errors
- [ ] Enabled `RUST_BACKTRACE=1` and `RUST_LOG=debug` for detailed errors
- [ ] Progress XML file created (check timestamps)
- [ ] Windows Event Viewer (if running as service)

---

## Getting Help

If you've tried all troubleshooting steps:

1. **Collect diagnostic information:**
   ```powershell
   # Save to file for sharing
   @{
       PSVersion = $PSVersionTable.PSVersion
       WindowsVersion = (Get-WmiObject Win32_OperatingSystem).Caption
       IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
       ExecutablePath = "dist\backend\progresso_service.exe"
       ExecutableExists = Test-Path "dist\backend\progresso_service.exe"
       ConfigExists = Test-Path "dist\backend\ordem.target.xml"
       LastLog = Get-Content "dist\backend\run-progresso.log" -Tail 50 -ErrorAction SilentlyContinue
   } | ConvertTo-Json | Out-File "progresso-diagnostic.json"
   ```

2. **Include in your report:**
   - Output from the command above
   - Exact error messages
   - Steps to reproduce
   - What you expected to happen
   - What actually happened

3. **Check the log files:**
   - `dist\backend\run-progresso.log`
   - Windows Event Viewer (if running as service)
   - Generated `progresso.*.xml` files

---

## Related Documentation

- [README.md](README.md) - Main documentation
- [services/progresso_service/README.md](services/progresso_service/README.md) - Service-specific documentation
