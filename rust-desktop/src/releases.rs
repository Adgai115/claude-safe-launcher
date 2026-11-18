use semver::Version;
use serde::{Deserialize, Serialize};
use std::io::Read;
use std::time::Duration;

const REPOSITORY: &str = "Adgai115/claude-safe-launcher";
const TAG_PREFIX: &str = "desktop-v";
const PAGE_SIZE: usize = 50;
const MAX_PAGE_BYTES: u64 = 2 * 1024 * 1024;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateCheck {
    pub current_version: String,
    pub available_version: Option<String>,
    pub signed: bool,
}

#[derive(Deserialize)]
struct Release {
    tag_name: String,
    draft: bool,
    prerelease: bool,
    assets: Vec<Asset>,
}

#[derive(Deserialize)]
struct Asset {
    name: String,
    state: String,
    size: u64,
}

fn stable_version(value: &str) -> Option<Version> {
    let version = Version::parse(value).ok()?;
    (version.pre.is_empty() && version.build.is_empty()).then_some(version)
}

impl Release {
    fn desktop_version(&self) -> Option<Version> {
        if self.draft || self.prerelease {
            return None;
        }
        let version = stable_version(self.tag_name.strip_prefix(TAG_PREFIX)?)?;
        let installer = format!("Claude-Environment-Checker-v{version}-win-x64-setup.exe");
        self.assets
            .iter()
            .any(|asset| asset.name == installer && asset.state == "uploaded" && asset.size > 0)
            .then_some(version)
    }
}

fn latest_desktop(releases: &[Release]) -> Option<Version> {
    releases.iter().filter_map(Release::desktop_version).max()
}

pub fn check(current: &Version) -> Result<UpdateCheck, String> {
    let failure = "无法检查 GitHub 更新，请稍后重试";
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(10))
        .redirect(reqwest::redirect::Policy::none())
        .user_agent(concat!(
            "ClaudeEnvironmentChecker/",
            env!("CARGO_PKG_VERSION")
        ))
        .build()
        .map_err(|_| failure)?;
    let endpoint = format!("https://api.github.com/repos/{REPOSITORY}/releases");
    let mut latest = None;
    for page in 1..=3 {
        let response = client
            .get(&endpoint)
            .query(&[("per_page", PAGE_SIZE), ("page", page)])
            .header("Accept", "application/vnd.github+json")
            .send()
            .and_then(reqwest::blocking::Response::error_for_status)
            .map_err(|_| failure)?;
        let mut body = Vec::new();
        response
            .take(MAX_PAGE_BYTES + 1)
            .read_to_end(&mut body)
            .map_err(|_| failure)?;
        if body.len() as u64 > MAX_PAGE_BYTES {
            return Err(failure.into());
        }
        let releases: Vec<Release> = serde_json::from_slice(&body).map_err(|_| failure)?;
        latest = latest.max(latest_desktop(&releases));
        if releases.len() < PAGE_SIZE {
            break;
        }
    }
    let latest = latest.ok_or("GitHub 暂无可用的 Windows x64 桌面版发布")?;
    Ok(UpdateCheck {
        current_version: current.to_string(),
        available_version: (latest > *current).then(|| latest.to_string()),
        signed: false,
    })
}

fn release_url(version: Option<&str>) -> Result<String, String> {
    let page = format!("https://github.com/{REPOSITORY}/releases");
    match version {
        Some(value) => stable_version(value)
            .map(|version| format!("{page}/tag/{TAG_PREFIX}{version}"))
            .ok_or_else(|| "发布版本格式无效".into()),
        None => Ok(page),
    }
}

#[cfg(windows)]
pub fn open(version: Option<&str>) -> Result<(), String> {
    use windows::core::{w, HSTRING, PCWSTR};
    use windows::Win32::UI::{Shell::ShellExecuteW, WindowsAndMessaging::SW_SHOWNORMAL};

    let url = HSTRING::from(release_url(version)?);
    let result = unsafe {
        ShellExecuteW(
            None,
            w!("open"),
            &url,
            PCWSTR::null(),
            PCWSTR::null(),
            SW_SHOWNORMAL,
        )
    };
    if result.0 as isize <= 32 {
        Err("无法打开浏览器，请在 GitHub 仓库的 Releases 页面查看更新".into())
    } else {
        Ok(())
    }
}

#[cfg(not(windows))]
pub fn open(version: Option<&str>) -> Result<(), String> {
    let _url = release_url(version)?;
    Err("请在 GitHub 仓库的 Releases 页面查看更新".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn selects_the_highest_complete_stable_desktop_release() {
        let release = |tag: &str, assets: Vec<Asset>, draft, prerelease| Release {
            tag_name: tag.into(),
            draft,
            prerelease,
            assets,
        };
        let asset = |version: &str, state: &str| Asset {
            name: format!("Claude-Environment-Checker-v{version}-win-x64-setup.exe"),
            state: state.into(),
            size: 1024,
        };
        let releases = [
            release(
                "desktop-v0.1.9",
                vec![asset("0.1.9", "uploaded")],
                false,
                false,
            ),
            release("v3.5.3", vec![asset("3.5.3", "uploaded")], false, false),
            release(
                "desktop-v0.1.10",
                vec![asset("0.1.10", "uploaded")],
                false,
                false,
            ),
            release("desktop-v0.2.0", vec![asset("0.2.0", "new")], false, false),
            release(
                "desktop-v0.3.0",
                vec![asset("0.3.0", "uploaded")],
                true,
                false,
            ),
            release(
                "desktop-v0.4.0",
                vec![asset("0.4.0", "uploaded")],
                false,
                true,
            ),
            release(
                "desktop-v0.5.0-alpha.1",
                vec![asset("0.5.0-alpha.1", "uploaded")],
                false,
                false,
            ),
            release(
                "desktop-v0.6.0",
                vec![asset("0.5.0", "uploaded")],
                false,
                false,
            ),
        ];
        assert_eq!(latest_desktop(&releases), Some(Version::new(0, 1, 10)));
    }

    #[test]
    fn browser_links_are_limited_to_the_fixed_project_and_stable_tags() {
        assert_eq!(
            release_url(Some("0.1.22")).unwrap(),
            "https://github.com/Adgai115/claude-safe-launcher/releases/tag/desktop-v0.1.22"
        );
        assert!(release_url(Some("0.1.22/../../../elsewhere")).is_err());
        assert!(release_url(Some("0.1.22+custom")).is_err());
    }
}
