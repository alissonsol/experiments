// Copyright (c) 2025 - Alisson Sol
//
// Service Control Utilities
//
// Provides functions for interacting with Windows services using the `sc` command.
// Includes utilities for querying service state and waiting for state transitions.

// # Service Control Utilities
//
// This module provides a thin wrapper around the Windows `sc.exe` command for
// querying and controlling Windows services.
//
// ## Functions
//
// - run_sc: Execute arbitrary `sc` commands
// - is_service_running: Check if a service is in RUNNING state
// - wait_for_service_state_with_stop: Poll until a service reaches a desired state

use std::process::{Command, Output};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};
use std::thread::sleep;
use std::io;

/// Polling interval for service state checks.
const POLL_INTERVAL: Duration = Duration::from_secs(1);

/// Executes the Windows `sc.exe` command with the provided arguments.
///
/// This is a low-level function that runs `sc` with arbitrary arguments.
/// For common operations, prefer the higher-level functions like
/// [`is_service_running`] or [`wait_for_service_state_with_stop`].
///
/// # Arguments
///
/// * `args` - Command arguments to pass to `sc` (e.g., `["query", "Spooler"]`)
///
/// # Returns
///
/// * `Ok(Output)` - Command executed (check `status` and `stdout` for results)
/// * `Err` - Failed to spawn the process
///
/// # Example
///
/// ```rust,no_run
/// use progresso_service::service_ctrl::run_sc;
///
/// // Query a service
/// let output = run_sc(&["query", "Spooler"]).expect("failed to run sc");
/// println!("stdout: {}", String::from_utf8_lossy(&output.stdout));
///
/// // Start a service
/// let _ = run_sc(&["start", "MyService"]);
/// ```
#[inline]
pub fn run_sc(args: &[&str]) -> io::Result<Output> {
    Command::new("sc").args(args).output()
}

/// Checks if a Windows service is currently in the RUNNING state.
///
/// Queries the service using `sc query` and parses the output to determine
/// if the service is running.
///
/// # Arguments
///
/// * `name` - The Windows service name to query (e.g., "Spooler", "W32Time")
///
/// # Returns
///
/// * `true` - Service exists and is in RUNNING state
/// * `false` - Service is not running, doesn't exist, or query failed
///
/// # Example
///
/// ```rust,no_run
/// use progresso_service::service_ctrl::is_service_running;
///
/// if is_service_running("Spooler") {
///     println!("Print Spooler service is running");
/// }
/// ```
#[inline]
pub fn is_service_running(name: &str) -> bool {
    Command::new("sc")
        .args(["query", name])
        .output()
        .ok()
        .map(|out| {
            String::from_utf8_lossy(&out.stdout)
                .to_lowercase()
                .contains("running")
        })
        .unwrap_or(false)
}

/// Waits for a service to reach a desired state with timeout and cancellation support.
///
/// Polls the service state at 1-second intervals until either:
/// - The desired state is reached (returns `true`)
/// - The timeout expires (returns `false`)
/// - The stop flag is set (returns `false`)
///
/// # Arguments
///
/// * `name` - The Windows service name to monitor
/// * `desired` - The desired state string (e.g., "RUNNING", "STOPPED")
/// * `timeout_secs` - Maximum seconds to wait before giving up
/// * `stop_flag` - Atomic flag for early cancellation; if set to `true`, returns immediately
///
/// # Returns
///
/// * `true` - Service reached the desired state within the timeout
/// * `false` - Timeout expired or cancellation was requested
///
/// # Example
///
/// ```rust,no_run
/// use progresso_service::service_ctrl::wait_for_service_state_with_stop;
/// use std::sync::{Arc, atomic::AtomicBool};
///
/// let stop_flag = Arc::new(AtomicBool::new(false));
///
/// // Wait up to 60 seconds for service to start
/// if wait_for_service_state_with_stop("MyService", "RUNNING", 60, stop_flag) {
///     println!("Service started successfully");
/// } else {
///     println!("Service failed to start or was cancelled");
/// }
/// ```
pub fn wait_for_service_state_with_stop(
    name: &str,
    desired: &str,
    timeout_secs: u64,
    stop_flag: Arc<AtomicBool>,
) -> bool {
    let start = Instant::now();
    let desired_lower = desired.to_lowercase();
    let timeout = Duration::from_secs(timeout_secs);

    while start.elapsed() < timeout {
        // Check for cancellation request
        if stop_flag.load(Ordering::SeqCst) {
            return false;
        }

        // Query current service state
        if let Ok(output) = Command::new("sc").args(["query", name]).output() {
            let stdout = String::from_utf8_lossy(&output.stdout).to_lowercase();
            if stdout.contains(&desired_lower) {
                return true;
            }
        }

        sleep(POLL_INTERVAL);
    }

    false
}
