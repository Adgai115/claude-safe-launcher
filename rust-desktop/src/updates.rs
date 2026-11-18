use crate::releases::UpdateCheck;
use crate::{machine, prepare_update_install, Config, Launcher};
use semver::Version;
use serde_json::Value;
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

pub fn prefer_direct(
    current: &Version,
    public: Result<UpdateCheck, String>,
    direct: Option<String>,
) -> Result<UpdateCheck, String> {
    if let Some(version) = direct.and_then(|version| Version::parse(&version).ok()) {
        let public_version = public
            .as_ref()
            .ok()
            .and_then(|info| info.available_version.as_deref())
            .and_then(|version| Version::parse(version).ok());
        if public_version.is_none_or(|public_version| version >= public_version) {
            return Ok(UpdateCheck {
                current_version: current.to_string(),
                available_version: Some(version.to_string()),
                direct: true,
            });
        }
    }
    public
}

pub fn can_install_directly(app: &AppHandle, update: &Update) -> bool {
    let Some(config) = app.config().plugins.0.get("updater") else {
        return false;
    };
    let windows = &config["windows"];
    let mode = windows
        .get("installMode")
        .or_else(|| windows.get("install-mode"));
    let unattended = match mode {
        None => true,
        Some(mode) => matches!(mode.as_str(), Some("passive" | "quiet")),
    };
    unattended
        && is_direct_patch(
            &app.package_info().version,
            &update.version,
            &update.raw_json,
        )
}

fn is_direct_patch(current: &Version, target: &str, manifest: &Value) -> bool {
    let Ok(target) = Version::parse(target) else {
        return false;
    };
    current.pre.is_empty()
        && current.build.is_empty()
        && target.pre.is_empty()
        && target.build.is_empty()
        && target.major == current.major
        && target.minor == current.minor
        && target.patch > current.patch
        && manifest["installMode"].as_str() == Some("direct")
}

pub async fn install(app: AppHandle, version: &str) -> Result<(), String> {
    let update = latest(&app)
        .await?
        .filter(|update| update.version == version)
        .ok_or("可安装版本已变更，请重新检查更新")?;
    if !can_install_directly(&app, &update) {
        return Err("此版本需要使用安装向导，请重新检查更新".into());
    }
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn direct_install_requires_an_explicit_compatible_patch() {
        let current = Version::new(0, 1, 24);
        let direct = json!({"installMode": "direct"});
        assert!(is_direct_patch(&current, "0.1.25", &direct));
        assert!(is_direct_patch(&current, "0.1.30", &direct));
        for version in [
            "0.1.24",
            "0.1.23",
            "0.2.0",
            "1.0.0",
            "0.1.25-beta.1",
            "0.1.25+local",
            "invalid",
        ] {
            assert!(!is_direct_patch(&current, version, &direct), "{version}");
        }
        assert!(!is_direct_patch(&current, "0.1.25", &json!({})));
        assert!(!is_direct_patch(
            &current,
            "0.1.25",
            &json!({"installMode": "installer"})
        ));
    }

    #[test]
    fn newer_public_release_uses_the_installer_even_with_an_older_signed_patch() {
        let current = Version::new(0, 1, 24);
        let public = |version: &str| {
            Ok(UpdateCheck {
                current_version: current.to_string(),
                available_version: Some(version.to_owned()),
                direct: false,
            })
        };
        let patch = Some("0.1.25".to_owned());
        assert!(
            prefer_direct(&current, public("0.1.25"), patch.clone())
                .unwrap()
                .direct
        );
        let upgrade = prefer_direct(&current, public("0.2.0"), patch).unwrap();
        assert_eq!(upgrade.available_version.as_deref(), Some("0.2.0"));
        assert!(!upgrade.direct);
        assert!(
            !prefer_direct(&current, public("0.1.25"), None)
                .unwrap()
                .direct
        );
    }
}
