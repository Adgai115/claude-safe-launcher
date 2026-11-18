use crate::config::Config;
use crate::machine::Machine;
use crate::net::is_public_ip;
use crate::report::{Group, Level};
use std::net::{IpAddr, ToSocketAddrs};

#[derive(Debug, PartialEq, Eq)]
enum Route {
    Vpn(String),
    Other,
    Unknown,
}

pub fn interface(front: Option<IpAddr>, api: Option<IpAddr>) -> (Group, Option<String>) {
    interface_from_routes(
        front.map_or(Route::Unknown, route),
        api.map_or(Route::Unknown, route),
    )
}

fn interface_from_routes(front: Route, api: Route) -> (Group, Option<String>) {
    let (level, detail, id) = match (front, api) {
        (Route::Vpn(front), Route::Vpn(api)) if front == api => (
            Level::Pass,
            "Claude 网页和 Anthropic API 的探测连接均匹配同一个 VPN 路由接口",
            Some(front),
        ),
        (Route::Other, _) | (_, Route::Other) | (Route::Vpn(_), Route::Vpn(_)) => (
            Level::Failed,
            "网页和 API 探测未同时匹配同一个可识别的 VPN 路由接口",
            None,
        ),
        _ => (
            Level::Unknown,
            "尚未取得两条 HTTPS 探测连接的有效路由证据",
            None,
        ),
    };
    let group = Group::new(1, "Windows VPN 路由", level, detail);
    (
        if level == Level::Pass {
            group
        } else {
            group.gate()
        },
        id,
    )
}

pub fn baseline(config: &Config, current: Option<&str>) -> Group {
    let (level, detail) = match (config.vpn_interface.as_deref(), current) {
        (Some(expected), Some(actual)) if expected == actual => {
            (Level::Pass, "当前 VPN 接口与已保存的基准一致")
        }
        (Some(_), Some(_)) => (Level::Failed, "VPN 接口已变化，请核对后重新记住当前环境"),
        (None, Some(_)) => (Level::Unknown, "已确认 VPN 路由，请先记住当前环境"),
        _ => (Level::Unknown, "VPN 路由未确认，无法核对接口基准"),
    };
    let group = Group::new(3, "VPN 接口基准", level, detail);
    if level == Level::Pass {
        group
    } else {
        group.gate()
    }
}

pub fn verify_ipv6(group: Group, expected: Option<&str>) -> Group {
    let Some(expected) = expected else {
        return Group::new(
            7,
            group.title,
            Level::Unknown,
            "缺少基准 VPN 接口，无法核对 IPv6 路由",
        );
    };
    let mut saw_ipv6 = false;
    let mut unknown = false;
    for host in ["claude.ai", "api.anthropic.com"] {
        let Ok(addresses) = (host, 443).to_socket_addrs() else {
            unknown = true;
            continue;
        };
        for peer in addresses
            .map(|address| address.ip())
            .filter(|ip| ip.is_ipv6() && is_public_ip(*ip))
        {
            saw_ipv6 = true;
            match route(peer) {
                Route::Vpn(id) if id == expected => {}
                Route::Unknown => unknown = true,
                _ => {
                    return Group::new(
                        7,
                        group.title,
                        Level::Failed,
                        "Claude 服务存在与基准 VPN 接口不匹配的公网 IPv6 路由",
                    )
                }
            }
        }
    }
    let (level, detail) = if unknown {
        (
            Level::Unknown,
            "公网 IPv6 已可用，Claude 服务的 IPv6 路由尚未完全核实",
        )
    } else if saw_ipv6 {
        (
            Level::Pass,
            "Claude 服务的已解析公网 IPv6 目标均匹配基准 VPN 接口",
        )
    } else {
        (
            Level::Pass,
            "公网 IPv6 已可用，Claude 网页和 API 当前未解析到公网 IPv6 地址",
        )
    };
    Group::new(7, group.title, level, detail)
}

pub fn client_routes(machine: &Machine, config: &Config) -> Group {
    use crate::observations::{routes_before_launch, unidentified_client, ROUTES};
    if !machine.claude_running {
        return routes_before_launch();
    }
    if machine.claude.is_empty() {
        return unidentified_client();
    }
    let Some((expected, sockets)) = config
        .vpn_interface
        .as_deref()
        .zip(crate::machine::tcp_sockets())
    else {
        return Group::new(
            13,
            ROUTES,
            Level::Unknown,
            "缺少 VPN 基准或无法读取客户端 TCP 连接",
        );
    };
    let peers: std::collections::BTreeSet<_> = sockets
        .into_iter()
        .filter(|socket| socket.established && is_public_ip(socket.remote_ip))
        .filter(|socket| {
            machine
                .claude
                .iter()
                .any(|process| process.pid == socket.pid)
        })
        .map(|socket| socket.remote_ip)
        .collect();
    if peers.is_empty() {
        return Group::new(
            13,
            ROUTES,
            Level::PendingConnection,
            "等待客户端产生可核对的公网 TCP 连接",
        );
    }
    let mut unknown = false;
    for peer in peers {
        match route(peer) {
            Route::Vpn(actual) if actual == expected => {}
            Route::Unknown => unknown = true,
            _ => {
                return Group::new(
                    13,
                    ROUTES,
                    Level::Failed,
                    "客户端存在与基准 VPN 接口不匹配的公网 TCP 路由",
                );
            }
        }
    }
    let (level, detail) = if unknown {
        (Level::Unknown, "部分客户端公网 TCP 路由无法核实")
    } else {
        (
            Level::Pass,
            "客户端公网 TCP 目标的当前 Windows 路由匹配基准 VPN 接口",
        )
    };
    Group::new(13, ROUTES, level, detail)
}

#[cfg(windows)]
fn route(ip: IpAddr) -> Route {
    use windows_sys::Win32::NetworkManagement::IpHelper::{
        GetBestInterfaceEx, GetIfEntry2, MIB_IF_ROW2,
    };
    use windows_sys::Win32::NetworkManagement::Ndis::IfOperStatusUp;
    use windows_sys::Win32::Networking::WinSock::{
        AF_INET, AF_INET6, IN6_ADDR, IN6_ADDR_0, IN_ADDR, IN_ADDR_0, SOCKADDR, SOCKADDR_IN,
        SOCKADDR_IN6,
    };

    let mut row: MIB_IF_ROW2 = unsafe { std::mem::zeroed() };
    let status = unsafe {
        match ip {
            IpAddr::V4(ip) => {
                let mut address: SOCKADDR_IN = std::mem::zeroed();
                address.sin_family = AF_INET;
                address.sin_addr = IN_ADDR {
                    S_un: IN_ADDR_0 {
                        S_addr: u32::from_ne_bytes(ip.octets()),
                    },
                };
                GetBestInterfaceEx(
                    (&address as *const SOCKADDR_IN).cast::<SOCKADDR>(),
                    &mut row.InterfaceIndex,
                )
            }
            IpAddr::V6(ip) => {
                let mut address: SOCKADDR_IN6 = std::mem::zeroed();
                address.sin6_family = AF_INET6;
                address.sin6_addr = IN6_ADDR {
                    u: IN6_ADDR_0 { Byte: ip.octets() },
                };
                GetBestInterfaceEx(
                    (&address as *const SOCKADDR_IN6).cast::<SOCKADDR>(),
                    &mut row.InterfaceIndex,
                )
            }
        }
    };
    if status != 0 || row.InterfaceIndex == 0 || unsafe { GetIfEntry2(&mut row) } != 0 {
        return Route::Unknown;
    }
    if row.OperStatus != IfOperStatusUp {
        return Route::Unknown;
    }
    let description = crate::machine::utf16_field(&row.Description);
    if !known_vpn_adapter(&description) {
        return Route::Other;
    }
    let guid = row.InterfaceGuid;
    if guid.data1 == 0 && guid.data2 == 0 && guid.data3 == 0 && guid.data4 == [0; 8] {
        return Route::Unknown;
    }
    let tail = u64::from_be_bytes(guid.data4);
    Route::Vpn(format!(
        "{:08x}{:04x}{:04x}{tail:016x}",
        guid.data1, guid.data2, guid.data3
    ))
}

#[cfg(windows)]
fn known_vpn_adapter(description: &str) -> bool {
    let description = description.to_ascii_lowercase();
    [
        "wireguard",
        "wintun",
        "openvpn",
        "tap-windows",
        "tailscale tunnel",
        "wan miniport (ikev2)",
        "wan miniport (sstp)",
        "wan miniport (l2tp)",
        "wan miniport (pptp)",
    ]
    .iter()
    .any(|driver| description.contains(driver))
}

#[cfg(not(windows))]
fn route(_ip: IpAddr) -> Route {
    Route::Unknown
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn both_service_routes_must_match_the_same_vpn() {
        let primary = || Route::Vpn("primary".into());
        assert_eq!(
            interface_from_routes(primary(), primary()).1.as_deref(),
            Some("primary")
        );
        assert_eq!(
            interface_from_routes(primary(), Route::Other).0.level,
            Level::Failed
        );
        assert_eq!(
            interface_from_routes(primary(), Route::Vpn("other".into()))
                .0
                .level,
            Level::Failed
        );
        assert_eq!(
            interface_from_routes(primary(), Route::Unknown).0.level,
            Level::Unknown
        );
    }

    #[cfg(windows)]
    #[test]
    fn windows_routes_do_not_classify_loopback_as_a_vpn() {
        assert_eq!(route("127.0.0.1".parse().unwrap()), Route::Other);
    }
}
