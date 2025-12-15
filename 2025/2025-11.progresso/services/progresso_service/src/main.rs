mod service_ctrl;

// Copyright (c) 2025 - Alisson Sol
//
use chrono::Local;
use serde_xml_rs::from_str;
use std::fs;
use std::io::Write;
// std::process::Command used in service_ctrl module
use std::sync::{atomic::{AtomicBool, Ordering}, Arc};
use std::thread::sleep;
use std::time::{Duration, Instant};
use sysinfo::System;

use anyhow::Result;
use std::io::BufWriter;
use windows_service::service_control_handler::{self, ServiceControlHandlerResult};
use windows_service::service_dispatcher;
use windows_service::service::{ServiceControl, ServiceControlAccept, ServiceExitCode, ServiceState, ServiceStatus, ServiceType};

use progresso_service::OrdemTargets;

const SERVICE_NAME: &str = "ProgressoService";

fn main() {
    env_logger::init();

    // Try to run as service; if that fails, run as console
    match service_dispatcher::start(SERVICE_NAME, service_main) {
        Ok(_) => return, // service completed
        Err(e) => {
            eprintln!("Not running as service ({}), falling back to console mode", e);
        }
    }

    let stop_flag = Arc::new(AtomicBool::new(false));
    if let Err(e) = run_main(stop_flag.clone()) {
        eprintln!("Error: {}", e);
        std::process::exit(1);
    }
}

extern "system" fn service_main(_argc: u32, _argv: *mut *mut u16) {
    // register service control handler
    let stop_flag = Arc::new(AtomicBool::new(false));
    let flag_clone = stop_flag.clone();

    let status_handle = match service_control_handler::register(SERVICE_NAME, move |control_event| {
        match control_event {
            ServiceControl::Stop | ServiceControl::Interrogate => {
                flag_clone.store(true, Ordering::SeqCst);
                ServiceControlHandlerResult::NoError
            }
            _ => ServiceControlHandlerResult::NotImplemented,
        }
    }) {
        Ok(h) => h,
        Err(e) => {
            eprintln!("Failed to register service control handler: {}", e);
            return;
        }
    };

    // tell SCM that we're running
    let status = ServiceStatus {
        service_type: ServiceType::OWN_PROCESS,
        current_state: ServiceState::Running,
        controls_accepted: ServiceControlAccept::STOP,
        exit_code: ServiceExitCode::Win32(0),
        checkpoint: 0,
        wait_hint: Duration::from_secs(10),
        process_id: None,
    };

    let _ = status_handle.set_service_status(status);

    // run main worker
    if let Err(e) = run_main(stop_flag.clone()) {
        eprintln!("Service worker error: {}", e);
    }

    // signal stopped
    let _ = status_handle.set_service_status(ServiceStatus {
        service_type: ServiceType::OWN_PROCESS,
        current_state: ServiceState::Stopped,
        controls_accepted: ServiceControlAccept::empty(),
        exit_code: ServiceExitCode::Win32(0),
        checkpoint: 0,
        wait_hint: Duration::from_secs(0),
        process_id: None,
    });
}

fn run_main(stop_flag: Arc<AtomicBool>) -> Result<()> {
    let ordem_path = "ordem.target.xml";
    let raw = fs::read_to_string(ordem_path)?;
    let ordem: OrdemTargets = from_str(&raw).unwrap_or_default();
    let timestamp = Local::now().format("%Y%m%d.%H%M%S");
    let progresso_path = format!("progresso.{}.xml", timestamp);

    fs::File::create(&progresso_path)?;

    let mut progress = OrdemTargets::default();
    progress.services.reserve(ordem.services.len());

    // CPU monitor
    let mut sys = System::new_all();
    let cpu_threshold = 60.0_f32; // percent; could be made configurable

    println!("\n========================================");
    println!("Processing {} service(s)", ordem.services.len());
    println!("========================================\n");

    for mut svc in ordem.services {
        if stop_flag.load(Ordering::SeqCst) {
            eprintln!("Stop requested before processing next service");
            break;
        }

        let now = Local::now();
        svc.start_processing_time = Some(now.to_rfc3339());

        let Some(svc_name) = svc.name.as_deref().filter(|n| !n.is_empty()) else {
            log::warn!("Skipping service with empty name");
            println!("⚠ Skipping service with empty name");
            continue;
        };

        println!("[{}] Processing service...", svc_name);

        // Remember whether it was running before we start any actions
        let was_running = service_ctrl::is_service_running(svc_name);
        svc.stop_time = Some(now.to_rfc3339());
        svc.end_time = Some(now.to_rfc3339());

        if let Some(et) = &svc.end_mode {
            let should_start = et.to_lowercase().contains("automatic");

            if should_start {
                if was_running {
                    log::info!("Service '{}' already running and target end_mode is '{}'; skipping.", svc_name, et);
                    println!("  ✓ Already running (target: {})", et);
                } else {
                    log::info!("Starting '{}' with target end_mode '{}'.", svc_name, et);
                    println!("  → Starting service (target: {})...", et);
                    let _ = service_ctrl::run_sc(&["start", svc_name]);
                    if !service_ctrl::wait_for_service_state_with_stop(svc_name, "RUNNING", STOP_TIMEOUT_SECS, Arc::clone(&stop_flag)) {
                        log::warn!("Starting '{}' failed.", svc_name);
                        println!("  ✗ Failed to start");
                    } else {
                        println!("  ✓ Started successfully");
                    }
                    svc.end_time = Some(Local::now().to_rfc3339());
                }
            } else {
                if !was_running {
                    log::info!("Service '{}' already stopped and target end_mode is '{}'; skipping.", svc_name, et);
                    println!("  ✓ Already stopped (target: {})", et);
                    svc.stop_time.get_or_insert_with(|| Local::now().to_rfc3339());
                } else {
                    log::info!("Stopping '{}' with target end_mode '{}'.", svc_name, et);
                    println!("  → Stopping service (target: {})...", et);
                    let _ = service_ctrl::run_sc(&["stop", svc_name]);
                    if !service_ctrl::wait_for_service_state_with_stop(svc_name, "STOPPED", STOP_TIMEOUT_SECS, Arc::clone(&stop_flag)) {
                        log::warn!("Stopping '{}' failed.", svc_name);
                        println!("  ✗ Failed to stop");
                    } else {
                        println!("  ✓ Stopped successfully");
                    }
                    svc.stop_time = Some(Local::now().to_rfc3339());
                }
            }
        } else {
            println!("  - No end_mode configured, skipping");
        }

        // Wait for CPU below threshold
        println!("  → Waiting for CPU below {}%...", cpu_threshold);
        let start_wait = Instant::now();
        let mut last_reported_usage = -1.0_f32;
        loop {
            if stop_flag.load(Ordering::SeqCst) {
                log::info!("Stop requested while waiting for CPU");
                println!("  ! Stop requested");
                svc.cpu_responsive_time = Some(Local::now().to_rfc3339());
                break;
            }
            sys.refresh_cpu_all();
            let usage = sys.global_cpu_usage();

            // Report CPU usage every 5% change
            if (usage - last_reported_usage).abs() >= 5.0 {
                println!("    CPU: {:.1}%", usage);
                last_reported_usage = usage;
            }

            if usage < cpu_threshold {
                println!("  ✓ CPU below threshold ({:.1}%)", usage);
                svc.cpu_responsive_time = Some(Local::now().to_rfc3339());
                break;
            }
            if start_wait.elapsed() > Duration::from_secs(CPU_WAIT_TIMEOUT_SECS) {
                println!("  ⏱ CPU wait timeout reached ({:.1}%)", usage);
                // give up after configured timeout
                svc.cpu_responsive_time = Some(Local::now().to_rfc3339());
                break;
            }
            sleep(CPU_POLL_INTERVAL);
        }

        progress.services.push(svc);
        // write progress file after each service
        write_progress_file(&progress, &progresso_path)?;
        println!();
    }

    println!("========================================");
    println!("Processing complete!");
    println!("Progress file: {}", progresso_path);
    println!("========================================\n");
    Ok(())
}

const CPU_POLL_INTERVAL: Duration = Duration::from_secs(1);
const CPU_WAIT_TIMEOUT_SECS: u64 = 300;
const STOP_TIMEOUT_SECS: u64 = 60;

fn write_progress_file(progress: &OrdemTargets, path: &str) -> Result<()> {
    let xml_body = progresso_service::write_progress_xml(progress)
        .map_err(|e| {
            eprintln!("Failed to serialize progress to XML: {}", e);
            anyhow::anyhow!("serialize error: {}", e)
        })?;

    let f = fs::File::create(path)?;
    let mut w = BufWriter::new(f);
    write!(w, "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n")?;
    w.write_all(xml_body.as_bytes())?;
    w.flush()?;
    Ok(())
}

// service control helpers are implemented in src/service_ctrl.rs and used via crate::service_ctrl
