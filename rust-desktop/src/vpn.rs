use crate::config::Config;
use crate::machine::Machine;
use crate::net::is_public_ip;
use crate::report::{Group, Level};
use std::net::{IpAddr, ToSocketAddrs};

const IF_TYPE_ETHERNET_CSMACD: u32 = 6;
const IF_TYPE_PPP: u32 = 23;
const IF_TYPE_SOFTWARE_LOOPBACK: u32 = 24;
const IF_TYPE_PROP_VIRTUAL: u32 = 53;
const IF_TYPE_IEEE80211: u32 = 71;
const IF_TYPE_TUNNEL: u32 = 131;
const FLAG_HARDWARE_INTERFACE: u8 = 1;
const FLAG_CONNECTOR_PRESENT: u8 = 1 << 2;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum VpnDetection {
    Description,
    InterfaceType,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum OtherRoute {
    Physical,
    UnrecognizedVirtual,
    Other,
}

#[derive(Debug, PartialEq, Eq)]
enum Route {
    Vpn(String, VpnDetection),
    Other(OtherRoute),
    Unknown,
}

pub fn interface(front: Option<IpAddr>, api: Option<IpAddr>) -> (Group, Option<String>) {
    interface_from_routes(
        front.map_or(Route::Unknown, route),
        api.map_or(Route::Unknown, route),
    )
}

fn interface_from_routes(front: Route, api: Route) -> (Group, Option<String>) {
    let (level, detail, reason, id) = match (front, api) {
        (Route::Vpn(front, front_detection), Route::Vpn(api, api_detection)) if front == api => {
            let structural = matches!(front_detection, VpnDetection::InterfaceType)
                || matches!(api_detection, VpnDetection::InterfaceType);
            (
                Level::Pass,
                if structural {
                    "Claude 网页和 Anthropic API 均匹配同一个 Windows 虚拟或隧道路由接口"
                } else {
                    "Claude 网页和 Anthropic API 均匹配同一个 VPN 路由接口"
                },
                if structural {
                    "vpn_route_same_structural_interface"
                } else {
                    "vpn_route_same_named_interface"
                },
                Some(front),
            )
        }
        (Route::Vpn(_, _), Route::Vpn(_, _)) => (
            Level::Failed,
            "Claude 网页和 Anthropic API 命中了不同的 VPN 路由接口",
            "vpn_route_interface_mismatch",
            None,
        ),
        (Route::Other(kind), _) | (_, Route::Other(kind)) => (
            Level::Failed,
            match kind {
                OtherRoute::Physical => "至少一条 Claude 探测连接仍使用物理或普通网络接口",
                OtherRoute::UnrecognizedVirtual => {
                    "探测连接使用未识别的虚拟接口，暂不能确认其为 VPN"
                }
                OtherRoute::Other => "至少一条 Claude 探测连接未匹配可识别的 VPN 接口",
            },
            match kind {
                OtherRoute::Physical => "vpn_route_physical_interface",
                OtherRoute::UnrecognizedVirtual => "vpn_route_unrecognized_virtual_interface",
                OtherRoute::Other => "vpn_route_non_vpn_interface",
            },
            None,
        ),
        _ => (
            Level::Unknown,
            "尚未取得两条 HTTPS 探测连接的有效路由证据",
            "vpn_route_evidence_missing",
            None,
        ),
    };
    let group = Group::new(1, "Windows VPN 路由", level, detail).reason(reason);
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
    let (level, detail, reason) = match (config.vpn_interface.as_deref(), current) {
        (Some(expected), Some(actual)) if expected == actual => (
            Level::Pass,
            "当前 VPN 接口与已保存的基准一致",
            "vpn_baseline_match",
        ),
        (Some(_), Some(_)) => (
            Level::Failed,
            "VPN 接口已变化，请核对后重新记住当前环境",
            "vpn_baseline_interface_changed",
        ),
        (None, Some(_)) => (
            Level::Unknown,
            "已确认 VPN 路由，正在建立接口基准",
            "vpn_baseline_missing",
        ),
        _ => (
            Level::Unknown,
            "VPN 路由未确认，无法核对接口基准",
            "vpn_baseline_route_unconfirmed",
        ),
    };
    let group = Group::new(3, "VPN 接口基准", level, detail).reason(reason);
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
                Route::Vpn(id, _) if id == expected => {}
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
            Route::Vpn(actual, _) if actual == expected => {}
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
    let class = classify_adapter(
        &description,
        row.Type,
        row.InterfaceAndOperStatusFlags._bitfield,
    );
    let detection = match class {
        AdapterClass::Vpn(detection) => detection,
        AdapterClass::Other(other) => return Route::Other(other),
    };
    let guid = row.InterfaceGuid;
    if guid.data1 == 0 && guid.data2 == 0 && guid.data3 == 0 && guid.data4 == [0; 8] {
        return Route::Unknown;
    }
    let tail = u64::from_be_bytes(guid.data4);
    Route::Vpn(
        format!(
            "{:08x}{:04x}{:04x}{tail:016x}",
            guid.data1, guid.data2, guid.data3
        ),
        detection,
    )
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum AdapterClass {
    Vpn(VpnDetection),
    Other(OtherRoute),
}

fn classify_adapter(description: &str, interface_type: u32, flags: u8) -> AdapterClass {
    if vpn_name_hint(description) {
        return AdapterClass::Vpn(VpnDetection::Description);
    }
    if matches!(
        interface_type,
        IF_TYPE_PPP | IF_TYPE_PROP_VIRTUAL | IF_TYPE_TUNNEL
    ) {
        return AdapterClass::Vpn(VpnDetection::InterfaceType);
    }
    let hardware = flags & FLAG_HARDWARE_INTERFACE != 0;
    let connector = flags & FLAG_CONNECTOR_PRESENT != 0;
    if hardware
        || connector
        || matches!(interface_type, IF_TYPE_ETHERNET_CSMACD | IF_TYPE_IEEE80211)
    {
        AdapterClass::Other(OtherRoute::Physical)
    } else if interface_type == IF_TYPE_SOFTWARE_LOOPBACK {
        AdapterClass::Other(OtherRoute::Other)
    } else {
        AdapterClass::Other(OtherRoute::UnrecognizedVirtual)
    }
}

fn vpn_name_hint(description: &str) -> bool {
    let description = description.to_ascii_lowercase();
    [
        " vpn",
        "vpn ",
        "vpn-",
        "vpn_",
        " tun",
        "tun ",
        "tun-",
        "tun_",
        "wireguard",
        "wintun",
        "openvpn",
        "tap-windows",
        "tailscale tunnel",
        "sing-box",
        "singbox",
        "mihomo",
        "clash",
        "cloudflare warp",
        "zerotier",
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
        let primary = || Route::Vpn("primary".into(), VpnDetection::Description);
        assert_eq!(
            interface_from_routes(primary(), primary()).1.as_deref(),
            Some("primary")
        );
        assert_eq!(
            interface_from_routes(primary(), Route::Other(OtherRoute::Physical))
                .0
                .level,
            Level::Failed
        );
        assert_eq!(
            interface_from_routes(
                primary(),
                Route::Vpn("other".into(), VpnDetection::InterfaceType)
            )
            .0
            .level,
            Level::Failed
        );
        assert_eq!(
            interface_from_routes(primary(), Route::Unknown).0.level,
            Level::Unknown
        );
    }

    #[test]
    fn recognizes_structural_vpn_types_without_vendor_names() {
        for interface_type in [IF_TYPE_PPP, IF_TYPE_PROP_VIRTUAL, IF_TYPE_TUNNEL] {
            assert_eq!(
                classify_adapter("vendor-neutral adapter", interface_type, 0),
                AdapterClass::Vpn(VpnDetection::InterfaceType)
            );
        }
        assert_eq!(
            classify_adapter("Vendor VPN Adapter", IF_TYPE_ETHERNET_CSMACD, 0),
            AdapterClass::Vpn(VpnDetection::Description)
        );
    }

    #[test]
    fn physical_and_ambiguous_virtual_interfaces_do_not_pass_as_vpns() {
        assert_eq!(
            classify_adapter(
                "Ethernet",
                IF_TYPE_ETHERNET_CSMACD,
                FLAG_HARDWARE_INTERFACE | FLAG_CONNECTOR_PRESENT
            ),
            AdapterClass::Other(OtherRoute::Physical)
        );
        assert_eq!(
            classify_adapter("vEthernet", 1, 0),
            AdapterClass::Other(OtherRoute::UnrecognizedVirtual)
        );
    }

    #[cfg(windows)]
    #[test]
    fn windows_routes_do_not_classify_loopback_as_a_vpn() {
        assert!(matches!(
            route("127.0.0.1".parse().unwrap()),
            Route::Other(_)
        ));
    }
}
