#![cfg_attr(windows, windows_subsystem = "windows")]

mod downloads;
mod history;
mod notification;
mod releases;
#[cfg(all(windows, feature = "signed-updates"))]
mod updates;

use chrono::{DateTime, Utc};
use claude_safe_launcher_rust::{
    checks::{self, Action},
    config::Config,
    machine,
    report::{Group, Level, Report},
    timezone::{self, Recovery},
};
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::{Mutex, MutexGuard, TryLockError};
use std::time::{Duration, Instant};
use tauri::ipc::Channel;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, State, WindowEvent};

#[derive(Clone, Copy, Default, PartialEq, Eq)]
enum MonitorMode {
    #[default]
    Waiting,
    Watching,
    Paused,
}

impl MonitorMode {
    fn label(self) -> &'static str {
        match self {
            Self::Waiting => "waiting",
            Self::Watching => "watching",
            Self::Paused => "paused",
        }
    }
}

#[derive(Default)]
struct Snapshot {
    groups: Vec<Group>,
    message: String,
    claude_running: bool,
    monitor: MonitorMode,
    monitor_generation: u64,
    last_monitor_at: Option<DateTime<Utc>>,
    history_last: Option<(&'static str, history::Status)>,
    history_error: bool,
    notified_risks: BTreeMap<u8, Level>,
    timezone_pending: bool,
    timezone_status: Option<&'static str>,
    revision: u64,
    verified: bool,
}

impl Snapshot {
    fn as_json(&self) -> Value {
        let report = Report::new(&self.groups);
        json!({
            "version": env!("CARGO_PKG_VERSION"),
            "launchReady": self.verified && report.can_launch() && !self.claude_running,
            "claudeRunning": self.claude_running,
            "report": report,
            "monitorMode": self.monitor.label(),
            "lastMonitorAt": self.last_monitor_at,
            "historyError": self.history_error,
            "timezonePending": self.timezone_pending,
            "timezoneStatus": self.timezone_status,
            "message": self.message,
            "revision": self.revision,
        })
    }

    fn begin_check(&mut self, action: Action) -> Result<(), String> {
        if action == Action::Launch
            && !(self.verified && Report::new(&self.groups).can_launch() && !self.claude_running)
        {
            return Err("请先完成环境检查并达到 100 分".into());
        }
        self.verified = false;
        self.groups.clear();
        self.message.clear();
        Ok(())
    }

    fn tooltip(&self) -> &'static str {
        if self.monitor == MonitorMode::Paused {
            "Claude 环境检查器：监控已暂停"
        } else if self.monitor == MonitorMode::Waiting {
            "Claude 环境检查器：等待 Claude 运行"
        } else if !Report::new(&self.groups).can_launch() {
            "Claude 环境检查器：监控发现偏差"
        } else {
            "Claude 环境检查器：监控中"
        }
    }

    fn track_client(&mut self, running: bool) {
        self.claude_running = running;
        if !running {
            self.notified_risks.clear();
        }
        if self.monitor != MonitorMode::Paused {
            self.monitor = if running {
                MonitorMode::Watching
            } else {
                MonitorMode::Waiting
            };
        }
        if self.monitor != MonitorMode::Watching {
            self.last_monitor_at = None;
        }
    }

    fn new_risks(&mut self, groups: &[Group]) -> Vec<&'static str> {
        let mut titles = Vec::new();
        for group in groups {
            match group.level {
                Level::Failed | Level::Warning => {
                    if self.notified_risks.insert(group.id, group.level) != Some(group.level) {
                        titles.push(group.title);
                    }
                }
                Level::Unknown | Level::NoData | Level::PendingConnection => {}
                _ => {
                    self.notified_risks.remove(&group.id);
                }
            }
        }
        titles
    }

    fn merge(&mut self, updates: Vec<Group>) {
        for updated in updates {
            if let Some(previous) = self.groups.iter_mut().find(|group| group.id == updated.id) {
                if matches!(previous.level, Level::Failed | Level::Warning)
                    && updated.level == Level::Unknown
                {
                    const STALE: &str = "\n实时证据不足，保留上次确认的偏差";
                    if !previous.detail.ends_with(STALE) {
                        previous.detail.push_str(STALE);
                    }
                    continue;
                }
                *previous = updated;
            } else {
                self.groups.push(updated);
            }
        }
        self.groups.sort_by_key(|group| group.id);
    }
}

struct Launcher {
    folder: PathBuf,
    snapshot: Mutex<Snapshot>,
    operation: Mutex<()>,
    #[cfg(all(windows, feature = "signed-updates"))]
    updates_enabled: bool,
}

impl Launcher {
    fn begin(&self) -> Result<MutexGuard<'_, ()>, String> {
        self.operation.try_lock().map_err(|error| match error {
            TryLockError::WouldBlock => "正在检查或复查，请稍候".into(),
            TryLockError::Poisoned(_) => "检查进程异常，请重启 Rust 版".into(),
        })
    }
}

fn lock<T>(mutex: &Mutex<T>) -> Result<MutexGuard<'_, T>, String> {
    mutex
        .lock()
        .map_err(|_| "应用状态无法读取，请重启 Rust 版".into())
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Settings {
    claude_group: String,
    main_group: String,
    pin_main_group: bool,
    auto_repair: bool,
    has_baseline: bool,
    directory: String,
    log_path: String,
    claude_running: bool,
}

fn read_settings(state: &Launcher) -> Result<Settings, String> {
    let config = Config::load(&state.folder)?;
    let claude_running = machine::is_claude_running(&config);
    Ok(Settings {
        has_baseline: config.has_baseline(),
        claude_group: config.claude_group,
        main_group: config.main_group,
        pin_main_group: config.pin_main_group,
        auto_repair: config.auto_repair,
        directory: state.folder.to_string_lossy().into_owned(),
        log_path: history::path(&state.folder).to_string_lossy().into_owned(),
        claude_running,
    })
}

#[tauri::command]
fn load_settings(state: State<'_, Launcher>) -> Result<Settings, String> {
    read_settings(&state)
}

#[tauri::command]
fn save_groups(
    app: AppHandle,
    state: State<'_, Launcher>,
    claude_group: String,
    main_group: String,
    pin_main_group: bool,
    auto_repair: bool,
) -> Result<Settings, String> {
    let primary = claude_group.trim();
    let secondary = main_group.trim();
    let valid = |name: &str| {
        !name.is_empty()
            && name.chars().count() <= 128
            && !name.chars().any(char::is_control)
            && name != "."
            && name != ".."
    };
    if !valid(primary) || (pin_main_group && (!valid(secondary) || primary == secondary)) {
        return Err("请填写有效且不同的策略组名称".into());
    }
    let _operation = state.begin()?;
    let mut config = Config::load(&state.folder)?;
    let changed_groups = config.claude_group != primary
        || config.main_group != secondary
        || config.pin_main_group != pin_main_group;
    if changed_groups || config.auto_repair != auto_repair {
        machine::require_claude_stopped(&config)?;
        if changed_groups {
            config.claude_group = primary.into();
            config.main_group = secondary.into();
            config.pin_main_group = pin_main_group;
            config.expected_node.clear();
        }
        config.auto_repair = auto_repair;
        config.save(&state.folder)?;
    }
    if changed_groups {
        let mut snapshot = lock(&state.snapshot)?;
        snapshot.groups.clear();
        snapshot.message = "策略组已变更，请重新核对环境".into();
        snapshot.verified = false;
        snapshot.last_monitor_at = None;
        publish(&app, snapshot, "settings_changed");
    }
    read_settings(&state)
}

#[tauri::command]
fn get_snapshot(state: State<'_, Launcher>) -> Result<Value, String> {
    Ok(lock(&state.snapshot)?.as_json())
}

#[tauri::command]
fn read_monitor_history(state: State<'_, Launcher>) -> Result<Vec<history::Entry>, String> {
    let _snapshot = lock(&state.snapshot)?;
    history::recent(&state.folder).map_err(|_| "无法读取本地监控日志".into())
}

#[tauri::command]
fn export_diagnostics(app: AppHandle, state: State<'_, Launcher>) -> Result<String, String> {
    let destination = app
        .path()
        .download_dir()
        .map_err(|_| "无法定位 Windows 下载文件夹")?;
    let snapshot = lock(&state.snapshot)?;
    let status = history::Status::new(&Report::new(&snapshot.groups), snapshot.monitor.label());
    let path = history::export(
        &state.folder,
        &destination,
        &status,
        snapshot.timezone_pending,
    )
    .map_err(|_| "无法将诊断文件保存到下载文件夹".to_owned())?;
    Ok(path.to_string_lossy().into_owned())
}

#[tauri::command]
fn copy_status(summary: String) -> Result<(), String> {
    if summary.len() > 4096 {
        return Err("检查状态超出复制限制".into());
    }
    arboard::Clipboard::new()
        .and_then(|mut clipboard| clipboard.set_text(summary))
        .map_err(|_| "无法写入剪贴板，请重试".into())
}

#[tauri::command]
async fn preview_repair(app: AppHandle) -> Result<Vec<checks::RepairChange>, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<Launcher>();
        let _operation = state.begin()?;
        checks::preview_repair(&state.folder)
    })
    .await
    .map_err(|_| "修复预览任务异常退出".to_owned())?
}

#[tauri::command]
async fn run_check(
    app: AppHandle,
    action: Action,
    browser_zone: String,
    browser_webrtc: Option<Vec<String>>,
    progress: Channel<Value>,
    approved_repairs: Option<Vec<checks::RepairChange>>,
    automatic: Option<bool>,
) -> Result<Value, String> {
    if browser_zone.len() > 128 || browser_zone.chars().any(char::is_control) {
        return Err("面板时区格式无效".into());
    }
    let browser_webrtc = browser_webrtc.map(|addresses| {
        addresses
            .into_iter()
            .take(32)
            .filter_map(|address| address.parse().ok())
            .collect::<Vec<_>>()
    });
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<Launcher>();
        let _operation = state.begin()?;
        let running = machine::is_claude_running(&Config::load(&state.folder)?);
        let action = action.when_running(running)?;
        {
            let mut snapshot = lock(&state.snapshot)?;
            snapshot.claude_running = running;
            snapshot.begin_check(action)?;
        }
        let result = checks::run(
            &state.folder,
            action,
            approved_repairs.as_deref(),
            automatic.unwrap_or(false),
            &browser_zone,
            browser_webrtc.as_deref(),
            |groups| {
                let _ = progress.send(json!(Report::progress(groups)));
            },
        );
        let mut snapshot = lock(&state.snapshot)?;
        let result = match result {
            Ok(result) => result,
            Err(error) => {
                snapshot.message = "检查未完成".into();
                publish(&app, snapshot, "check_failed");
                return Err(error);
            }
        };
        snapshot.groups = result.groups;
        snapshot.message = result.message;
        snapshot.track_client(result.claude_running);
        if result.launched && snapshot.monitor == MonitorMode::Paused {
            snapshot.message = "Claude 已运行，后台监控已暂停".into();
        }
        snapshot.verified = true;
        let event = match result.action {
            Action::Check => "read_only_check",
            Action::Repair => "check_and_repair",
            Action::Learn => "learn_baseline",
            Action::Launch if result.launched => "launch_confirmed",
            Action::Launch => "launch_unconfirmed",
        };
        Ok(publish(&app, snapshot, event))
    })
    .await
    .map_err(|_| "检查任务异常退出".to_owned())?
}

#[tauri::command]
fn set_monitor(app: AppHandle, state: State<'_, Launcher>, enabled: bool) -> Result<Value, String> {
    let mut snapshot = lock(&state.snapshot)?;
    snapshot.monitor = if enabled {
        MonitorMode::Waiting
    } else {
        MonitorMode::Paused
    };
    snapshot.monitor_generation += 1;
    snapshot.notified_risks.clear();
    snapshot.last_monitor_at = None;
    snapshot.message = if enabled {
        "监控已恢复，等待 Claude 运行"
    } else {
        "监控已暂停"
    }
    .into();
    let event = if enabled {
        "monitor_resumed"
    } else {
        "monitor_paused"
    };
    Ok(publish(&app, snapshot, event))
}

fn publish(app: &AppHandle, mut snapshot: MutexGuard<'_, Snapshot>, event: &'static str) -> Value {
    snapshot.revision += 1;
    let folder = &app.state::<Launcher>().folder;
    let pending = timezone::pending(folder);
    if pending && !snapshot.timezone_pending && event != "timezone_restore_error" {
        snapshot.timezone_status = None;
    }
    snapshot.timezone_pending = pending;
    let status = history::Status::new(&Report::new(&snapshot.groups), snapshot.monitor.label());
    let unchanged_sample = matches!(event, "monitor_error" | "timezone_restore_error")
        && snapshot
            .history_last
            .as_ref()
            .is_some_and(|(kind, last)| *kind == event && *last == status);
    if !unchanged_sample {
        match history::append(folder, event, &status) {
            Ok(()) => {
                snapshot.history_error = false;
                snapshot.history_last = Some((event, status));
            }
            Err(_) => snapshot.history_error = true,
        }
    }
    let tooltip = snapshot.tooltip();
    let payload = snapshot.as_json();
    drop(snapshot);
    if let Some(tray) = app.tray_by_id("launcher") {
        let _ = tray.set_tooltip(Some(tooltip));
    }
    payload
}

fn monitor(app: AppHandle) {
    let mut next_risk = Instant::now();
    let mut next_environment = next_risk;
    let mut next_timezone_retry = next_risk;
    loop {
        std::thread::sleep(Duration::from_secs(3));
        let state = app.state::<Launcher>();
        let Ok(_operation) = state.begin() else {
            continue;
        };
        if Instant::now() >= next_timezone_retry && timezone::pending(&state.folder) {
            if finish_timezone_recovery(&app, false) {
                next_timezone_retry = Instant::now() + Duration::from_secs(15);
                continue;
            }
        }
        let (mode, generation, verified) = match lock(&state.snapshot) {
            Ok(snapshot) => (
                snapshot.monitor,
                snapshot.monitor_generation,
                snapshot.verified,
            ),
            Err(_) => continue,
        };
        let now = Instant::now();
        if mode != MonitorMode::Watching {
            next_risk = now;
            next_environment = now;
        }
        let passive = mode == MonitorMode::Paused || (mode == MonitorMode::Waiting && !verified);
        let Ok(config) = Config::load(&state.folder) else {
            continue;
        };
        let running = machine::is_claude_running(&config);
        // Check process presence while waiting or between full connection snapshots.
        let result = if running && mode == MonitorMode::Watching && now >= next_risk {
            let include_environment = now >= next_environment;
            let observations = checks::observe(&state.folder, include_environment);
            let done = Instant::now();
            next_risk = done + Duration::from_secs(30);
            if include_environment {
                next_environment = done + Duration::from_secs(300);
            }
            observations
        } else {
            Ok(running.then(Vec::new))
        };
        let Ok(mut snapshot) = lock(&state.snapshot) else {
            continue;
        };
        if snapshot.monitor_generation != generation {
            continue;
        }
        let guard_changed = snapshot.claude_running != running;
        snapshot.claude_running = running;
        let mut risks = Vec::new();
        let event = if passive {
            if !guard_changed {
                continue;
            }
            if !snapshot.groups.is_empty() {
                snapshot.merge(vec![if running {
                    checks::routes_after_launch()
                } else {
                    checks::routes_before_launch()
                }]);
            }
            snapshot.message = if running {
                "Claude 正在运行，相关配置已锁定"
            } else {
                "Claude 已退出，相关配置已解锁"
            }
            .into();
            if running {
                "configuration_locked"
            } else {
                "configuration_unlocked"
            }
        } else {
            match result {
                Ok(Some(groups)) if groups.is_empty() && mode == MonitorMode::Waiting => {
                    snapshot.track_client(true);
                    snapshot.merge(vec![checks::routes_after_launch()]);
                    snapshot.message = "检测到 Claude，正在进入后台监控".into();
                    "monitor_attached"
                }
                Ok(Some(groups)) if groups.is_empty() => continue,
                Ok(Some(groups)) => {
                    risks = snapshot.new_risks(&groups);
                    snapshot.merge(groups);
                    snapshot.message = if snapshot
                        .groups
                        .iter()
                        .any(|group| matches!(group.level, Level::Failed | Level::Warning))
                    {
                        "后台监控发现偏差，请查看检查明细"
                    } else {
                        "后台监控中"
                    }
                    .into();
                    snapshot.last_monitor_at = Some(Utc::now());
                    if risks.is_empty() {
                        "monitor_sample"
                    } else {
                        "monitor_risk"
                    }
                }
                Ok(None) if mode == MonitorMode::Waiting => continue,
                Ok(None) => {
                    snapshot.merge(vec![checks::routes_before_launch()]);
                    snapshot.track_client(false);
                    snapshot.message = "Claude 已退出，等待下次运行".into();
                    "claude_exited"
                }
                Err(err) => {
                    snapshot.message = format!("监控复查失败：{err}");
                    "monitor_error"
                }
            }
        };
        let payload = publish(&app, snapshot, event);
        let _ = app.emit_to("main", "monitor-snapshot", payload);
        if !risks.is_empty() {
            notification::show(format!("{}出现偏差，请打开面板查看。", risks.join("、")));
        }
    }
}

fn finish_timezone_recovery(app: &AppHandle, inactive_cleanup: bool) -> bool {
    let state = app.state::<Launcher>();
    let (event, message) = match timezone::reconcile(&state.folder, inactive_cleanup) {
        Ok(Recovery::None) => return false,
        Ok(Recovery::Restored) => (
            "timezone_restored",
            "已恢复 Windows 原时区，下次启动前请重新检查".to_owned(),
        ),
        Ok(Recovery::Preserved) => (
            "timezone_preserved",
            "检测到时区后来被调整，已保留当前时区".to_owned(),
        ),
        Err(error) => ("timezone_restore_error", error),
    };
    let Ok(mut snapshot) = lock(&state.snapshot) else {
        return false;
    };
    let previous_status = snapshot.timezone_status.replace(event);
    if event != "timezone_restore_error" {
        snapshot.verified = false;
        snapshot.track_client(false);
        if !snapshot.groups.is_empty() {
            let mut updates = vec![checks::routes_before_launch()];
            if let Ok(zone) = checks::recheck_system_timezone(&state.folder) {
                updates.push(zone);
            }
            snapshot.merge(updates);
        }
    }
    snapshot.message = message;
    let payload = publish(app, snapshot, event);
    let _ = app.emit_to("main", "monitor-snapshot", payload);
    if event == "timezone_restore_error" && previous_status != Some(event) {
        notification::show("Windows 原时区恢复失败，可在面板底部重试。".into());
    }
    true
}

#[tauri::command]
async fn retry_timezone_restore(app: AppHandle) -> Result<Value, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<Launcher>();
        let _operation = state.begin()?;
        machine::require_claude_stopped(&Config::load(&state.folder)?)?;
        finish_timezone_recovery(&app, true);
        let payload = lock(&state.snapshot)?.as_json();
        Ok(payload)
    })
    .await
    .map_err(|_| "时区恢复任务异常退出".to_owned())?
}

#[tauri::command]
async fn check_for_update(app: AppHandle) -> Result<releases::UpdateCheck, String> {
    let current = app.package_info().version.clone();
    let public_check = tauri::async_runtime::spawn_blocking(move || releases::check(&current));
    #[cfg(all(windows, feature = "signed-updates"))]
    if app.state::<Launcher>().updates_enabled {
        let direct = updates::latest(&app)
            .await
            .ok()
            .flatten()
            .filter(|update| updates::can_install_directly(&app, update))
            .map(|update| update.version);
        let public = public_check
            .await
            .map_err(|_| "更新检查任务异常退出".to_owned())?;
        return updates::prefer_direct(&app.package_info().version, public, direct);
    }
    public_check
        .await
        .map_err(|_| "更新检查任务异常退出".to_owned())?
}

#[tauri::command]
fn open_release_page(version: Option<String>) -> Result<(), String> {
    releases::open(version.as_deref())
}

#[tauri::command]
async fn install_update(
    app: AppHandle,
    version: String,
    direct: bool,
) -> Result<(), releases::UpdateFailure> {
    use releases::{UpdateFailure, UpdateNext};

    if direct {
        #[cfg(all(windows, feature = "signed-updates"))]
        if app.state::<Launcher>().updates_enabled {
            return updates::install(app, &version).await;
        }
        return Err(UpdateFailure::new(
            "此构建无法直接更新，请重新检查更新。",
            UpdateNext::Recheck,
        ));
    }
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<Launcher>();
        let _operation = state.begin()?;
        require_claude_stopped_for_update(&state)?;
        let folder = app
            .path()
            .download_dir()
            .map_err(|_| "无法定位 Windows 下载文件夹")?;
        let installer = releases::download(&app.package_info().version, &version, &folder)?;
        prepare_update_install(&app, &state)?;
        releases::launch_installer(&installer)?;
        app.exit(0);
        Ok(())
    })
    .await
    .map_err(|_| UpdateFailure::from("更新任务意外中断，请重试。"))?
}

fn require_claude_stopped_for_update(state: &Launcher) -> Result<(), releases::UpdateFailure> {
    machine::require_claude_stopped(&Config::load(&state.folder)?)
        .map_err(|_| "Claude 正在运行。请完全退出 Claude，再点击「重试更新」。".into())
}

fn prepare_update_install(
    app: &AppHandle,
    state: &Launcher,
) -> Result<(), releases::UpdateFailure> {
    require_claude_stopped_for_update(state)?;
    if timezone::pending(&state.folder) {
        finish_timezone_recovery(app, true);
        if timezone::pending(&state.folder) {
            return Err("请先完成原时区恢复再安装更新".into());
        }
    }
    Ok(())
}

fn quit_launcher(app: &AppHandle) {
    let state = app.state::<Launcher>();
    if let Ok(_operation) = state.begin() {
        finish_timezone_recovery(app, true);
    }
    app.exit(0);
}

fn show_main(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.unminimize();
        let _ = window.set_focus();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn client_rechecks_respect_pause_and_follow_running_state() {
        let mut snapshot = Snapshot::default();
        assert!(snapshot.monitor == MonitorMode::Waiting);
        snapshot.track_client(true);
        assert!(snapshot.monitor == MonitorMode::Watching);
        snapshot.monitor = MonitorMode::Paused;
        snapshot.last_monitor_at = Some(Utc::now());
        snapshot.track_client(true);
        assert!(snapshot.monitor == MonitorMode::Paused);
        assert!(snapshot.last_monitor_at.is_none());
        snapshot.monitor = MonitorMode::Waiting;
        snapshot.track_client(true);
        snapshot.track_client(false);
        assert!(snapshot.monitor == MonitorMode::Waiting);
    }

    #[test]
    fn launch_gate_requires_a_fresh_complete_full_score() {
        let mut snapshot = Snapshot::default();
        assert!(snapshot.begin_check(Action::Launch).is_err());
        snapshot.groups = (1..=14)
            .map(|id| Group::new(id, "检查", Level::Pass, ""))
            .collect();
        assert!(snapshot.begin_check(Action::Launch).is_err());
        snapshot.verified = true;
        snapshot.groups[1] = Group::new(2, "时区", Level::Warning, "偏差");
        assert!(snapshot.begin_check(Action::Launch).is_err());
        snapshot.groups[1] = Group::new(2, "时区", Level::Pass, "");
        snapshot.track_client(true);
        assert!(snapshot.begin_check(Action::Launch).is_err());
        snapshot.track_client(false);
        assert!(snapshot.begin_check(Action::Launch).is_ok());
        assert!(snapshot.begin_check(Action::Launch).is_err());
    }

    #[test]
    fn risk_notifications_rearm_after_recovery_and_ignore_inconclusive_samples() {
        let mut snapshot = Snapshot::default();
        let sample = |level| [Group::new(4, "出口一致性", level, "")];
        assert_eq!(snapshot.new_risks(&sample(Level::Failed)), ["出口一致性"]);
        assert!(snapshot.new_risks(&sample(Level::Unknown)).is_empty());
        assert!(snapshot.new_risks(&sample(Level::Failed)).is_empty());
        assert!(snapshot.new_risks(&sample(Level::Pass)).is_empty());
        assert_eq!(snapshot.new_risks(&sample(Level::Failed)), ["出口一致性"]);
    }
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _, _| {
            show_main(app)
        }))
        .setup(|app| {
            let folder = app.path().app_local_data_dir()?;
            let claude_running =
                Config::load(&folder).is_ok_and(|config| machine::is_claude_running(&config));
            let timezone_pending = timezone::pending(&folder);
            #[cfg(all(windows, feature = "signed-updates"))]
            let updates_enabled = updates::register(app.handle())?;
            app.manage(Launcher {
                folder,
                snapshot: Mutex::new(Snapshot {
                    claude_running,
                    timezone_pending,
                    ..Snapshot::default()
                }),
                operation: Mutex::default(),
                #[cfg(all(windows, feature = "signed-updates"))]
                updates_enabled,
            });
            finish_timezone_recovery(app.handle(), true);
            let open = MenuItem::with_id(app, "open", "打开面板", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "退出 Rust 版", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&open, &quit])?;
            let mut tray = TrayIconBuilder::with_id("launcher")
                .tooltip("Claude 环境检查器")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id().as_ref() {
                    "open" => show_main(app),
                    "quit" => quit_launcher(app),
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        ..
                    } = event
                    {
                        show_main(tray.app_handle());
                    }
                });
            if let Some(icon) = app.default_window_icon() {
                tray = tray.icon(icon.clone());
            }
            tray.build(app)?;
            let handle = app.handle().clone();
            std::thread::spawn(move || monitor(handle));
            Ok(())
        })
        .on_window_event(|window, event| {
            if let WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .invoke_handler(tauri::generate_handler![
            load_settings,
            save_groups,
            get_snapshot,
            read_monitor_history,
            export_diagnostics,
            copy_status,
            preview_repair,
            run_check,
            set_monitor,
            retry_timezone_restore,
            check_for_update,
            install_update,
            open_release_page,
        ])
        .run(tauri::generate_context!())
        .expect("unable to start Claude 环境检查器");
}
