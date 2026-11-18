use serde::{Deserialize, Serialize};
use std::io::{self, Write};
use std::net::IpAddr;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Config {
    pub claude_group: String,
    pub main_group: String,
    pub pin_main_group: bool,
    pub expected_ip: Option<IpAddr>,
    pub expected_loc: String,
    pub expected_node: String,
    pub vpn_interface: Option<String>,
    pub timezone: String,
    pub expected_tz_iana: String,
    pub claude_exe: Option<PathBuf>,
    pub claude_aumid: String,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            claude_group: "Claude".into(),
            main_group: String::new(),
            pin_main_group: false,
            expected_ip: None,
            expected_loc: String::new(),
            expected_node: String::new(),
            vpn_interface: None,
            timezone: String::new(),
            expected_tz_iana: String::new(),
            claude_exe: None,
            claude_aumid: String::new(),
        }
    }
}

impl Config {
    pub fn load(folder: &Path) -> Result<Self, String> {
        match std::fs::read_to_string(folder.join("preflight.json")) {
            Ok(json) => serde_json::from_str(json.trim_start_matches('\u{feff}'))
                .map_err(|_| "Rust 版配置无法解析，请检查 preflight.json".into()),
            Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(Self::default()),
            Err(_) => Err("无法读取 Rust 版配置".into()),
        }
    }

    pub fn groups(&self) -> impl Iterator<Item = &str> {
        std::iter::once(self.claude_group.as_str()).chain(
            (self.pin_main_group
                && !self.main_group.is_empty()
                && self.main_group != self.claude_group)
                .then_some(self.main_group.as_str()),
        )
    }

    pub fn has_baseline(&self) -> bool {
        self.expected_ip.is_some()
            && !self.expected_loc.is_empty()
            && (self.vpn_interface.is_some() || !self.expected_node.is_empty())
            && !self.timezone.is_empty()
    }

    pub fn save(&self, folder: &Path) -> Result<(), String> {
        write_json(folder, "preflight.json", self).map_err(|_| "无法保存 Rust 版配置".into())
    }
}

pub(crate) fn write_json<T: Serialize>(folder: &Path, name: &str, data: &T) -> io::Result<()> {
    std::fs::create_dir_all(folder)?;
    let mut temp = tempfile::NamedTempFile::new_in(folder)?;
    serde_json::to_writer_pretty(&mut temp, data)?;
    temp.write_all(b"\n")?;
    temp.as_file().sync_all()?;
    temp.persist(folder.join(name))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_round_trips_and_uses_only_its_own_directory() {
        let root = tempfile::tempdir().unwrap();
        let legacy = root.path().join("legacy");
        let rust = root.path().join("rust");
        std::fs::create_dir(&legacy).unwrap();
        std::fs::write(legacy.join("preflight.json"), b"legacy fixture").unwrap();
        assert_eq!(Config::load(&rust).unwrap().claude_group, "Claude");

        let mut config = Config {
            claude_group: "Fixture group".into(),
            ..Config::default()
        };
        config.save(&rust).unwrap();
        config.expected_ip = Some("203.0.113.10".parse().unwrap());
        config.save(&rust).unwrap();
        let saved = Config::load(&rust).unwrap();
        assert_eq!(saved.claude_group, config.claude_group);
        assert_eq!(saved.expected_ip, config.expected_ip);
        assert_eq!(
            std::fs::read(legacy.join("preflight.json")).unwrap(),
            b"legacy fixture"
        );
    }
}
