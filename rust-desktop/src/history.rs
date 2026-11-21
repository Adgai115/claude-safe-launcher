use chrono::{DateTime, Utc};
use claude_safe_launcher_rust::report::{Level, Report};
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};

const MAX_BYTES: u64 = 1024 * 1024;
const RECENT_LIMIT: usize = 50;

#[derive(Clone, PartialEq, Eq, Deserialize, Serialize)]
pub struct Status {
    score: Option<u16>,
    monitor: String,
    checks: Vec<Check>,
}

#[derive(Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Check {
    id: u8,
    level: Level,
    blocked: bool,
    #[serde(default)]
    weight: u8,
    #[serde(default)]
    earned: u8,
    #[serde(default)]
    elapsed_ms: u64,
    #[serde(default)]
    observed_at: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    reason_code: Option<String>,
}

#[derive(Deserialize, Serialize)]
pub struct Entry {
    at: DateTime<Utc>,
    event: String,
    status: Status,
}

impl Status {
    pub fn new(report: &Report<'_>, monitor: &'static str) -> Self {
        Self {
            score: report.score,
            monitor: monitor.into(),
            checks: report
                .groups
                .iter()
                .map(|group| Check {
                    id: group.id,
                    level: group.level,
                    blocked: group.blocks_launch,
                    weight: group.weight,
                    earned: group.earned,
                    elapsed_ms: group.elapsed_ms,
                    observed_at: Some(group.observed_at),
                    reason_code: group.reason_code.map(str::to_owned),
                })
                .collect(),
        }
    }
}

pub fn path(folder: &Path) -> PathBuf {
    folder.join("logs").join("diagnostics.jsonl")
}

pub fn recent(folder: &Path) -> io::Result<Vec<Entry>> {
    let active = path(folder);
    let mut entries = read_last(&active, RECENT_LIMIT)?;
    if entries.len() < RECENT_LIMIT {
        let previous = active.with_file_name("diagnostics.previous.jsonl");
        entries.extend(read_last(&previous, RECENT_LIMIT - entries.len())?);
    }
    Ok(entries)
}

pub fn export(
    folder: &Path,
    destination: &Path,
    current: &Status,
    timezone_pending: bool,
) -> io::Result<PathBuf> {
    let events = collapsed_events(recent(folder)?);
    let report = serde_json::json!({
        "schemaVersion": 3,
        "appVersion": env!("CARGO_PKG_VERSION"),
        "exportedAt": Utc::now(),
        "environment": {
            "platform": std::env::consts::OS,
            "architecture": std::env::consts::ARCH,
        },
        "timezonePending": timezone_pending,
        "current": current.sanitized(),
        "events": events,
    });
    fs::create_dir_all(destination)?;
    let mut temp = tempfile::NamedTempFile::new_in(destination)?;
    serde_json::to_writer_pretty(&mut temp, &report).map_err(io::Error::other)?;
    temp.write_all(b"\n")?;
    crate::downloads::save(temp, destination, "monitor-diagnostics", "json")
}

impl Status {
    fn sanitized(&self) -> serde_json::Value {
        let checks: Vec<_> = self
            .checks
            .iter()
            .filter(|check| (1..=14).contains(&check.id))
            .take(14)
            .map(|check| {
                let weight = check.weight.min(100);
                serde_json::json!({
                    "id": check.id,
                    "name": check_name(check.id),
                    "level": check.level,
                    "resultCode": result_code(check.id, check.level),
                    "blocked": check.blocked,
                    "weight": weight,
                    "earned": check.earned.min(weight),
                    "elapsedMs": check.elapsed_ms.min(120_000),
                    "observedAt": check.observed_at,
                    "reasonCode": check.reason_code.as_deref(),
                })
            })
            .collect();
        let passed = self
            .checks
            .iter()
            .filter(|check| matches!(check.level, Level::Pass | Level::Fixed))
            .count();
        let needs_attention = self
            .checks
            .iter()
            .filter(|check| matches!(check.level, Level::Failed | Level::Warning | Level::Unknown))
            .count();
        let blocked = self.checks.iter().filter(|check| check.blocked).count();
        serde_json::json!({
            "score": self.score.filter(|&score| score <= 100),
            "monitor": match self.monitor.as_str() {
                "waiting" | "watching" | "paused" => self.monitor.as_str(),
                _ => "unknown",
            },
            "summary": {
                "total": checks.len(),
                "passed": passed,
                "needsAttention": needs_attention,
                "blocked": blocked,
            },
            "checks": checks,
        })
    }
}

#[derive(PartialEq, Eq)]
struct CollapsedEvent {
    first_at: DateTime<Utc>,
    last_at: DateTime<Utc>,
    event: String,
    status: Status,
    repeat_count: usize,
}

fn collapsed_events(entries: Vec<Entry>) -> Vec<serde_json::Value> {
    let mut collapsed: Vec<CollapsedEvent> = Vec::new();
    for entry in entries {
        let event = safe_event(&entry.event).to_owned();
        if let Some(previous) = collapsed
            .last_mut()
            .filter(|previous| previous.event == event && previous.status == entry.status)
        {
            previous.first_at = entry.at;
            previous.repeat_count += 1;
            continue;
        }
        collapsed.push(CollapsedEvent {
            first_at: entry.at,
            last_at: entry.at,
            event,
            status: entry.status,
            repeat_count: 1,
        });
    }
    collapsed
        .into_iter()
        .map(|entry| {
            serde_json::json!({
                "firstAt": entry.first_at,
                "lastAt": entry.last_at,
                "repeatCount": entry.repeat_count,
                "event": entry.event,
                "status": entry.status.sanitized(),
            })
        })
        .collect()
}

fn safe_event(event: &str) -> &str {
    match event {
        "read_only_check"
        | "check_and_repair"
        | "learn_baseline"
        | "settings_changed"
        | "check_failed"
        | "launch_confirmed"
        | "launch_unconfirmed"
        | "monitor_attached"
        | "monitor_sample"
        | "monitor_risk"
        | "monitor_error"
        | "monitor_paused"
        | "monitor_resumed"
        | "claude_exited"
        | "claude_closed_for_risk"
        | "configuration_locked"
        | "configuration_unlocked"
        | "timezone_restored"
        | "timezone_preserved"
        | "timezone_restore_error" => event,
        _ => "other",
    }
}

fn check_name(id: u8) -> &'static str {
    const NAMES: [&str; 14] = [
        "Windows VPN 路由",
        "系统时区",
        "VPN 接口基准",
        "出口一致性",
        "IP 风险",
        "系统 DNS",
        "IPv6 出口探测",
        "Anthropic API 连通性",
        "环境变量",
        "Claude Code 接口",
        "面板时区与 WebRTC",
        "官方支持地区",
        "Claude 运行与连接",
        "客户端日志告警",
    ];
    NAMES
        .get(usize::from(id.saturating_sub(1)))
        .copied()
        .unwrap_or("未知检查")
}

fn result_code(id: u8, level: Level) -> String {
    const SLUGS: [&str; 14] = [
        "vpn_route",
        "system_timezone",
        "vpn_interface_baseline",
        "exit_consistency",
        "ip_risk",
        "system_dns",
        "ipv6_egress",
        "anthropic_api",
        "environment_variables",
        "claude_code_endpoint",
        "panel_timezone_webrtc",
        "supported_region",
        "claude_connection",
        "client_log_alerts",
    ];
    let slug = SLUGS
        .get(usize::from(id.saturating_sub(1)))
        .copied()
        .unwrap_or("unknown_check");
    let result = match level {
        Level::Pass => "pass",
        Level::Fixed => "fixed",
        Level::Warning => "warning",
        Level::Failed => "failed",
        Level::Unknown => "unknown",
        Level::Reference => "reference",
        Level::PendingLaunch => "pending_launch",
        Level::PendingConnection => "pending_connection",
        Level::NoData => "no_data",
    };
    format!("{slug}_{result}")
}

fn read_last(path: &Path, limit: usize) -> io::Result<Vec<Entry>> {
    let file = match File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error),
    };
    let mut entries = VecDeque::with_capacity(limit);
    for line in BufReader::new(file.take(MAX_BYTES)).split(b'\n') {
        if let Ok(entry) = serde_json::from_slice(&line?) {
            if entries.len() == limit {
                entries.pop_front();
            }
            entries.push_back(entry);
        }
    }
    Ok(entries.into_iter().rev().collect())
}

pub fn append(folder: &Path, event: &str, status: &Status) -> io::Result<()> {
    let active = path(folder);
    fs::create_dir_all(folder.join("logs"))?;
    let record = serde_json::json!({
        "at": Utc::now(),
        "event": event,
        "status": status,
    });
    let mut line = serde_json::to_vec(&record).map_err(io::Error::other)?;
    line.push(b'\n');
    if fs::metadata(&active).is_ok_and(|info| info.len() + line.len() as u64 > MAX_BYTES) {
        let previous = active.with_file_name("diagnostics.previous.jsonl");
        match fs::remove_file(&previous) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
        fs::rename(&active, previous)?;
    }
    OpenOptions::new()
        .create(true)
        .append(true)
        .open(active)?
        .write_all(&line)
}

#[cfg(test)]
mod tests {
    use super::*;
    use claude_safe_launcher_rust::report::Group;

    #[test]
    fn export_excludes_raw_check_details_and_unknown_log_fields() {
        let folder = tempfile::tempdir().unwrap();
        let mut group = Group::new(3, "private node label", Level::Failed, "private address")
            .reason("vpn_baseline_interface_changed");
        group.elapsed_ms = 847;
        let groups = [group];
        let status = Status::new(&Report::new(&groups), "private monitor label");
        append(folder.path(), "private legacy event", &status).unwrap();
        append(folder.path(), "private legacy event", &status).unwrap();
        let destination = folder.path().join("Downloads");
        let file = export(folder.path(), &destination, &status, true).unwrap();
        let repeated = export(folder.path(), &destination, &status, false).unwrap();
        assert_eq!(file, destination.join("monitor-diagnostics.json"));
        assert_ne!(repeated, file);
        let contents = fs::read_to_string(file).unwrap();
        assert!(!contents.contains("private"));
        assert!(contents.contains("\"schemaVersion\": 3"));
        assert!(contents.contains("\"timezonePending\": true"));
        assert!(contents.contains("\"level\": \"failed\""));
        assert!(contents.contains("\"name\": \"VPN 接口基准\""));
        assert!(contents.contains("\"resultCode\": \"vpn_interface_baseline_failed\""));
        assert!(contents.contains("\"reasonCode\": \"vpn_baseline_interface_changed\""));
        assert!(contents.contains("\"elapsedMs\": 847"));
        assert!(contents.contains("\"repeatCount\": 2"));
        assert!(contents.contains("\"event\": \"other\""));
    }

    #[test]
    fn old_status_records_remain_readable_with_safe_defaults() {
        let folder = tempfile::tempdir().unwrap();
        let active = path(folder.path());
        fs::create_dir_all(active.parent().unwrap()).unwrap();
        fs::write(
            &active,
            r#"{"at":"2026-11-20T00:00:00Z","event":"read_only_check","status":{"score":22,"monitor":"waiting","checks":[{"id":1,"level":"failed","blocked":true}]}}
"#,
        )
        .unwrap();
        let status = Status::new(&Report::new(&[]), "waiting");
        let destination = folder.path().join("Downloads");
        let file = export(folder.path(), &destination, &status, false).unwrap();
        let report: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(file).unwrap()).unwrap();
        assert_eq!(
            report["events"][0]["status"]["checks"][0]["resultCode"],
            "vpn_route_failed"
        );
        assert_eq!(report["events"][0]["status"]["checks"][0]["elapsedMs"], 0);
    }

    #[test]
    fn recent_keeps_the_latest_fifty_samples_even_when_the_status_is_unchanged() {
        let folder = tempfile::tempdir().unwrap();
        let groups = [Group::new(3, "策略组", Level::Pass, "")];
        let status = Status::new(&Report::new(&groups), "watching");
        for _ in 0..55 {
            append(folder.path(), "monitor_sample", &status).unwrap();
        }
        let entries = recent(folder.path()).unwrap();
        assert_eq!(entries.len(), RECENT_LIMIT);
        assert!(entries.iter().all(|entry| entry.event == "monitor_sample"));
        assert!(entries.windows(2).all(|pair| pair[0].at >= pair[1].at));
    }

    #[test]
    fn recent_includes_rotated_log_and_skips_partial_lines() {
        let folder = tempfile::tempdir().unwrap();
        let folder = folder.path();
        assert!(recent(folder).unwrap().is_empty());
        let status = Status::new(&Report::new(&[]), "waiting");
        append(folder, "old", &status).unwrap();
        let active = path(folder);
        fs::rename(&active, active.with_file_name("diagnostics.previous.jsonl")).unwrap();
        append(folder, "new", &status).unwrap();
        OpenOptions::new()
            .append(true)
            .open(&active)
            .unwrap()
            .write_all(b"{broken")
            .unwrap();
        assert_eq!(
            recent(folder)
                .unwrap()
                .into_iter()
                .map(|entry| entry.event)
                .collect::<Vec<_>>(),
            ["new", "old"]
        );
    }

    #[test]
    fn rotates_logs_and_records_only_status_fields() {
        let folder = tempfile::tempdir().unwrap();
        let groups = [Group::new(3, "策略组", Level::Pass, "private-fixture-node")];
        let status = Status::new(&Report::new(&groups), "watching");
        let active = path(folder.path());
        append(folder.path(), "check", &status).unwrap();
        let data = fs::read_to_string(&active).unwrap();
        assert!(!data.contains("private-fixture-node"));
        let record: serde_json::Value = serde_json::from_str(&data).unwrap();
        assert_eq!(record["status"]["checks"][0]["level"], "pass");
        OpenOptions::new()
            .write(true)
            .open(&active)
            .unwrap()
            .set_len(MAX_BYTES)
            .unwrap();
        append(folder.path(), "monitor", &status).unwrap();
        assert_eq!(
            fs::metadata(active.with_file_name("diagnostics.previous.jsonl"))
                .unwrap()
                .len(),
            MAX_BYTES
        );
        assert!(fs::read_to_string(active)
            .unwrap()
            .contains("\"event\":\"monitor\""));
    }
}
