use crate::config::Config;
use reqwest::blocking::{Client, Response};
use reqwest::redirect::Policy;
use reqwest::Url;
use serde::{de::DeserializeOwned, Deserialize};
use serde_json::Value;
use std::io::Read;
use std::net::{IpAddr, SocketAddr};
use std::path::Path;
use std::time::Duration;

pub struct Network {
    pub web: Client,
    control: Client,
    address: Url,
    secret: String,
    clash_mi: bool,
}

#[derive(Deserialize, Default)]
struct Verge {
    #[serde(default, rename = "external-controller")]
    controller: String,
    #[serde(default)]
    secret: String,
}

#[derive(Deserialize, Default)]
struct ClashMiService {
    #[serde(default)]
    control_port: u16,
    #[serde(default)]
    secret: String,
    #[serde(default)]
    id: String,
}

#[derive(Deserialize)]
pub struct ProxyGroup {
    pub now: String,
    #[serde(default)]
    pub all: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Trace {
    pub ip: IpAddr,
    pub country: String,
}

impl Network {
    pub fn new(runtime: Option<&Path>) -> Result<Self, String> {
        let clash_mi = runtime.is_some_and(|path| {
            path.file_name()
                .is_some_and(|name| name.eq_ignore_ascii_case("service_core_setting.json"))
        });
        let verge = load_runtime_config(runtime, clash_mi)?;
        let web = Client::builder()
            .no_proxy()
            .redirect(Policy::none())
            .timeout(Duration::from_secs(8))
            .user_agent("ClaudeSafeLauncherRust/0.1")
            .build()
            .map_err(|_| "无法初始化 HTTPS 客户端")?;
        let control = Client::builder()
            .no_proxy()
            .redirect(Policy::none())
            .timeout(Duration::from_secs(3))
            .build()
            .map_err(|_| "无法初始化本地控制器客户端")?;
        Ok(Self {
            web,
            control,
            address: controller_address(&verge.controller, if clash_mi { 9090 } else { 9097 })
                .ok_or("检查器只连接本机回环地址上的代理控制器")?,
            secret: verge.secret,
            clash_mi,
        })
    }

    pub fn is_clash_mi(&self) -> bool {
        self.clash_mi
    }

    fn endpoint(&self, segments: &[&str]) -> Url {
        let mut url = self.address.clone();
        url.path_segments_mut()
            .expect("HTTP base URL")
            .pop_if_empty()
            .extend(segments);
        url
    }

    fn send(
        &self,
        method: reqwest::Method,
        path: &[&str],
        body: Option<Value>,
    ) -> Option<Response> {
        let mut req = self.control.request(method, self.endpoint(path));
        if !self.secret.is_empty() {
            req = req.bearer_auth(&self.secret);
        }
        if let Some(body) = body {
            req = req.json(&body);
        }
        req.send().ok()?.error_for_status().ok()
    }

    pub fn get<T: DeserializeOwned>(&self, path: &[&str]) -> Option<T> {
        let response = self.send(reqwest::Method::GET, path, None)?;
        let body = read_body(response, 8 * 1024 * 1024)?;
        serde_json::from_str(&body).ok()
    }

    pub fn group(&self, name: &str) -> Option<ProxyGroup> {
        self.get(&["proxies", name])
    }

    pub fn select(&self, config: &Config, group: &str, node: &str) -> bool {
        crate::machine::require_claude_stopped(config).is_ok()
            && self
                .send(
                    reqwest::Method::PUT,
                    &["proxies", group],
                    Some(serde_json::json!({"name": node})),
                )
                .is_some()
            && self.group(group).is_some_and(|group| group.now == node)
    }

    pub fn tun(&self) -> Option<bool> {
        self.get::<Value>(&["configs"])?["tun"]["enable"].as_bool()
    }

    pub fn enable_tun(&self, config: &Config) -> bool {
        crate::machine::require_claude_stopped(config).is_ok()
            && self
                .send(
                    reqwest::Method::PATCH,
                    &["configs"],
                    Some(serde_json::json!({"tun": {"enable": true}})),
                )
                .is_some()
            && self.tun() == Some(true)
    }

    pub fn configure_clash_mi(&self, config: &Config) -> bool {
        if !self.clash_mi || crate::machine::require_claude_stopped(config).is_err() {
            return false;
        }
        if let Some(group) = self.group("GLOBAL") {
            if is_non_proxy_selection(&group.now) {
                if let Some(candidate) = group.all.iter().find(|node| !is_non_proxy_selection(node))
                {
                    let _ = self.select(config, "GLOBAL", candidate);
                }
            }
        }
        let changed = self
            .send(
                reqwest::Method::PATCH,
                &["configs"],
                Some(serde_json::json!({
                    "mode": "global",
                    "ipv6": false,
                    "tun": {"enable": true}
                })),
            )
            .is_some();
        let verified = self.get::<Value>(&["configs"]).is_some_and(|configs| {
            configs["mode"].as_str() == Some("global")
                && configs["ipv6"].as_bool() == Some(false)
                && configs["tun"]["enable"].as_bool() == Some(true)
        });
        if changed && verified {
            let _ = self.send(reqwest::Method::DELETE, &["connections"], None);
        }
        changed && verified
    }

    pub fn clash_mi_needs_safe_mode(&self) -> bool {
        self.clash_mi
            && self.get::<Value>(&["configs"]).is_some_and(|configs| {
                configs["mode"].as_str() != Some("global")
                    || configs["ipv6"].as_bool() != Some(false)
                    || configs["tun"]["enable"].as_bool() != Some(true)
            })
    }

    pub fn reset_connections(&self, config: &Config) -> bool {
        crate::machine::require_claude_stopped(config).is_ok()
            && self
                .send(reqwest::Method::DELETE, &["connections"], None)
                .is_some()
    }

    pub fn trace(&self, url: &str) -> Option<Trace> {
        self.trace_with_peer(url).map(|(trace, _)| trace)
    }

    pub fn trace_with_peer(&self, url: &str) -> Option<(Trace, Option<IpAddr>)> {
        let response = self.web.get(url).send().ok()?.error_for_status().ok()?;
        let peer = response.remote_addr().map(|socket| socket.ip());
        let body = read_body(response, 16 * 1024)?;
        Some((parse_trace(&body)?, peer))
    }

    pub fn body(&self, url: &str, limit: u64) -> Option<String> {
        read_body(
            self.web.get(url).send().ok()?.error_for_status().ok()?,
            limit,
        )
    }
}

fn is_non_proxy_selection(node: &str) -> bool {
    matches!(
        node.trim().to_ascii_uppercase().as_str(),
        "" | "DIRECT" | "REJECT" | "REJECT-DROP" | "PASS" | "COMPATIBLE"
    )
}

fn load_runtime_config(runtime: Option<&Path>, clash_mi: bool) -> Result<Verge, String> {
    let primary = match runtime.and_then(|path| std::fs::read_to_string(path).ok()) {
        Some(yaml) => {
            serde_yaml_ng::from_str::<Verge>(&yaml).map_err(|_| "代理客户端运行配置无法解析")?
        }
        None => Verge::default(),
    };
    if !clash_mi {
        return Ok(primary);
    }
    let folder = runtime.and_then(Path::parent);
    let patch_final = folder
        .and_then(|dir| std::fs::read_to_string(dir.join("service_core_patch_final.json")).ok())
        .and_then(|json| serde_yaml_ng::from_str::<Verge>(&json).ok())
        .unwrap_or_default();
    let service = folder
        .and_then(|dir| std::fs::read_to_string(dir.join("service.json")).ok())
        .and_then(|json| serde_json::from_str::<ClashMiService>(&json).ok())
        .unwrap_or_default();
    let controller = [patch_final.controller.trim(), primary.controller.trim()]
        .into_iter()
        .find(|value| !value.is_empty())
        .map(str::to_owned)
        .or_else(|| {
            (service.control_port > 0).then(|| format!("127.0.0.1:{}", service.control_port))
        })
        .unwrap_or_default();
    let secret = [
        patch_final.secret.trim(),
        service.secret.trim(),
        primary.secret.trim(),
    ]
    .into_iter()
    .find(|value| !value.is_empty())
    .map(str::to_owned)
    .or_else(|| {
        let id = service.id.trim();
        (id.len() >= 24 && id.is_char_boundary(8) && id.is_char_boundary(24))
            .then(|| id[8..24].to_owned())
    })
    .unwrap_or_default();
    Ok(Verge { controller, secret })
}

fn controller_address(raw: &str, default_port: u16) -> Option<Url> {
    let raw = raw.trim();
    let address = if raw.is_empty() {
        format!("127.0.0.1:{default_port}")
    } else if raw.starts_with(':') {
        format!("127.0.0.1{raw}")
    } else if let Some(port) = raw.strip_prefix("localhost:") {
        format!("127.0.0.1:{port}")
    } else {
        raw.to_owned()
    };
    let mut addr: SocketAddr = address.parse().ok()?;
    if addr.port() == 0 {
        return None;
    }
    if addr.ip().is_unspecified() {
        addr.set_ip(if addr.is_ipv4() {
            std::net::Ipv4Addr::LOCALHOST.into()
        } else {
            std::net::Ipv6Addr::LOCALHOST.into()
        });
    }
    addr.ip()
        .is_loopback()
        .then(|| Url::parse(&format!("http://{addr}/")).expect("socket address URL"))
}

fn parse_trace(body: &str) -> Option<Trace> {
    let fields: std::collections::HashMap<_, _> = body
        .lines()
        .filter_map(|line| line.split_once('='))
        .collect();
    let ip = fields.get("ip")?.parse().ok()?;
    let country = fields.get("loc")?.to_string();
    is_country_code(&country).then_some(Trace { ip, country })
}

pub fn is_country_code(code: &str) -> bool {
    code.len() == 2 && code.bytes().all(|byte| byte.is_ascii_uppercase())
}

pub fn is_fake_ip(address: IpAddr) -> bool {
    match address.to_canonical() {
        IpAddr::V4(ip) => {
            let [a, b, ..] = ip.octets();
            (a == 198 && (18..=19).contains(&b)) || (a == 172 && b == 19)
        }
        IpAddr::V6(ip) => {
            let [a, b, ..] = ip.segments();
            (a & 0xffc0) == 0xfc00 || (a == 0xfdfe && b == 0xdcbe)
        }
    }
}

pub fn is_public_ip(address: IpAddr) -> bool {
    match address.to_canonical() {
        IpAddr::V4(ip) => {
            let [a, b, c, _] = ip.octets();
            a != 0
                && a < 224
                && !ip.is_private()
                && !ip.is_loopback()
                && !ip.is_link_local()
                && !ip.is_documentation()
                && !(a == 100 && (64..=127).contains(&b))
                && !(a == 198 && (18..=19).contains(&b))
                && !(a == 192 && b == 0 && c == 0)
        }
        IpAddr::V6(ip) => {
            let [a, b, ..] = ip.segments();
            a & 0xe000 == 0x2000 && (a, b) != (0x2001, 0x0db8)
        }
    }
}

fn read_body(response: Response, limit: u64) -> Option<String> {
    let mut buffer = Vec::new();
    response.take(limit + 1).read_to_end(&mut buffer).ok()?;
    if buffer.len() as u64 > limit {
        return None;
    }
    String::from_utf8(buffer).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn controller_stays_on_loopback() {
        for raw in ["", ":9097", "0.0.0.0:9097", "localhost:9097", "[::]:9097"] {
            assert!(controller_address(raw, 9097).is_some());
        }
        for raw in [
            "192.0.2.1:9097",
            "localhost:0",
            "localhost:9097@remote.test",
            "localhost:9097/path",
        ] {
            assert!(controller_address(raw, 9097).is_none());
        }
    }

    #[test]
    fn proxy_clients_use_their_own_default_controller_ports() {
        assert_eq!(controller_address("", 9090).unwrap().port(), Some(9090));
        assert_eq!(controller_address("", 9097).unwrap().port(), Some(9097));
    }

    #[test]
    fn trace_requires_both_valid_ip_and_country() {
        assert!(parse_trace("ip=203.0.113.20\nloc=US\n").is_some());
        assert!(parse_trace("ip=203.0.113.20\nloc=???\n").is_none());
        assert!(parse_trace("ip=invalid\nloc=US\n").is_none());
    }

    #[test]
    fn clash_mi_controller_settings_use_the_standard_mihomo_fields() {
        let config: Verge = serde_yaml_ng::from_str(
            r#"{
                "external-controller": "127.0.0.1:9090",
                "secret": "fixture-secret"
            }"#,
        )
        .unwrap();
        assert_eq!(config.controller, "127.0.0.1:9090");
        assert_eq!(config.secret, "fixture-secret");
        assert_eq!(
            controller_address(&config.controller, 9090).unwrap().port(),
            Some(9090)
        );
    }

    #[test]
    fn clash_mi_runtime_loads_secret_and_port_from_companion_files() {
        let temp = tempfile::tempdir().unwrap();
        let setting = temp.path().join("service_core_setting.json");
        std::fs::write(&setting, r#"{"mode":"rule"}"#).unwrap();
        std::fs::write(
            temp.path().join("service.json"),
            r#"{"control_port":9090,"id":"01234567abcdef0123456789abcdef"}"#,
        )
        .unwrap();
        let loaded = load_runtime_config(Some(&setting), true).unwrap();
        assert_eq!(loaded.controller, "127.0.0.1:9090");
        assert_eq!(loaded.secret, "abcdef0123456789");

        std::fs::write(
            temp.path().join("service_core_patch_final.json"),
            r#"{"external-controller":"127.0.0.1:9090","secret":"patch-secret"}"#,
        )
        .unwrap();
        let loaded = load_runtime_config(Some(&setting), true).unwrap();
        assert_eq!(loaded.controller, "127.0.0.1:9090");
        assert_eq!(loaded.secret, "patch-secret");
    }

    #[test]
    fn recognizes_clash_and_clash_mi_fake_ip_ranges() {
        assert!(is_fake_ip("198.18.0.2".parse().unwrap()));
        assert!(is_fake_ip("172.19.0.2".parse().unwrap()));
        assert!(is_fake_ip("fdfe:dcbe:9876::2".parse().unwrap()));
        assert!(!is_fake_ip("172.20.0.2".parse().unwrap()));
        assert!(!is_fake_ip("203.0.113.10".parse().unwrap()));
    }
}
