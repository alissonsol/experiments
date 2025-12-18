// Copyright (c) 2025 - Alisson Sol
//
// Mock Service Control Tests
//
// Tests service_ctrl module functionality using a mock `sc` command that simulates
// Windows service query responses. This allows testing on any platform without
// requiring actual Windows services.

use std::env;
use std::fs::File;
use std::io::Write;
use std::path::PathBuf;
use std::sync::{Arc, atomic::AtomicBool};

use tempfile::TempDir;

use progresso_service::service_ctrl;

/// Creates a mock `sc` script in the given directory.
///
/// The mock script responds to `sc query <service>` commands:
/// - "RunningSvc" returns RUNNING state
/// - Any other service returns STOPPED state
///
/// # Arguments
///
/// * `dir` - Temporary directory to create the script in
///
/// # Returns
///
/// Path to the created script
fn create_mock_sc_script(dir: &TempDir) -> PathBuf {
    let script_path = if cfg!(windows) {
        let path = dir.path().join("sc.bat");
        let mut file = File::create(&path).expect("create sc.bat");

        // Windows batch script that mocks sc.exe query command
        writeln!(file, "@echo off").unwrap();
        writeln!(file, r#"if "%1"=="query" ("#).unwrap();
        writeln!(file, r#"  if "%2"=="RunningSvc" ("#).unwrap();
        writeln!(file, "    echo SERVICE_NAME: %2").unwrap();
        writeln!(file, "    echo         STATE              : 4  RUNNING").unwrap();
        writeln!(file, "    exit /b 0").unwrap();
        writeln!(file, "  ) else (").unwrap();
        writeln!(file, "    echo SERVICE_NAME: %2").unwrap();
        writeln!(file, "    echo         STATE              : 1  STOPPED").unwrap();
        writeln!(file, "    exit /b 0").unwrap();
        writeln!(file, "  )").unwrap();
        writeln!(file, ")").unwrap();
        writeln!(file, "exit /b 0").unwrap();

        path
    } else {
        let path = dir.path().join("sc");
        let mut file = File::create(&path).expect("create sc");

        // Unix shell script that mocks sc command
        writeln!(file, "#!/bin/sh").unwrap();
        writeln!(file, r#"if [ "$1" = "query" ]; then"#).unwrap();
        writeln!(file, r#"  if [ "$2" = "RunningSvc" ]; then"#).unwrap();
        writeln!(file, "    echo SERVICE_NAME: $2").unwrap();
        writeln!(file, "    echo '        STATE              : 4  RUNNING'").unwrap();
        writeln!(file, "    exit 0").unwrap();
        writeln!(file, "  else").unwrap();
        writeln!(file, "    echo SERVICE_NAME: $2").unwrap();
        writeln!(file, "    echo '        STATE              : 1  STOPPED'").unwrap();
        writeln!(file, "    exit 0").unwrap();
        writeln!(file, "  fi").unwrap();
        writeln!(file, "fi").unwrap();
        writeln!(file, "exit 0").unwrap();

        // Make script executable on Unix
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        }

        path
    };

    script_path
}

/// Prepends a directory to the PATH environment variable.
///
/// # Returns
///
/// The original PATH value (for restoration)
fn prepend_to_path(dir: &TempDir) -> std::ffi::OsString {
    let original_path = env::var_os("PATH").unwrap_or_default();

    let mut paths = vec![dir.path().to_path_buf()];
    paths.extend(env::split_paths(&original_path));

    let new_path = env::join_paths(paths).expect("join paths");
    env::set_var("PATH", &new_path);

    original_path
}

/// Tests service_ctrl functions using a mock sc command.
///
/// This test:
/// 1. Creates a mock `sc` script in a temp directory
/// 2. Prepends that directory to PATH so the mock is found first
/// 3. Tests is_service_running() with running and stopped services
/// 4. Tests wait_for_service_state_with_stop() with various scenarios
/// 5. Restores the original PATH
#[test]
fn test_is_service_running_and_wait() {
    // Setup: create mock sc and modify PATH
    let temp_dir = TempDir::new().expect("create temp directory");
    let _script_path = create_mock_sc_script(&temp_dir);
    let original_path = prepend_to_path(&temp_dir);

    // Test 1: is_service_running() detects running service
    assert!(
        service_ctrl::is_service_running("RunningSvc"),
        "RunningSvc should be detected as running"
    );

    // Test 2: is_service_running() detects stopped service
    assert!(
        !service_ctrl::is_service_running("OtherSvc"),
        "OtherSvc should be detected as stopped"
    );

    // Test 3: wait_for_service_state_with_stop() succeeds for running service
    let stop_flag = Arc::new(AtomicBool::new(false));
    let result = service_ctrl::wait_for_service_state_with_stop(
        "RunningSvc",
        "RUNNING",
        2,
        Arc::clone(&stop_flag),
    );
    assert!(result, "Should detect RunningSvc as RUNNING");

    // Test 4: wait_for_service_state_with_stop() times out for stopped service
    let stop_flag = Arc::new(AtomicBool::new(false));
    let result = service_ctrl::wait_for_service_state_with_stop(
        "OtherSvc",
        "RUNNING",
        2,
        Arc::clone(&stop_flag),
    );
    assert!(!result, "Should timeout waiting for OtherSvc RUNNING");

    // Test 5: Early cancellation via stop flag
    let stop_flag = Arc::new(AtomicBool::new(true)); // Pre-set to cancelled
    let result = service_ctrl::wait_for_service_state_with_stop(
        "RunningSvc",
        "RUNNING",
        10,
        Arc::clone(&stop_flag),
    );
    assert!(!result, "Should return false immediately when stop flag is set");

    // Cleanup: restore original PATH
    env::set_var("PATH", &original_path);
}
