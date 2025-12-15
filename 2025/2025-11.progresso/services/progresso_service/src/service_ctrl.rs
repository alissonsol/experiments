// Copyright (c) 2025 - Alisson Sol
//
use std::process::Command;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::time::{Duration, Instant};
use std::thread::sleep;

pub fn run_sc(args: &[&str]) -> std::io::Result<std::process::Output> {
    Command::new("sc").args(args).output()
}

pub fn is_service_running(name: &str) -> bool {
    Command::new("sc")
        .arg("query")
        .arg(name)
        .output()
        .ok()
        .map(|out| String::from_utf8_lossy(&out.stdout).to_lowercase().contains("running"))
        .unwrap_or(false)
}

pub fn wait_for_service_state_with_stop(name: &str, desired: &str, timeout_secs: u64, stop_flag: Arc<AtomicBool>) -> bool {
    let start = Instant::now();
    let desired_lower = desired.to_lowercase();
    let timeout = Duration::from_secs(timeout_secs);
    let poll_interval = Duration::from_secs(1);

    while start.elapsed() < timeout {
        if stop_flag.load(std::sync::atomic::Ordering::SeqCst) {
            return false;
        }

        if let Ok(out) = Command::new("sc").arg("query").arg(name).output() {
            if String::from_utf8_lossy(&out.stdout).to_lowercase().contains(&desired_lower) {
                return true;
            }
        }

        sleep(poll_interval);
    }
    false
}
