// Copyright (c) 2025 - Alisson Sol
//
// Progresso Test Harness
//
// Example program demonstrating the XML parsing and serialization workflow.
// Reads an ordem configuration, populates timestamps, and writes a progress file.
//
// Usage:
//   cargo run --example harness
//
// Input:
//   - ordem.target.xml (if present in current directory)
//   - Falls back to embedded sample if file not found
//
// Output:
//   - progresso.example.xml with populated timestamps

use progresso_service::{parse_ordem, populate_test_timestamps, write_progress_xml};
use std::fs;
use std::path::Path;

/// Input configuration file name.
const INPUT_FILE: &str = "ordem.target.xml";

/// Output progress file name.
const OUTPUT_FILE: &str = "progresso.example.xml";

/// Fallback XML sample when input file is not found.
const FALLBACK_XML: &str = r#"<OrdemTargets>
  <Service>
    <name>ExampleService</name>
    <description>Example service for testing</description>
    <end_mode>Automatic</end_mode>
  </Service>
</OrdemTargets>"#;

fn main() {
    println!("Progresso Test Harness");
    println!("======================\n");

    // Read input configuration (file or fallback)
    let input_path = Path::new(INPUT_FILE);
    let xml = if input_path.exists() {
        println!("Reading configuration from: {}", INPUT_FILE);
        fs::read_to_string(input_path).expect("failed to read ordem.target.xml")
    } else {
        println!("No {} found, using embedded sample", INPUT_FILE);
        FALLBACK_XML.to_string()
    };

    // Parse XML into structures
    let mut ordem = parse_ordem(&xml).expect("failed to parse XML");
    println!("Parsed {} service(s)", ordem.len());

    // Populate timestamps (simulating runtime processing)
    populate_test_timestamps(&mut ordem);
    println!("Populated timestamps for all services");

    // Serialize to XML with header
    let xml_body = write_progress_xml(&ordem).expect("failed to serialize XML");
    let output = format!("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n{}", xml_body);

    // Write output file
    fs::write(OUTPUT_FILE, output).expect("failed to write output file");
    println!("\nWrote output to: {}", OUTPUT_FILE);
}
