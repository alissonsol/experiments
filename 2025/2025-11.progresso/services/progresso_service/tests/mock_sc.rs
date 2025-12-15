// Copyright (c) 2025 - Alisson Sol
//
use std::env;
use std::fs::File;
use std::io::Write;
use std::path::PathBuf;
use std::sync::{Arc, atomic::{AtomicBool, Ordering}};
use std::thread;
use std::time::Duration;

use tempfile::TempDir;

use progresso_service::service_ctrl;

fn write_sc_script(dir: &TempDir) -> PathBuf {
    let path = dir.path().to_path_buf();
    if cfg!(windows) {
        let sc_path = path.join("sc.bat");
        let mut f = File::create(&sc_path).expect("create sc.bat");
        writeln!(f, "@echo off").unwrap();
        writeln!(f, "if "%1"==\"query\" (").unwrap();
        writeln!(f, "  if "%2"==\"RunningSvc\" (").unwrap();
        writeln!(f, "    echo SERVICE_NAME: %2").unwrap();
        writeln!(f, "    echo         STATE              : 4  RUNNING").unwrap();
        writeln!(f, "    exit /b 0").unwrap();
        writeln!(f, "  ) else (").unwrap();
        writeln!(f, "    echo SERVICE_NAME: %2").unwrap();
        writeln!(f, "    echo         STATE              : 1  STOPPED").unwrap();
        writeln!(f, "    exit /b 0").unwrap();
        writeln!(f, "  )").unwrap();
        writeln!(f, ")").unwrap();
        writeln!(f, "exit /b 0").unwrap();
        sc_path
    } else {
        let sc_path = path.join("sc");
        let mut f = File::create(&sc_path).expect("create sc");
        writeln!(f, "#!/bin/sh").unwrap();
        writeln!(f, "if [ \"$1\" = \"query\" ]; then").unwrap();
        writeln!(f, "  if [ \"$2\" = \"RunningSvc\" ]; then").unwrap();
        writeln!(f, "    echo SERVICE_NAME: $2").unwrap();
        writeln!(f, "    echo         STATE              : 4  RUNNING").unwrap();
        writeln!(f, "    exit 0").unwrap();
        writeln!(f, "  else").unwrap();
        writeln!(f, "    echo SERVICE_NAME: $2").unwrap();
        writeln!(f, "    echo         STATE              : 1  STOPPED").unwrap();
        writeln!(f, "    exit 0").unwrap();
        writeln!(f, "  fi").unwrap();
        writeln!(f, "fi").unwrap();
        writeln!(f, "exit 0").unwrap();
        // make executable
        #[cfg(unix)] {
            use std::os::unix::fs::PermissionsExt;
            let perm = std::fs::Permissions::from_mode(0o755);
            std::fs::set_permissions(&sc_path, perm).unwrap();
        }
        sc_path
    }
}

#[test]
fn test_is_service_running_and_wait() {
    let td = TempDir::new().expect("tempdir");
    let sc_path = write_sc_script(&td);

    // prepend tempdir to PATH
    let orig_path = env::var_os("PATH").unwrap_or_default();
    let mut new_path = td.path().to_path_buf();
    new_path.push("");
    let sep = if cfg!(windows) { ";" } else { ":" };
    let mut combined = env::join_paths(env::split_paths(&orig_path).collect::<Vec<_>>()).unwrap();
    let mut paths = vec![td.path().to_path_buf()];
    paths.extend(env::split_paths(&orig_path));
    let new_path_os = env::join_paths(paths).unwrap();
    env::set_var("PATH", &new_path_os);

    // RunningSvc should be detected as running
    assert!(service_ctrl::is_service_running("RunningSvc"));
    // OtherSvc should not be running
    assert!(!service_ctrl::is_service_running("OtherSvc"));

    // wait for RunningSvc RUNNING should succeed quickly
    let stop_flag = Arc::new(AtomicBool::new(false));
    let got = service_ctrl::wait_for_service_state_with_stop("RunningSvc", "RUNNING", 2, stop_flag.clone());
    assert!(got);

    // wait for OtherSvc RUNNING should timeout and return false
    let stop_flag2 = Arc::new(AtomicBool::new(false));
    let got2 = service_ctrl::wait_for_service_state_with_stop("OtherSvc", "RUNNING", 2, stop_flag2.clone());
    assert!(!got2);

    // test early stop: set flag true and verify immediate return false
    let stop_flag3 = Arc::new(AtomicBool::new(true));
    let got3 = service_ctrl::wait_for_service_state_with_stop("RunningSvc", "RUNNING", 10, stop_flag3.clone());
    assert!(!got3);

    // restore PATH
    env::set_var("PATH", &orig_path);
    drop(td);
}
