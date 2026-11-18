use crate::config::write_json;
use crate::machine::{paths_match, Process, TcpSocket};
use crate::net::{is_country_code, is_public_ip, Network};
use crate::report::{Group, Level};
use chrono::{DateTime, Duration, NaiveDateTime, Utc};
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeSet, HashMap, HashSet};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::net::IpAddr;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;
use unicode_normalization::UnicodeNormalization;

const POLICY_URL: &str = "https://support.claude.com/en/articles/8461763-where-can-i-access-claude";
const POLICY_ANCHOR: &str = "You can access Claude in the following locations:";
pub(crate) const ROUTES: &str = "Claude 运行与连接";
const LOGS: &str = "客户端日志告警";
const REGIONS: &str = "官方支持地区";

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct RegionList {
    schema_version: u8,
    source: String,
    fetched_at_utc: DateTime<Utc>,
    countries: Vec<String>,
}

impl RegionList {
    fn current(&self, now: DateTime<Utc>) -> bool {
        self.schema_version == 1
            && self.source == POLICY_URL
            && self.fetched_at_utc >= now - Duration::days(7)
            && self.fetched_at_utc <= now + Duration::minutes(5)
            && valid_countries(&self.countries)
    }
}

fn valid_countries(codes: &[String]) -> bool {
    (100..=250).contains(&codes.len())
        && codes.iter().all(|code| is_country_code(code))
        && codes.iter().collect::<BTreeSet<_>>().len() == codes.len()
}

fn parse_region_list(html: &str, now: DateTime<Utc>) -> Option<RegionList> {
    static LIST: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"(?is)<ul\b[^>]*>(.*?)</ul>").unwrap());
    static ITEM: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"(?is)<li\b[^>]*>(.*?)</li>").unwrap());
    static TAG: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"<[^>]*>").unwrap());
    static NAMES: LazyLock<HashMap<String, String>> = LazyLock::new(|| {
        serde_json::from_str(include_str!("../data/country-name-map.json"))
            .expect("bundled policy name map")
    });
    let after = html.split_once(POLICY_ANCHOR)?.1;
    let list = LIST.captures(after)?.get(1)?.as_str();
    let mut codes = BTreeSet::new();
    for item in ITEM.captures_iter(list) {
        let plain = TAG.replace_all(&item[1], "");
        let decoded = html_escape::decode_html_entities(&plain);
        let key: String = decoded
            .nfd()
            .filter(char::is_ascii_alphanumeric)
            .map(|c| c.to_ascii_lowercase())
            .collect();
        codes.insert(NAMES.get(&key)?.clone());
    }
    let countries: Vec<_> = codes.into_iter().collect();
    valid_countries(&countries).then(|| RegionList {
        schema_version: 1,
        source: POLICY_URL.into(),
        fetched_at_utc: now,
        countries,
    })
}

pub fn supported_region(network: &Network, folder: &Path, country: Option<&str>) -> Group {
    let Some(country) = country.filter(|country| is_country_code(country)) else {
        return Group::new(
            12,
            REGIONS,
            Level::Unknown,
            "没有可靠的 Claude 探测地区，暂停自动启动",
        )
        .gate();
    };
    let now = Utc::now();
    let cached = std::fs::read_to_string(folder.join("supported-regions.json"))
        .ok()
        .and_then(|json| serde_json::from_str::<RegionList>(&json).ok())
        .or_else(|| serde_json::from_str(include_str!("../data/supported-regions.json")).ok())
        .filter(|list| list.current(now));
    let list = if cached
        .as_ref()
        .is_some_and(|list| list.fetched_at_utc >= now - Duration::days(1))
    {
        cached
    } else {
        let fresh = network
            .body(POLICY_URL, 2 * 1024 * 1024)
            .and_then(|html| parse_region_list(&html, now));
        if let Some(ref list) = fresh {
            let _ = write_json(folder, "supported-regions.json", list);
        }
        fresh.or(cached)
    };
    match list {
        Some(list) if list.countries.iter().any(|code| code == country) => Group::new(
            12,
            REGIONS,
            Level::Pass,
            "探测地区在官方名单内。使用资格由 Claude 官方确认",
        ),
        Some(_) => Group::new(12, REGIONS, Level::Failed, "探测地区不在当前官方支持名单内"),
        None => Group::new(
            12,
            REGIONS,
            Level::Unknown,
            "官方地区名单无法刷新，且没有有效缓存",
        )
        .gate(),
    }
}

const SERVICE_SUFFIXES: &[&str] = &[
    "anthropic.com",
    "claude.ai",
    "claude.com",
    "claude.app",
    "claudeusercontent.com",
    "claudemcpcontent.com",
];

fn service_host(host: &str) -> bool {
    let host = host.trim_end_matches('.').to_ascii_lowercase();
    SERVICE_SUFFIXES.iter().any(|suffix| {
        host == *suffix
            || host
                .strip_suffix(suffix)
                .is_some_and(|prefix| prefix.ends_with('.'))
    })
}

fn number(value: &Value) -> Option<u32> {
    value
        .as_u64()
        .and_then(|n| u32::try_from(n).ok())
        .or_else(|| value.as_str()?.parse().ok())
}

type SocketKey = (IpAddr, u32, u32);

fn socket_key(socket: &TcpSocket) -> SocketKey {
    (
        socket.local_ip.to_canonical(),
        socket.local_port.into(),
        socket.remote_port.into(),
    )
}

fn metadata_socket_key(metadata: &Value) -> Option<SocketKey> {
    if metadata["network"].as_str() != Some("tcp") {
        return None;
    }
    let address = metadata["sourceIP"]
        .as_str()?
        .parse::<IpAddr>()
        .ok()?
        .to_canonical();
    Some((
        address,
        number(&metadata["sourcePort"])?,
        number(&metadata["destinationPort"])?,
    ))
}

fn owner<'a>(
    metadata: &Value,
    processes: &'a [Process],
    sockets: &[TcpSocket],
) -> Option<&'a Process> {
    let pid = number(&metadata["processId"]).filter(|pid| *pid != 0);
    let path = metadata["processPath"]
        .as_str()
        .filter(|path| !path.is_empty())
        .map(Path::new);
    if pid.is_some() || path.is_some() {
        return processes.iter().find(|process| {
            pid.is_none_or(|pid| process.pid == pid)
                && path.is_none_or(|path| paths_match(&process.path, path))
        });
    }
    if metadata["process"].as_str().is_some_and(|name| {
        !name.is_empty()
            && !name.eq_ignore_ascii_case("claude")
            && !name.eq_ignore_ascii_case("claude.exe")
    }) {
        return None;
    }
    let key = metadata_socket_key(metadata)?;
    let socket = sockets.iter().find(|socket| socket_key(socket) == key)?;
    // A socket tuple that matches different processes is ambiguous.
    if sockets
        .iter()
        .any(|other| other.pid != socket.pid && socket_key(other) == key)
    {
        return None;
    }
    processes.iter().find(|process| process.pid == socket.pid)
}

fn classify_routes(
    connections: &[Value],
    processes: &[Process],
    socket_snapshot: Option<&[TcpSocket]>,
    expected: &str,
) -> Group {
    let mut observed = 0;
    let mut mismatch = 0;
    let mut ambiguous = false;
    let sockets = socket_snapshot.unwrap_or_default();
    let mut covered = HashSet::new();
    for connection in connections {
        let meta = &connection["metadata"];
        let official = meta["host"].as_str().is_some_and(service_host);
        let Some(process) = owner(meta, processes, sockets) else {
            ambiguous |= official
                && meta["process"]
                    .as_str()
                    .is_some_and(|name| name.eq_ignore_ascii_case("claude.exe"));
            continue;
        };
        if process.started > 0
            && !connection["start"]
                .as_str()
                .and_then(|start| DateTime::parse_from_rfc3339(start).ok())
                .is_some_and(|start| start.timestamp() >= process.started as i64 - 1)
        {
            ambiguous |= official;
            continue;
        }
        if let Some(key) = metadata_socket_key(meta) {
            let matches = sockets
                .iter()
                .filter(|socket| process.pid == socket.pid && socket_key(socket) == key)
                .take(2)
                .count();
            if matches == 1 {
                covered.insert((process.pid, key));
            }
        }
        if !official {
            continue;
        }
        let Some(chain) = connection["chains"]
            .as_array()
            .filter(|chain| !chain.is_empty())
        else {
            ambiguous = true;
            continue;
        };
        observed += 1;
        let direct = chain.iter().any(|hop| hop.as_str() == Some("DIRECT"));
        let matches =
            !expected.is_empty() && chain.iter().any(|hop| hop.as_str() == Some(expected));
        if !matches && (direct || !expected.is_empty()) {
            mismatch += 1;
        }
    }
    let unmatched = sockets
        .iter()
        .filter(|socket| {
            socket.established
                && is_public_ip(socket.remote_ip)
                && processes.iter().any(|process| process.pid == socket.pid)
                && !covered.contains(&(socket.pid, socket_key(socket)))
        })
        .count();
    if mismatch > 0 {
        Group::new(
            13,
            ROUTES,
            Level::Failed,
            format!("确认 {mismatch} 条官方服务连接未走预设节点"),
        )
    } else if unmatched > 0 {
        Group::new(
            13,
            ROUTES,
            Level::Unknown,
            format!(
                "发现 {unmatched} 条 Claude 公网 TCP 连接未在 Clash 快照中匹配，实际线路待核实"
            ),
        )
    } else if socket_snapshot.is_none() {
        Group::new(
            13,
            ROUTES,
            Level::Unknown,
            "Claude 正在运行，无法读取 Windows TCP 连接表",
        )
    } else if observed == 0 || ambiguous || expected.is_empty() {
        Group::new(
            13,
            ROUTES,
            Level::Unknown,
            format!("Claude 正在运行，已归属 {observed} 条连接，证据或预设不足"),
        )
    } else {
        Group::new(
            13,
            ROUTES,
            Level::Pass,
            format!("已归属 {observed} 条官方服务连接，均包含预设节点"),
        )
    }
}

pub fn routes_before_launch() -> Group {
    Group::new(
        13,
        ROUTES,
        Level::PendingLaunch,
        "Claude 未运行，启动后复查",
    )
}

pub fn unidentified_client() -> Group {
    Group::new(
        13,
        ROUTES,
        Level::Unknown,
        "检测到 Claude 进程，尚无法确认桌面客户端的实际连接",
    )
}

pub fn routes_after_launch() -> Group {
    Group::new(
        13,
        ROUTES,
        Level::PendingConnection,
        "已检测到客户端，等待监控核对实际连接",
    )
}

pub fn routes(network: &Network, machine: &crate::machine::Machine, expected: &str) -> Group {
    let processes = &machine.claude;
    if processes.is_empty() {
        return if machine.claude_running {
            unidentified_client()
        } else {
            routes_before_launch()
        };
    }
    let snapshot = network.get::<Value>(&["connections"]);
    match snapshot
        .as_ref()
        .and_then(|value| value["connections"].as_array())
    {
        Some(connections) => classify_routes(
            connections,
            processes,
            crate::machine::tcp_sockets().as_deref(),
            expected,
        ),
        None => Group::new(
            13,
            ROUTES,
            Level::Unknown,
            "Claude 正在运行，无法读取代理连接元数据",
        ),
    }
}

fn log_category(line: &str) -> Option<&'static str> {
    static CONTEXT: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"(?i)\berror\b|APIError|http[_ ]?status|request failed|auth(?:entication)?[_ -]?(?:error|failed)|response[_ -]?(?:error|status)").unwrap()
    });
    static SIGNALS: LazyLock<Vec<(&str, Regex)>> = LazyLock::new(|| {
        [
            ("账号限制", r"account_(?:disabled|suspended|banned)|your account (?:has been|is) (?:disabled|suspended|banned)"),
            ("地区限制", r"unsupported_(?:country|region|location)|not (?:available|supported) in your (?:country|region)"),
            ("账单", r#"billing_error|payment_required|status[\s":_=-]*402\b"#),
            ("限流", r#"rate_limit_error|(?:status|http)[\s":_=-]*429\b"#),
            ("认证", r#"authentication_error|(?:status|http)[\s":_=-]*401\b"#),
            ("权限", r#"permission_error|(?:status|http)[\s":_=-]*403\b"#),
            ("服务端错误", r#"overloaded_error|(?:status|http)[\s":_=-]*5(?:00|02|03|04|29)\b"#),
        ].into_iter().map(|(name, pattern)| (name, Regex::new(&format!("(?i){pattern}")).unwrap())).collect()
    });
    if !CONTEXT.is_match(line) {
        return None;
    }
    SIGNALS
        .iter()
        .find_map(|(label, pattern)| pattern.is_match(line).then_some(*label))
}

fn log_time(line: &str) -> Option<DateTime<Utc>> {
    static STAMP: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"^.{0,3}(\d{4}-\d{2}-\d{2}[T ][0-9:.]+(?:Z|[+-]\d{2}:?\d{2})?)").unwrap()
    });
    let record;
    let raw = if line.trim_start().starts_with('{') {
        record = serde_json::from_str::<Value>(line).ok()?;
        ["timestamp", "time", "ts"]
            .into_iter()
            .find_map(|key| record[key].as_str())?
    } else {
        STAMP.captures(line)?.get(1)?.as_str()
    };
    let normalized = raw.replace(' ', "T");
    if let Ok(timestamp) = DateTime::parse_from_rfc3339(&normalized) {
        return Some(timestamp.to_utc());
    }
    let date = NaiveDateTime::parse_from_str(&normalized, "%Y-%m-%dT%H:%M:%S%.f").ok()?;
    date.and_local_timezone(chrono::Local)
        .single()
        .map(|value| value.to_utc())
}

fn tail(path: &Path) -> Option<String> {
    const MAX_BYTES: u64 = 256 * 1024;
    let mut file = File::open(path).ok()?;
    let skip = file.metadata().ok()?.len().saturating_sub(MAX_BYTES);
    file.seek(SeekFrom::Start(skip)).ok()?;
    let mut data = Vec::new();
    file.take(MAX_BYTES).read_to_end(&mut data).ok()?;
    let text = String::from_utf8_lossy(&data);
    if skip == 0 {
        Some(text.into_owned())
    } else {
        Some(text.split_once('\n')?.1.to_owned())
    }
}

pub fn logs(paths: &[PathBuf], now: DateTime<Utc>) -> Group {
    let mut recent = false;
    let mut categories = BTreeSet::new();
    for base in paths {
        for name in ["main.log", "claude.ai-web.log"] {
            let Some(body) = tail(&base.join(name)) else {
                continue;
            };
            for line in body.lines() {
                if log_time(line).is_some_and(|time| {
                    time >= now - Duration::hours(2) && time <= now + Duration::minutes(5)
                }) {
                    recent = true;
                    categories.extend(log_category(line));
                }
            }
        }
    }
    if !categories.is_empty() {
        let names = categories.into_iter().collect::<Vec<_>>().join("、");
        Group::new(
            14,
            LOGS,
            Level::Warning,
            format!("近期日志告警类别：{names}。请在 Claude 内核对当前状态"),
        )
    } else if recent {
        Group::new(
            14,
            LOGS,
            Level::Pass,
            "最近两小时的可用日志中未发现匹配的告警",
        )
    } else {
        Group::new(14, LOGS, Level::NoData, "暂无最近两小时的可用日志")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn service_matching_requires_a_domain_boundary() {
        assert!(service_host("Sso.Claude.com"));
        assert!(!service_host("evilclaude.com"));
        assert!(!service_host("claude.com.example.invalid"));
    }

    #[test]
    fn route_requires_process_evidence_and_distinguishes_direct_hops() {
        let processes = [Process {
            pid: 7,
            path: "C:/fixture/Claude.exe".into(),
            started: 0,
        }];
        let mut route = serde_json::json!({"metadata": {"host": "api.anthropic.com", "processId": 7}, "chains": ["expected", "DIRECT"]});
        assert_eq!(
            classify_routes(&[route.clone()], &processes, Some(&[]), "expected").level,
            Level::Pass
        );
        route["chains"] = serde_json::json!(["DIRECT"]);
        assert_eq!(
            classify_routes(&[route.clone()], &processes, Some(&[]), "expected").level,
            Level::Failed
        );
        route["metadata"]["processId"] = serde_json::json!(8);
        assert_eq!(
            classify_routes(&[route], &processes, Some(&[]), "expected").level,
            Level::Unknown
        );
    }

    #[test]
    fn unmatched_public_claude_socket_prevents_a_pass() {
        let process = Process {
            pid: 7,
            path: "C:/fixture/Claude.exe".into(),
            started: 0,
        };
        let mut socket = TcpSocket {
            pid: 7,
            local_ip: "192.168.0.10".parse().unwrap(),
            local_port: 50010,
            remote_ip: "1.1.1.1".parse().unwrap(),
            remote_port: 443,
            established: true,
        };
        let observed = serde_json::json!({"metadata": {"host": "api.anthropic.com", "processId": 7}, "chains": ["expected"]});
        let result = classify_routes(
            &[observed.clone()],
            std::slice::from_ref(&process),
            Some(std::slice::from_ref(&socket)),
            "expected",
        );
        assert_eq!(result.level, Level::Unknown);
        assert!(result.detail.contains("1 条 Claude 公网 TCP 连接"));
        let matching_non_service = serde_json::json!({"metadata": {"host": "fixture.example", "processId": 7, "network": "tcp", "sourceIP": "192.168.0.10", "sourcePort": 50010, "destinationPort": "443"}});
        assert_eq!(
            classify_routes(
                &[observed.clone(), matching_non_service],
                std::slice::from_ref(&process),
                Some(std::slice::from_ref(&socket)),
                "expected"
            )
            .level,
            Level::Pass
        );
        socket.remote_ip = "198.18.0.7".parse().unwrap();
        assert_eq!(
            classify_routes(&[observed], &[process], Some(&[socket]), "expected").level,
            Level::Pass
        );
    }

    #[test]
    fn logs_recognize_timestamped_json_errors() {
        let folder = tempfile::tempdir().unwrap();
        let now = Utc::now();
        let line = serde_json::json!({"timestamp": now.to_rfc3339(), "level": "error", "status": 529, "message": "fixture-private-text"});
        std::fs::write(folder.path().join("main.log"), line.to_string()).unwrap();
        let result = logs(&[folder.path().to_owned()], now);
        assert_eq!(result.level, Level::Warning);
        assert!(result.detail.contains("服务端错误"));
        assert!(!result.detail.contains("fixture-private-text"));
    }

    #[test]
    fn logs_record_categories_only() {
        let folder = tempfile::tempdir().unwrap();
        let now = Utc::now();
        let payload = format!(
            "{} Error: account_disabled session-private-text\n{} chat: unsupported_region",
            now.to_rfc3339(),
            now.to_rfc3339()
        );
        std::fs::write(folder.path().join("main.log"), payload).unwrap();
        let report = logs(&[folder.path().to_owned()], now);
        assert_eq!(report.level, Level::Warning);
        assert!(report.detail.contains("账号限制"));
        assert!(!report.detail.contains("session-private-text"));
        assert!(!report.detail.contains("地区限制"));
    }

    #[test]
    fn stale_or_incomplete_region_evidence_is_rejected() {
        let now = Utc::now();
        let seed: RegionList =
            serde_json::from_str(include_str!("../data/supported-regions.json")).unwrap();
        assert!(seed.current(seed.fetched_at_utc));
        assert!(!seed.current(seed.fetched_at_utc + Duration::days(8)));
        let malformed = format!("{POLICY_ANCHOR}<ul><li>United States</li></ul>");
        assert!(parse_region_list(&malformed, now).is_none());
    }
}
