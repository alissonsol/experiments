// Copyright (c) 2025 - Alisson Sol
//
use chrono::Local;
use serde::{Deserialize, Serialize};
use serde_xml_rs::from_str;
use anyhow::Result;
use quick_xml::se::to_string as to_xml_string;

#[derive(Debug, Deserialize, Serialize, Clone, Default)]
pub struct OrdemTargets {
    #[serde(rename = "Service")]
    #[serde(default)]
    pub services: Vec<ServiceEntry>,
}

#[derive(Debug, Deserialize, Serialize, Clone, Default)]
pub struct ServiceEntry {
    pub name: Option<String>,
    pub description: Option<String>,
    pub status: Option<String>,
    pub start_mode: Option<String>,
    pub end_mode: Option<String>,
    pub log_on_as: Option<String>,
    pub path: Option<String>,

    #[serde(skip_serializing_if = "Option::is_none")]
    pub start_processing_time: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stop_time: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub end_time: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cpu_responsive_time: Option<String>,
}

pub fn parse_ordem(xml: &str) -> Result<OrdemTargets, serde_xml_rs::Error> {
    from_str(xml)
}

pub fn write_progress_xml(progress: &OrdemTargets) -> Result<String> {
    // quick-xml supports serializing sequences correctly where serde_xml_rs may fail
    Ok(to_xml_string(progress)?)
}

/// For testing: populate the timestamps with 'now'.
pub fn populate_test_timestamps(progress: &mut OrdemTargets) {
    let now = Local::now().to_rfc3339();
    for s in &mut progress.services {
        if s.start_processing_time.is_none() {
            s.start_processing_time = Some(now.clone());
        }
        if s.stop_time.is_none() {
            s.stop_time = Some(now.clone());
        }
        if s.end_time.is_none() {
            s.end_time = Some(now.clone());
        }
        if s.cpu_responsive_time.is_none() {
            s.cpu_responsive_time = Some(now.clone());
        }
    }
}


