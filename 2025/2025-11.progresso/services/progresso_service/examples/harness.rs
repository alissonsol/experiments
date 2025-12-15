use progresso_service::lib::{parse_ordem, populate_test_timestamps, write_progress_xml};
use std::fs;
// Copyright (c) 2025 - Alisson Sol
//
use progresso_service::lib::{parse_ordem, populate_test_timestamps, write_progress_xml};
use std::fs;
use std::path::Path;

fn main() {
    // try to read ordem.target.xml from current dir
    let path = Path::new("ordem.target.xml");
    let xml = if path.exists() {
        fs::read_to_string(path).expect("failed to read ordem.target.xml")
    } else {
        // fallback sample
        r#"<OrdemTargets><Service><name>Example</name></Service></OrdemTargets>"#.to_string()
    };

    let mut ordem = parse_ordem(&xml).expect("parse failed");
    populate_test_timestamps(&mut ordem);
    let out = write_progress_xml(&ordem).expect("serialize failed");

    let out_path = "progresso.example.xml";
    fs::write(out_path, out).expect("write failed");
    println!("Wrote {}", out_path);
}
