"use strict";

const byId = (id) => document.getElementById(id);
const labels = {
  pass: "通过", failed: "风险", warning: "警告", unknown: "待核实",
  pending_launch: "待启动", pending_connection: "待连接",
  no_data: "暂无数据", reference: "参考", fixed: "已修复",
};
const titles = [
  "Clash Verge 与 TUN", "系统时区", "策略组与预设节点", "出口一致性", "IP 风险",
  "系统 DNS", "IPv6 出口探测", "Anthropic API 连通性", "环境变量", "Claude Code 接口",
  "面板时区与 WebRTC", "官方支持地区", "Claude 运行与连接", "客户端日志告警",
];
const actions = Array.from(document.querySelectorAll("[data-action]"));
const state = { busy: false, settings: null, report: null, claudeRunning: false, monitorMode: "waiting", lastMonitorAt: null, historyError: false, timezonePending: false, timezoneStatus: null, revision: 0, lastGroup: null, launchReady: false };
const tauri = window.__TAURI__;
let assistedRepairPending = false;
let assistedRepairArmedAt = 0;

function node(tag, classes, text) {
  const element = document.createElement(tag);
  element.className = classes;
  element.textContent = text;
  return element;
}

const statusCounts = byId("status-counts");
const chips = Object.entries(labels).map(([level, label]) => {
  const chip = node("li", "chip", "");
  const amount = node("b", "", "0");
  chip.dataset.level = level;
  chip.hidden = true;
  chip.append(amount, " " + label);
  statusCounts.append(chip);
  return { level, chip, amount };
});

const cards = titles.map((title, index) => {
  const card = node("article", "card", "");
  card.id = "check-" + (index + 1);
  card.tabIndex = -1;
  const heading = node("h3", "", "");
  const titleText = node("span", "", title);
  const label = node("span", "cst", "等待检查");
  const detail = node("p", "txt", "");
  const meta = node("p", "meta", "");
  heading.append(node("span", "idx", String(index + 1).padStart(2, "0")), titleText, label);
  card.append(heading, detail, meta);
  byId("groups").append(card);
  return { card, titleText, label, detail, meta };
});

function renderReport(report) {
  const previousIds = new Set(state.report?.groups.map((group) => group.id));
  state.report = report;
  const checked = report?.groups ?? [];
  const byGroup = new Map(checked.map((group) => [group.id, group]));
  const total = titles.length;
  const count = checked.length;
  const score = report?.score ?? null;
  byId("score").textContent = score ?? "—";
  byId("bar").style.strokeDashoffset = String(100 - (score ?? 0));
  byId("coverage").textContent = `${count} / ${total} 组`;
  byId("progress").setAttribute("aria-valuenow", String(count));
  byId("progress-fill").style.width = `${count / total * 100}%`;
  if (state.busy) {
    state.lastGroup = checked.findLast((group) => !previousIds.has(group.id))?.title ?? state.lastGroup;
    byId("activity").textContent = count === total ? "检查已完成，正在处理结果" :
      state.lastGroup ? `已完成 · ${state.lastGroup}` : "正在准备检查";
  } else {
    byId("activity").textContent = report?.launchBlocked ? "存在启动阻断" : count ? "已检查" : "检查进度";
  }
  byId("scoreLabel").textContent = state.busy ? "当前加权得分" : "加权评分";
  let haveCounts = false;
  for (const { level, chip, amount } of chips) {
    const value = report?.counts?.[level] ?? 0;
    chip.hidden = value === 0;
    amount.textContent = value;
    haveCounts ||= value > 0;
  }
  statusCounts.hidden = !haveCounts;
  for (const [index, { card, titleText, label, detail, meta }] of cards.entries()) {
    const group = byGroup.get(index + 1);
    titleText.textContent = group?.title ?? titles[index];
    card.dataset.level = group?.level ?? "pending";
    if (!group || !state.busy) card.classList.remove("arrived");
    else if (!previousIds.has(group.id)) card.classList.add("arrived");
    label.textContent = labels[group?.level] ?? (state.busy ? "等待结果" : "未检查");
    detail.textContent = group?.detail ?? "";
    meta.textContent = group ? [
      group.weight ? `${group.earned} / ${group.weight} 分` : "",
      group.blocksLaunch ? "阻止启动" : "",
      group.elapsedMs > 0 ? `${group.elapsedMs} ms` : "",
    ].filter(Boolean).join(" · ") : "";
    meta.title = group?.observedAt ? `最近核对：${new Date(group.observedAt).toLocaleString()}` : "";
  }
  updateButtons();
}

function setStatus(text) { byId("state").textContent = text; }

function canLaunch() {
  return !!tauri && !state.busy && !state.claudeRunning && !!state.settings?.hasBaseline && state.launchReady
    && state.report?.complete === true && state.report.score === 100 && !state.report.launchBlocked;
}

function updateButtons() {
  byId("check-updates").disabled = !tauri;
  byId("feedback").disabled = !tauri;
  const launchable = canLaunch();
  for (const button of actions) {
    const action = button.dataset.action;
    button.disabled = action === "launch" ? !launchable :
      !tauri || state.busy || (action === "learn" && state.claudeRunning);
    if (action === "repair") button.textContent = state.claudeRunning ? "只读检查" : "检查并修复";
  }
  const healthy = launchable || (!state.busy && state.claudeRunning &&
    state.report?.complete === true && state.report.score === 100 && !state.report.launchBlocked);
  byId("ring").classList.toggle("blocked", !state.busy && !!state.report?.complete && !healthy);
  byId("ring").classList.toggle("ready", healthy);
  byId("settings").disabled = !tauri || state.busy;
  byId("monitor-history").disabled = !tauri;
  const launchHint = byId("launch-hint");
  launchHint.classList.toggle("locked", state.claudeRunning);
  const blockers = !state.busy && !state.claudeRunning && state.report?.complete
    ? state.report.groups.filter((group) => group.blocksLaunch || group.earned < group.weight) : [];
  const firstBlocker = blockers.find((group) => group.blocksLaunch) ?? blockers[0];
  const blocker = byId("launch-blocker");
  const repairHint = firstBlocker && [1, 2, 3, 4].includes(firstBlocker.id)
    ? "，可查看修复方案" : firstBlocker?.level === "unknown" ? "，可复查" : "，请查看处理说明";
  blocker.hidden = !firstBlocker;
  blocker.textContent = firstBlocker
    ? `${firstBlocker.title}${blockers.length > 1 ? `等 ${blockers.length} 项` : ""}${firstBlocker.level === "unknown" ? "待核实" : "需处理"}${repairHint}`
    : "";
  blocker.href = firstBlocker ? "#check-" + firstBlocker.id : "#groups";
  launchHint.textContent = launchable || firstBlocker ? "" :
    state.claudeRunning ? "Claude 运行中 · 配置已锁定" :
    state.settings?.hasBaseline ? "检查达到 100 分后可启动" : "检查并修复会核实并建立基准";
  byId("copy").disabled = state.busy || !state.report?.groups?.length;
  byId("spinner").hidden = !state.busy;
  byId("progress").classList.toggle("running", state.busy);
  byId("groups").setAttribute("aria-busy", String(state.busy));
  const watching = state.monitorMode === "watching";
  const paused = state.monitorMode === "paused";
  byId("monitor-toggle").hidden = !tauri;
  byId("monitor-toggle").disabled = state.busy;
  byId("monitor-toggle").textContent = paused ? "恢复监控" : "暂停监控";
  byId("monitor-indicator").classList.toggle("active", watching);
  let monitorText = paused ? "监控已暂停" : watching ? "后台只读监控中" : "托盘驻留 · 等待 Claude 运行";
  if (watching && state.lastMonitorAt) {
    monitorText += ` · 最近复查 ${new Date(state.lastMonitorAt).toLocaleTimeString()}`;
  }
  if (state.historyError) monitorText += " · 诊断日志写入失败";
  byId("monitor-status").textContent = tauri ? monitorText : "请在桌面应用中打开";
  const recovery = byId("timezone-recovery");
  const failure = state.timezoneStatus === "timezone_restore_error";
  recovery.textContent = failure ? "原时区恢复失败"
    : state.timezonePending ? (state.claudeRunning ? "Claude 退出后恢复原时区" : "已保留原时区备份")
    : state.timezoneStatus === "timezone_restored" ? "原时区已恢复"
    : state.timezoneStatus === "timezone_preserved" ? "已保留手动更改的时区"
    : "";
  recovery.hidden = !recovery.textContent;
  recovery.classList.toggle("has-error", failure);
  const retry = byId("retry-timezone");
  retry.hidden = !tauri || !state.timezonePending || state.claudeRunning;
  retry.disabled = state.busy;
  retry.textContent = failure ? "重试恢复" : "恢复原时区";
  updateGroupField();
}

function repairSteps(report) {
  const problemIds = new Set((report?.groups ?? [])
    .filter((group) => group.blocksLaunch || group.earned < group.weight)
    .map((group) => group.id));
  const steps = [];
  if ([1, 3, 4].some((id) => problemIds.has(id))) {
    steps.push("先连接 VPN。若客户端提供 TUN、增强模式、全局模式或“接管系统流量”，建议开启；没有 TUN 选项也可以，关键是浏览器和 Claude API 走同一个 VPN 出口。");
  }
  if (problemIds.has(12)) {
    steps.push("选择 Anthropic 官方支持地区的节点，并保持节点不变。不要在检查过程中自动切换节点。");
  }
  if (problemIds.has(8)) {
    steps.push("确认 VPN 已连接且 Claude 客户端可以正常登录。单独出现 HTTP 403 只代表探测结果待核实，检查器不会把它当成已通过。");
  }
  if ([2, 3, 4].some((id) => problemIds.has(id))) {
    steps.push("切换到 VPN 客户端完成连接并保持节点稳定；回到检查器后会自动复查并继续“检查并修复”。路由确认后，检查器才能建立或核对 VPN 接口、出口和时区基准。");
  }
  if (!steps.length) steps.push("查看下方未通过或待核实的检查说明，处理后重新检查。");
  steps.push("仍无法通过时，点“反馈问题”，导出脱敏诊断并手动附加到反馈中。");
  return steps;
}

function showRepairGuide(report = state.report) {
  const problems = (report?.groups ?? [])
    .filter((group) => group.blocksLaunch || group.earned < group.weight);
  byId("repair-guide-summary").textContent = problems.length
    ? `当前有 ${problems.length} 项需要处理，其中 ${problems.filter((group) => group.blocksLaunch).length} 项会阻止启动。`
    : "当前没有可自动修复的项目，请按下面的步骤手动核对。";
  byId("repair-guide-steps").replaceChildren(...repairSteps(report).map((step) => node("li", "", step)));
  byId("repair-guide-dialog").showModal();
}

function armAssistedRepair(report = state.report) {
  assistedRepairPending = (report?.groups ?? []).some((group) =>
    [1, 2, 3, 4].includes(group.id) && (group.blocksLaunch || group.earned < group.weight));
  assistedRepairArmedAt = assistedRepairPending ? Date.now() : 0;
  return assistedRepairPending;
}

function resumeAssistedRepair() {
  if (!assistedRepairPending || state.busy || Date.now() - assistedRepairArmedAt < 750) return;
  assistedRepairPending = false;
  if (byId("repair-guide-dialog").open) byId("repair-guide-dialog").close();
  setStatus("已返回检查器，正在自动复查并继续修复…");
  void runCheck("repair");
}

byId("launch-blocker").addEventListener("click", (event) => {
  event.preventDefault();
  const id = Number(event.currentTarget.hash.replace("#check-", ""));
  if ([1, 2, 3, 4].includes(id)) {
    showRepairGuide();
    return;
  }
  const card = byId(event.currentTarget.hash.slice(1));
  card?.scrollIntoView({ block: "nearest" });
  card?.focus({ preventScroll: true });
});

function displaySnapshot(snapshot) {
  if (snapshot.version) byId("app-version").textContent = "v" + snapshot.version;
  const revision = snapshot.revision ?? 0;
  if (revision < state.revision) return;
  state.revision = revision;
  state.claudeRunning = snapshot.claudeRunning === true;
  state.monitorMode = snapshot.monitorMode ?? "waiting";
  state.lastMonitorAt = snapshot.lastMonitorAt ?? null;
  state.historyError = snapshot.historyError === true;
  state.timezonePending = snapshot.timezonePending === true;
  state.timezoneStatus = snapshot.timezoneStatus ?? null;
  state.launchReady = snapshot.launchReady === true;
  renderReport(snapshot.report);
  setStatus(snapshot.message || "准备检查");
}

async function confirmAction(action) {
  const details = {
    learn: ["记住当前环境", "仅在当前环境证据完整时保存 Rust 版基准。已有基准会更新。"],
  };
  if (!details[action]) return true;
  return confirmDialog(...details[action]);
}

function confirmDialog(title, message) {
  const dialog = byId("confirm-dialog");
  dialog.returnValue = "";
  byId("confirm-title").textContent = title;
  byId("confirm-message").textContent = message;
  return new Promise((resolve) => {
    dialog.addEventListener("close", () => resolve(dialog.returnValue === "confirm"), { once: true });
    dialog.showModal();
  });
}

async function collectWebRtcCandidates() {
  if (typeof RTCPeerConnection !== "function") return null;
  let connection;
  let timeout;
  try {
    connection = new RTCPeerConnection({
      iceServers: [{ urls: ["stun:stun.cloudflare.com:3478", "stun:stun.l.google.com:19302"] }],
    });
    const candidates = new Set();
    return await new Promise((resolve) => {
      timeout = setTimeout(() => resolve([...candidates]), 2500);
      connection.onicecandidate = ({ candidate }) => {
        if (!candidate) {
          resolve([...candidates]);
        } else if ((candidate.type === "host" || candidate.type === "srflx") && candidate.address && candidates.size < 32) {
          candidates.add(candidate.address);
        }
      };
      connection.createDataChannel("preflight");
      connection.createOffer().then((offer) => connection.setLocalDescription(offer)).catch(() => resolve(null));
    });
  } catch {
    return null;
  } finally {
    clearTimeout(timeout);
    connection?.close();
  }
}

function currentPanelTimezone() {
  return Intl.DateTimeFormat().resolvedOptions().timeZone || "";
}

async function waitForPanelTimezone(expected) {
  if (!expected) return false;
  for (let attempt = 0; attempt < 20; attempt++) {
    if (currentPanelTimezone() === expected) return true;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  return false;
}

async function runCheck(action) {
  if (state.busy || (action === "launch" && !canLaunch()) || (action === "learn" && state.claudeRunning)) return;
  if (action === "repair" && state.claudeRunning) action = "check";
  const automatic = action === "repair";
  if (settingsDialog.open) settingsDialog.close();
  if (!(await confirmAction(action))) return;
  if (action === "repair") assistedRepairPending = false;
  state.busy = true;
  updateButtons();
  try {
    state.launchReady = false;
    state.lastGroup = null;
    renderReport(null);
    setStatus(action === "launch" ? "启动前复核…" : action === "repair" ? "正在检查并修复…" : "正在检查…");
    const progress = new tauri.core.Channel();
    progress.onmessage = (report) => { if (state.busy) renderReport(report); };
    const snapshot = await tauri.core.invoke("run_check", {
      action,
      browserZone: currentPanelTimezone(),
      browserWebrtc: await collectWebRtcCandidates(),
      progress,
    });
    state.busy = false;
    if (action === "learn" || action === "repair") state.settings = await tauri.core.invoke("load_settings");
    displaySnapshot(snapshot);
    const timezoneChanged = action === "repair"
      && snapshot.report?.groups?.some((group) => group.id === 2 && group.level === "fixed")
      && snapshot.report?.groups?.some((group) => group.id === 11
        && group.reasonCode === "panel_timezone_runtime_stale");
    if (timezoneChanged) {
      setStatus("Windows 时区已修复，正在同步面板时区并自动复查…");
      if (await waitForPanelTimezone(state.settings?.expectedTzIana)) {
        await runCheck("check");
        return;
      }
      sessionStorage.setItem("panel-timezone-recheck", "1");
      window.location.reload();
      return;
    }
    const automaticNeedsManual = action === "repair" && automatic && (state.report?.groups ?? [])
      .some((group) => group.blocksLaunch || group.earned < group.weight);
    const waitingForVpn = automaticNeedsManual ? armAssistedRepair(state.report) : false;
    if (automaticNeedsManual) {
      if (!waitingForVpn) armAssistedRepair(state.report);
      setStatus(waitingForVpn
        ? "请连接 VPN；返回检查器后会自动复查并继续修复"
        : automaticNeedsManual
          ? "已完成可控项目自动修复，仍有项目需要手动处理"
          : "暂无可自动修复项，请按修复方案手动处理");
      showRepairGuide(state.report);
    }
  } catch (error) {
    state.busy = false;
    renderReport(null);
    setStatus(String(error));
  } finally {
    state.busy = false;
    updateButtons();
  }
}

for (const button of actions) {
  button.addEventListener("click", () => runCheck(button.dataset.action));
}
byId("monitor-toggle").addEventListener("click", async () => {
  try { displaySnapshot(await tauri.core.invoke("set_monitor", { enabled: state.monitorMode === "paused" })); }
  catch (error) { setStatus(String(error)); }
});

byId("retry-timezone").addEventListener("click", async () => {
  byId("retry-timezone").disabled = true;
  try { displaySnapshot(await tauri.core.invoke("retry_timezone_restore")); }
  catch (error) { setStatus(String(error)); }
  finally { byId("retry-timezone").disabled = state.busy; }
});

const historyEvents = {
  read_only_check: "只读检查",
  check_and_repair: "检查并修复",
  check_failed: "检查未完成",
  learn_baseline: "保存环境基准",
  launch_confirmed: "Claude 已启动",
  launch_unconfirmed: "Claude 启动未确认",
  monitor_attached: "开始后台监控",
  monitor_sample: "后台复查",
  monitor_risk: "后台发现偏差",
  monitor_error: "后台复查失败",
  monitor_paused: "暂停监控",
  monitor_resumed: "恢复监控",
  configuration_locked: "配置已锁定",
  configuration_unlocked: "配置已解锁",
  settings_changed: "策略组已修改",
  claude_exited: "Claude 已退出",
  claude_closed_for_risk: "确认关闭 Claude",
  timezone_restored: "已恢复 Windows 时区",
  timezone_preserved: "已保留手动调整的时区",
  timezone_restore_error: "时区恢复失败",
};
const historyDialog = byId("history-dialog");
const historyList = byId("history-list");
const historyStatus = byId("history-status");
const historyDate = new Intl.DateTimeFormat("zh-CN", { dateStyle: "short", timeStyle: "medium" });
let historyRequest = 0;
let historyLoading = false;
let historyContent = "";
let historyTimer;

function renderHistoryEntry(entry) {
  const row = node("li", "history-entry", "");
  row.dataset.record = JSON.stringify(entry);
  const heading = node("div", "history-row", "");
  const title = Object.hasOwn(historyEvents, entry.event) ? historyEvents[entry.event] : "状态变更";
  const time = node("time", "history-time", historyDate.format(new Date(entry.at)));
  time.dateTime = entry.at;
  heading.append(node("span", "history-event", title));
  if (entry.status.score !== null) heading.append(node("span", "history-score", entry.status.score + " 分"));
  heading.append(time);
  row.append(heading);
  const changed = entry.status.checks
    .filter((check) => titles[check.id - 1] && ["failed", "warning", "unknown", "fixed"].includes(check.level))
    .map((check) => {
      const name = check.id === 1 ? "网络就绪" : check.id === 3 ? "网络基准" : titles[check.id - 1];
      return name + " · " + labels[check.level];
    });
  if (changed.length) row.append(node("p", "history-detail", changed.join("、")));
  return row;
}

async function refreshHistory() {
  if (!historyDialog.open || historyLoading) return;
  historyLoading = true;
  const request = ++historyRequest;
  try {
    const entries = await tauri.core.invoke("read_monitor_history");
    if (!historyDialog.open || request !== historyRequest) return;
    const content = JSON.stringify(entries);
    if (content !== historyContent) {
      const top = historyList.getBoundingClientRect().top;
      const anchor = historyList.scrollTop > 0
        ? [...historyList.children].find((row) => row.getBoundingClientRect().bottom > top)
        : null;
      const anchorTop = anchor?.getBoundingClientRect().top;
      historyList.replaceChildren(...entries.map(renderHistoryEntry));
      const updatedAnchor = anchor && [...historyList.children].find((row) => row.dataset.record === anchor.dataset.record);
      if (updatedAnchor) historyList.scrollTop += updatedAnchor.getBoundingClientRect().top - anchorTop;
      historyContent = content;
    }
    historyStatus.hidden = entries.length > 0;
    if (!entries.length) historyStatus.textContent = "暂无监控日志";
  } catch (error) {
    if (historyDialog.open && request === historyRequest) {
      historyStatus.hidden = false;
      historyStatus.textContent = String(error);
    }
  } finally {
    if (request === historyRequest) historyLoading = false;
  }
}

byId("monitor-history").addEventListener("click", () => {
  byId("diagnostics-path").hidden = true;
  historyList.replaceChildren();
  historyContent = "";
  historyStatus.hidden = false;
  historyStatus.textContent = "正在读取监控日志…";
  historyDialog.showModal();
  void refreshHistory();
  historyTimer = setInterval(() => { void refreshHistory(); }, 3000);
});
historyDialog.addEventListener("close", () => {
  clearInterval(historyTimer);
  historyRequest += 1;
  historyLoading = false;
});
byId("close-history").addEventListener("click", () => historyDialog.close());
async function exportDiagnostics(button, result) {
  button.disabled = true;
  try {
    result.textContent = "已导出到 " + await tauri.core.invoke("export_diagnostics");
  } catch (error) {
    result.textContent = String(error);
  } finally {
    result.hidden = false;
    button.disabled = false;
  }
}

byId("export-diagnostics").addEventListener("click", (event) => {
  void exportDiagnostics(event.currentTarget, byId("diagnostics-path"));
});

const feedbackDialog = byId("feedback-dialog");
function showFeedback() {
  byId("feedback-result").hidden = true;
  feedbackDialog.showModal();
}
byId("feedback").addEventListener("click", showFeedback);
byId("repair-guide-feedback").addEventListener("click", () => {
  assistedRepairPending = false;
  byId("repair-guide-dialog").close();
  showFeedback();
});
byId("close-repair-guide").addEventListener("click", () => byId("repair-guide-dialog").close());
byId("close-feedback").addEventListener("click", () => feedbackDialog.close());
byId("feedback-export").addEventListener("click", (event) => {
  void exportDiagnostics(event.currentTarget, byId("feedback-result"));
});
byId("open-feedback").addEventListener("click", async (event) => {
  const button = event.currentTarget;
  const result = byId("feedback-result");
  button.disabled = true;
  try {
    await tauri.core.invoke("open_feedback_page");
    result.textContent = "已打开 GitHub 反馈页面。请按需手动附加诊断文件。";
  } catch (error) {
    result.textContent = String(error);
  } finally {
    result.hidden = false;
    button.disabled = false;
  }
});

byId("copy").addEventListener("click", async () => {
  const report = state.report;
  const summary = [
    `Claude 环境检查器 · ${report.groups.length}/${titles.length} 组 · 评分 ${report.score ?? "—"}`,
    ...report.groups.map((group) => `${group.id}. ${group.title} · ${labels[group.level]}${group.weight ? ` · ${group.earned}/${group.weight} 分` : ""}`),
  ];
  try {
    await tauri.core.invoke("copy_status", { summary: summary.join("\n") });
    settingsDialog.close();
    setStatus("已复制检查状态");
  } catch (error) { byId("settings-error").textContent = String(error); }
});

const settingsDialog = byId("settings-dialog");
const form = byId("settings-form");
const primaryGroup = form.elements.namedItem("claudeGroup");
const mainGroup = form.elements.namedItem("mainGroup");
const pinGroup = form.elements.namedItem("pinMainGroup");
function updateGroupField() {
  const locked = state.claudeRunning;
  primaryGroup.disabled = locked;
  pinGroup.disabled = locked;
  mainGroup.disabled = locked || !pinGroup.checked;
  mainGroup.required = !locked && pinGroup.checked;
  form.querySelector("[type=submit]").disabled = locked;
  byId("settings-lock").hidden = !locked;
}
pinGroup.addEventListener("change", updateGroupField);
byId("settings").addEventListener("click", async () => {
  try {
    state.settings = await tauri.core.invoke("load_settings");
    state.claudeRunning = state.settings.claudeRunning === true;
    updateButtons();
    primaryGroup.value = state.settings.claudeGroup;
    mainGroup.value = state.settings.mainGroup;
    pinGroup.checked = state.settings.pinMainGroup;
    updateGroupField();
    byId("data-directory").textContent = state.settings.directory;
    byId("log-path").textContent = state.settings.logPath ? `本地诊断日志 · ${state.settings.logPath}` : "";
    byId("settings-error").textContent = "";
    settingsDialog.showModal();
  } catch (error) { setStatus(String(error)); }
});
byId("cancel-settings").addEventListener("click", () => settingsDialog.close());
const runtimeRiskDialog = byId("runtime-risk-dialog");
const runtimeRiskTitles = new Set();

function showRuntimeRisk(payload) {
  for (const title of payload?.risks ?? []) {
    if (typeof title === "string" && title) runtimeRiskTitles.add(title);
  }
  if (!runtimeRiskTitles.size) return;
  byId("runtime-risk-message").textContent =
    `${[...runtimeRiskTitles].join("、")}发生偏差。是否现在关闭 Claude，避免继续使用已变化的运行环境？`;
  byId("runtime-risk-error").textContent = "";
  if (!runtimeRiskDialog.open) runtimeRiskDialog.showModal();
}

byId("keep-claude-running").addEventListener("click", () => runtimeRiskDialog.close());
byId("close-risk-claude").addEventListener("click", async () => {
  const close = byId("close-risk-claude");
  close.disabled = true;
  byId("keep-claude-running").disabled = true;
  byId("runtime-risk-error").textContent = "正在请求 Claude 正常退出…";
  try {
    displaySnapshot(await tauri.core.invoke("close_claude_for_risk"));
    runtimeRiskDialog.close();
    await runCheck("repair");
  } catch (error) {
    byId("runtime-risk-error").textContent = String(error);
  } finally {
    close.disabled = false;
    byId("keep-claude-running").disabled = false;
  }
});
runtimeRiskDialog.addEventListener("close", () => {
  runtimeRiskTitles.clear();
  byId("runtime-risk-error").textContent = "";
});
const updateDialog = byId("update-dialog");
const updateVersion = byId("update-version");
const updateResult = byId("update-result");
const updateAction = byId("update-action");
const availableUpdate = byId("available-update");
const updateInterval = 6 * 60 * 60 * 1000;
let updateInfo = null;
let checkingUpdate = null;
let lastUpdateCheck = 0;
let applyingUpdate = false;
let updateNext = null;

function refreshUpdate() {
  if (!checkingUpdate) {
    lastUpdateCheck = Date.now();
    checkingUpdate = tauri.core.invoke("check_for_update").then((info) => {
      updateInfo = info;
      byId("app-version").textContent = "v" + info.currentVersion;
      availableUpdate.hidden = !info.availableVersion;
      availableUpdate.title = info.availableVersion ? "更新至 v" + info.availableVersion : "";
      return info;
    }).finally(() => { checkingUpdate = null; });
  }
  return checkingUpdate;
}

function checkUpdateInBackground() {
  if (Date.now() - lastUpdateCheck >= updateInterval) void refreshUpdate().catch(() => {});
}

function showUpdate(info, message, next = info?.availableVersion ? "apply" : null) {
  updateVersion.hidden = !info;
  if (info) updateVersion.textContent = "当前版本 v" + info.currentVersion;
  updateResult.textContent = message ?? (info?.availableVersion
    ? `发现新版本 v${info.availableVersion}。可${info.direct ? "直接更新" : "通过安装向导升级"}。`
    : "已是最新版本。");
  updateNext = next;
  updateAction.hidden = !next;
  updateAction.textContent = {
    apply: info?.direct ? "直接更新" : "下载安装包",
    retry: "重试更新",
    recheck: "重新检查",
    releasePage: "打开正式发布页",
  }[next] ?? "";
}

async function checkUpdates() {
  showUpdate(null, "正在检查更新…");
  if (!updateDialog.open) updateDialog.showModal();
  try {
    const info = await refreshUpdate();
    if (updateDialog.open) showUpdate(info);
  } catch (error) {
    if (updateDialog.open) showUpdate(null, String(error), "recheck");
  }
}

byId("check-updates").addEventListener("click", () => { void checkUpdates(); });
byId("close-update").addEventListener("click", () => updateDialog.close());
updateDialog.addEventListener("cancel", (event) => { if (applyingUpdate) event.preventDefault(); });

async function applyUpdate() {
  const info = updateInfo;
  if (!info?.availableVersion || applyingUpdate) return;
  applyingUpdate = true;
  updateAction.disabled = true;
  availableUpdate.disabled = true;
  try {
    const message = info.direct
      ? "请先关闭 Claude。确认后会校验补丁签名，更新后重新打开环境检查器。"
      : "请先关闭 Claude。确认后将下载并校验安装包，并退出环境检查器以打开安装器。";
    if (!(await confirmDialog("更新至 v" + info.availableVersion, message))) return;
    showUpdate(info, "正在下载并校验更新…");
    if (!updateDialog.open) updateDialog.showModal();
    byId("close-update").disabled = true;
    await tauri.core.invoke("install_update", { version: info.availableVersion, direct: info.direct === true });
  } catch (error) {
    showUpdate(info, error?.message ?? String(error), error?.next ?? "retry");
    if (!updateDialog.open) updateDialog.showModal();
  } finally {
    applyingUpdate = false;
    byId("close-update").disabled = false;
    availableUpdate.disabled = false;
    updateAction.disabled = false;
  }
}

availableUpdate.addEventListener("click", () => { void applyUpdate(); });
updateAction.addEventListener("click", async () => {
  switch (updateNext) {
    case "apply":
    case "retry":
      await applyUpdate();
      break;
    case "recheck":
      await checkUpdates();
      break;
    case "releasePage":
      try { await tauri.core.invoke("open_release_page", { version: null }); }
      catch (error) { updateResult.textContent = String(error); }
      break;
  }
});
form.addEventListener("submit", async (event) => {
  event.preventDefault();
  if (state.claudeRunning) return;
  const submit = form.querySelector("[type=submit]");
  submit.disabled = true;
  try {
    state.settings = await tauri.core.invoke("save_groups", {
      claudeGroup: primaryGroup.value, mainGroup: mainGroup.value, pinMainGroup: pinGroup.checked,
    });
    settingsDialog.close();
    displaySnapshot(await tauri.core.invoke("get_snapshot"));
  } catch (error) {
    byId("settings-error").textContent = String(error);
  } finally {
    updateGroupField();
  }
});

async function init() {
  updateButtons();
  if (!tauri) {
    setStatus("请在 Rust 桌面应用中打开");
    return;
  }
  checkUpdateInBackground();
  window.setInterval(checkUpdateInBackground, updateInterval);
  window.addEventListener("focus", resumeAssistedRepair);
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) {
      checkUpdateInBackground();
      resumeAssistedRepair();
    }
  });
  try {
    await tauri.event.listen("monitor-snapshot", ({ payload }) => {
      if (!state.busy) displaySnapshot(payload);
      void refreshHistory();
    });
    await tauri.event.listen("runtime-risk", ({ payload }) => showRuntimeRisk(payload));
    state.settings = await tauri.core.invoke("load_settings");
    const snapshot = await tauri.core.invoke("get_snapshot");
    displaySnapshot(snapshot);
    const timezoneRecheck = sessionStorage.getItem("panel-timezone-recheck") === "1";
    sessionStorage.removeItem("panel-timezone-recheck");
    if (timezoneRecheck) {
      void runCheck("check");
    } else if (!snapshot.report?.complete) {
      void runCheck("repair");
    }
  } catch (error) { setStatus(String(error)); }
}
void init();
