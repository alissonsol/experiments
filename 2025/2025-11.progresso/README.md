# Progresso

A Windows service for monitoring and tracking the progress of Windows services based on target configurations.

Source: [gibhub.com/alissonsol](https://github.com/alissonsol)  
Copyright (c) 2025, Alisson Sol - All rights reserved.

## Overview

Progresso is a Windows service written in Rust that:
- Reads a target configuration file (`ordem.target.xml`) containing a list of Windows services to monitor
- Tracks the status and progress of these services
- Generates progress reports with timestamps for service lifecycle events
- Can run as a Windows service or in console mode for testing

## Project Structure

```
progresso/
├── scripts/                    # Build and distribution scripts
│   ├── build-all.ps1          # Main build script (uses Cargo)
│   ├── clean-all.ps1          # Clean build artifacts
│   └── dist-all.ps1           # Create distribution package
├── services/
│   └── progresso_service/     # Main service implementation
│       ├── src/
│       │   ├── main.rs        # Service entry point and Windows service integration
│       │   ├── lib.rs         # Core data structures and XML parsing
│       │   └── service_ctrl.rs # Service control utilities
│       ├── examples/
│       │   └── harness.rs     # Example/test harness
│       ├── tests/             # Unit tests
│       ├── scripts/           # Service installation scripts
│       │   ├── install-service.ps1
│       │   └── uninstall-service.ps1
│       └── Cargo.toml         # Rust dependencies
├── dist/                      # Build output directory
│   └── backend/
│       └── progresso_service.exe
├── BUILD.bazel                # Bazel build configuration (optional)
├── MODULE.bazel               # Bazel module configuration (optional)
└── ordem.target.xml           # Sample target configuration

```

## Building

### Prerequisites

- **Rust** (1.70+): Install from [rustup.rs](https://rustup.rs/)
- **PowerShell** (for build scripts)

### Build Commands

```powershell
# Build the service
.\scripts\build-all.ps1

# Clean build artifacts
.\scripts\clean-all.ps1

# Create distribution package
.\scripts\dist-all.ps1
```

The build script uses **Cargo** (Rust's native build tool) instead of Bazel due to Windows symlink limitations with Bazel's `rules_rust`. If you want to use Bazel, you need to enable Windows Developer Mode first.

### Build Output

- Binary: `dist/backend/progresso_service.exe`
- Distribution package: `progresso-dist-YYYYMMDD-HHMMSS.zip`

## Configuration

### Target Configuration File (`ordem.target.xml`)

The service reads an XML file containing the list of Windows services to monitor:

```xml
<OrdemTargets>
  <Service>
    <name>ServiceName</name>
    <description>Service Description</description>
    <status>Running</status>
    <start_mode>Auto</start_mode>
    <end_mode>Auto</end_mode>
    <log_on_as>LocalSystem</log_on_as>
    <path>C:\Path\To\Service.exe</path>
  </Service>
  <!-- More services... -->
</OrdemTargets>
```

### Progress Output

The service generates progress reports with additional timestamp fields:
- `start_processing_time`: When processing started
- `stop_time`: When the service stopped
- `end_time`: When processing ended
- `cpu_responsive_time`: CPU responsiveness timestamp

## Running

### Console Mode (for testing)

```powershell
cd dist/backend
.\progresso_service.exe
```

The service will automatically fall back to console mode if not running as a Windows service.

### As a Windows Service

```powershell
# Install the service
cd services/progresso_service/scripts
.\install-service.ps1

# Uninstall the service
.\uninstall-service.ps1
```

## Code Structure

### Core Components

1. **`lib.rs`** - Core library
   - `OrdemTargets`: Root structure for service list
   - `ServiceEntry`: Individual service information
   - `parse_ordem()`: Parse XML configuration
   - `write_progress_xml()`: Generate progress XML
   - `populate_test_timestamps()`: Add timestamps for testing

2. **`main.rs`** - Service entry point
   - Windows service integration using `windows-service` crate
   - Service control handler (start/stop)
   - Console mode fallback
   - Main processing loop

3. **`service_ctrl.rs`** - Service control utilities
   - Helper functions for service management

### Dependencies

- **serde** / **serde-xml-rs**: XML serialization/deserialization
- **windows-service**: Windows service API integration
- **sysinfo**: System and CPU monitoring
- **chrono**: Timestamp generation
- **anyhow**: Error handling
- **log** / **env_logger**: Logging

## Development

### Running Tests

```powershell
cd services/progresso_service
cargo test
```

### Running Examples

```powershell
cd services/progresso_service
cargo run --example harness
```

This will read `ordem.target.xml` and generate `progresso.example.xml` with populated timestamps.

## License

[Specify your license here]