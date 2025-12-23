// Copyright (c) 2025 - Alisson Sol
//
// Progresso Windows Service
//
// A Windows service that reads target service configurations from `ordem.target.xml`,
// executes service start/stop commands, monitors CPU usage, and writes timestamped
// progress reports. Can run as a Windows service or in console mode.
//
// # Configuration
// Reads from: `ordem.target.xml` in the working directory
// Writes to: `progresso.YYYYMMDD.HHMMSS.xml` with timestamped execution results
//
// # Operation
// 1. Reads target configurations
// 2. For each service, starts/stops based on end_mode
// 3. Waits for CPU usage to drop below threshold (60%)
// 4. Records timestamps for each operation
// 5. Writes incremental progress to XML file

use chrono::Local;
use serde_xml_rs::from_str;
use std::fs;
use std::io::{BufWriter, Write};
use std::sync::{atomic::{AtomicBool, Ordering}, Arc};
use std::thread::sleep;
use std::time::{Duration, Instant};
use sysinfo::System;

use anyhow::Result;
use windows_service::service_control_handler::{self, ServiceControlHandlerResult};
use windows_service::service_dispatcher;
use windows_service::service::{ServiceControl, ServiceControlAccept, ServiceExitCode, ServiceState, ServiceStatus, ServiceType};

use progresso_service::{OrdemTargets, service_ctrl};

/// Windows service name as registered with the Service Control Manager.
const SERVICE_NAME: &str = "ProgressoService";

/// Input configuration file name (must be in working directory).
const INPUT_FILE: &str = "ordem.target.xml";

/// Output file prefix for progress reports.
const OUTPUT_PREFIX: &str = "progresso";

// Performance tuning constants
/// Interval between CPU usage polls.
const CPU_POLL_INTERVAL: Duration = Duration::from_secs(1);
/// Maximum time to wait for CPU to drop below threshold (5 minutes).
const CPU_WAIT_TIMEOUT: Duration = Duration::from_secs(300);
/// Maximum time to wait for a service state transition (1 minute).
const SERVICE_STATE_TIMEOUT: Duration = Duration::from_secs(60);
/// CPU usage threshold percentage - processing continues when below this value.
const CPU_THRESHOLD: f32 = 60.0;
/// Minimum CPU change percentage to report (reduces log spam).
const CPU_REPORT_DELTA: f32 = 5.0;

/// Application entry point.
///
/// Attempts to start as a Windows service first. If that fails (e.g., when run
/// from command line), falls back to console mode for testing and debugging.
fn main() {
    env_logger::init();

    // Try to run as Windows service; falls back to console mode if not launched by SCM
    if let Err(e) = service_dispatcher::start(SERVICE_NAME, service_main) {
        println!("Warning: Not running as service ({}), falling back to console mode", e);

        let stop_flag = Arc::new(AtomicBool::new(false));
        if let Err(e) = run_main(stop_flag) {
            eprintln!("Error: {}", e);
            std::process::exit(1);
        }
    }
}

/// Windows service entry point called by the Service Control Manager.
///
/// Registers a control handler for stop/interrogate commands, signals the service
/// as running, executes the main worker, then signals stopped on completion.
extern "system" fn service_main(_argc: u32, _argv: *mut *mut u16) {
    let stop_flag = Arc::new(AtomicBool::new(false));
    let flag_clone = Arc::clone(&stop_flag);

    // Register handler for service control events (stop, interrogate)
    let status_handle = match service_control_handler::register(SERVICE_NAME, move |event| {
        match event {
            ServiceControl::Stop | ServiceControl::Interrogate => {
                flag_clone.store(true, Ordering::SeqCst);
                ServiceControlHandlerResult::NoError
            }
            _ => ServiceControlHandlerResult::NotImplemented,
        }
    }) {
        Ok(handle) => handle,
        Err(e) => {
            eprintln!("Failed to register service control handler: {}", e);
            return;
        }
    };

    // Notify SCM that the service is now running
    let running_status = ServiceStatus {
        service_type: ServiceType::OWN_PROCESS,
        current_state: ServiceState::Running,
        controls_accepted: ServiceControlAccept::STOP,
        exit_code: ServiceExitCode::Win32(0),
        checkpoint: 0,
        wait_hint: Duration::from_secs(10),
        process_id: None,
    };
    let _ = status_handle.set_service_status(running_status);

    // Execute main processing loop
    if let Err(e) = run_main(Arc::clone(&stop_flag)) {
        eprintln!("Service worker error: {}", e);
    }

    // Notify SCM that the service has stopped
    let stopped_status = ServiceStatus {
        service_type: ServiceType::OWN_PROCESS,
        current_state: ServiceState::Stopped,
        controls_accepted: ServiceControlAccept::empty(),
        exit_code: ServiceExitCode::Win32(0),
        checkpoint: 0,
        wait_hint: Duration::from_secs(0),
        process_id: None,
    };
    let _ = status_handle.set_service_status(stopped_status);
}

/// Main worker function that processes all target services.
///
/// Workflow for each service:
/// 1. Records start processing timestamp
/// 2. Checks current running state
/// 3. Starts or stops service based on `end_mode` configuration
/// 4. Waits for state transition to complete
/// 5. Waits for CPU usage to drop below threshold
/// 6. Records completion timestamps
/// 7. Writes incremental progress to output file
///
/// # Arguments
///
/// * `stop_flag` - Atomic flag for graceful shutdown signaling. When set to `true`,
///   the function will complete the current service and exit the loop.
///
/// # Returns
///
/// * `Ok(())` - All services processed (or stopped early via flag)
/// * `Err` - File I/O or XML parsing failed
fn run_main(stop_flag: Arc<AtomicBool>) -> Result<()> {
    // Read and parse input configuration
    let raw_xml = fs::read_to_string(INPUT_FILE)?;
    let ordem: OrdemTargets = from_str(&raw_xml).unwrap_or_default();

    // Create timestamped output file
    let timestamp = Local::now().format("%Y%m%d.%H%M%S");
    let output_path = format!("{}.{}.xml", OUTPUT_PREFIX, timestamp);
    fs::File::create(&output_path)?;

    // Pre-allocate progress tracking with known capacity
    let mut progress = OrdemTargets::with_capacity(ordem.len());

    // Initialize CPU monitoring system
    let mut sys = System::new_all();

    print_header(ordem.len());

    for mut svc in ordem.services {
        // Check for graceful shutdown request
        if stop_flag.load(Ordering::SeqCst) {
            eprintln!("Stop requested before processing next service");
            break;
        }

        svc.record_start_processing();

        // Extract service name - check early to avoid unnecessary work
        // Clone the name string to avoid borrow checker issues (we need mutable access to svc later)
        let svc_name = match svc.name() {
            Some(name) => name.to_string(),
            None => {
                log::warn!("Skipping service with empty or missing name");
                println!("  Skipping service with empty name");
                continue;
            }
        };

        println!("[{}] Processing service...", svc_name);

        // Capture initial state before any modifications
        let was_running = service_ctrl::is_service_running(&svc_name);
        svc.record_stop();
        svc.record_end();

        // Process based on end_mode configuration
        // Clone end_mode to avoid borrow checker complexity (it's a small string)
        if let Some(end_mode) = svc.end_mode.clone() {
            process_service_action(&mut svc, &svc_name, &end_mode, was_running, &stop_flag);
        } else {
            println!("  - No end_mode configured, skipping");
        }

        // Wait for system CPU to stabilize before processing next service
        wait_for_cpu_stable(&mut sys, &mut svc, &stop_flag);

        // Save progress incrementally after each service
        progress.services.push(svc);
        write_progress_file(&progress, &output_path)?;
        println!();
    }

    print_footer(&output_path);
    Ok(())
}

/// Executes the start or stop action for a service based on its end_mode.
///
/// # Arguments
///
/// * `svc` - Service entry to update with timestamps
/// * `svc_name` - Service name for sc.exe commands
/// * `end_mode` - Target end mode (contains "automatic" to start, otherwise stop)
/// * `was_running` - Whether the service was running before this action
/// * `stop_flag` - Graceful shutdown flag
///
/// # Performance Notes
///
/// - Borrows strings instead of cloning to reduce allocations
/// - Early returns when service is already in desired state
fn process_service_action(
    svc: &mut progresso_service::ServiceEntry,
    svc_name: &str,
    end_mode: &str,
    was_running: bool,
    stop_flag: &Arc<AtomicBool>,
) {
    // Determine action based on end_mode (avoid multiple string comparisons)
    let should_start = end_mode.to_lowercase().contains("automatic");
    let timeout_secs = SERVICE_STATE_TIMEOUT.as_secs();

    if should_start {
        if was_running {
            log::info!("Service '{}' already running (target: {}); skipping.", svc_name, end_mode);
            println!("  Already running (target: {})", end_mode);
        } else {
            log::info!("Starting '{}' (target: {}).", svc_name, end_mode);
            println!("  Starting service (target: {})...", end_mode);
            let _ = service_ctrl::run_sc(&["start", svc_name]);

            if service_ctrl::wait_for_service_state_with_stop(svc_name, "RUNNING", timeout_secs, Arc::clone(stop_flag)) {
                println!("  Started successfully");
            } else {
                log::warn!("Starting '{}' failed.", svc_name);
                println!("  Failed to start");
            }
            svc.record_end();
        }
    } else if !was_running {
        log::info!("Service '{}' already stopped (target: {}); skipping.", svc_name, end_mode);
        println!("  Already stopped (target: {})", end_mode);
    } else {
        log::info!("Stopping '{}' (target: {}).", svc_name, end_mode);
        println!("  Stopping service (target: {})...", end_mode);
        let _ = service_ctrl::run_sc(&["stop", svc_name]);

        if service_ctrl::wait_for_service_state_with_stop(svc_name, "STOPPED", timeout_secs, Arc::clone(stop_flag)) {
            println!("  Stopped successfully");
        } else {
            log::warn!("Stopping '{}' failed.", svc_name);
            println!("  Failed to stop");
        }
        svc.record_stop();
    }
}

/// Waits for CPU usage to drop below the threshold before continuing.
///
/// This ensures the system is responsive before processing the next service,
/// preventing overload scenarios. Implements adaptive polling with delta-based
/// reporting to reduce console spam.
///
/// # Arguments
///
/// * `sys` - System info handle for CPU monitoring (reused across calls for efficiency)
/// * `svc` - Service entry to record CPU responsive timestamp
/// * `stop_flag` - Graceful shutdown flag for early termination
///
/// # Behavior
///
/// - Polls CPU usage every second
/// - Reports only when usage changes by ≥5% (see [`CPU_REPORT_DELTA`])
/// - Times out after 5 minutes (see [`CPU_WAIT_TIMEOUT`])
/// - Records timestamp when CPU drops below threshold or on timeout/cancellation
///
/// # Performance Notes
///
/// - Reuses System instance to avoid re-initialization overhead
/// - Uses atomic operations for thread-safe cancellation
fn wait_for_cpu_stable(
    sys: &mut System,
    svc: &mut progresso_service::ServiceEntry,
    stop_flag: &Arc<AtomicBool>,
) {
    println!("  Waiting for CPU below {}%...", CPU_THRESHOLD);

    let start_wait = Instant::now();
    let mut last_reported_usage = -1.0_f32;

    loop {
        // Check for shutdown request (fast path - atomic load)
        if stop_flag.load(Ordering::SeqCst) {
            log::info!("Stop requested while waiting for CPU");
            println!("  Stop requested");
            svc.record_cpu_responsive();
            break;
        }

        sys.refresh_cpu_all();
        let usage = sys.global_cpu_usage();

        // Report significant CPU changes to avoid log spam
        if (usage - last_reported_usage).abs() >= CPU_REPORT_DELTA {
            println!("    CPU: {:.1}%", usage);
            last_reported_usage = usage;
        }

        // Check threshold (success case)
        if usage < CPU_THRESHOLD {
            println!("  CPU below threshold ({:.1}%)", usage);
            svc.record_cpu_responsive();
            break;
        }

        // Check timeout (failure case - CPU still high)
        if start_wait.elapsed() > CPU_WAIT_TIMEOUT {
            log::warn!(
                "CPU wait timeout reached after {} seconds (current: {:.1}%)",
                CPU_WAIT_TIMEOUT.as_secs(),
                usage
            );
            println!("  CPU wait timeout reached ({:.1}%)", usage);
            svc.record_cpu_responsive();
            break;
        }

        sleep(CPU_POLL_INTERVAL);
    }
}

/// Prints the processing header with service count.
#[inline]
fn print_header(service_count: usize) {
    println!("\n========================================");
    println!("Processing {} service(s)", service_count);
    println!("========================================\n");
}

/// Prints the completion footer with output file path.
#[inline]
fn print_footer(output_path: &str) {
    println!("========================================");
    println!("Processing complete!");
    println!("Progress file: {}", output_path);
    println!("========================================\n");
}

/// Writes the current progress data to an XML file with proper formatting.
///
/// Creates a complete XML document with declaration header and serialized progress data.
/// Uses buffered I/O for efficiency when writing incrementally after each service.
///
/// # Arguments
///
/// * `progress` - The progress data to serialize
/// * `path` - Output file path (will be overwritten)
///
/// # Returns
///
/// * `Ok(())` - File written successfully
/// * `Err` - Serialization or file I/O failed
fn write_progress_file(progress: &OrdemTargets, path: &str) -> Result<()> {
    let xml_body = progresso_service::write_progress_xml(progress)
        .map_err(|e| {
            eprintln!("Failed to serialize progress to XML: {}", e);
            anyhow::anyhow!("serialize error: {}", e)
        })?;

    let file = fs::File::create(path)?;
    let mut writer = BufWriter::new(file);
    writeln!(writer, "<?xml version=\"1.0\" encoding=\"utf-8\"?>")?;
    writer.write_all(xml_body.as_bytes())?;
    writer.flush()?;

    Ok(())
}
