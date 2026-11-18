use crate::config::{write_json, Config};
use crate::machine::{self, Timezone};
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::ErrorKind;
use std::path::Path;

const JOURNAL: &str = "timezone-restore.json";

#[derive(Deserialize, Serialize)]
struct Change {
    original: Timezone,
    applied: Option<Timezone>,
    planned: Option<String>,
    saw_claude: bool,
}

impl Change {
    fn owns(&self, current: &Timezone) -> bool {
        self.applied.as_ref() == Some(current)
            || self.planned.as_deref() == Some(current.id.as_str())
    }

    fn next(previous: Option<Self>, current: Timezone, target: &str) -> Self {
        let mut change = previous
            .filter(|previous| previous.owns(&current))
            .unwrap_or(Self {
                original: current,
                applied: None,
                planned: None,
                saw_claude: false,
            });
        change.planned = Some(target.to_owned());
        change
    }
}

fn load(folder: &Path) -> Result<Option<Change>, String> {
    match fs::read(folder.join(JOURNAL)) {
        Ok(json) => serde_json::from_slice(&json)
            .map(Some)
            .map_err(|_| "时区恢复记录无法解析".into()),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(None),
        Err(_) => Err("时区恢复记录无法读取".into()),
    }
}

fn save(folder: &Path, change: &Change) -> Result<(), String> {
    write_json(folder, JOURNAL, change).map_err(|_| "无法保存时区恢复记录".into())
}

pub fn pending(folder: &Path) -> bool {
    folder.join(JOURNAL).is_file()
}

pub(crate) fn apply(folder: &Path, config: &Config, target: &str) -> Result<bool, String> {
    machine::require_claude_stopped(config)?;
    apply_with(folder, target, machine::current_timezone, |zone| {
        machine::set_timezone(config, zone)
    })
}

fn apply_with(
    folder: &Path,
    target: &str,
    read: impl Fn() -> Option<Timezone>,
    set: impl Fn(&str) -> bool,
) -> Result<bool, String> {
    let current = read().ok_or("无法读取原时区及夏令时设置")?;
    if current.id == target {
        return Ok(false);
    }
    let mut change = Change::next(load(folder)?, current, target);
    save(folder, &change)?;
    if !set(target) {
        return Err("时区更改未执行或未成功".into());
    }
    let applied = read()
        .filter(|zone| zone.id == target)
        .ok_or("无法确认时区更改结果")?;
    change.applied = Some(applied);
    change.planned = None;
    save(folder, &change)?;
    Ok(true)
}

#[derive(Debug, PartialEq, Eq)]
pub enum Recovery {
    None,
    Restored,
    Preserved,
}

pub fn reconcile(folder: &Path, inactive_cleanup: bool) -> Result<Recovery, String> {
    if !pending(folder) {
        return Ok(Recovery::None);
    }
    let config = Config::load(folder)?;
    let running = machine::is_claude_running(&config);
    reconcile_with(
        folder,
        running,
        inactive_cleanup,
        machine::current_timezone,
        |zone| machine::set_timezone(&config, zone),
    )
}

pub(crate) fn note_client_running(folder: &Path) -> Result<(), String> {
    reconcile_with(folder, true, false, machine::current_timezone, |_| false).map(|_| ())
}

fn reconcile_with(
    folder: &Path,
    running: bool,
    inactive_cleanup: bool,
    read: impl Fn() -> Option<Timezone>,
    set: impl Fn(&str) -> bool,
) -> Result<Recovery, String> {
    let Some(mut change) = load(folder)? else {
        return Ok(Recovery::None);
    };
    if running {
        if !change.saw_claude {
            change.saw_claude = true;
            save(folder, &change)?;
        }
        return Ok(Recovery::None);
    }
    if !change.saw_claude && !inactive_cleanup {
        return Ok(Recovery::None);
    }
    let current = read().ok_or("无法读取当前时区以执行恢复")?;
    let outcome = if current == change.original {
        Recovery::Restored
    } else if change.owns(&current) {
        let argument = if change.original.daylight_disabled {
            format!("{}_dstoff", change.original.id)
        } else {
            change.original.id.clone()
        };
        if !set(&argument) || read().as_ref() != Some(&change.original) {
            return Err("恢复原时区失败，已保留恢复记录".into());
        }
        Recovery::Restored
    } else {
        Recovery::Preserved
    };
    fs::remove_file(folder.join(JOURNAL)).map_err(|_| "无法清理时区恢复记录")?;
    Ok(outcome)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::{Cell, RefCell};

    fn zone(id: &str, daylight_disabled: bool) -> Timezone {
        Timezone {
            id: id.to_owned(),
            daylight_disabled,
        }
    }

    #[test]
    fn backs_up_before_change_and_restores_original_dst_after_exit() {
        let folder = tempfile::tempdir().unwrap();
        let path = folder.path();
        let original = zone("Pacific Standard Time", true);
        let current = RefCell::new(original.clone());
        let read = || Some(current.borrow().clone());
        let apply_temporary = |target: &str| {
            let change = load(path).unwrap().unwrap();
            assert_eq!(change.original, original);
            assert_eq!(change.planned.as_deref(), Some(target));
            current.replace(zone(target, false));
            true
        };
        assert!(apply_with(path, "Eastern Standard Time", read, apply_temporary).unwrap());
        let restore_original = |target: &str| {
            assert_eq!(target, "Pacific Standard Time_dstoff");
            current.replace(original.clone());
            true
        };
        assert_eq!(
            reconcile_with(path, false, false, read, restore_original).unwrap(),
            Recovery::None
        );
        assert_eq!(
            reconcile_with(path, true, false, read, restore_original).unwrap(),
            Recovery::None
        );
        assert_eq!(
            reconcile_with(path, false, false, read, restore_original).unwrap(),
            Recovery::Restored
        );
        assert_eq!(*current.borrow(), original);
        assert!(!pending(path));
    }

    #[test]
    fn preserves_a_later_manual_timezone_change() {
        let folder = tempfile::tempdir().unwrap();
        let path = folder.path();
        let original = zone("Pacific Standard Time", false);
        let current = RefCell::new(original);
        let read = || Some(current.borrow().clone());
        apply_with(path, "Eastern Standard Time", read, |target| {
            current.replace(zone(target, false));
            true
        })
        .unwrap();
        reconcile_with(path, true, false, read, |_| {
            panic!("restored while Claude was active")
        })
        .unwrap();
        current.replace(zone("Central Standard Time", false));
        let result = reconcile_with(path, false, false, read, |_| {
            panic!("overwrote manual change")
        });
        assert_eq!(result.unwrap(), Recovery::Preserved);
        assert!(!pending(path));
    }

    #[test]
    fn recovers_a_planned_change_after_interruption_and_retains_failed_retries() {
        let folder = tempfile::tempdir().unwrap();
        let path = folder.path();
        let original = zone("Pacific Standard Time", false);
        let current = RefCell::new(original.clone());
        let read = || Some(current.borrow().clone());
        assert!(apply_with(path, "Eastern Standard Time", read, |target| {
            current.replace(zone(target, false));
            false
        })
        .is_err());
        assert!(reconcile_with(path, false, true, read, |_| false).is_err());
        assert!(pending(path));
        assert_eq!(
            reconcile_with(path, false, true, read, |target| {
                assert_eq!(target, original.id);
                current.replace(original.clone());
                true
            })
            .unwrap(),
            Recovery::Restored
        );
        assert!(!pending(path));
    }

    #[test]
    fn leaves_windows_alone_if_journal_cannot_be_written() {
        let folder = tempfile::tempdir().unwrap();
        let path = folder.path().join("not-a-directory");
        fs::write(&path, "").unwrap();
        let setter_called = Cell::new(false);
        let result = apply_with(
            &path,
            "Eastern Standard Time",
            || Some(zone("Pacific Standard Time", false)),
            |_| {
                setter_called.set(true);
                true
            },
        );
        assert!(result.is_err());
        assert!(!setter_called.get());
    }
}
