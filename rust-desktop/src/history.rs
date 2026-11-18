use chrono::{DateTime, Utc};
use claude_safe_launcher_rust::report::{Level, Report};
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};

const MAX_BYTES: u64 = 1024 * 1024;
const RECENT_LIMIT: usize = 50;

#[derive(PartialEq, Eq, Deserialize, Serialize)]
pub struct Status {
    score: Option<u16>,
    monitor: String,
    checks: Vec<Check>,
}

#[derive(PartialEq, Eq, Deserialize, Serialize)]
struct Check {
    id: u8,
    level: Level,
    blocked: bool,
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
    let events: Vec<_> = recent(folder)?
        .into_iter()
        .map(|entry| serde_json::json!({
            "at": entry.at,
            "event": match entry.event.as_str() {
                "read_only_check" | "check_and_repair" | "learn_baseline" | "settings_changed"
                | "check_failed" | "launch_confirmed" | "launch_unconfirmed"
                | "monitor_attached" | "monitor_sample" | "monitor_risk" | "monitor_error"
                | "monitor_paused" | "monitor_resumed" | "claude_exited"
                | "configuration_locked" | "configuration_unlocked"
                | "timezone_restored" | "timezone_preserved" | "timezone_restore_error" => entry.event.as_str(),
                _ => "other",
            },
            "status": entry.status.sanitized(),
        }))
        .collect();
    let report = serde_json::json!({
        "schemaVersion": 1,
        "appVersion": env!("CARGO_PKG_VERSION"),
        "exportedAt": Utc::now(),
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
            .collect();
        serde_json::json!({
            "score": self.score.filter(|&score| score <= 100),
            "monitor": match self.monitor.as_str() {
                "waiting" | "watching" | "paused" => self.monitor.as_str(),
                _ => "unknown",
            },
            "checks": checks,
        })
    }
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
        let groups = [Group::new(
            3,
            "private node label",
            Level::Failed,
            "private address",
        )];
        let status = Status::new(&Report::new(&groups), "private monitor label");
        append(folder.path(), "private legacy event", &status).unwrap();
        let destination = folder.path().join("Downloads");
        let file = export(folder.path(), &destination, &status, true).unwrap();
        let repeated = export(folder.path(), &destination, &status, false).unwrap();
        assert_eq!(file, destination.join("monitor-diagnostics.json"));
        assert_ne!(repeated, file);
        let contents = fs::read_to_string(file).unwrap();
        assert!(!contents.contains("private"));
        assert!(contents.contains("\"timezonePending\": true"));
        assert!(contents.contains("\"level\": \"failed\""));
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
