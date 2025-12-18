// Copyright (c) 2025 - Alisson Sol
//
// Progresso Service Library
//
// Core data structures and XML parsing utilities for the Progresso Windows service.
// This library handles reading target configurations and writing progress reports
// with timestamps for service lifecycle events.

// # Progresso Service Library
//
// This crate provides core data structures and XML utilities for the Progresso
// Windows service orchestration system.
//
// ## Main Components
//
// - OrdemTargets: Root container for service configurations
// - ServiceEntry: Individual service configuration with lifecycle timestamps
// - parse_ordem: Deserialize XML configuration into Rust structures
// - write_progress_xml: Serialize progress data back to XML

use chrono::Local;
use serde::{Deserialize, Serialize};
use serde_xml_rs::from_str;
use anyhow::Result;
use quick_xml::se::to_string as to_xml_string;

// Re-export service_ctrl module for external use
pub mod service_ctrl;

/// Root structure containing all target service configurations.
///
/// This is the top-level element in the XML configuration file (`ordem.target.xml`).
/// It holds a vector of [`ServiceEntry`] items, each representing a Windows service
/// to be monitored and managed.
///
/// # XML Format
///
/// ```xml
/// <OrdemTargets>
///   <Service>...</Service>
///   <Service>...</Service>
/// </OrdemTargets>
/// ```
#[derive(Debug, Deserialize, Serialize, Clone, Default, PartialEq)]
pub struct OrdemTargets {
    /// List of services to process. Renamed to `Service` in XML output.
    #[serde(rename = "Service", default)]
    pub services: Vec<ServiceEntry>,
}

impl OrdemTargets {
    /// Creates a new empty `OrdemTargets` instance.
    #[inline]
    pub fn new() -> Self {
        Self::default()
    }

    /// Creates an `OrdemTargets` with pre-allocated capacity for services.
    ///
    /// Use this when the number of services is known ahead of time to avoid
    /// reallocations during population.
    #[inline]
    pub fn with_capacity(capacity: usize) -> Self {
        Self {
            services: Vec::with_capacity(capacity),
        }
    }

    /// Returns the number of services in the configuration.
    #[inline]
    pub fn len(&self) -> usize {
        self.services.len()
    }

    /// Returns `true` if there are no services configured.
    #[inline]
    pub fn is_empty(&self) -> bool {
        self.services.is_empty()
    }
}

/// Represents a single Windows service with its configuration and execution timestamps.
///
/// # Configuration Fields
///
/// These fields define the service's identity and desired state:
/// - `name`: Service identifier (required for processing)
/// - `description`: Human-readable description
/// - `status`: Current status at time of configuration
/// - `start_mode`: Service startup type (e.g., "Manual", "Automatic")
/// - `end_mode`: Target state after processing (e.g., "Automatic" to start, other to stop)
/// - `log_on_as`: Service account (e.g., "LocalSystem")
/// - `path`: Executable path
///
/// # Timestamp Fields
///
/// These fields are populated during execution to track progress:
/// - `start_processing_time`: When this service began processing
/// - `stop_time`: When a stop command was issued
/// - `end_time`: When processing completed
/// - `cpu_responsive_time`: When CPU dropped below threshold after service operation
#[derive(Debug, Deserialize, Serialize, Clone, Default, PartialEq)]
pub struct ServiceEntry {
    /// Service name identifier (matches Windows service name).
    pub name: Option<String>,
    /// Human-readable service description.
    pub description: Option<String>,
    /// Current service status at configuration time.
    pub status: Option<String>,
    /// Service startup mode (e.g., "Manual", "Automatic", "Disabled").
    pub start_mode: Option<String>,
    /// Target end state: "Automatic" means start the service, other values mean stop.
    pub end_mode: Option<String>,
    /// Account under which the service runs.
    pub log_on_as: Option<String>,
    /// Path to the service executable.
    pub path: Option<String>,

    /// Timestamp (RFC 3339) when processing of this service began.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub start_processing_time: Option<String>,

    /// Timestamp (RFC 3339) when a stop command was issued.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stop_time: Option<String>,

    /// Timestamp (RFC 3339) when processing of this service completed.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub end_time: Option<String>,

    /// Timestamp (RFC 3339) when CPU usage dropped below threshold.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cpu_responsive_time: Option<String>,
}

impl ServiceEntry {
    /// Returns the service name, or `None` if empty or not set.
    #[inline]
    pub fn name(&self) -> Option<&str> {
        self.name.as_deref().filter(|n| !n.is_empty())
    }

    /// Returns `true` if the service should be started based on `end_mode`.
    ///
    /// A service should be started if its `end_mode` contains "automatic" (case-insensitive).
    #[inline]
    pub fn should_start(&self) -> bool {
        self.end_mode
            .as_ref()
            .map(|m| m.to_lowercase().contains("automatic"))
            .unwrap_or(false)
    }

    /// Records the current time as the start processing timestamp.
    #[inline]
    pub fn record_start_processing(&mut self) {
        self.start_processing_time = Some(Local::now().to_rfc3339());
    }

    /// Records the current time as the stop timestamp.
    #[inline]
    pub fn record_stop(&mut self) {
        self.stop_time = Some(Local::now().to_rfc3339());
    }

    /// Records the current time as the end timestamp.
    #[inline]
    pub fn record_end(&mut self) {
        self.end_time = Some(Local::now().to_rfc3339());
    }

    /// Records the current time as the CPU responsive timestamp.
    #[inline]
    pub fn record_cpu_responsive(&mut self) {
        self.cpu_responsive_time = Some(Local::now().to_rfc3339());
    }
}

/// Parses ordem target configuration from an XML string.
///
/// # Arguments
///
/// * `xml` - XML string containing service configurations in `OrdemTargets` format
///
/// # Returns
///
/// * `Ok(OrdemTargets)` - Successfully parsed configuration
/// * `Err(serde_xml_rs::Error)` - XML parsing or deserialization failed
///
/// # Example
///
/// ```rust
/// use progresso_service::parse_ordem;
///
/// let xml = r#"<OrdemTargets>
///   <Service><name>MyService</name></Service>
/// </OrdemTargets>"#;
///
/// let ordem = parse_ordem(xml).expect("valid XML");
/// assert_eq!(ordem.services.len(), 1);
/// ```
#[inline]
pub fn parse_ordem(xml: &str) -> Result<OrdemTargets, serde_xml_rs::Error> {
    from_str(xml)
}

/// Serializes progress data to XML format.
///
/// Uses `quick-xml` for serialization, which handles sequence elements correctly
/// (each `ServiceEntry` becomes a `<Service>` element).
///
/// # Arguments
///
/// * `progress` - The progress data to serialize
///
/// # Returns
///
/// * `Ok(String)` - XML string without the `<?xml?>` declaration
/// * `Err` - Serialization failed
///
/// # Note
///
/// The caller should prepend `<?xml version="1.0" encoding="utf-8"?>` if a
/// complete XML document is needed.
#[inline]
pub fn write_progress_xml(progress: &OrdemTargets) -> Result<String> {
    Ok(to_xml_string(progress)?)
}

/// Populates all empty timestamp fields with the current time.
///
/// This is primarily useful for testing scenarios where all timestamps need
/// to be set to demonstrate the output format.
///
/// Only populates fields that are currently `None`; existing timestamps are preserved.
///
/// # Arguments
///
/// * `progress` - Mutable reference to progress data to populate
///
/// # Example
///
/// ```rust
/// use progresso_service::{OrdemTargets, ServiceEntry, populate_test_timestamps};
///
/// let mut progress = OrdemTargets {
///     services: vec![ServiceEntry::default()],
/// };
/// populate_test_timestamps(&mut progress);
/// assert!(progress.services[0].start_processing_time.is_some());
/// ```
pub fn populate_test_timestamps(progress: &mut OrdemTargets) {
    let now = Local::now().to_rfc3339();
    for service in &mut progress.services {
        service.start_processing_time.get_or_insert_with(|| now.clone());
        service.stop_time.get_or_insert_with(|| now.clone());
        service.end_time.get_or_insert_with(|| now.clone());
        service.cpu_responsive_time.get_or_insert_with(|| now.clone());
    }
}


