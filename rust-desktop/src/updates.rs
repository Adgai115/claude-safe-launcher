use crate::{machine, prepare_update_install, Config, Launcher};
use std::time::Duration;
use tauri::{AppHandle, Manager};
use tauri_plugin_updater::{Update, UpdaterExt};

pub fn register(app: &AppHandle) -> tauri::Result<bool> {
    let Some(config) = app.config().plugins.0.get("updater") else {
        return Ok(false);
    };
    let configured = config["pubkey"]
        .as_str()
        .is_some_and(|key| !key.trim().is_empty())
        && config["endpoints"].as_array().is_some_and(|endpoints| {
            !endpoints.is_empty()
                && endpoints
                    .iter()
                    .all(|url| url.as_str().is_some_and(|url| url.starts_with("https://")))
        })
        && config["requireSignedVersion"].as_bool() == Some(true)
        && [
            "allowDowngrades",
            "dangerousInsecureTransportProtocol",
            "dangerousAcceptInvalidCerts",
            "dangerousAcceptInvalidHostnames",
        ]
        .iter()
        .all(|key| config[key].as_bool() != Some(true));
    if configured {
        app.plugin(tauri_plugin_updater::Builder::new().build())?;
    }
    Ok(configured)
}

pub async fn latest(app: &AppHandle) -> Result<Option<Update>, String> {
    let updater = app
        .updater_builder()
        .timeout(Duration::from_secs(60))
        .build()
        .map_err(|_| "更新服务配置无效")?;
    updater
        .check()
        .await
        .map_err(|_| "无法获取更新，请稍后重试".into())
}

pub async fn install(app: AppHandle, version: &str) -> Result<(), String> {
    let update = latest(&app)
        .await?
        .filter(|update| update.version == version)
        .ok_or("可安装版本已变更，请重新检查更新")?;
    {
        let state = app.state::<Launcher>();
        machine::require_claude_stopped(&Config::load(&state.folder)?)?;
    }
    let bytes = update
        .download(|_, _| {}, || {})
        .await
        .map_err(|_| "下载失败或更新签名校验未通过")?;
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<Launcher>();
        let _operation = state.begin()?;
        prepare_update_install(&app, &state)?;
        update
            .install(bytes)
            .map_err(|_| "无法安装已验证的更新".into())
    })
    .await
    .map_err(|_| "更新任务异常退出".to_owned())?
}
