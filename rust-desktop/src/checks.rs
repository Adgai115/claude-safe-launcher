use crate::config::Config;
use crate::machine::{self, Ipv6Probe, Machine};
use crate::net::{is_public_ip, Network, Trace};
use crate::observations;
use crate::report::{Group, Level, Report};
use crate::timezone;
use crate::vpn;
use chrono::Utc;
use serde::{Deserialize, Serialize};
use std::fs::File;
use std::io::{ErrorKind, Read};
use std::net::{IpAddr, ToSocketAddrs};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

pub use crate::observations::{routes_after_launch, routes_before_launch};

const FRONT_TRACE: &str = "https://claude.ai/cdn-cgi/trace";
const API_TRACE: &str = "https://api.anthropic.com/cdn-cgi/trace";
const TUN: &str = "代理客户端与 TUN";
const ZONE: &str = "系统时区";
const NODE: &str = "策略组与预设节点";
const EXIT: &str = "出口一致性";
const IP_RISK: &str = "IP 风险";
const IP_RISK_WARNING: u64 = 33;
const IP_RISK_FAILURE: u64 = 66;

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Action {
    Check,
    Learn,
    Repair,
    Launch,
}

impl Action {
    pub fn when_running(self, running: bool) -> Result<Self, String> {
        match (running, self) {
            (true, Self::Learn) => {
                Err("Claude 正在运行，环境基准已锁定。请退出 Claude 后再修改".into())
            }
            (true, Self::Repair | Self::Launch) => Ok(Self::Check),
            _ => Ok(self),
        }
    }
}

fn measure(check: impl FnOnce() -> Group) -> Group {
    let started = Instant::now();
    let mut group = check();
    group.elapsed_ms = started.elapsed().as_millis() as u64;
    group.observed_at = Utc::now();
    group
}

fn timed<T>(probe: impl FnOnce() -> T) -> (T, u64) {
    let started = Instant::now();
    (probe(), started.elapsed().as_millis() as u64)
}

struct Exits {
    front: Option<Trace>,
    api: Option<Trace>,
    local: Option<IpAddr>,
    front_peer: Option<IpAddr>,
}

impl Exits {
    fn confirmed(&self) -> Option<&Trace> {
        self.front
            .as_ref()
            .filter(|front| self.api.as_ref().is_none_or(|api| api == *front))
    }
}

fn probe_exits(network: &Network) -> Exits {
    std::thread::scope(|scope| {
        let front = scope.spawn(|| network.trace_with_peer(FRONT_TRACE));
        let api = scope.spawn(|| network.trace(API_TRACE));
        let local = scope.spawn(|| {
            network
                .body("https://api.ipify.org", 128)
                .and_then(|ip| ip.trim().parse().ok())
        });
        let (front, front_peer) = match front.join().expect("frontend trace") {
            Some((trace, peer)) => (Some(trace), peer),
            None => (None, None),
        };
        Exits {
            front,
            api: api.join().expect("API trace"),
            local: local.join().expect("public trace"),
            front_peer,
        }
    })
}

fn probe_nodes(config: &Config, network: &Network) -> Vec<(String, Option<String>)> {
    let mut nodes: Vec<_> = config
        .groups()
        .filter_map(|name| {
            network
                .group(name)
                .map(|group| (name.to_owned(), Some(group.now)))
        })
        .collect();
    if nodes.is_empty() && network.is_clash_mi() {
        nodes.push((
            "GLOBAL".into(),
            network.group("GLOBAL").map(|group| group.now),
        ));
    }
    nodes
}

fn tun_group(machine: &Machine, enabled: Option<bool>) -> Group {
    match (machine.proxy_running, machine.tun_up, enabled) {
        (true, Some(true), Some(true)) => {
            Group::new(1, TUN, Level::Pass, "代理内核、TUN 适配器和控制器均就绪")
                .reason("proxy_tun_ready")
        }
        (false, _, _) => Group::new(1, TUN, Level::Failed, "代理内核未运行")
            .reason("proxy_core_not_running")
            .gate(),
        (_, Some(false), _) => Group::new(1, TUN, Level::Failed, "系统 TUN 适配器未就绪")
            .reason("tun_adapter_down")
            .gate(),
        (_, _, Some(false)) => Group::new(1, TUN, Level::Failed, "代理控制器中的 TUN 尚未启用")
            .reason("tun_controller_disabled")
            .gate(),
        _ => Group::new(1, TUN, Level::Unknown, "无法完整确认控制器与系统 TUN 状态")
            .reason("tun_state_unverified")
            .gate(),
    }
}

fn zone_group(config: &Config, timezone: Option<&str>) -> Group {
    match timezone {
        Some(zone) if config.timezone.is_empty() => {
            Group::new(2, ZONE, Level::Unknown, format!("当前为 {zone}，尚无基准"))
                .reason("timezone_baseline_missing")
                .gate()
        }
        Some(zone) if config.timezone == zone => {
            Group::new(2, ZONE, Level::Pass, format!("与预设一致：{zone}"))
                .reason("timezone_baseline_match")
        }
        Some(zone) => Group::new(
            2,
            ZONE,
            Level::Warning,
            format!("当前 {zone}，预设 {}", config.timezone),
        )
        .reason("timezone_baseline_mismatch")
        .gate(),
        None => Group::new(2, ZONE, Level::Unknown, "无法读取 Windows 时区")
            .reason("timezone_unreadable")
            .gate(),
    }
}

fn nodes_group(config: &Config, nodes: &[(String, Option<String>)]) -> Group {
    let mut details = Vec::new();
    let mut unknown = config.expected_node.is_empty();
    let mut failed = false;
    for (name, selected) in nodes {
        match selected {
            Some(node) if !is_proxy_node(node) => {
                failed = true;
                details.push(format!("{name}：当前未选择代理节点"));
            }
            Some(node) => {
                let differs = !config.expected_node.is_empty() && node != &config.expected_node;
                failed |= differs;
                details.push(format!(
                    "{name}：{node}{}",
                    if differs { "（偏离预设）" } else { "" }
                ));
            }
            None => {
                unknown = true;
                details.push(format!("{name}：无法读取"));
            }
        }
    }
    let level = if failed {
        Level::Failed
    } else if unknown {
        Level::Unknown
    } else {
        Level::Pass
    };
    if details.is_empty() {
        details.push("代理控制器未返回可用策略组".into());
    }
    let reason = if failed {
        "proxy_node_unsafe"
    } else if nodes.is_empty() {
        "proxy_groups_unavailable"
    } else if nodes.iter().any(|(_, selected)| selected.is_none()) {
        "proxy_node_unreadable"
    } else if config.expected_node.is_empty() {
        "proxy_node_baseline_missing"
    } else {
        "proxy_node_baseline_match"
    };
    let item = Group::new(3, NODE, level, details.join("\n")).reason(reason);
    if unknown {
        item.gate()
    } else {
        item
    }
}

fn is_proxy_node(node: &str) -> bool {
    let normalized = node.trim().to_ascii_uppercase();
    !matches!(
        normalized.as_str(),
        "" | "DIRECT" | "REJECT" | "REJECT-DROP" | "PASS" | "COMPATIBLE"
    )
}

fn trace_group(config: &Config, exits: &Exits) -> Group {
    let Some(front) = exits.front.as_ref() else {
        return Group::new(4, EXIT, Level::Unknown, "Claude 网页出口无法确认")
            .reason("exit_front_unavailable")
            .gate();
    };
    if exits.confirmed().is_none() {
        return Group::new(
            4,
            EXIT,
            Level::Failed,
            "Claude 网页与 API 探测出口或地区不一致",
        )
        .reason("exit_probe_mismatch");
    }
    let mut detail = format!("已读到 Claude 网页出口（{}）", front.country);
    if exits.api.is_none() {
        detail.push_str("\nAPI 端点未返回出口探测结果");
    }
    match exits.local {
        Some(local) if local != front.ip => {
            detail.push_str("\n通用 IP 查询与 Claude 出口不同，可能是分流");
        }
        Some(_) => detail.push_str("\n通用 IP 查询与 Claude 出口一致"),
        None => detail.push_str("\n通用 IP 查询暂无结果"),
    }
    if config.expected_ip.is_none() || config.expected_loc.is_empty() {
        detail.push_str("\n正在等待建立出口基准");
        return Group::new(4, EXIT, Level::Unknown, detail)
            .reason("exit_baseline_missing")
            .gate();
    }
    if config.expected_ip != Some(front.ip) || config.expected_loc != front.country {
        return Group::new(4, EXIT, Level::Failed, "探测出口或地区与已记录的预设不一致")
            .reason("exit_baseline_mismatch");
    }
    detail.push_str("\nClaude 出口与基准一致");
    Group::new(4, EXIT, Level::Pass, detail).reason("exit_baseline_match")
}

fn learn_exit(config: &mut Config, exits: &Exits, replace: bool) -> bool {
    let Some(trace) = exits.confirmed() else {
        return false;
    };
    if !replace
        && (config.expected_ip.is_some_and(|ip| ip != trace.ip)
            || (!config.expected_loc.is_empty() && config.expected_loc != trace.country))
    {
        return false;
    }
    let changed = config.expected_ip != Some(trace.ip) || config.expected_loc != trace.country;
    config.expected_ip = Some(trace.ip);
    config.expected_loc.clone_from(&trace.country);
    changed
}

fn learn_node(config: &mut Config, selected: Option<&str>, replace: bool) -> bool {
    if !replace && !config.expected_node.is_empty() {
        return false;
    }
    let Some(node) = selected.filter(|node| is_proxy_node(node)) else {
        return false;
    };
    let changed = config.expected_node != node;
    config.expected_node = node.to_owned();
    changed
}

fn windows_timezone(iana: &str) -> Option<&'static str> {
    // Match the mapping used by the Windows PowerShell panel.
    Some(match iana {
        "America/New_York" | "America/Detroit" | "America/Toronto" => "Eastern Standard Time",
        "America/Chicago" => "Central Standard Time",
        "America/Denver" => "Mountain Standard Time",
        "America/Phoenix" => "US Mountain Standard Time",
        "America/Los_Angeles" | "America/Vancouver" => "Pacific Standard Time",
        "America/Anchorage" => "Alaskan Standard Time",
        "Pacific/Honolulu" => "Hawaiian Standard Time",
        "America/Sao_Paulo" => "E. South America Standard Time",
        "Europe/London" | "Europe/Dublin" | "Europe/Lisbon" => "GMT Standard Time",
        "Europe/Berlin" | "Europe/Amsterdam" | "Europe/Zurich" | "Europe/Stockholm"
        | "Europe/Vienna" | "Europe/Rome" => "W. Europe Standard Time",
        "Europe/Paris" | "Europe/Brussels" | "Europe/Madrid" => "Romance Standard Time",
        "Europe/Warsaw" => "Central European Standard Time",
        "Europe/Prague" => "Central Europe Standard Time",
        "Europe/Helsinki" => "FLE Standard Time",
        "Asia/Tokyo" => "Tokyo Standard Time",
        "Asia/Seoul" => "Korea Standard Time",
        "Asia/Singapore" | "Asia/Kuala_Lumpur" => "Singapore Standard Time",
        "Asia/Taipei" => "Taipei Standard Time",
        "Asia/Bangkok" => "SE Asia Standard Time",
        "Asia/Dubai" => "Arabian Standard Time",
        "Asia/Kolkata" => "India Standard Time",
        "Australia/Sydney" | "Australia/Melbourne" => "AUS Eastern Standard Time",
        "Pacific/Auckland" => "New Zealand Standard Time",
        _ => return None,
    })
}

fn exit_timezone(network: &Network, trace: &Trace) -> Option<(String, &'static str)> {
    #[derive(Deserialize)]
    struct Location {
        ip: IpAddr,
        country: String,
        timezone: String,
    }
    let url = format!("https://ipinfo.io/{}/json", trace.ip);
    let result: Location = serde_json::from_str(&network.body(&url, 16 * 1024)?).ok()?;
    if result.ip != trace.ip || result.country != trace.country {
        return None;
    }
    let windows = windows_timezone(&result.timezone)?;
    Some((result.timezone, windows))
}

fn ip_risk(network: &Network, trace: Option<&Trace>) -> Group {
    let Some(trace) = trace else {
        return Group::new(
            5,
            IP_RISK,
            Level::Unknown,
            "缺少 Claude 出口 IP，无法查询第三方风险",
        );
    };
    let risk = (|| {
        let url = format!("https://proxycheck.io/v2/{}?vpn=1&asn=1&risk=1", trace.ip);
        let body = network.body(&url, 64 * 1024)?;
        let value: serde_json::Value = serde_json::from_str(&body).ok()?;
        let risk = &value[trace.ip.to_string()]["risk"];
        risk.as_u64().or_else(|| risk.as_str()?.parse().ok())
    })();
    ip_risk_group(risk)
}

fn ip_risk_group(risk: Option<u64>) -> Group {
    let Some(score) = risk.filter(|&score| score <= 100) else {
        return Group::new(5, IP_RISK, Level::Unknown, "第三方查询未返回有效风险分");
    };
    let (level, detail) = if score >= IP_RISK_FAILURE {
        (Level::Failed, format!("达到高风险阈值 {IP_RISK_FAILURE}"))
    } else if score >= IP_RISK_WARNING {
        (Level::Warning, format!("达到警告阈值 {IP_RISK_WARNING}"))
    } else {
        (Level::Pass, format!("低于警告阈值 {IP_RISK_WARNING}"))
    };
    Group::new(
        5,
        IP_RISK,
        level,
        format!("第三方风险分 {score}/100，{detail}"),
    )
}

fn repair_clash_mi_exit(folder: &Path, config: &mut Config, network: &Network) -> bool {
    if !network.is_clash_mi() {
        return false;
    }
    let Some((group_name, selected)) = probe_nodes(config, network).into_iter().next() else {
        return false;
    };
    let Some(group) = network.group(&group_name) else {
        return false;
    };
    let original = selected.unwrap_or(group.now);
    let mut candidates = vec![original.clone()];
    for node in group.all {
        if is_proxy_node(&node) && !candidates.contains(&node) {
            candidates.push(node);
        }
        if candidates.len() >= 6 {
            break;
        }
    }
    for node in candidates {
        if node != original {
            if !network.select(config, &group_name, &node) {
                continue;
            }
            let _ = network.reset_connections(config);
            std::thread::sleep(Duration::from_secs(2));
        }
        let exits = probe_exits(network);
        let Some(trace) = exits.confirmed() else {
            continue;
        };
        let (api, _) = api_reachable(network);
        let region = observations::supported_region(network, folder, Some(&trace.country));
        let risk = ip_risk(network, Some(trace));
        let dns = dns(true);
        if api.level != Level::Pass
            || region.level != Level::Pass
            || risk.level != Level::Pass
            || !matches!(dns.level, Level::Pass | Level::Reference)
        {
            continue;
        }
        let changed = config.expected_node != node
            || config.expected_ip != Some(trace.ip)
            || config.expected_loc != trace.country
            || config.vpn_interface.is_some();
        config.expected_node = node;
        config.expected_ip = Some(trace.ip);
        config.expected_loc.clone_from(&trace.country);
        config.vpn_interface = None;
        if let Some((iana, windows)) = exit_timezone(network, trace) {
            config.expected_tz_iana = iana;
            config.timezone = windows.into();
        }
        return changed;
    }
    if network
        .group(&group_name)
        .is_some_and(|group| group.now != original)
        && network.select(config, &group_name, &original)
    {
        let _ = network.reset_connections(config);
    }
    false
}

fn ip_protocol(front: Option<&Trace>, ipv6_probe: Ipv6Probe) -> Group {
    let front_ip = front.map(|trace| trace.ip);
    let claude = match front_ip {
        Some(IpAddr::V4(_)) => "Claude 探测使用 IPv4",
        Some(IpAddr::V6(_)) => "Claude 探测使用 IPv6",
        None => "缺少 Claude 出口探测结果",
    };
    let (level, ipv6) = match ipv6_probe {
        Ipv6Probe::Reachable => (
            Level::Pass,
            "独立探测已获取通用 IPv6 出口，Claude 的 IPv6 路由需结合实际连接核对",
        ),
        Ipv6Probe::NoPublicRoute if front_ip.is_some_and(|ip| ip.is_ipv4()) => {
            (Level::Pass, "Windows 路由表未发现公网 IPv6 路由")
        }
        Ipv6Probe::NoPublicRoute => (
            Level::Unknown,
            "Windows 路由表未发现公网 IPv6 路由，且未确认 Claude 使用 IPv4",
        ),
        Ipv6Probe::PublicRouteUnreachable => (
            Level::Unknown,
            "Windows 有公网 IPv6 路由，但出口探测未取得有效结果",
        ),
        Ipv6Probe::Unverified => (
            Level::Unknown,
            "出口探测没有有效结果，Windows IPv6 路由表也无法读取",
        ),
    };
    Group::new(7, "IPv6 出口探测", level, format!("{claude}\n{ipv6}"))
}

fn network_protocol(
    clash: bool,
    config: &Config,
    front: Option<&Trace>,
    result: Ipv6Probe,
) -> Group {
    let group = ip_protocol(front, result);
    if !clash && result == Ipv6Probe::Reachable {
        return vpn::verify_ipv6(group, config.vpn_interface.as_deref());
    }
    group
}

fn dns(clash: bool) -> Group {
    let title = "系统 DNS";
    match ("claude.ai", 443).to_socket_addrs() {
        Ok(addresses) => {
            let ips: Vec<_> = addresses.map(|address| address.ip()).collect();
            let fake = ips.iter().any(|ip| matches!(ip, IpAddr::V4(v4) if v4.octets()[0] == 198 && (18..=19).contains(&v4.octets()[1])));
            if !clash {
                let public = !fake && ips.iter().any(|&address| is_public_ip(address));
                let (level, detail, reason) = if fake {
                    (
                        Level::Unknown,
                        "系统 DNS 返回 TUN 常用 Fake IP，正在等待核对 VPN 路由",
                        "dns_fake_ip_unverified",
                    )
                } else if public {
                    (
                        Level::Pass,
                        "系统 DNS 已返回 claude.ai 的公网地址",
                        "dns_public_resolution",
                    )
                } else {
                    (
                        Level::Unknown,
                        "当前 VPN 模式下未确认 claude.ai 的公网解析",
                        "dns_resolution_unverified",
                    )
                };
                Group::new(6, title, level, detail).reason(reason)
            } else if fake {
                Group::new(
                    6,
                    title,
                    Level::Pass,
                    "系统解析返回 Clash 常用 Fake IP 网段",
                )
                .reason("dns_clash_fake_ip")
            } else if ips.iter().any(|&address| is_public_ip(address)) {
                Group::new(
                    6,
                    title,
                    Level::Unknown,
                    "系统 DNS 返回公网地址，正在核对 Clash TUN 状态",
                )
                .reason("dns_clash_public_unverified")
            } else {
                Group::new(
                    6,
                    title,
                    Level::Unknown,
                    "Clash 模式下未确认 claude.ai 的有效解析",
                )
                .reason("dns_clash_resolution_unverified")
            }
        }
        Err(_) => Group::new(6, title, Level::Unknown, "系统无法解析 claude.ai")
            .reason("dns_resolution_failed"),
    }
}

fn confirm_tun_dns(group: &mut Group, interface_confirmed: bool) {
    if !interface_confirmed {
        return;
    }
    let (detail, reason) = match group.reason_code {
        Some("dns_fake_ip_unverified") => (
            "系统 DNS 返回 Fake IP，且 Claude 网页与 API 已核对为同一 TUN 接口",
            "dns_fake_ip_verified_tun",
        ),
        Some("dns_clash_public_unverified") => (
            "系统 DNS 返回公网地址，且 Clash 控制器与 Windows TUN 均已确认",
            "dns_clash_public_verified_tun",
        ),
        _ => return,
    };
    {
        group.level = Level::Pass;
        group.earned = group.weight;
        group.blocks_launch = false;
        group.detail = detail.into();
        group.reason_code = Some(reason);
    }
}

fn api_reachable(network: &Network) -> (Group, Option<IpAddr>) {
    let title = "Anthropic API 连通性";
    let result = network
        .web
        .get("https://api.anthropic.com/v1/messages")
        .send();
    let (group, peer) = match result {
        Ok(response) if matches!(response.status().as_u16(), 200 | 400 | 401 | 404 | 405) => (
            Group::new(8, title, Level::Pass, "服务已响应无凭据连通性探测"),
            response.remote_addr().map(|socket| socket.ip()),
        ),
        Ok(response) => (
            Group::new(
                8,
                title,
                Level::Unknown,
                format!(
                    "探测返回 HTTP {}，请核对客户端连接",
                    response.status().as_u16()
                ),
            )
            .gate(),
            None,
        ),
        Err(_) => (
            Group::new(8, title, Level::Unknown, "HTTPS 连接失败或超时").gate(),
            None,
        ),
    };
    (group, peer)
}

fn variables() -> Group {
    let names = [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_MODEL",
    ]
    .into_iter()
    .filter(|name| std::env::var_os(name).is_some())
    .collect::<Vec<_>>();
    let text = if names.is_empty() {
        "未发现常见 Claude Code 变量".to_owned()
    } else {
        format!("保留已设置变量：{}。仅显示变量名", names.join("、"))
    };
    Group::new(9, "环境变量", Level::Pass, text)
}

fn is_custom_endpoint(value: &str) -> bool {
    let value = value.trim();
    !value.is_empty()
        && !reqwest::Url::parse(value).is_ok_and(|url| {
            url.scheme() == "https"
                && url.host_str() == Some("api.anthropic.com")
                && url.port().is_none()
                && url.username().is_empty()
                && url.password().is_none()
        })
}

#[derive(Deserialize)]
struct EndpointEnv {
    #[serde(rename = "ANTHROPIC_BASE_URL")]
    endpoint: Option<String>,
}

#[derive(Deserialize)]
struct EndpointSettings {
    #[serde(rename = "ANTHROPIC_BASE_URL")]
    endpoint: Option<String>,
    env: Option<EndpointEnv>,
}

fn file_has_custom_endpoint(path: &Path) -> Result<bool, ()> {
    const MAX_SIZE: u64 = 1024 * 1024;
    let file = match File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(false),
        Err(_) => return Err(()),
    };
    let mut bytes = Vec::new();
    file.take(MAX_SIZE + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| ())?;
    if bytes.len() as u64 > MAX_SIZE {
        return Err(());
    }
    let bytes = bytes.strip_prefix(b"\xef\xbb\xbf").unwrap_or(&bytes);
    let settings: EndpointSettings = serde_json::from_slice(bytes).map_err(|_| ())?;
    Ok(settings.endpoint.as_deref().is_some_and(is_custom_endpoint)
        || settings
            .env
            .and_then(|env| env.endpoint)
            .as_deref()
            .is_some_and(is_custom_endpoint))
}

fn endpoint_results(process_value: Option<&str>, folder: Option<&Path>) -> Group {
    let title = "Claude Code 接口";
    let mut findings = Vec::new();
    let mut unchecked = Vec::new();
    if process_value.is_some_and(is_custom_endpoint) {
        findings.push("当前进程环境");
    }
    if let Some(folder) = folder {
        for name in ["settings.json", "settings.local.json", "config.json"] {
            match file_has_custom_endpoint(&folder.join(name)) {
                Ok(true) => findings.push(name),
                Ok(false) => {}
                Err(()) => unchecked.push(name),
            }
        }
    } else {
        unchecked.push("未找到用户配置目录");
    }
    if !findings.is_empty() {
        let mut detail = format!("发现自定义 ANTHROPIC_BASE_URL · {}", findings.join("、"));
        if !unchecked.is_empty() {
            detail.push_str(&format!("\n未能核对 · {}", unchecked.join("、")));
        }
        Group::new(10, title, Level::Warning, detail)
    } else if !unchecked.is_empty() {
        Group::new(
            10,
            title,
            Level::Unknown,
            format!("未能核对 · {}", unchecked.join("、")),
        )
    } else {
        Group::new(
            10,
            title,
            Level::Pass,
            "当前进程环境与用户配置未发现自定义 ANTHROPIC_BASE_URL",
        )
    }
}

fn endpoint() -> Group {
    let folder = claude_config_folder();
    endpoint_results(
        std::env::var("ANTHROPIC_BASE_URL").ok().as_deref(),
        folder.as_deref(),
    )
}

fn claude_config_folder() -> Option<PathBuf> {
    std::env::var_os("CLAUDE_CONFIG_DIR")
        .filter(|path| !path.is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("USERPROFILE").map(|home| PathBuf::from(home).join(".claude")))
}

fn repair_custom_endpoints() -> bool {
    const OFFICIAL: &str = "https://api.anthropic.com";
    let mut changed = false;
    if std::env::var("ANTHROPIC_BASE_URL")
        .ok()
        .as_deref()
        .is_some_and(is_custom_endpoint)
    {
        std::env::set_var("ANTHROPIC_BASE_URL", OFFICIAL);
        changed = true;
    }
    let Some(folder) = claude_config_folder() else {
        return changed;
    };
    for name in ["settings.json", "settings.local.json", "config.json"] {
        let path = folder.join(name);
        let Ok(bytes) = std::fs::read(&path) else {
            continue;
        };
        if bytes.len() > 1024 * 1024 {
            continue;
        }
        let bytes = bytes.strip_prefix(b"\xef\xbb\xbf").unwrap_or(&bytes);
        let Ok(mut value) = serde_json::from_slice::<serde_json::Value>(bytes) else {
            continue;
        };
        let mut file_changed = false;
        if value["ANTHROPIC_BASE_URL"]
            .as_str()
            .is_some_and(is_custom_endpoint)
        {
            value["ANTHROPIC_BASE_URL"] = OFFICIAL.into();
            file_changed = true;
        }
        if value["env"]["ANTHROPIC_BASE_URL"]
            .as_str()
            .is_some_and(is_custom_endpoint)
        {
            value["env"]["ANTHROPIC_BASE_URL"] = OFFICIAL.into();
            file_changed = true;
        }
        if file_changed && crate::config::write_json(&folder, name, &value).is_ok() {
            changed = true;
        }
    }
    changed
}

fn browser_info(
    config: &Config,
    zone: &str,
    webrtc: Option<&[IpAddr]>,
    front: Option<&Trace>,
) -> Group {
    let title = "面板时区与 WebRTC";
    let mut group = if zone.is_empty() || config.expected_tz_iana.is_empty() {
        Group::new(11, title, Level::NoData, "缺少面板时区或已记住的时区参考")
    } else if config.expected_tz_iana == zone {
        Group::new(11, title, Level::Pass, "面板时区与基准一致")
    } else {
        Group::new(11, title, Level::Reference, "面板时区与基准不同，仅供参考")
    };
    group.detail.push_str("\n");
    let result = match webrtc {
        None => "WebView2 无可用的 WebRTC 探测结果",
        Some(addresses) => {
            let mut public = addresses
                .iter()
                .map(|ip| ip.to_canonical())
                .filter(|&ip| is_public_ip(ip))
                .peekable();
            if public.peek().is_none() {
                "WebView2 WebRTC 未观测到公网候选地址"
            } else if let Some(exit) = front {
                if public.all(|address| address == exit.ip.to_canonical()) {
                    "WebView2 WebRTC 公网候选与 Claude 网页出口一致"
                } else {
                    "WebView2 WebRTC 观测到与 Claude 网页出口不同的公网候选"
                }
            } else {
                "WebView2 WebRTC 已观测到公网候选，缺少 Claude 网页出口用于比对"
            }
        }
    };
    group.detail.push_str(result);
    group
}

#[derive(Default)]
struct Repairs {
    timezone: bool,
    timezone_error: Option<String>,
    nodes: bool,
    tun: bool,
    endpoint: bool,
}

impl Repairs {
    fn merge(&mut self, next: Self) {
        self.timezone |= next.timezone;
        self.nodes |= next.nodes;
        self.tun |= next.tun;
        self.endpoint |= next.endpoint;
        if next.timezone_error.is_some() {
            self.timezone_error = next.timezone_error;
        }
    }
}

#[derive(Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RepairChange {
    check_id: u8,
    label: String,
    before: String,
    after: String,
}

struct RepairPlan {
    config: Config,
    changes: Vec<RepairChange>,
    tun: bool,
    nodes: Vec<(String, String)>,
    timezone: bool,
    baseline: bool,
}

impl RepairPlan {
    fn change(&mut self, check_id: u8, label: impl Into<String>, before: &str, after: &str) {
        if before != after {
            self.changes.push(RepairChange {
                check_id,
                label: label.into(),
                before: before.to_owned(),
                after: after.to_owned(),
            });
        }
    }
}

fn require_repair_approval(
    changes: &[RepairChange],
    approved: Option<&[RepairChange]>,
    automatic: bool,
) -> Result<(), String> {
    if automatic || approved == Some(changes) {
        Ok(())
    } else {
        Err("修复方案已变化，请重新预览并确认".into())
    }
}

fn prepare_repair(config: &Config, network: &Network, machine: &Machine) -> RepairPlan {
    let mut plan = RepairPlan {
        config: config.clone(),
        changes: Vec::new(),
        tun: false,
        nodes: Vec::new(),
        timezone: false,
        baseline: false,
    };
    let clash = machine.proxy_running;
    let migrate_clash_mi = clash && network.is_clash_mi() && config.vpn_interface.is_some();
    if (clash && config.vpn_interface.is_some() && !migrate_clash_mi)
        || (clash && !config.expected_node.is_empty() && !is_proxy_node(&config.expected_node))
    {
        return plan;
    }
    let mut candidate = config.clone();
    if migrate_clash_mi {
        candidate.vpn_interface = None;
    }
    let tun = clash.then(|| network.tun()).flatten();
    if clash && tun.is_none() {
        return plan;
    }
    if tun == Some(false) || network.clash_mi_needs_safe_mode() {
        plan.tun = true;
        if network.is_clash_mi() {
            plan.change(
                1,
                "Clash Mi 安全路由",
                "未完整启用",
                "全局 + TUN + 关闭 IPv6",
            );
        } else {
            plan.change(1, "Clash TUN", "关闭", "开启");
        }
    }
    if clash && !candidate.expected_node.is_empty() {
        for (name, selected) in probe_nodes(config, network) {
            if let Some(group) = network.group(&name) {
                if group.now != candidate.expected_node
                    && group.all.contains(&candidate.expected_node)
                {
                    plan.change(
                        3,
                        format!("策略组 {name}"),
                        selected.as_deref().unwrap_or(&group.now),
                        &candidate.expected_node,
                    );
                    plan.nodes.push((name, group.now));
                }
            }
        }
    }
    // A network change can affect the observed exit. Establish missing baseline
    // fields during the next preview, after the network is stable.
    if !config.has_baseline() && (plan.tun || !plan.nodes.is_empty()) {
        return plan;
    }
    if !config.has_baseline() || !clash || migrate_clash_mi {
        let exits = probe_exits(network);
        if !clash {
            let (_, api_peer) = api_reachable(network);
            let (_, interface) = vpn::interface(exits.front_peer, api_peer);
            let Some(interface) = interface else {
                return plan;
            };
            if candidate
                .vpn_interface
                .as_ref()
                .is_some_and(|saved| saved != &interface)
            {
                return plan;
            }
            candidate.expected_node.clear();
            candidate.vpn_interface = Some(interface);
        } else if candidate.expected_node.is_empty() {
            let selected = probe_nodes(config, network).into_iter().next();
            learn_node(
                &mut candidate,
                selected.as_ref().and_then(|(_, node)| node.as_deref()),
                false,
            );
        }
        learn_exit(&mut candidate, &exits, false);
        if candidate.timezone.is_empty() {
            let matching_exit = exits.confirmed().filter(|trace| {
                candidate.expected_ip == Some(trace.ip) && candidate.expected_loc == trace.country
            });
            if let Some((iana, windows)) =
                matching_exit.and_then(|trace| exit_timezone(network, trace))
            {
                candidate.timezone = windows.into();
                candidate.expected_tz_iana = iana;
            }
        }
        if !candidate.has_baseline() {
            return plan;
        }
        plan.change(
            3,
            "基准节点",
            &config.expected_node,
            &candidate.expected_node,
        );
        plan.change(
            3,
            "VPN 接口基准",
            config.vpn_interface.as_deref().unwrap_or(""),
            candidate.vpn_interface.as_deref().unwrap_or(""),
        );
        let exit = |config: &Config| {
            config
                .expected_ip
                .map_or_else(String::new, |ip| format!("{} · {ip}", config.expected_loc))
        };
        plan.change(4, "出口基准", &exit(config), &exit(&candidate));
        plan.change(2, "时区基准", &config.timezone, &candidate.timezone);
        plan.baseline = config.expected_node != candidate.expected_node
            || config.vpn_interface != candidate.vpn_interface
            || config.expected_ip != candidate.expected_ip
            || config.expected_loc != candidate.expected_loc
            || config.timezone != candidate.timezone;
    }
    if let Some(current) = machine.timezone.as_deref() {
        if !candidate.timezone.is_empty() && current != candidate.timezone {
            plan.timezone = true;
            plan.change(2, "Windows 时区", current, &candidate.timezone);
        }
    }
    plan.config = candidate;
    plan
}

pub fn preview_repair(folder: &Path) -> Result<Vec<RepairChange>, String> {
    let config = Config::load(folder)?;
    machine::require_claude_stopped(&config)?;
    let machine = Machine::inspect(&config);
    let runtime = machine.proxy_running.then(machine::proxy_runtime).flatten();
    let network = Network::new(runtime.as_deref())?;
    Ok(prepare_repair(&config, &network, &machine).changes)
}

fn apply_repair(folder: &Path, network: &Network, machine: &Machine, plan: &RepairPlan) -> Repairs {
    let config = &plan.config;
    let mut repairs = Repairs {
        tun: plan.tun
            && if network.is_clash_mi() {
                network.configure_clash_mi(config)
            } else {
                network.tun() == Some(false) && network.enable_tun(config)
            },
        ..Repairs::default()
    };
    if plan.timezone && machine::current_timezone().map(|zone| zone.id) == machine.timezone {
        repair_timezone(folder, config, machine, &mut repairs);
    }
    for (name, before) in &plan.nodes {
        if let Some(group) = network.group(name) {
            if group.now == *before && group.all.contains(&config.expected_node) {
                repairs.nodes |= network.select(config, name, &config.expected_node);
            }
        }
    }
    if repairs.nodes || repairs.tun {
        std::thread::sleep(std::time::Duration::from_secs(3));
    }
    repairs
}

fn repair_timezone(folder: &Path, config: &Config, machine: &Machine, repairs: &mut Repairs) {
    if !config.timezone.is_empty()
        && machine
            .timezone
            .as_deref()
            .is_some_and(|zone| zone != config.timezone)
    {
        match timezone::apply(folder, config, &config.timezone) {
            Ok(changed) => repairs.timezone |= changed,
            Err(message) => repairs.timezone_error = Some(message),
        }
    }
}

pub fn recheck_system_timezone(folder: &Path) -> Result<Group, String> {
    let config = Config::load(folder)?;
    let current = machine::current_timezone();
    Ok(zone_group(
        &config,
        current.as_ref().map(|zone| zone.id.as_str()),
    ))
}

fn mark_fixed(group: &mut Group, changed: bool) {
    if changed && group.level == Level::Pass {
        group.mark_fixed();
        group.detail = format!("已修复并复查。{}", group.detail);
    }
}

fn record(mut groups: Vec<Group>, group: Group, progress: &mut impl FnMut(&[Group])) -> Vec<Group> {
    groups.push(group);
    groups.sort_by_key(|group| group.id);
    progress(&groups);
    groups
}

pub struct Outcome {
    pub action: Action,
    pub groups: Vec<Group>,
    pub message: String,
    pub launched: bool,
    pub claude_running: bool,
}

pub fn run(
    folder: &Path,
    action: Action,
    approved_repairs: Option<&[RepairChange]>,
    automatic: bool,
    webview_zone: &str,
    webview_webrtc: Option<&[IpAddr]>,
    mut progress: impl FnMut(&[Group]),
) -> Result<Outcome, String> {
    let mut config = Config::load(folder)?;
    let action = action.when_running(machine::is_claude_running(&config))?;
    if action == Action::Repair && automatic {
        let _ = machine::start_clash_mi(&config);
    }
    if config.claude_group.trim().is_empty()
        || (config.pin_main_group && config.main_group.trim().is_empty())
    {
        return Err("请填写需要检查的 Clash 策略组".into());
    }
    let mut machine = Machine::inspect(&config);
    let clash = machine.proxy_running;
    let baseline_matches = if clash {
        config.vpn_interface.is_none() && is_proxy_node(&config.expected_node)
    } else {
        config.vpn_interface.is_some()
    };
    if action == Action::Launch && !(config.has_baseline() && baseline_matches) {
        return Err("请先为当前网络建立环境基准".into());
    }
    let runtime = clash.then(machine::proxy_runtime).flatten();
    let network = Network::new(runtime.as_deref())?;
    let endpoint_changed = action == Action::Repair && automatic && repair_custom_endpoints();
    let mut baseline_changed = false;
    let mut repairs = if action == Action::Repair {
        let plan = prepare_repair(&config, &network, &machine);
        require_repair_approval(&plan.changes, approved_repairs, automatic)?;
        machine::require_claude_stopped(&config)?;
        let mut changes = apply_repair(folder, &network, &machine, &plan);
        baseline_changed = plan.baseline;
        config = plan.config;
        machine = Machine::inspect(&config);
        if automatic && (changes.tun || changes.nodes) {
            let follow_up = prepare_repair(&config, &network, &machine);
            let follow_up_changes = apply_repair(folder, &network, &machine, &follow_up);
            baseline_changed |= follow_up.baseline;
            config = follow_up.config;
            changes.merge(follow_up_changes);
            machine = Machine::inspect(&config);
        }
        changes
    } else {
        Repairs::default()
    };
    repairs.endpoint |= endpoint_changed;
    if action == Action::Repair && automatic && repair_clash_mi_exit(folder, &mut config, &network)
    {
        baseline_changed = true;
        machine = Machine::inspect(&config);
        let follow_up = prepare_repair(&config, &network, &machine);
        let follow_up_changes = apply_repair(folder, &network, &machine, &follow_up);
        config = follow_up.config;
        repairs.merge(follow_up_changes);
        machine = Machine::inspect(&config);
    }
    let ((tun_enabled, tun_ms), (nodes, nodes_ms), (exits, exit_ms), api_peer, mut groups) =
        std::thread::scope(|scope| {
            let tun = scope.spawn(|| timed(|| clash.then(|| network.tun()).flatten()));
            let nodes = scope.spawn(|| {
                timed(|| {
                    if clash {
                        probe_nodes(&config, &network)
                    } else {
                        Vec::new()
                    }
                })
            });
            let exits = scope.spawn(|| timed(|| probe_exits(&network)));
            let api_status = scope.spawn(|| timed(|| api_reachable(&network)));
            let dns = scope.spawn(|| measure(|| dns(clash)));
            let mut groups = Vec::new();
            for group in [measure(variables), measure(endpoint)] {
                groups = record(groups, group, &mut progress);
            }
            let ((mut api, api_peer), api_ms) = api_status.join().expect("API check");
            api.elapsed_ms = api_ms;
            groups = record(groups, api, &mut progress);
            groups = record(groups, dns.join().expect("DNS check"), &mut progress);
            (
                tun.join().expect("TUN check"),
                nodes.join().expect("node check"),
                exits.join().expect("exit probes"),
                api_peer,
                groups,
            )
        });
    let (mut tun, interface) = if clash {
        (measure(|| tun_group(&machine, tun_enabled)), None)
    } else {
        vpn::interface(exits.front_peer, api_peer)
    };
    if let Some(dns) = groups.iter_mut().find(|group| group.id == 6) {
        let confirmed = if clash {
            machine.proxy_running && machine.tun_up == Some(true) && tun_enabled == Some(true)
        } else {
            interface.is_some()
        };
        confirm_tun_dns(dns, confirmed);
    }
    if action == Action::Learn {
        if let Some(zone) = &machine.timezone {
            config.timezone.clone_from(zone);
        }
        if clash {
            config.vpn_interface = None;
            learn_node(
                &mut config,
                nodes.first().and_then(|(_, node)| node.as_deref()),
                true,
            );
        } else if let Some(id) = &interface {
            config.expected_node.clear();
            config.vpn_interface = Some(id.clone());
        }
        learn_exit(&mut config, &exits, true);
        config.expected_tz_iana = webview_zone.to_owned();
    }

    let mut zone = measure(|| zone_group(&config, machine.timezone.as_deref()));
    let mut node = if clash {
        measure(|| nodes_group(&config, &nodes))
    } else {
        vpn::baseline(&config, interface.as_deref())
    };
    let mut exit = measure(|| trace_group(&config, &exits));
    tun.elapsed_ms += tun_ms;
    node.elapsed_ms += nodes_ms;
    exit.elapsed_ms += exit_ms;
    mark_fixed(&mut tun, repairs.tun);
    mark_fixed(&mut zone, repairs.timezone);
    if let Some(error) = repairs.timezone_error {
        zone = Group::new(2, ZONE, Level::Unknown, format!("{}\n{error}", zone.detail)).gate();
    }
    mark_fixed(&mut node, repairs.nodes);
    for group in [
        tun,
        zone,
        node,
        exit,
        measure(|| browser_info(&config, webview_zone, webview_webrtc, exits.front.as_ref())),
    ] {
        groups = record(groups, group, &mut progress);
    }
    let mut groups = std::thread::scope(|scope| {
        let policy = scope.spawn(|| {
            measure(|| {
                observations::supported_region(
                    &network,
                    folder,
                    exits.front.as_ref().map(|trace| trace.country.as_str()),
                )
            })
        });
        let risk = scope.spawn(|| measure(|| ip_risk(&network, exits.front.as_ref())));
        let protocol = scope.spawn(|| {
            measure(|| {
                network_protocol(
                    clash,
                    &config,
                    exits.front.as_ref(),
                    machine::probe_ipv6_exit(),
                )
            })
        });
        let route = scope.spawn(|| measure(|| client_routes(clash, &network, &machine, &config)));
        let mut results = record(
            groups,
            measure(|| observations::logs(&machine::log_folders(), Utc::now())),
            &mut progress,
        );
        results = record(results, route.join().expect("route check"), &mut progress);
        results = record(results, policy.join().expect("region check"), &mut progress);
        results = record(results, risk.join().expect("IP risk check"), &mut progress);
        record(
            results,
            protocol.join().expect("IP protocol check"),
            &mut progress,
        )
    });
    if repairs.endpoint {
        if let Some(group) = groups.iter_mut().find(|group| group.id == 10) {
            group.mark_fixed();
        }
    }
    let report = Report::new(&groups);
    let baseline_confirmed = report.complete && !report.launch_blocked && config.has_baseline();
    let mut launched = false;
    let running = machine::is_claude_running(&config);
    let action = action.when_running(running)?;
    let mut message = match action {
        Action::Check if running => "Claude 正在运行，已完成只读检查".into(),
        Action::Check => "已完成只读检查".into(),
        Action::Learn if baseline_confirmed => {
            machine::require_claude_stopped(&config)?;
            config.save(folder)?;
            "已保存 Rust 版的独立环境基准".into()
        }
        Action::Learn => {
            "环境证据不足或存在阻断，基准未保存。结果中的一致性按本次候选基准核对".into()
        }
        Action::Repair if baseline_changed && baseline_confirmed => {
            machine::require_claude_stopped(&config)?;
            config.save(folder)?;
            "检查并修复完成，已自动保存核实后的基准".into()
        }
        Action::Repair if !report.launch_blocked => "已完成修复复查".into(),
        Action::Repair => "复查仍有阻断项，请查看明细".into(),
        Action::Launch if !report.can_launch() => "启动前复核未达到 100 分".into(),
        Action::Launch => match machine::launch_claude(&config) {
            Ok(()) => {
                launched = true;
                "Claude 已运行，后台监控已开启".into()
            }
            Err(message) => message,
        },
    };
    if launched {
        if let Some(group) = groups
            .iter_mut()
            .find(|group| group.level == Level::PendingLaunch)
        {
            *group = observations::routes_after_launch();
        }
    }
    let claude_running = launched || running;
    if claude_running && timezone::pending(folder) {
        if let Err(error) = timezone::note_client_running(folder) {
            message.push_str(&format!(" · {error}"));
        }
    }
    Ok(Outcome {
        action: if action == Action::Check && (repairs.timezone || repairs.nodes || repairs.tun) {
            Action::Repair
        } else {
            action
        },
        groups,
        message,
        launched,
        claude_running,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repair_requires_the_exact_current_plan_or_automatic_action() {
        let change = |before: &str| RepairChange {
            check_id: 2,
            label: "Windows 时区".into(),
            before: before.into(),
            after: "Eastern Standard Time".into(),
        };
        let current = [change("UTC")];
        let previous = [change("Pacific Standard Time")];
        assert!(require_repair_approval(&current, Some(&current), false).is_ok());
        assert!(require_repair_approval(&current, Some(&previous), false).is_err());
        assert!(require_repair_approval(&current, None, true).is_ok());
    }

    #[test]
    fn fake_ip_dns_passes_only_after_the_tun_route_is_confirmed() {
        let mut group =
            Group::new(6, "系统 DNS", Level::Unknown, "fixture").reason("dns_fake_ip_unverified");
        confirm_tun_dns(&mut group, false);
        assert_eq!(group.level, Level::Unknown);
        confirm_tun_dns(&mut group, true);
        assert_eq!(group.level, Level::Pass);
        assert_eq!(group.earned, group.weight);
        assert_eq!(group.reason_code, Some("dns_fake_ip_verified_tun"));
    }

    #[test]
    fn clash_public_dns_passes_after_controller_and_adapter_are_confirmed() {
        let mut group = Group::new(6, "系统 DNS", Level::Unknown, "fixture")
            .reason("dns_clash_public_unverified");
        confirm_tun_dns(&mut group, false);
        assert_eq!(group.level, Level::Unknown);
        confirm_tun_dns(&mut group, true);
        assert_eq!(group.level, Level::Pass);
        assert_eq!(group.earned, group.weight);
        assert_eq!(group.reason_code, Some("dns_clash_public_verified_tun"));
    }

    #[test]
    fn running_client_forces_read_only_and_rejects_baseline_writes() {
        assert_eq!(Action::Repair.when_running(true).unwrap(), Action::Check);
        assert_eq!(Action::Launch.when_running(true).unwrap(), Action::Check);
        assert_eq!(Action::Check.when_running(true).unwrap(), Action::Check);
        assert!(Action::Learn.when_running(true).is_err());
        assert_eq!(Action::Repair.when_running(false).unwrap(), Action::Repair);
        assert_eq!(Action::Learn.when_running(false).unwrap(), Action::Learn);
    }

    #[test]
    fn exit_check_uses_claude_hosts_and_keeps_general_egress_informational() {
        let sample = Trace {
            ip: "203.0.113.10".parse().unwrap(),
            country: "US".into(),
        };
        let another = Trace {
            ip: "203.0.113.11".parse().unwrap(),
            ..sample.clone()
        };
        let config = Config {
            expected_ip: Some(sample.ip),
            expected_loc: sample.country.clone(),
            ..Config::default()
        };
        let mut exits = Exits {
            front: Some(sample.clone()),
            api: None,
            local: Some(another.ip),
            front_peer: None,
        };
        let observed = trace_group(&config, &exits);
        assert_eq!(observed.level, Level::Pass);
        assert!(observed.detail.contains("可能是分流"));
        exits.api = Some(another);
        assert_eq!(trace_group(&config, &exits).level, Level::Failed);
        exits.front = None;
        let unknown = trace_group(&config, &exits);
        assert!(unknown.blocks_launch);
        assert_eq!((unknown.earned, unknown.weight), (0, 16));
    }

    #[test]
    fn endpoint_scan_reports_sources_and_keeps_values_out_of_the_result() {
        let folder = tempfile::tempdir().unwrap();
        assert_eq!(
            endpoint_results(None, Some(folder.path())).level,
            Level::Pass
        );
        std::fs::write(
            folder.path().join("settings.local.json"),
            r#"{"env":{"ANTHROPIC_BASE_URL":"https://private-fixture.example/path"}}"#,
        )
        .unwrap();
        std::fs::write(folder.path().join("config.json"), "broken").unwrap();
        let result = endpoint_results(Some("https://api.anthropic.com"), Some(folder.path()));
        assert_eq!(result.level, Level::Warning);
        assert!(result.detail.contains("settings.local.json"));
        assert!(result.detail.contains("config.json"));
        assert!(!result.detail.contains("private-fixture"));
        std::fs::remove_file(folder.path().join("settings.local.json")).unwrap();
        assert_eq!(
            endpoint_results(None, Some(folder.path())).level,
            Level::Unknown
        );
    }

    #[test]
    fn webview_candidates_are_advisory_and_redacted() {
        let config = Config {
            expected_tz_iana: "America/New_York".into(),
            ..Config::default()
        };
        let exit = Trace {
            ip: "8.8.8.8".parse().unwrap(),
            country: "US".into(),
        };
        let candidates = ["192.168.1.2".parse().unwrap(), "1.1.1.1".parse().unwrap()];
        let report = browser_info(&config, "America/New_York", Some(&candidates), Some(&exit));
        assert_eq!((report.level, report.earned), (Level::Pass, 2));
        assert!(report.detail.contains("不同的公网候选"));
        assert!(!report.detail.contains("1.1.1.1"));
    }

    #[test]
    fn ip_risk_requires_a_valid_score_and_applies_both_thresholds() {
        for (risk, level, earned) in [
            (None, Level::Unknown, 0),
            (Some(101), Level::Unknown, 0),
            (Some(0), Level::Pass, 4),
            (Some(32), Level::Pass, 4),
            (Some(33), Level::Warning, 0),
            (Some(65), Level::Warning, 0),
            (Some(66), Level::Failed, 0),
        ] {
            let group = ip_risk_group(risk);
            assert_eq!((group.level, group.earned), (level, earned));
            assert_eq!(group.weight, 4);
            assert_eq!(group.blocks_launch, level == Level::Failed);
        }
    }

    #[test]
    fn ipv6_probe_distinguishes_ipv4_only_networks_from_unverified_routes() {
        let trace = Trace {
            ip: "203.0.113.10".parse().unwrap(),
            country: "US".into(),
        };
        for (probe, level, earned) in [
            (Ipv6Probe::Reachable, Level::Pass, 4),
            (Ipv6Probe::NoPublicRoute, Level::Pass, 4),
            (Ipv6Probe::PublicRouteUnreachable, Level::Unknown, 0),
            (Ipv6Probe::Unverified, Level::Unknown, 0),
        ] {
            let result = ip_protocol(Some(&trace), probe);
            assert_eq!(
                (result.level, result.earned, result.weight),
                (level, earned, 4)
            );
        }
        assert_eq!(
            ip_protocol(None, Ipv6Probe::NoPublicRoute).level,
            Level::Unknown
        );
        let trace = Trace {
            ip: "2001:db8::10".parse().unwrap(),
            ..trace
        };
        assert_eq!(
            ip_protocol(Some(&trace), Ipv6Probe::NoPublicRoute).level,
            Level::Unknown
        );
    }

    #[test]
    fn automatic_baseline_only_fills_missing_settings_using_verified_observations() {
        let trace = Trace {
            ip: "203.0.113.10".parse().unwrap(),
            country: "US".into(),
        };
        let mut exits = Exits {
            front: Some(trace.clone()),
            api: None,
            local: None,
            front_peer: None,
        };
        let mut config = Config::default();
        assert!(learn_node(&mut config, Some("fixture"), false));
        assert!(learn_exit(&mut config, &exits, false));
        assert!(!learn_node(&mut config, Some("different"), false));
        exits.front.as_mut().unwrap().ip = "203.0.113.11".parse().unwrap();
        assert!(!learn_exit(&mut config, &exits, false));
        assert_eq!(config.expected_ip, Some(trace.ip));
        exits.api = Some(trace);
        assert!(!learn_exit(&mut Config::default(), &exits, false));
        assert_eq!(
            windows_timezone("America/New_York"),
            Some("Eastern Standard Time")
        );
    }

    #[test]
    fn direct_is_not_learnable_as_a_proxy_baseline() {
        let config = Config::default();
        let nodes = vec![("Claude".into(), Some("DIRECT".into()))];
        assert!(nodes_group(&config, &nodes).blocks_launch);
        assert!(!is_proxy_node("DIRECT"));
        assert!(is_proxy_node("fixture group"));
    }
}

fn client_routes(clash: bool, network: &Network, machine: &Machine, config: &Config) -> Group {
    if clash {
        observations::routes(network, machine, &config.expected_node)
    } else {
        vpn::client_routes(machine, config)
    }
}

pub fn observe(folder: &Path, include_environment: bool) -> Result<Option<Vec<Group>>, String> {
    let config = Config::load(folder)?;
    let machine = Machine::inspect(&config);
    if !machine.claude_running {
        return Ok(None);
    }
    let clash = machine.proxy_running
        || (config.vpn_interface.is_none() && !config.expected_node.is_empty());
    let runtime = clash.then(machine::proxy_runtime).flatten();
    let network = Network::new(runtime.as_deref())?;
    let mut groups = vec![
        measure(|| client_routes(clash, &network, &machine, &config)),
        measure(|| observations::logs(&machine::log_folders(), Utc::now())),
    ];
    if include_environment {
        std::thread::scope(|scope| {
            let exits = scope.spawn(|| timed(|| probe_exits(&network)));
            let api = scope.spawn(|| timed(|| api_reachable(&network)));
            let dns = scope.spawn(|| measure(|| dns(clash)));
            let ipv6 = scope.spawn(|| timed(machine::probe_ipv6_exit));
            groups.push(measure(|| zone_group(&config, machine.timezone.as_deref())));
            let (exits, elapsed) = exits.join().expect("background exit probes");
            let ((mut api, api_peer), api_ms) = api.join().expect("background API check");
            api.elapsed_ms = api_ms;
            if clash {
                let tun_enabled = network.tun();
                groups.extend([
                    measure(|| tun_group(&machine, tun_enabled)),
                    measure(|| nodes_group(&config, &probe_nodes(&config, &network))),
                ]);
            } else {
                let (route, id) = vpn::interface(exits.front_peer, api_peer);
                groups.extend([route, vpn::baseline(&config, id.as_deref())]);
            }
            let mut exit = trace_group(&config, &exits);
            exit.elapsed_ms = elapsed;
            groups.push(exit);
            let (protocol, elapsed) = ipv6.join().expect("background IPv6 probe");
            let mut protocol = network_protocol(clash, &config, exits.front.as_ref(), protocol);
            protocol.elapsed_ms = elapsed;
            let mut dns = dns.join().expect("background DNS check");
            if clash {
                confirm_tun_dns(
                    &mut dns,
                    machine.proxy_running
                        && machine.tun_up == Some(true)
                        && network.tun() == Some(true),
                );
            }
            groups.extend([protocol, api, dns]);
            groups.push(measure(|| {
                observations::supported_region(
                    &network,
                    folder,
                    exits.front.as_ref().map(|trace| trace.country.as_str()),
                )
            }));
        });
    }
    Ok(Some(groups))
}
