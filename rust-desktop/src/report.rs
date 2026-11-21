use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

// Check IDs 1–14. Unscored results waive their weight. Missing results still
// count toward the denominator until that check is classified.
const WEIGHTS: [u8; 14] = [12, 8, 12, 16, 4, 6, 4, 12, 4, 4, 2, 14, 8, 2];

#[derive(Debug, Copy, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Level {
    Pass,
    Fixed,
    Warning,
    Failed,
    Unknown,
    Reference,
    PendingLaunch,
    PendingConnection,
    NoData,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Group {
    pub id: u8,
    pub title: &'static str,
    pub level: Level,
    pub detail: String,
    pub weight: u8,
    pub earned: u8,
    pub blocks_launch: bool,
    pub elapsed_ms: u64,
    pub observed_at: DateTime<Utc>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason_code: Option<&'static str>,
}

impl Group {
    pub fn new(id: u8, title: &'static str, level: Level, detail: impl Into<String>) -> Self {
        let weight = match level {
            Level::Pass | Level::Fixed | Level::Warning | Level::Failed | Level::Unknown => {
                WEIGHTS[usize::from(id) - 1]
            }
            Level::Reference | Level::PendingLaunch | Level::PendingConnection | Level::NoData => 0,
        };
        Self {
            id,
            title,
            level,
            detail: detail.into(),
            weight,
            earned: if matches!(level, Level::Pass | Level::Fixed) {
                weight
            } else {
                0
            },
            blocks_launch: level == Level::Failed,
            elapsed_ms: 0,
            observed_at: Utc::now(),
            reason_code: None,
        }
    }

    pub fn reason(mut self, code: &'static str) -> Self {
        self.reason_code = Some(code);
        self
    }

    pub fn gate(mut self) -> Self {
        self.blocks_launch = true;
        self
    }

    pub fn mark_fixed(&mut self) {
        self.level = Level::Fixed;
        self.earned = self.weight;
    }
}

#[derive(Debug, Default, Serialize)]
pub struct Counts {
    pass: usize,
    fixed: usize,
    warning: usize,
    failed: usize,
    unknown: usize,
    pending_launch: usize,
    pending_connection: usize,
    no_data: usize,
    reference: usize,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Report<'a> {
    pub groups: &'a [Group],
    pub score: Option<u16>,
    pub counts: Counts,
    pub complete: bool,
    pub launch_blocked: bool,
}

impl<'a> Report<'a> {
    pub fn new(groups: &'a [Group]) -> Self {
        Self::assess(groups, true)
    }

    pub fn progress(groups: &'a [Group]) -> Self {
        Self::assess(groups, false)
    }

    fn assess(groups: &'a [Group], finished: bool) -> Self {
        let mut checks = [None; WEIGHTS.len()];
        for group in groups {
            checks[usize::from(group.id) - 1] = Some(group);
        }
        let mut counts = Counts::default();
        for group in checks.iter().flatten() {
            match group.level {
                Level::Pass => counts.pass += 1,
                Level::Fixed => counts.fixed += 1,
                Level::Warning => counts.warning += 1,
                Level::Failed => counts.failed += 1,
                Level::Unknown => counts.unknown += 1,
                Level::PendingLaunch => counts.pending_launch += 1,
                Level::PendingConnection => counts.pending_connection += 1,
                Level::NoData => counts.no_data += 1,
                Level::Reference => counts.reference += 1,
            }
        }
        let complete = finished && checks.iter().all(Option::is_some);
        let launch_blocked = groups.iter().any(|group| group.blocks_launch);
        let available: u16 = WEIGHTS
            .iter()
            .zip(&checks)
            .map(|(&weight, group)| u16::from(group.map_or(weight, |group| group.weight)))
            .sum();
        let earned: u16 = checks
            .iter()
            .flatten()
            .map(|group| u16::from(group.earned))
            .sum();
        let score = if groups.is_empty() {
            None
        } else {
            let score = (100 * earned).checked_div(available).unwrap_or(0);
            // A percentage must not round up to full marks, or show full marks
            // before the completed result can be used to launch.
            Some(score.min(if complete && !launch_blocked { 100 } else { 99 }))
        };
        Self {
            groups,
            score,
            counts,
            complete,
            launch_blocked,
        }
    }

    pub fn can_launch(&self) -> bool {
        self.complete && self.score == Some(100) && !self.launch_blocked
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn score_grows_by_completed_weight_and_waits_for_final_report() {
        let groups: Vec<_> = (1..=14)
            .map(|id| Group::new(id, "检查", Level::Pass, ""))
            .collect();
        assert_eq!(WEIGHTS.iter().map(|&w| u16::from(w)).sum::<u16>(), 108);
        assert_eq!(Report::new(&[]).score, None);
        assert_eq!(Report::progress(&groups[..1]).score, Some(11));
        assert_eq!(Report::progress(&groups[..4]).score, Some(44));
        assert_eq!(Report::progress(&groups).score, Some(99));
        assert!(!Report::progress(&groups).can_launch());
        assert_eq!(Report::new(&groups).score, Some(100));
        assert!(Report::new(&groups).can_launch());
    }

    #[test]
    fn pending_launch_is_unscored_but_weighted_unknowns_and_warnings_lose_points() {
        let mut groups: Vec<_> = (1..=14)
            .map(|id| Group::new(id, "检查", Level::Pass, ""))
            .collect();
        groups[12] = Group::new(13, "连接", Level::PendingLaunch, "启动后复查");
        assert_eq!(groups[12].weight, 0);
        let mut report = Report::new(&groups);
        assert_eq!(report.score, Some(100));
        assert!(report.can_launch());
        groups[1] = Group::new(2, "时区", Level::Unknown, "无基准").gate();
        report = Report::new(&groups);
        assert_eq!(report.score, Some(92));
        assert!(!report.can_launch());
        groups[1] = Group::new(2, "时区", Level::Pass, "与预设一致");
        groups[13] = Group::new(14, "日志", Level::Warning, "告警");
        report = Report::new(&groups);
        assert_eq!(report.score, Some(98));
        assert!(!report.launch_blocked);
        assert!(!report.can_launch());
    }

    #[test]
    fn prelaunch_statuses_allow_full_score_and_each_group_is_counted_once() {
        let groups: Vec<_> = (1..=14)
            .map(|id| {
                let level = match id {
                    3 => Level::Fixed,
                    13 => Level::PendingLaunch,
                    14 => Level::NoData,
                    _ => Level::Pass,
                };
                Group::new(id, "检查", level, "")
            })
            .collect();
        let report = Report::new(&groups);
        assert!(report.can_launch());
        assert_eq!(groups[9].earned, 4);
        assert_eq!(groups[13].weight, 0);
        assert_eq!(report.counts.pass, 11);
        assert_eq!(report.counts.fixed, 1);
        assert_eq!(report.counts.pending_launch, 1);
        assert_eq!(report.counts.no_data, 1);
    }

    #[test]
    fn advisory_states_have_separate_summary_counts() {
        let groups = [
            Group::new(6, "DNS", Level::Reference, ""),
            Group::new(13, "实际连接", Level::PendingConnection, ""),
            Group::new(14, "日志", Level::NoData, ""),
        ];
        let counts = Report::progress(&groups).counts;
        assert_eq!(counts.reference, 1);
        assert_eq!(counts.pending_connection, 1);
        assert_eq!(counts.no_data, 1);
        assert_eq!(counts.pending_launch, 0);
    }

    #[test]
    fn unverified_ip_risk_or_ipv6_prevents_full_score() {
        for unverified in [[5].as_slice(), [7].as_slice(), [5, 7].as_slice()] {
            let groups: Vec<_> = (1..=14)
                .map(|id| {
                    let level = match id {
                        13 => Level::PendingLaunch,
                        14 => Level::NoData,
                        _ if unverified.contains(&id) => Level::Unknown,
                        _ => Level::Pass,
                    };
                    Group::new(id, "检查", level, "")
                })
                .collect();
            let report = Report::new(&groups);
            let expected = if unverified.len() == 2 { 91 } else { 95 };
            assert_eq!(report.score, Some(expected));
            assert!(!report.can_launch());
        }
    }

    #[test]
    fn missing_baseline_with_no_failures_does_not_score_full_marks() {
        let groups: Vec<_> = (1..=14)
            .map(|id| match id {
                2..=4 => Group::new(id, "基准", Level::Unknown, "无预设").gate(),
                5 | 7 => Group::new(id, "IP 检查", Level::Unknown, ""),
                13 => Group::new(id, "客户端", Level::PendingLaunch, ""),
                11 => Group::new(id, "面板时区", Level::NoData, ""),
                _ => Group::new(id, "检查", Level::Pass, ""),
            })
            .collect();
        let report = Report::new(&groups);
        assert!(report.complete);
        assert_eq!(report.counts.failed, 0);
        assert_eq!(report.score, Some(55));
        assert!(!report.can_launch());
    }
}
