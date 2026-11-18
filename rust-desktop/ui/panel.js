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
  launchHint.textContent = launchable ? "" :
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

function displaySnapshot(snapshot) {
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

async function runCheck(action) {
  if (state.busy || (action === "launch" && !canLaunch()) || (action === "learn" && state.claudeRunning)) return;
  if (action === "repair" && state.claudeRunning) action = "check";
  if (settingsDialog.open) settingsDialog.close();
  if (!(await confirmAction(action))) return;
  state.busy = true;
  state.launchReady = false;
  state.lastGroup = null;
  renderReport(null);
  setStatus(action === "launch" ? "启动前复核…" : action === "repair" ? "正在检查并修复…" : "正在检查…");
  const progress = new tauri.core.Channel();
  progress.onmessage = (report) => { if (state.busy) renderReport(report); };
  try {
    const snapshot = await tauri.core.invoke("run_check", {
      action,
      browserZone: Intl.DateTimeFormat().resolvedOptions().timeZone || "",
      browserWebrtc: await collectWebRtcCandidates(),
      progress,
    });
    state.busy = false;
    if (action === "learn" || action === "repair") state.settings = await tauri.core.invoke("load_settings");
    displaySnapshot(snapshot);
  } catch (error) {
    state.busy = false;
    renderReport(null);
    setStatus(String(error));
  } finally {
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
byId("export-diagnostics").addEventListener("click", async (event) => {
  const button = event.currentTarget;
  const result = byId("diagnostics-path");
  button.disabled = true;
  try {
    result.textContent = "已导出到 " + await tauri.core.invoke("export_diagnostics");
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
const updateDialog = byId("update-dialog");
const updateVersion = byId("update-version");
const updateResult = byId("update-result");
const updateAction = byId("update-action");
let updateRequest = 0;
let updateInfo = null;

byId("check-updates").addEventListener("click", async () => {
  const request = ++updateRequest;
  updateInfo = null;
  updateVersion.hidden = true;
  updateAction.hidden = true;
  updateAction.disabled = false;
  updateResult.textContent = "正在检查更新…";
  updateDialog.showModal();
  try {
    const info = await tauri.core.invoke("check_for_update");
    if (request !== updateRequest || !updateDialog.open) return;
    updateInfo = info;
    updateVersion.textContent = "当前版本 v" + info.currentVersion;
    updateVersion.hidden = false;
    updateResult.textContent = info.availableVersion ? "发现新版本 v" + info.availableVersion : "已是最新版本。";
    updateAction.hidden = !info.availableVersion;
    updateAction.textContent = info.signed ? "安装更新" : "前往 GitHub 下载";
  } catch (error) {
    if (request !== updateRequest || !updateDialog.open) return;
    updateResult.textContent = String(error);
    updateAction.textContent = "打开发布页";
    updateAction.hidden = false;
  }
});
byId("close-update").addEventListener("click", () => updateDialog.close());
updateDialog.addEventListener("close", () => { updateRequest += 1; });
updateAction.addEventListener("click", async () => {
  const request = updateRequest;
  const info = updateInfo;
  updateAction.disabled = true;
  try {
    if (info?.signed && info.availableVersion) {
      if (!(await confirmDialog("安装 v" + info.availableVersion, "请先关闭 Claude。环境检查器将在安装时退出。"))) return;
      updateResult.textContent = "正在验证并安装更新…";
      await tauri.core.invoke("install_update", { version: info.availableVersion });
    } else {
      await tauri.core.invoke("open_release_page", { version: info?.availableVersion ?? null });
    }
  } catch (error) {
    if (request === updateRequest) updateResult.textContent = String(error);
  } finally {
    if (request === updateRequest) updateAction.disabled = false;
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
  try {
    await tauri.event.listen("monitor-snapshot", ({ payload }) => {
      if (!state.busy) displaySnapshot(payload);
      void refreshHistory();
    });
    state.settings = await tauri.core.invoke("load_settings");
    const snapshot = await tauri.core.invoke("get_snapshot");
    displaySnapshot(snapshot);
    if (!snapshot.report?.complete) void runCheck("repair");
  } catch (error) { setStatus(String(error)); }
}
void init();
