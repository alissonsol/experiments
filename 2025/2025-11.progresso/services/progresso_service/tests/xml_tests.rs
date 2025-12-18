// Copyright (c) 2025 - Alisson Sol
//
// XML Parsing and Serialization Tests
//
// Tests for verifying XML round-trip (parse -> modify -> serialize) functionality
// and edge case handling for the ordem configuration format.

use progresso_service::{parse_ordem, populate_test_timestamps, write_progress_xml, OrdemTargets, ServiceEntry};

/// Sample XML configuration with a single service entry containing all fields.
const SAMPLE_FULL_SERVICE: &str = r#"<?xml version="1.0" encoding="utf-8"?>
<OrdemTargets>
  <Service>
    <name>TestSvc</name>
    <description>Test Service</description>
    <status>Running</status>
    <start_mode>Manual</start_mode>
    <end_mode>Automatic</end_mode>
    <log_on_as>LocalSystem</log_on_as>
    <path>C:\Windows\system32\svchost.exe</path>
  </Service>
</OrdemTargets>"#;

/// Verifies that XML can be parsed, modified with timestamps, and re-serialized.
///
/// This test ensures the complete workflow:
/// 1. Parse XML configuration into Rust structures
/// 2. Populate timestamp fields (simulating runtime processing)
/// 3. Serialize back to XML
/// 4. Verify key data is preserved
#[test]
fn parse_and_serialize_roundtrip() {
    // Parse the sample XML
    let mut ordem = parse_ordem(SAMPLE_FULL_SERVICE).expect("parse failed");
    assert_eq!(ordem.services.len(), 1, "Expected exactly one service");

    // Verify parsed service name
    let service = &ordem.services[0];
    assert_eq!(service.name.as_deref(), Some("TestSvc"));
    assert_eq!(service.end_mode.as_deref(), Some("Automatic"));

    // Populate timestamps (simulating runtime behavior)
    populate_test_timestamps(&mut ordem);

    // Serialize to XML
    let output = write_progress_xml(&ordem).expect("serialize failed");

    // Verify output contains expected data
    assert!(output.contains("TestSvc"), "Output should contain service name");
    assert!(output.contains("start_processing_time"), "Output should contain timestamp field");
}

/// Verifies that an empty OrdemTargets (no services) parses successfully.
#[test]
fn empty_ordem_is_valid() {
    let xml = "<OrdemTargets></OrdemTargets>";
    let ordem = parse_ordem(xml).expect("parse empty failed");

    assert!(ordem.services.is_empty(), "Empty config should have no services");
    assert!(ordem.is_empty(), "is_empty() should return true");
    assert_eq!(ordem.len(), 0, "len() should return 0");
}

/// Verifies that OrdemTargets self-closing tag parses correctly.
#[test]
fn self_closing_ordem_is_valid() {
    let xml = "<OrdemTargets/>";
    let ordem = parse_ordem(xml).expect("parse self-closing failed");

    assert!(ordem.is_empty());
}

/// Verifies ServiceEntry helper methods work correctly.
#[test]
fn service_entry_helpers() {
    let mut entry = ServiceEntry {
        name: Some("TestService".to_string()),
        end_mode: Some("Automatic".to_string()),
        ..Default::default()
    };

    // Test name() helper
    assert_eq!(entry.name(), Some("TestService"));

    // Test should_start() - "Automatic" should trigger start
    assert!(entry.should_start(), "Automatic end_mode should start");

    // Test with non-automatic mode
    entry.end_mode = Some("Manual".to_string());
    assert!(!entry.should_start(), "Manual end_mode should not start");

    // Test with empty name
    entry.name = Some(String::new());
    assert_eq!(entry.name(), None, "Empty name should return None");
}

/// Verifies OrdemTargets::with_capacity pre-allocates correctly.
#[test]
fn ordem_with_capacity() {
    let ordem = OrdemTargets::with_capacity(10);

    assert!(ordem.is_empty());
    assert!(ordem.services.capacity() >= 10);
}
