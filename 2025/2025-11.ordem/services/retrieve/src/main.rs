// Copyright (c) 2025 - Alisson Sol
//
// Ordem Service Retrieval Backend
//
// A REST API server that provides endpoints for querying Windows services
// and managing target service configurations. Built with Actix-web.
//
// # Endpoints
// - `GET /api/services` - Retrieves all Windows services from the system
// - `GET /api/targets` - Retrieves saved target configurations
// - `POST /api/targets` - Saves target configurations
// - `GET /` - Serves the frontend UI (if available)

use actix_web::{get, post, web, App, HttpResponse, HttpServer, Responder, middleware::Logger};
use actix_cors::Cors;
use actix_files::Files;
use serde::{Deserialize, Serialize};
use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

/// Represents a Windows service with its configuration and state.
#[derive(Debug, Serialize, Deserialize, Clone)]
struct ServiceInfo {
    name: String,
    description: String,
    status: String,
    start_mode: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    end_mode: Option<String>,
    log_on_as: String,
    path: String,
}

/// Wrapper for XML serialization of service targets.
#[derive(Debug, Serialize, Deserialize)]
struct OrdemTargets {
    #[serde(rename = "Service")]
    services: Vec<ServiceInfo>,
}

/// Determines the file path for storing target configurations.
/// Uses LOCALAPPDATA environment variable, with fallback to USERPROFILE.
///
/// # Returns
/// `Some(PathBuf)` with the path to ordem.target.xml, or `None` if environment variables are missing.
fn targets_file_path() -> Option<PathBuf> {
    env::var("LOCALAPPDATA")
        .or_else(|_| env::var("USERPROFILE").map(|p| format!("{p}\\AppData\\Local")))
        .ok()
        .map(|base| PathBuf::from(base).join("Ordem").join("ordem.target.xml"))
}

/// Parses a single service entry from JSON returned by PowerShell WMI query.
///
/// # Arguments
/// * `item` - JSON value containing service information
///
/// # Returns
/// A populated `ServiceInfo` struct with normalized start mode.
fn parse_service_json(item: &serde_json::Value) -> ServiceInfo {
    let get_str = |key: &str| {
        item.get(key)
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string()
    };
    let get_bool = |key: &str| {
        item.get(key)
            .and_then(|v| v.as_bool())
            .unwrap_or(false)
    };

    let raw_start_mode = get_str("StartMode");
    let delayed_auto_start = get_bool("DelayedAutoStart");
    let start_mode = normalize_start_mode(&raw_start_mode, delayed_auto_start);

    ServiceInfo {
        name: get_str("Name"),
        description: get_str("DisplayName"),
        status: get_str("State"),
        start_mode,
        end_mode: None,
        log_on_as: get_str("StartName"),
        path: get_str("PathName"),
    }
}

/// Normalizes a Windows service start mode to a standard format.
///
/// # Arguments
/// * `raw_mode` - The raw start mode string from WMI
/// * `delayed` - Whether delayed auto-start is enabled
///
/// # Returns
/// A normalized startup mode string.
fn normalize_start_mode(raw_mode: &str, delayed: bool) -> String {
    match (raw_mode, delayed) {
        ("Auto", true) => "Automatic (Delayed Start)".to_string(),
        ("Auto", false) => "Automatic".to_string(),
        ("Manual", _) => "Manual".to_string(),
        ("Disabled", _) => "Disabled".to_string(),
        _ => raw_mode.to_string(),
    }
}

/// Retrieves all Windows services from the system using PowerShell WMI queries.
/// Tries pwsh first, then falls back to powershell for compatibility.
///
/// # Returns
/// `Ok(Vec<ServiceInfo>)` on success, or `Err(String)` with error message on failure.
async fn get_services_from_system() -> Result<Vec<ServiceInfo>, String> {
    if !cfg!(windows) {
        return Err("Not running on Windows".into());
    }

    const PS_COMMAND: &str = "Get-WmiObject -Class Win32_Service | Select-Object Name, DisplayName, State, StartMode, DelayedAutoStart, StartName, PathName | ConvertTo-Json -Depth 2";

    // Try pwsh first (PowerShell 7+), then fall back to powershell (Windows PowerShell 5.x)
    let stdout = ["pwsh", "powershell"]
        .iter()
        .find_map(|&cmd| {
            Command::new(cmd)
                .args(["-NoProfile", "-Command", PS_COMMAND])
                .output()
                .ok()
                .filter(|o| o.status.success())
                .map(|o| o.stdout)
        })
        .ok_or_else(|| "Failed to run PowerShell to query services".to_string())?;

    let json: serde_json::Value = serde_json::from_slice(&stdout)
        .map_err(|e| format!("JSON parse error: {}", e))?;

    // Parse JSON response - handle both array (multiple services) and object (single service)
    let services = match json {
        serde_json::Value::Array(arr) => {
            let mut services = Vec::with_capacity(arr.len());
            for item in arr.iter() {
                services.push(parse_service_json(item));
            }
            services
        }
        serde_json::Value::Object(_) => vec![parse_service_json(&json)],
        _ => Vec::new(),
    };

    Ok(services)
}

/// API endpoint to retrieve all Windows services from the system.
#[get("/api/services")]
async fn api_services() -> impl Responder {
    match get_services_from_system().await {
        Ok(list) => HttpResponse::Ok().json(list),
        Err(e) => HttpResponse::InternalServerError().body(e),
    }
}

/// Reads target configurations from the XML file.
///
/// # Arguments
/// * `path` - Path to the ordem.target.xml file
///
/// # Returns
/// `Some(Vec<ServiceInfo>)` if file exists and parses successfully, `None` otherwise.
fn read_targets_from_file(path: &PathBuf) -> Option<Vec<ServiceInfo>> {
    fs::read_to_string(path)
        .ok()
        .and_then(|content| quick_xml::de::from_str::<OrdemTargets>(&content).ok())
        .map(|wrapper| wrapper.services)
}

/// Writes target configurations to the XML file.
/// Creates the parent directory if it doesn't exist.
///
/// # Arguments
/// * `path` - Path where the XML file should be written
/// * `services` - Service configurations to save
///
/// # Returns
/// `Ok(())` on success, or an IO error on failure.
fn write_targets_to_file(path: &PathBuf, services: &[ServiceInfo]) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }

    let wrapper = OrdemTargets {
        services: services.to_vec(),
    };

    let xml = quick_xml::se::to_string(&wrapper)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;

    fs::write(path, xml.as_bytes())
}

/// API endpoint to retrieve saved target configurations.
/// Initializes the file with current system services if it doesn't exist.
#[get("/api/targets")]
async fn api_get_targets() -> impl Responder {
    let Some(path) = targets_file_path() else {
        return HttpResponse::InternalServerError().body("Could not determine targets file path");
    };

    if path.exists() {
        return match read_targets_from_file(&path) {
            Some(list) => HttpResponse::Ok().json(list),
            None => HttpResponse::InternalServerError().body("Failed to parse existing target file"),
        };
    }

    // Initialize file with current services
    match get_services_from_system().await {
        Ok(list) => {
            if let Err(e) = write_targets_to_file(&path, &list) {
                HttpResponse::InternalServerError().body(format!("Failed to write initial target file: {}", e))
            } else {
                HttpResponse::Ok().json(list)
            }
        }
        Err(e) => HttpResponse::InternalServerError().body(e),
    }
}

/// API endpoint to save target configurations.
#[post("/api/targets")]
async fn api_post_targets(body: web::Json<Vec<ServiceInfo>>) -> impl Responder {
    let Some(path) = targets_file_path() else {
        return HttpResponse::InternalServerError().body("Could not determine targets file path");
    };

    match write_targets_to_file(&path, &body) {
        Ok(_) => HttpResponse::Ok().body("saved"),
        Err(e) => HttpResponse::InternalServerError().body(format!("write error: {}", e)),
    }
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    env_logger::init();
    let bind = "127.0.0.1:4000";

    println!("========================================");
    println!("Ordem Service Retrieval Backend");
    println!("========================================");

    /// Attempts to locate the built frontend UI distribution folder.
    /// Searches multiple common locations relative to both the current directory and executable.
    /// This allows the server to serve both API and UI from a single process.
    ///
    /// # Returns
    /// `Some(PathBuf)` if the UI dist folder is found, `None` otherwise.
    fn find_ui_dist() -> Option<PathBuf> {
        let cwd = env::current_dir().ok()?;
        let exe_dir = env::current_exe()
            .ok()
            .and_then(|p| p.parent().map(|d| d.to_path_buf()));

        const PATHS: &[&str] = &["dist/ui", "../dist/ui", "../../dist/ui", "ui/dist", "../ui/dist"];

        PATHS
            .iter()
            .flat_map(|&p| {
                let mut candidates = vec![cwd.join(p)];
                if let Some(ref exe) = exe_dir {
                    candidates.push(exe.join(p));
                }
                candidates
            })
            .find(|c| c.exists() && c.is_dir())
    }

    let ui_path = find_ui_dist();

    if let Some(ref p) = ui_path {
        println!("Backend:  http://{}", bind);
        println!("Frontend: http://{} (served from: {})", bind, p.display());
        println!("Mode:     Integrated (single endpoint)");
    } else {
        println!("Backend:  http://{}", bind);
        println!("Frontend: NOT FOUND");
        println!("Mode:     API-only (no UI)");
        println!();
        println!("To enable UI, build it first:");
        println!("  ./scripts/build-all.ps1");
    }
    println!("========================================");
    println!();

    HttpServer::new(move || {
        let mut app = App::new()
            .wrap(Cors::permissive())
            .wrap(Logger::default())
            .service(api_services)
            .service(api_get_targets)
            .service(api_post_targets);

        if let Some(ref p) = ui_path {
            app = app.service(Files::new("/", p).index_file("index.html"));
        } else {
            app = app.default_service(actix_web::web::route().to(|| HttpResponse::NotFound()));
        }

        app
    })
    .bind(bind)?
    .run()
    .await
}
