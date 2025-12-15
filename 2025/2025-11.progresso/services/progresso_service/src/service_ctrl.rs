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
    match Command::new("sc").arg("query").arg(name).output() {
        Ok(out) => {
            let s = String::from_utf8_lossy(&out.stdout).to_string();
            s.to_lowercase().contains("running")
        }
        Err(_) => false,
    }
}

pub fn wait_for_service_state_with_stop(name: &str, desired: &str, timeout_secs: u64, stop_flag: Arc<AtomicBool>) -> bool {
    let start = Instant::now();
    let desired_l = desired.to_lowercase();
    while start.elapsed() < Duration::from_secs(timeout_secs) {
        if stop_flag.load(std::sync::atomic::Ordering::SeqCst) {
            return false;
        }
        if let Ok(out) = Command::new("sc").arg("query").arg(name).output() {
            let s = String::from_utf8_lossy(&out.stdout).to_string();
            if s.to_lowercase().contains(&desired_l) {
                return true;
            }
        }
        sleep(Duration::from_secs(1));
    }
    false
}
