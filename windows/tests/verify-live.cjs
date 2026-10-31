// Static HTTP fixtures only: no Windows changes, account requests or Claude attachment.
const fs = require('fs');
const path = require('path');
const http = require('http');
const { chromium } = require(process.env.CSL_PLAYWRIGHT_MODULE || 'playwright');
const assert = require('node:assert/strict');
const output = process.env.CSL_QA_OUTPUT || path.join(require('os').tmpdir(), 'claude-live-qa-' + Date.now());
fs.mkdirSync(output, { recursive: true });
const html = fs.readFileSync(path.join(__dirname, '..', 'claude-panel.html'), 'utf8')
  .replaceAll('__THEME__', 'anime').replaceAll('__CSL_TOKEN__', 'synthetic-session')
  .replaceAll('__CSL_TESTMODE__', '0').replaceAll('__CSL_USERPROFILE__', 'FixtureUser')
  .replaceAll('__CSL_COMPUTERNAME__', 'FixtureComputer');
const stages = Array.from({ length: 13 }, (_, i) => `${i + 1}. 合成检查 ${i + 1}`)
  .concat(['14. Claude 实际进程连接', '15. 客户端告警扫描']);
const report = { complete: true, schemaVersion: 2, checkCount: 15, stages, score: 100,
  result: 'WARN', repairMode: true, riskSummary: { launchBlocked: false },
  events: stages.map((Group, i) => ({ Group, Level: i < 13 ? 'PASS' : 'UNKNOWN',
    Text: i < 13 ? '合成检查通过' : i === 13 ? 'Claude 未运行：旧快照' : '账号待核实：旧快照' })) };
let live = null, incomplete = false, passed = 0;
const requests = [], errors = [];
function check(ok, name) { assert.ok(ok, name); passed++; console.log('PASS: ' + name); }
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://fixture');
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Content-Type', url.pathname === '/' ? 'text/html;charset=utf-8' : 'application/json;charset=utf-8');
  if (url.pathname === '/') return res.end(html);
  requests.push(url.pathname);
  if (url.pathname === '/api/run') check(url.searchParams.get('apply') !== null, 'run explicitly declares repair mode');
  if (url.pathname === '/api/poll') return res.end(JSON.stringify({ lines: [], next: 0, done: true,
    complete: !incomplete, report, error: incomplete ? '合成检查中断' : null }));
  if (url.pathname === '/api/risk-status') return res.end(JSON.stringify({ ok: true, active: !!live, summary: live }));
  res.end(JSON.stringify({ ok: true }));
});
const good = { status: 'observed', code: 'route_observed', observed: 2, processCount: 9,
  message: 'Claude 已运行；已核对 2 条官方服务连接，均经过预设节点（只读观测）' };
const clean = { status: 'observed', code: 'no_recent_alerts', message: '已扫描近期客户端日志，未发现相关告警；此项仅报告日志扫描结果' };
const missing = { status: 'unavailable', code: 'no_recent_client_logs', message: '暂无最近两小时的可用客户端日志；跳过告警扫描，无需手动核实账号' };
const summary = (routes, account) => ({ routes, account, unknown: 0,
  remaining: [routes, account].filter(o => o.status === 'risk').length });
(async () => {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const browser = await chromium.launch({ headless: true, executablePath: process.env.CSL_EDGE_EXE });
  try {
    const context = await browser.newContext({ viewport: { width: 1120, height: 1000 } });
    await context.addInitScript(() => { window.RTCPeerConnection = class { constructor() { throw Error('Isolated fixture'); } }; });
    const page = await context.newPage();
    page.on('pageerror', e => errors.push(e.message));
    await page.goto('http://127.0.0.1:' + server.address().port);
    await page.waitForFunction(() => !document.getElementById('bCheck').disabled);
    check(await page.locator('.ver').innerText() === 'v3.5.3', 'updated version loads');
    check(await page.locator('#groups .card').count() === 15, 'fifteen groups render');
    check(await page.locator('#cunknown').innerText() === '2', 'startup evidence gaps are visible');
    check(await page.locator('#score').innerText() === '100', 'checked-item score stays visible while unknown groups are shown separately');
    // Exercise the real five-second timer without directly calling the merge function.
    live = summary(good, clean);
    await page.waitForFunction(() => document.getElementById('cunknown').textContent === '0', null, { timeout: 12000 });
    check((await page.locator('.card').nth(13).innerText()).includes('已核对 2 条'), 'timer replaces the stale client-not-running row');
    check(!(await page.locator('#groups').innerText()).includes('旧快照'), 'all old evidence rows are removed');
    check((await page.locator('.card').nth(14).locator('.cst').innerText()) === '已扫描', 'log scan has an accurate scanned badge');
    check(await page.locator('#score').innerText() === '100', 'score updates after evidence is observed');
    check(!(await page.locator('#state').innerText()).includes('未核实'), 'header updates with the live cards');
    check(await page.locator('#bCopyAll').isDisabled(), 'resolved observations do not retain stale issue actions');
    check(requests.filter(p => p === '/api/run').length === 1, 'live refresh does not rerun standard repair');
    await page.screenshot({ path: path.join(output, 'live-desktop.png'), fullPage: true, animations: 'disabled' });
    live = summary({ ...good, status: 'risk', code: 'route_mismatch', message: '连接路径偏差：只读提示' }, missing);
    await page.waitForFunction(() => document.getElementById('cfail').textContent === '1', null, { timeout: 12000 });
    check(await page.locator('#score').innerText() === '75', 'a newly observed route failure changes the score');
    check(await page.locator('#cunknown').innerText() === '0', 'missing logs do not invent an account verification failure');
    check(await page.locator('.card').nth(14).locator('.cst').innerText() === '无近期日志', 'missing logs have a neutral badge');
    check(await page.locator('#bCopyAll').isEnabled(), 'new route failure can be exported');
    live = summary(good, { status: 'risk', message: '近期日志出现权限告警；请在客户端确认是否仍存在' });
    await page.waitForFunction(() => document.getElementById('cwarn').textContent === '1', null, { timeout: 12000 });
    check(await page.locator('#cfail').innerText() === '0', 'resolved route failure is cleared');
    check(await page.locator('#cunknown').innerText() === '0', 'log alerts are warnings with no extra unverified-account state');
    check(await page.locator('#score').innerText() === '100', 'resolved route restores local consistency score');
    check((await page.locator('#state').innerText()).includes('存在告警'), 'log warnings remain visible above a verified local standard');
    live = summary(good, clean);
    await page.waitForFunction(() => document.getElementById('cwarn').textContent === '0', null, { timeout: 12000 });
    await page.setViewportSize({ width: 390, height: 844 });
    check(!(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth + 1)), 'mobile has no horizontal overflow');
    check(await page.locator('#groups .row[hidden]').count() === 0, 'mobile keeps evidence visible');
    await page.screenshot({ path: path.join(output, 'live-mobile.png'), fullPage: true, animations: 'disabled' });
    incomplete = true;
    await page.click('#bCheck');
    await page.waitForFunction(() => document.getElementById('state').textContent === '检查未完成');
    await page.waitForTimeout(5500);
    check(await page.locator('#state').innerText() === '检查未完成', 'live snapshots cannot override an incomplete full check');
    check(await page.locator('#score').innerText() === '--', 'an incomplete check stays unscored after live refresh');
    check(errors.length === 0, 'browser flow has no JavaScript errors');
    fs.writeFileSync(path.join(output, 'results.json'), JSON.stringify({ passed, errors, backend: 'static non-mutating fixtures' }, null, 2));
    console.log(JSON.stringify({ passed, output }));
  } finally { await browser.close(); await new Promise(resolve => server.close(resolve)); }
})().catch(error => { console.error(error.stack); process.exitCode = 1; server.close(); });
