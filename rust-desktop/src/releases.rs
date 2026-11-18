use semver::Version;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;

const REPOSITORY: &str = "Adgai115/claude-safe-launcher";
const TAG_PREFIX: &str = "desktop-v";
const PAGE_SIZE: usize = 50;
const MAX_PAGE_BYTES: u64 = 2 * 1024 * 1024;
const MAX_INSTALLER_BYTES: u64 = 128 * 1024 * 1024;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateCheck {
    pub current_version: String,
    pub available_version: Option<String>,
    pub direct: bool,
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
    digest: Option<String>,
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
        self.installer(&version).map(|_| version)
    }

    fn installer(&self, version: &Version) -> Option<&Asset> {
        let name = format!("{}.exe", installer_stem(version));
        self.assets
            .iter()
            .find(|asset| asset.name == name && asset.state == "uploaded" && asset.size > 0)
    }
}

fn installer_stem(version: &Version) -> String {
    format!("Claude-Environment-Checker-v{version}-win-x64-setup")
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
        direct: false,
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

pub fn download(current: &Version, requested: &str, folder: &Path) -> Result<PathBuf, String> {
    let version = stable_version(requested)
        .filter(|version| version > current)
        .ok_or("可安装版本无效，请重新检查更新")?;
    let tag = format!("{TAG_PREFIX}{version}");
    let metadata = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(12))
        .redirect(reqwest::redirect::Policy::none())
        .user_agent("ClaudeEnvironmentChecker")
        .build()
        .and_then(|client| {
            client
                .get(format!(
                    "https://api.github.com/repos/{REPOSITORY}/releases/tags/{tag}"
                ))
                .header("Accept", "application/vnd.github+json")
                .send()
        })
        .and_then(reqwest::blocking::Response::error_for_status)
        .map_err(|_| "无法核实 GitHub 发布，请重新检查更新")?;
    let mut json = Vec::new();
    metadata
        .take(MAX_PAGE_BYTES + 1)
        .read_to_end(&mut json)
        .map_err(|_| "无法读取 GitHub 发布信息")?;
    if json.len() as u64 > MAX_PAGE_BYTES {
        return Err("GitHub 发布信息超出限制".into());
    }
    let release: Release = serde_json::from_slice(&json).map_err(|_| "GitHub 发布格式无效")?;
    let asset = release
        .installer(&version)
        .filter(|_| release.desktop_version() == Some(version.clone()))
        .filter(|asset| asset.size <= MAX_INSTALLER_BYTES)
        .ok_or("此版本的 Windows 安装包不可用")?;
    let digest = asset
        .digest
        .as_deref()
        .and_then(|digest| digest.strip_prefix("sha256:"))
        .filter(|hex| hex.len() == 64 && hex.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .ok_or("GitHub 未提供可验证的安装包校验值，请从发布页手动下载")?;
    let url = format!(
        "https://github.com/{REPOSITORY}/releases/download/{tag}/{}",
        asset.name
    );
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(120))
        .user_agent("ClaudeEnvironmentChecker")
        .redirect(reqwest::redirect::Policy::custom(|attempt| {
            if attempt.previous().len() < 5
                && attempt.url().scheme() == "https"
                && matches!(
                    attempt.url().host_str(),
                    Some(
                        "github.com"
                            | "release-assets.githubusercontent.com"
                            | "objects.githubusercontent.com"
                    )
                )
            {
                attempt.follow()
            } else {
                attempt.error("unexpected GitHub download redirect")
            }
        }))
        .build()
        .map_err(|_| "无法初始化更新下载")?;
    let response = client
        .get(&url)
        .send()
        .and_then(reqwest::blocking::Response::error_for_status)
        .map_err(|_| "无法下载安装包，请稍后重试")?;
    std::fs::create_dir_all(folder).map_err(|_| "无法创建下载文件夹")?;
    let mut temp = tempfile::NamedTempFile::new_in(folder).map_err(|_| "无法写入下载文件夹")?;
    verify_download(response, temp.as_file_mut(), asset.size, digest)?;
    mark_internet_download(temp.path(), &url)?;
    crate::downloads::save(temp, folder, &installer_stem(&version), "exe")
        .map_err(|_| "无法在下载文件夹保存安装包".into())
}

fn verify_download(
    input: impl Read,
    mut output: impl Write,
    size: u64,
    digest: &str,
) -> Result<(), String> {
    let mut input = input.take(size + 1);
    let mut hash = Sha256::new();
    let mut total = 0;
    let mut buffer = [0; 32 * 1024];
    loop {
        let count = input.read(&mut buffer).map_err(|_| "安装包下载中断")?;
        if count == 0 {
            break;
        }
        total += count as u64;
        let bytes = &buffer[..count];
        hash.update(bytes);
        output.write_all(bytes).map_err(|_| "无法写入安装包")?;
    }
    if total != size || !format!("{:x}", hash.finalize()).eq_ignore_ascii_case(digest) {
        return Err("安装包 SHA-256 校验失败，请重新下载".into());
    }
    output.flush().map_err(|_| "无法完成安装包保存".into())
}

#[cfg(windows)]
fn mark_internet_download(path: &Path, url: &str) -> Result<(), String> {
    let mut marker = path.as_os_str().to_os_string();
    marker.push(":Zone.Identifier");
    std::fs::write(
        marker,
        format!("[ZoneTransfer]\r\nZoneId=3\r\nHostUrl={url}\r\n"),
    )
    .map_err(|_| "无法保留 Windows 下载来源标记，请从 GitHub 发布页下载".into())
}

#[cfg(not(windows))]
fn mark_internet_download(_path: &Path, _url: &str) -> Result<(), String> {
    Err("此安装包适用于 Windows".into())
}

#[cfg(windows)]
pub fn open(version: Option<&str>) -> Result<(), String> {
    shell_open(std::ffi::OsStr::new(&release_url(version)?))
        .map_err(|_| "无法打开浏览器，请在 GitHub 仓库的 Releases 页面查看更新".into())
}

pub fn launch_installer(path: &Path) -> Result<(), String> {
    #[cfg(windows)]
    return shell_open(path.as_os_str())
        .map_err(|_| format!("Windows 未打开安装包，已保存到 {}", path.display()));
    #[cfg(not(windows))]
    {
        let _ = path;
        Err("此安装包适用于 Windows".into())
    }
}

#[cfg(windows)]
fn shell_open(target: &std::ffi::OsStr) -> Result<(), ()> {
    use windows::core::{w, HSTRING, PCWSTR};
    use windows::Win32::UI::{Shell::ShellExecuteW, WindowsAndMessaging::SW_SHOWNORMAL};

    let target = HSTRING::from(target);
    let result = unsafe {
        ShellExecuteW(
            None,
            w!("open"),
            &target,
            PCWSTR::null(),
            PCWSTR::null(),
            SW_SHOWNORMAL,
        )
    };
    if result.0 as isize <= 32 {
        Err(())
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
            digest: None,
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
    fn rejects_changed_or_truncated_installers() {
        let bytes = b"installer fixture";
        let digest = format!("{:x}", Sha256::digest(bytes));
        assert!(verify_download(bytes.as_slice(), Vec::new(), bytes.len() as u64, &digest).is_ok());
        assert!(verify_download(bytes.as_slice(), Vec::new(), 4, &digest).is_err());
        assert!(verify_download(
            b"another fixture!!".as_slice(),
            Vec::new(),
            bytes.len() as u64,
            &digest
        )
        .is_err());
    }

    #[cfg(windows)]
    #[test]
    fn downloaded_installer_keeps_its_windows_zone_marker_after_saving() {
        let folder = tempfile::tempdir().unwrap();
        let temp = tempfile::NamedTempFile::new_in(folder.path()).unwrap();
        mark_internet_download(temp.path(), "https://github.com/example/download").unwrap();
        let installed = crate::downloads::save(temp, folder.path(), "fixture", "exe").unwrap();
        let mut marker = installed.into_os_string();
        marker.push(":Zone.Identifier");
        let contents = std::fs::read_to_string(marker).unwrap();
        assert!(contents.contains("ZoneId=3"));
        assert!(contents.contains("https://github.com/example/download"));
    }

    #[cfg(windows)]
    #[test]
    #[ignore = "requires access to the public GitHub release feed"]
    fn downloads_and_verifies_the_published_installer() {
        let current = Version::new(0, 0, 0);
        let version = check(&current).unwrap().available_version.unwrap();
        let folder = tempfile::tempdir().unwrap();
        let installer = download(&current, &version, folder.path()).unwrap();
        assert!(installer.metadata().unwrap().len() > 0);
        let mut marker = installer.into_os_string();
        marker.push(":Zone.Identifier");
        assert!(std::fs::read_to_string(marker)
            .unwrap()
            .contains("ZoneId=3"));
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
