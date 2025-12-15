// Copyright (c) 2025 - Alisson Sol
//

const SAMPLE: &str = r#"<?xml version=\"1.0\" encoding=\"utf-8\"?>
<OrdemTargets>
  <Service>
    <name>TestSvc</name>
    <description>Test Service</description>
    <status>Running</status>
    <start_mode>Manual</start_mode>
    <end_mode>Automatic</end_mode>
    <log_on_as>LocalSystem</log_on_as>
    <path>C:\\Windows\\system32\\svchost.exe</path>
  </Service>
</OrdemTargets>"#;

#[test]
fn parse_and_serialize_roundtrip() {
    let mut ordem = parse_ordem(SAMPLE).expect("parse failed");
    assert_eq!(ordem.services.len(), 1);
    // populate timestamps (simulate processing)
    populate_test_timestamps(&mut ordem);

    let out = write_progress_xml(&ordem).expect("serialize failed");
    assert!(out.contains("TestSvc"));
    assert!(out.contains("start_processing_time") || out.contains("start_processing_time"));
}

#[test]
fn empty_ordem_is_valid() {
    let xml = "<OrdemTargets></OrdemTargets>";
    let ordem = parse_ordem(xml).expect("parse empty failed");
    assert!(ordem.services.is_empty());
}
