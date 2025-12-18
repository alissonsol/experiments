# VC++ Redistributable Auto-Installation Fix

## Problem

On machines without the Microsoft Visual C++ Redistributable installed, the `ordem_service.exe` fails to start with the error:

```
The code execution cannot proceed because vcruntime140.dll was not found.
Reinstalling the program may fix this problem.
```

This happens because Rust executables on Windows depend on the Visual C++ Runtime.

## Solution

The [run-ordem.ps1](run-ordem.ps1) launcher script now automatically detects and installs the missing VC++ Redistributable.

## How It Works

### Detection Phase

The script checks for `vcruntime140.dll` in:
- `C:\Windows\System32\vcruntime140.dll`
- `C:\Windows\SysWOW64\vcruntime140.dll`

### Installation Phase (if missing)

1. **Check for winget**: Verifies Windows Package Manager is available
2. **Automatic Installation**: Runs the following command:
   ```powershell
   winget install --id Microsoft.VCRedist.2015+.x64 --exact --accept-package-agreements --accept-source-agreements
   ```
3. **Fallback**: If winget is unavailable, provides manual installation instructions

### Output Examples

#### When VC++ is Already Installed
```
Checking runtime dependencies...
✓ Microsoft Visual C++ Redistributable found
```

#### When Auto-Installation Succeeds
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

#### When Manual Installation is Required
```
Checking runtime dependencies...

========================================
Missing Runtime Dependency
========================================

The Microsoft Visual C++ Redistributable is required but not found.
This is needed to run the ordem service executable.

Attempting to install it automatically using winget...

winget is not available on this system.

Please install the Microsoft Visual C++ Redistributable manually:
  1. Visit: https://aka.ms/vs/17/release/vc_redist.x64.exe
  2. Download and run the installer
  3. Restart this script

Cannot continue without VC++ Redistributable.
```

## Code Implementation

The check is implemented in [run-ordem.ps1](run-ordem.ps1) lines 140-214:

```powershell
# Check if vcruntime140.dll is available
$vcRuntimeFound = $false
$systemPaths = @(
    "$env:SystemRoot\System32",
    "$env:SystemRoot\SysWOW64"
)

foreach ($path in $systemPaths) {
    if (Test-Path (Join-Path $path "vcruntime140.dll")) {
        $vcRuntimeFound = $true
        break
    }
}

if (-not $vcRuntimeFound) {
    # Attempt automatic installation via winget
    # ... (see full code in run-ordem.ps1)
}
```

## winget Exit Codes Handled

| Exit Code | Meaning | Action |
|-----------|---------|--------|
| 0 | Success | Continue normally |
| -1978335189 (0x8A15000B) | Already installed | Continue normally |
| Other | Installation issue | Show warning but attempt to continue |

## Manual Installation

If automatic installation fails or winget is unavailable, users can install manually:

### Direct Download
- **x64 (64-bit)**: https://aka.ms/vs/17/release/vc_redist.x64.exe
- **x86 (32-bit)**: https://aka.ms/vs/17/release/vc_redist.x86.exe

### Using winget (if available)
```powershell
winget install --id Microsoft.VCRedist.2015+.x64
```

### Using Chocolatey (if available)
```powershell
choco install vcredist140
```

## Why This is Required

Rust uses the MSVC (Microsoft Visual C++) toolchain on Windows, which produces executables that link against the VC++ runtime libraries:

- **vcruntime140.dll** - Visual C++ Runtime
- **msvcp140.dll** - C++ Standard Library
- **concrt140.dll** - Concurrency Runtime (if used)

These DLLs are not included with Windows by default and must be installed separately.

## Deployment Considerations

### For Distribution Packages

When distributing `ordem_service.exe` to other machines:

1. **Use run-ordem.ps1**: This ensures dependencies are checked and installed
2. **Include README**: Mention VC++ Redistributable requirement
3. **Pre-installed Systems**: Many systems already have this from other software

### For Development Machines

Development machines with Visual Studio or Rust toolchain usually have these DLLs already installed. The issue typically occurs on:

- Clean Windows installations
- Virtual machines
- Servers without development tools
- End-user machines

## Testing the Fix

### Test on Clean System

1. Use a clean Windows VM or system
2. Ensure VC++ Redistributable is NOT installed
3. Run `.\run-ordem.ps1`
4. Verify automatic installation occurs
5. Confirm service starts successfully

### Test with Existing Installation

1. On a system with VC++ already installed
2. Run `.\run-ordem.ps1`
3. Verify it detects the existing installation
4. Confirm no unnecessary reinstallation

## Alternative Approaches Considered

### 1. Static Linking (Not Used)
**Pros:**
- No runtime dependency
- Single portable executable

**Cons:**
- Larger executable size
- Licensing complications
- Still requires Visual Studio redistributable license

### 2. Bundle DLLs with Executable (Not Used)
**Pros:**
- Self-contained distribution

**Cons:**
- Licensing issues (cannot redistribute VC++ DLLs)
- Microsoft explicitly prohibits this
- Violates VC++ Redistributable license terms

### 3. Auto-Installation (CHOSEN)
**Pros:**
- Legal and compliant
- Automatic and user-friendly
- Uses official Microsoft packages
- Minimal distribution size

**Cons:**
- Requires internet connection for first run
- Needs winget or manual installation

## Troubleshooting

### Issue: winget not found

**Solution 1**: Install App Installer from Microsoft Store
```
ms-windows-store://pdp/?ProductId=9NBLGGH4NNS1
```

**Solution 2**: Manual VC++ installation (see above)

**Solution 3**: Install winget manually
```powershell
# Windows 11 / Server 2022: Usually pre-installed
# Windows 10: May need App Installer from Store
```

### Issue: Installation requires admin rights

Some systems may require administrator privileges to install VC++ Redistributable.

**Solution**: Right-click PowerShell and "Run as Administrator" before running the script

### Issue: Corporate firewall blocks winget

On corporate networks, winget may be blocked.

**Solution 1**: Contact IT to whitelist winget sources

**Solution 2**: Request IT to pre-install VC++ Redistributable on all machines

**Solution 3**: Download offline installer:
```powershell
# Download from: https://aka.ms/vs/17/release/vc_redist.x64.exe
# Run installer manually
```

## Related Documentation

- [DIAGNOSTICS.md](DIAGNOSTICS.md) - Full service diagnostics documentation
- [DIAGNOSTIC-REFERENCE.txt](DIAGNOSTIC-REFERENCE.txt) - Quick reference card
- [run-ordem.ps1](run-ordem.ps1) - Launcher script with VC++ check

## Version Information

- **VC++ Redistributable Version**: Microsoft Visual C++ 2015-2022 Redistributable (v14.x)
- **Package ID**: `Microsoft.VCRedist.2015+.x64`
- **Target Architecture**: x64 (64-bit)
- **Compatibility**: Windows 7 SP1 and later

## Summary

The `vcruntime140.dll` issue has been resolved by adding an automatic detection and installation mechanism in the launcher script. Users will experience:

1. Automatic detection of missing VC++ runtime
2. Automatic installation via winget (when available)
3. Clear manual installation instructions (when winget unavailable)
4. No silent failures due to missing dependencies

This ensures the ordem service runs successfully on all Windows machines, regardless of whether they have development tools installed.
