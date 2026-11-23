use crate::config::Config;
use std::ffi::OsStr;
use std::net::{IpAddr, Ipv6Addr, SocketAddr};
use std::path::{Path, PathBuf};
use std::process::Command;

use serde::{Deserialize, Serialize};
use sysinfo::{ProcessRefreshKind, ProcessesToUpdate, System, UpdateKind};

#[derive(Debug)]
pub struct Process {
    pub pid: u32,
    pub path: PathBuf,
    pub started: u64,
}

pub struct Machine {
    pub claude: Vec<Process>,
    pub claude_running: bool,
    pub proxy_running: bool,
    pub tun_up: Option<bool>,
    pub timezone: Option<String>,
}

impl Machine {
    pub fn inspect(config: &Config) -> Self {
        let system = process_snapshot();
        let proxy_running = system
            .processes()
            .values()
            .any(|process| looks_like_proxy(process.name()));
        Self {
            claude: find_claude(&system, config),
            claude_running: has_claude(&system, config),
            proxy_running,
            tun_up: tun_adapter_up(),
            timezone: current_timezone()
                .map(|zone| zone.id)
                .or_else(|| output("tzutil.exe", &["/g"]).filter(|zone| !zone.is_empty())),
        }
    }
}

fn looks_like_proxy(name: &OsStr) -> bool {
    let name = name.to_string_lossy().to_ascii_lowercase();
    ["mihomo", "verge-mihomo", "clash-meta", "clashmiservice"]
        .iter()
        .any(|prefix| name.starts_with(prefix))
}

fn looks_like_clash_mi(name: &OsStr) -> bool {
    matches!(
        name.to_string_lossy().to_ascii_lowercase().as_str(),
        "clashmi" | "clashmi.exe"
    )
}

fn process_snapshot() -> System {
    let mut system = System::new();
    system.refresh_processes_specifics(ProcessesToUpdate::All, true, ProcessRefreshKind::nothing());
    let clients: Vec<_> = system
        .processes()
        .iter()
        .filter(|(_, process)| {
            looks_like_claude(Some(process.name())) || looks_like_clash_mi(process.name())
        })
        .map(|(&pid, _)| pid)
        .collect();
    if !clients.is_empty() {
        system.refresh_processes_specifics(
            ProcessesToUpdate::Some(&clients),
            true,
            ProcessRefreshKind::nothing().with_exe(UpdateKind::OnlyIfNotSet),
        );
    }
    system
}

fn find_claude(system: &System, config: &Config) -> Vec<Process> {
    system
        .processes()
        .values()
        .filter_map(|process| {
            if !looks_like_claude(Some(process.name())) {
                return None;
            }
            let path = process.exe().filter(|path| is_claude_path(path, config))?;
            Some(Process {
                pid: process.pid().as_u32(),
                path: path.to_owned(),
                started: process.start_time(),
            })
        })
        .collect()
}

pub fn claude_processes(config: &Config) -> Vec<Process> {
    find_claude(&process_snapshot(), config)
}

fn has_claude(system: &System, config: &Config) -> bool {
    system
        .processes()
        .values()
        .any(|process| is_claude_candidate(process.name(), process.exe(), config))
}

pub fn is_claude_running(config: &Config) -> bool {
    has_claude(&process_snapshot(), config)
}

pub fn require_claude_stopped(config: &Config) -> Result<(), String> {
    if is_claude_running(config) {
        Err("Claude 正在运行，相关配置已锁定。请退出 Claude 后再修改".into())
    } else {
        Ok(())
    }
}

pub fn close_claude(config: &Config) -> Result<(), String> {
    let processes = claude_processes(config);
    if processes.is_empty() {
        return Ok(());
    }
    if !request_desktop_close(&processes) {
        return Err("未找到可正常关闭的 Claude 窗口，请在 Claude 内手动退出。".into());
    }
    for _ in 0..40 {
        std::thread::sleep(std::time::Duration::from_millis(250));
        if !is_claude_running(config) {
            return Ok(());
        }
    }
    Err("Claude 未在 10 秒内退出，请保存工作后在 Claude 内手动退出。".into())
}

#[cfg(windows)]
fn request_desktop_close(processes: &[Process]) -> bool {
    use windows_sys::Win32::Foundation::{BOOL, HWND, LPARAM};
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        EnumWindows, GetWindowTextLengthW, GetWindowThreadProcessId, IsWindowVisible, PostMessageW,
        WM_CLOSE,
    };

    struct Request<'a> {
        processes: &'a [Process],
        sent: bool,
    }
    unsafe extern "system" fn close(window: HWND, parameter: LPARAM) -> BOOL {
        let request = unsafe { &mut *(parameter as *mut Request<'_>) };
        let mut pid = 0;
        unsafe {
            GetWindowThreadProcessId(window, &mut pid);
            if request.processes.iter().any(|process| process.pid == pid)
                && IsWindowVisible(window) != 0
                && GetWindowTextLengthW(window) > 0
                && PostMessageW(window, WM_CLOSE, 0, 0) != 0
            {
                request.sent = true;
            }
        }
        1
    }
    let mut request = Request {
        processes,
        sent: false,
    };
    // EnumWindows calls close synchronously while request and its process slice live.
    unsafe { EnumWindows(Some(close), (&mut request as *mut Request<'_>) as LPARAM) };
    request.sent
}

#[cfg(not(windows))]
fn request_desktop_close(_processes: &[Process]) -> bool {
    false
}

fn is_claude_candidate(name: &OsStr, path: Option<&Path>, config: &Config) -> bool {
    looks_like_claude(Some(name))
        && path
            .filter(|path| !path.as_os_str().is_empty())
            .is_none_or(|path| is_claude_path(path, config))
}

fn is_claude_path(path: &Path, config: &Config) -> bool {
    if config
        .claude_exe
        .as_deref()
        .is_some_and(|current| paths_match(current, path))
    {
        return true;
    }
    let text = path
        .to_string_lossy()
        .replace('/', "\\")
        .to_ascii_lowercase();
    if let Some((_, tail)) = text.split_once("\\windowsapps\\") {
        let package = tail.split('\\').next().unwrap_or_default();
        let parts: Vec<_> = package.split('_').collect();
        if let [name, version, arch, _, publisher] = parts.as_slice() {
            let family = format!("{name}_{publisher}");
            let configured = config
                .claude_aumid
                .split_once('!')
                .map(|(family, _)| family);
            return !version.is_empty()
                && matches!(*arch, "x64" | "arm64" | "x86" | "neutral")
                && (family == "claude_pzs8sxrjxfjjc"
                    || configured.is_some_and(|id| family.eq_ignore_ascii_case(id)));
        }
    }
    installed_claude_paths().into_iter().any(|candidate| {
        paths_match(&candidate, path)
            || candidate.parent().is_some_and(|root| {
                path.parent().is_some_and(|parent| {
                    parent
                        .file_name()
                        .is_some_and(|name| name.to_string_lossy().starts_with("app-"))
                        && parent
                            .parent()
                            .is_some_and(|owner| paths_match(root, owner))
                })
            })
    })
}

pub fn paths_match(a: &Path, b: &Path) -> bool {
    fn normalized(path: &Path) -> String {
        let path = path.to_string_lossy().replace('/', "\\");
        path.strip_prefix("\\\\?\\")
            .unwrap_or(&path)
            .to_ascii_lowercase()
    }
    normalized(a) == normalized(b)
}

#[test]
fn ordinary_name_matches_require_a_verified_installation_path() {
    let name = OsStr::new("CLAUDE.EXE");
    let config = Config {
        claude_exe: Some(PathBuf::from(r"D:\Apps\Claude.exe")),
        ..Config::default()
    };
    assert!(is_claude_candidate(name, None, &config));
    assert!(is_claude_candidate(
        name,
        Some(Path::new(r"\\?\D:\Apps\claude.exe")),
        &config
    ));
    assert!(is_claude_candidate(
        name,
        Some(Path::new(
            r"C:\Program Files\WindowsApps\Claude_1.0.0.0_x64__pzs8sxrjxfjjc\app\claude.exe"
        )),
        &config,
    ));
    assert!(!is_claude_candidate(
        name,
        Some(Path::new(r"D:\Downloads\Claude\Claude.exe")),
        &config
    ));
    assert!(!is_claude_candidate(
        name,
        Some(Path::new(
            r"C:\Program Files\WindowsApps\Claude_1.0.0.0_x64__another\app\claude.exe"
        )),
        &config,
    ));
}

fn system_command(program: &str) -> Command {
    let path = std::env::var_os("SystemRoot")
        .map(PathBuf::from)
        .map_or_else(
            || PathBuf::from(program),
            |root| root.join("System32").join(program),
        );
    let mut cmd = Command::new(path);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x08000000); // CREATE_NO_WINDOW
    }
    cmd
}

fn output(program: &str, args: &[&str]) -> Option<String> {
    let result = system_command(program).args(args).output().ok()?;
    result
        .status
        .success()
        .then(|| String::from_utf8_lossy(&result.stdout).trim().to_owned())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ipv6Probe {
    Reachable,
    NoPublicRoute,
    PublicRouteUnreachable,
    Unverified,
}

pub fn probe_ipv6_exit() -> Ipv6Probe {
    let address = output(
        "curl.exe",
        &[
            "--disable",
            "--noproxy",
            "*",
            "--ipv6",
            "--silent",
            "--fail",
            "--max-time",
            "8",
            "https://api64.ipify.org",
        ],
    )
    .and_then(|address| address.parse::<Ipv6Addr>().ok());
    if address.is_some_and(|address| (address.segments()[0] & 0xe000) == 0x2000) {
        return Ipv6Probe::Reachable;
    }
    match has_public_ipv6_route() {
        Some(false) => Ipv6Probe::NoPublicRoute,
        Some(true) => Ipv6Probe::PublicRouteUnreachable,
        None => Ipv6Probe::Unverified,
    }
}

#[cfg(windows)]
fn has_public_ipv6_route() -> Option<bool> {
    use std::{ptr, slice};
    use windows_sys::Win32::Foundation::{ERROR_NOT_FOUND, NO_ERROR};
    use windows_sys::Win32::NetworkManagement::IpHelper::{
        FreeMibTable, GetIpForwardTable2, MIB_IPFORWARD_ROW2,
    };
    use windows_sys::Win32::Networking::WinSock::AF_INET6;

    let mut table = ptr::null_mut();
    // The Windows API owns the variable-length table until FreeMibTable.
    unsafe {
        match GetIpForwardTable2(AF_INET6, &mut table) {
            ERROR_NOT_FOUND => return Some(false),
            NO_ERROR if !table.is_null() => {}
            _ => return None,
        }
        let entries = ptr::addr_of!((*table).Table).cast::<MIB_IPFORWARD_ROW2>();
        let rows = slice::from_raw_parts(entries, (*table).NumEntries as usize);
        let present = rows.iter().any(|row| {
            let destination = row.DestinationPrefix;
            let address = Ipv6Addr::from(destination.Prefix.Ipv6.sin6_addr.u.Byte);
            row.ValidLifetime != 0 && public_ipv6_prefix(address, destination.PrefixLength)
        });
        FreeMibTable(table.cast());
        Some(present)
    }
}

#[cfg(windows)]
fn public_ipv6_prefix(address: Ipv6Addr, length: u8) -> bool {
    let [first, second, ..] = address.segments();
    let high = (u32::from(first) << 16) | u32::from(second);
    // Include default and split-default routes, global unicast and NAT64.
    (high ^ 0x2000_0000).leading_zeros() >= u32::from(length.min(3))
        || (high ^ 0x0064_ff9b).leading_zeros() >= u32::from(length.min(32))
}

#[cfg(not(windows))]
fn has_public_ipv6_route() -> Option<bool> {
    None
}

#[cfg(all(test, windows))]
#[test]
fn recognizes_public_ipv6_routes_including_split_defaults() {
    for (prefix, length) in [
        ("::", 0),
        ("::", 1),
        ("2000::", 3),
        ("2606::", 32),
        ("64:ff9b::", 96),
    ] {
        assert!(public_ipv6_prefix(prefix.parse().unwrap(), length));
    }
    for (prefix, length) in [("::1", 128), ("fe80::", 64), ("fd00::", 8), ("ff00::", 8)] {
        assert!(!public_ipv6_prefix(prefix.parse().unwrap(), length));
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
pub(crate) struct Timezone {
    pub id: String,
    pub daylight_disabled: bool,
}

#[cfg(windows)]
pub(crate) fn current_timezone() -> Option<Timezone> {
    use windows_sys::Win32::System::Time::{
        GetDynamicTimeZoneInformation, DYNAMIC_TIME_ZONE_INFORMATION,
    };
    let mut info = std::mem::MaybeUninit::<DYNAMIC_TIME_ZONE_INFORMATION>::uninit();
    // On success the system has initialized the entire output structure.
    let info = unsafe {
        if GetDynamicTimeZoneInformation(info.as_mut_ptr()) == u32::MAX {
            return None;
        }
        info.assume_init()
    };
    let id = utf16_field(&info.TimeZoneKeyName);
    (!id.is_empty()).then_some(Timezone {
        id,
        daylight_disabled: info.DynamicDaylightTimeDisabled != 0,
    })
}

#[cfg(not(windows))]
pub(crate) fn current_timezone() -> Option<Timezone> {
    None
}

pub(crate) fn set_timezone(config: &Config, zone: &str) -> bool {
    require_claude_stopped(config).is_ok() && output("tzutil.exe", &["/s", zone]).is_some()
}

pub fn proxy_runtime() -> Option<PathBuf> {
    let appdata = PathBuf::from(std::env::var_os("APPDATA")?);
    let clash_mi = appdata.join("ClashMi").join("service_core_setting.json");
    let verge = appdata
        .join("io.github.clash-verge-rev.clash-verge-rev")
        .join("clash-verge.yaml");
    let clash_mi_running = process_snapshot().processes().values().any(|process| {
        process
            .name()
            .to_string_lossy()
            .to_ascii_lowercase()
            .starts_with("clashmiservice")
    });
    if clash_mi_running && clash_mi.is_file() {
        Some(clash_mi)
    } else {
        Some(verge)
    }
}

pub fn start_clash_mi(config: &Config) -> bool {
    if require_claude_stopped(config).is_err() {
        return false;
    }
    let Some(appdata) = std::env::var_os("APPDATA").map(PathBuf::from) else {
        return false;
    };
    let data = appdata.join("ClashMi");
    let setting_path = data.join("setting.json");
    let core_path = data.join("service_core_setting.json");
    if !core_path.is_file() {
        return false;
    }
    let _ = update_clash_mi_json(&setting_path, |value| {
        value["auto_connect_after_launch"] = true.into();
        value["auto_set_system_proxy"] = true.into();
    });
    let _ = update_clash_mi_json(&core_path, |value| {
        value["mode"] = "global".into();
        value["ipv6"] = false.into();
        value["tun"]["overwrite"] = true.into();
        value["tun"]["enable"] = true.into();
    });
    // Keep the persisted safe mode in sync even when the service is already
    // running. The live controller update is applied by the repair pipeline.
    if clash_mi_core_running() {
        return true;
    }
    let system = process_snapshot();
    let running = system
        .processes()
        .values()
        .find(|process| looks_like_clash_mi(process.name()))
        .and_then(|process| {
            process
                .exe()
                .map(|path| (process.pid().as_u32(), path.to_owned()))
        });
    let installed = ["ProgramW6432", "ProgramFiles", "LOCALAPPDATA"]
        .into_iter()
        .filter_map(|name| std::env::var_os(name).map(PathBuf::from))
        .flat_map(|root| {
            [
                root.join("Clash Mi").join("clashmi.exe"),
                root.join("Programs").join("Clash Mi").join("clashmi.exe"),
            ]
        })
        .find(|path| path.is_file());
    let Some(executable) = running
        .as_ref()
        .map(|(_, path)| path.to_owned())
        .or(installed)
    else {
        return false;
    };
    if let Some((pid, _)) = running {
        let pid = pid.to_string();
        let _ = system_command("taskkill.exe")
            .args(["/PID", &pid, "/T"])
            .status();
        for _ in 0..10 {
            if !clash_mi_gui_running() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(250));
        }
        if clash_mi_gui_running() {
            let _ = system_command("taskkill.exe")
                .args(["/PID", &pid, "/T", "/F"])
                .status();
            std::thread::sleep(std::time::Duration::from_millis(500));
        }
        if clash_mi_gui_running() {
            return false;
        }
    }
    if Command::new(executable)
        .arg("--launch_startup")
        .spawn()
        .is_err()
    {
        return false;
    }
    for _ in 0..30 {
        std::thread::sleep(std::time::Duration::from_millis(500));
        if clash_mi_core_running() {
            return true;
        }
    }
    false
}

fn clash_mi_core_running() -> bool {
    process_snapshot().processes().values().any(|process| {
        process
            .name()
            .to_string_lossy()
            .to_ascii_lowercase()
            .starts_with("clashmiservice")
    })
}

fn clash_mi_gui_running() -> bool {
    process_snapshot()
        .processes()
        .values()
        .any(|process| looks_like_clash_mi(process.name()))
}

fn update_clash_mi_json(path: &Path, update: impl FnOnce(&mut serde_json::Value)) -> bool {
    let Ok(bytes) = std::fs::read(path) else {
        return false;
    };
    let Ok(mut value) = serde_json::from_slice(&bytes) else {
        return false;
    };
    update(&mut value);
    let Some(folder) = path.parent() else {
        return false;
    };
    let Some(name) = path.file_name().and_then(OsStr::to_str) else {
        return false;
    };
    crate::config::write_json(folder, name, &value).is_ok()
}

fn installed_claude_paths() -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(local) = std::env::var_os("LOCALAPPDATA").map(PathBuf::from) {
        candidates.push(local.join("AnthropicClaude").join("claude.exe"));
        candidates.push(local.join("Programs").join("Claude").join("Claude.exe"));
    }
    if let Some(programs) = std::env::var_os("ProgramFiles") {
        candidates.push(PathBuf::from(programs).join("Claude").join("Claude.exe"));
    }
    candidates
}

fn packaged_app_command(app_id: &str) -> Command {
    let explorer = std::env::var_os("SystemRoot")
        .map(|root| PathBuf::from(root).join("explorer.exe"))
        .unwrap_or_else(|| PathBuf::from("explorer.exe"));
    let mut command = Command::new(explorer);
    command.arg(format!("shell:AppsFolder\\{app_id}"));
    command
}

pub fn launch_claude(config: &Config) -> Result<(), String> {
    if !claude_processes(config).is_empty() {
        return Ok(());
    }
    let explicit_exe = config
        .claude_exe
        .as_deref()
        .filter(|path| !path.as_os_str().is_empty());
    if !config.claude_aumid.is_empty() {
        return launch_packaged_claude(config, &config.claude_aumid);
    }
    let installed = || {
        installed_claude_paths()
            .into_iter()
            .find(|path| path.is_file())
    };
    let spawned = if let Some(path) = explicit_exe.map(Path::to_owned).or_else(installed) {
        if !path.is_absolute() || !path.is_file() || !looks_like_claude(path.file_name()) {
            return Err("Claude 可执行文件路径无效，请检查 Rust 版配置".into());
        }
        Command::new(path).spawn()
    } else if std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .is_some_and(|local| local.join("Packages").join("Claude_pzs8sxrjxfjjc").is_dir())
    {
        return launch_packaged_claude(config, "Claude_pzs8sxrjxfjjc!Claude");
    } else {
        return Err("未找到 Claude 桌面版。可在 Rust 版配置指定 claudeExe 或 claudeAumid".into());
    };
    spawned.map_err(|error| format!("无法打开 Claude 桌面版（{error}）"))?;
    for _ in 0..20 {
        if !claude_processes(config).is_empty() {
            return Ok(());
        }
        std::thread::sleep(std::time::Duration::from_millis(500));
    }
    Err("已请求启动 Claude，尚未观测到桌面进程".into())
}

fn launch_packaged_claude(config: &Config, app_id: &str) -> Result<(), String> {
    wait_for_packaged_window(
        || {
            packaged_app_command(app_id)
                .spawn()
                .map(|_| ())
                .map_err(|error| format!("无法打开 Claude 桌面版（{error}）"))
        },
        || {
            let processes = claude_processes(config);
            (!processes.is_empty(), has_desktop_window(&processes))
        },
        || std::thread::sleep(std::time::Duration::from_millis(500)),
    )
}

fn wait_for_packaged_window(
    activate: impl Fn() -> Result<(), String>,
    mut observe: impl FnMut() -> (bool, bool),
    pause: impl Fn(),
) -> Result<(), String> {
    activate()?;
    let mut running = false;
    for step in 0..40 {
        let (observed, window) = observe();
        if window {
            return Ok(());
        }
        running = observed;
        if step == 16 {
            activate()?;
        }
        pause();
    }
    if running {
        Err("Claude 进程已启动，但尚未检测到桌面窗口".into())
    } else {
        Err("已请求启动 Claude，尚未观测到桌面进程".into())
    }
}

#[cfg(windows)]
fn has_desktop_window(processes: &[Process]) -> bool {
    use windows_sys::Win32::Foundation::{BOOL, HWND, LPARAM};
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        EnumWindows, GetWindowTextLengthW, GetWindowThreadProcessId, IsWindowVisible,
    };

    if processes.is_empty() {
        return false;
    }
    struct Search<'a> {
        processes: &'a [Process],
        found: bool,
    }
    unsafe extern "system" fn check(window: HWND, parameter: LPARAM) -> BOOL {
        let search = unsafe { &mut *(parameter as *mut Search<'_>) };
        let mut pid = 0;
        unsafe {
            GetWindowThreadProcessId(window, &mut pid);
            if search.processes.iter().any(|process| process.pid == pid)
                && IsWindowVisible(window) != 0
                && GetWindowTextLengthW(window) > 0
            {
                search.found = true;
                return 0;
            }
        }
        1
    }
    let mut search = Search {
        processes,
        found: false,
    };
    // EnumWindows calls check synchronously while search and its process slice live.
    unsafe { EnumWindows(Some(check), (&mut search as *mut Search<'_>) as LPARAM) };
    search.found
}

#[cfg(not(windows))]
fn has_desktop_window(processes: &[Process]) -> bool {
    !processes.is_empty()
}

#[test]
fn packaged_app_retries_when_only_a_background_process_is_present() {
    use std::cell::Cell;
    let activations = Cell::new(0);
    wait_for_packaged_window(
        || {
            activations.set(activations.get() + 1);
            Ok(())
        },
        || (true, activations.get() == 2),
        || {},
    )
    .unwrap();
    assert_eq!(activations.get(), 2);
    let error = wait_for_packaged_window(|| Ok(()), || (true, false), || {}).unwrap_err();
    assert!(error.contains("尚未检测到桌面窗口"));
}

#[test]
fn recognizes_clash_mi_service_as_a_proxy_core() {
    assert!(looks_like_proxy(OsStr::new("clashmiService.exe")));
    assert!(looks_like_proxy(OsStr::new("mihomo.exe")));
    assert!(!looks_like_proxy(OsStr::new("clashmi.exe")));
    assert!(looks_like_clash_mi(OsStr::new("clashmi.exe")));
}

#[cfg(all(test, windows))]
#[test]
fn packaged_app_uses_windows_explorer_at_the_system_root() {
    let command = packaged_app_command("Claude_pzs8sxrjxfjjc!Claude");
    let root = std::env::var_os("SystemRoot").expect("Windows system root");
    assert_eq!(
        Path::new(command.get_program()),
        PathBuf::from(root).join("explorer.exe")
    );
    assert_eq!(
        command.get_args().collect::<Vec<_>>(),
        [OsStr::new("shell:AppsFolder\\Claude_pzs8sxrjxfjjc!Claude")]
    );
}

fn looks_like_claude(name: Option<&OsStr>) -> bool {
    name.is_some_and(|name| name.to_string_lossy().eq_ignore_ascii_case("Claude.exe"))
}

pub fn log_folders() -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if let Some(path) = std::env::var_os("APPDATA").map(PathBuf::from) {
        paths.push(path.join("Claude").join("logs"));
    }
    if let Some(path) = std::env::var_os("LOCALAPPDATA").map(PathBuf::from) {
        paths.push(path.join("Claude").join("logs"));
        paths.push(path.join("Packages/Claude_pzs8sxrjxfjjc/LocalCache/Roaming/Claude/logs"));
    }
    paths
}

#[cfg(windows)]
fn tun_adapter_up() -> Option<bool> {
    use windows_sys::Win32::NetworkManagement::IpHelper::{FreeMibTable, GetIfTable2};
    use windows_sys::Win32::NetworkManagement::Ndis::IfOperStatusUp;
    let mut ptr = std::ptr::null_mut();
    // The OS allocates a variable-sized table. Release it with FreeMibTable.
    unsafe {
        if GetIfTable2(&mut ptr) != 0 || ptr.is_null() {
            return None;
        }
        let rows = std::slice::from_raw_parts((*ptr).Table.as_ptr(), (*ptr).NumEntries as usize);
        let up = rows.iter().any(|row| {
            let description = utf16_field(&row.Description).to_ascii_lowercase();
            let alias = utf16_field(&row.Alias).to_ascii_lowercase();
            row.OperStatus == IfOperStatusUp
                && (["meta tunnel", "mihomo", "clash", "wintun"]
                    .iter()
                    .any(|name| description.contains(name))
                    || ["mihomo", "meta", "clash"]
                        .iter()
                        .any(|name| alias.starts_with(name)))
        });
        FreeMibTable(ptr.cast());
        Some(up)
    }
}

#[cfg(windows)]
pub(crate) fn utf16_field(field: &[u16]) -> String {
    let end = field
        .iter()
        .position(|&unit| unit == 0)
        .unwrap_or(field.len());
    String::from_utf16_lossy(&field[..end])
}

#[cfg(not(windows))]
fn tun_adapter_up() -> Option<bool> {
    None
}

#[derive(Debug)]
pub struct TcpSocket {
    pub pid: u32,
    pub local_ip: IpAddr,
    pub local_port: u16,
    pub remote_ip: IpAddr,
    pub remote_port: u16,
    pub established: bool,
}

pub fn tcp_sockets() -> Option<Vec<TcpSocket>> {
    // Netstat port/PID columns are stable across Windows display languages.
    // Numeric output avoids reverse DNS. Header lines fail address parsing.
    let snapshot = output("netstat.exe", &["-ano"])?;
    Some(snapshot.lines().filter_map(parse_socket).collect())
}

fn parse_socket(line: &str) -> Option<TcpSocket> {
    let mut columns = line.split_whitespace();
    if columns.next()? != "TCP" {
        return None;
    }
    let local: SocketAddr = columns.next()?.parse().ok()?;
    let remote: SocketAddr = columns.next()?.parse().ok()?;
    let established = columns.next()? == "ESTABLISHED";
    let pid = columns.next()?.parse().ok()?;
    (remote.port() != 0).then_some(TcpSocket {
        pid,
        local_ip: local.ip(),
        local_port: local.port(),
        remote_ip: remote.ip(),
        remote_port: remote.port(),
        established,
    })
}
