use actix_web::{get, post, web, App, HttpResponse, HttpServer, Responder, middleware::Logger};
use actix_cors::Cors;
use actix_files::Files;
use serde::{Deserialize, Serialize};
use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

#[derive(Debug, Serialize, Deserialize, Clone)]
struct ServiceInfo {
    name: String,
    description: String,
    status: String,
    startup_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    end_type: Option<String>,
    log_on_as: String,
    path: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct OrdemTargets {
    #[serde(rename = "Service")]
    services: Vec<ServiceInfo>,
}

fn targets_file_path() -> Option<PathBuf> {
    env::var("LOCALAPPDATA")
        .or_else(|_| env::var("USERPROFILE").map(|p| format!("{p}\\AppData\\Local")))
        .ok()
        .map(|base| PathBuf::from(base).join("Ordem").join("ordem.target.xml"))
}

fn parse_service_json(item: &serde_json::Value) -> ServiceInfo {
    let get_str = |key: &str| item.get(key).and_then(|v| v.as_str()).unwrap_or("").to_string();
    ServiceInfo {
        name: get_str("Name"),
        description: get_str("DisplayName"),
        status: get_str("State"),
        startup_type: get_str("StartMode"),
        end_type: None,
        log_on_as: get_str("StartName"),
        path: get_str("PathName"),
    }
}

async fn get_services_from_system() -> Result<Vec<ServiceInfo>, String> {
    if !cfg!(windows) {
        return Err("Not running on Windows".into());
    }

    const PS_COMMAND: &str = "Get-WmiObject -Class Win32_Service | Select-Object Name, DisplayName, State, StartMode, StartName, PathName | ConvertTo-Json -Depth 2";

    // Try pwsh first, then powershell
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

    let txt = String::from_utf8_lossy(&stdout);
    let json: serde_json::Value = serde_json::from_str(&txt)
        .map_err(|e| format!("JSON parse error: {}\nraw:{}", e, txt))?;

    let services = match json {
        serde_json::Value::Array(arr) => arr.iter().map(parse_service_json).collect(),
        serde_json::Value::Object(_) => vec![parse_service_json(&json)],
        _ => Vec::new(),
    };

    Ok(services)
}

#[get("/api/services")]
async fn api_services() -> impl Responder {
    match get_services_from_system().await {
        Ok(list) => HttpResponse::Ok().json(list),
        Err(e) => HttpResponse::InternalServerError().body(e),
    }
}

fn read_targets_from_file(path: &PathBuf) -> Option<Vec<ServiceInfo>> {
    let content = fs::read_to_string(path).ok()?;
    quick_xml::de::from_str::<OrdemTargets>(&content)
        .ok()
        .map(|wrapper| wrapper.services)
}

fn write_targets_to_file(path: &PathBuf, services: &[ServiceInfo]) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let xml = quick_xml::se::to_string(&OrdemTargets { services: services.to_vec() })
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
    fs::write(path, xml)
}

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

    // Try to locate a `ui/dist` folder next to the repository. This allows the server
    // to serve the built frontend when present so a single process serves both API and UI.
    fn find_ui_dist() -> Option<PathBuf> {
        let cwd = env::current_dir().ok()?;
        let exe_dir = env::current_exe().ok().and_then(|p| p.parent().map(|d| d.to_path_buf()));

        let paths = ["dist/ui", "../dist/ui", "../../dist/ui", "ui/dist", "../ui/dist"];

        paths.iter()
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
