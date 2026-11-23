const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { readFileSync } = require('node:fs');
const https = require('node:https');
const { setTimeout: delay } = require('node:timers/promises');
const { chromium } = require('playwright-core');

const [certificate, exe, baselinePath, mockClaude, patchPath, base, patch] = process.argv.slice(2);
const baseline = readFileSync(baselinePath);
const payload = readFileSync(patchPath);
const signature = readFileSync(patchPath + '.sig', 'utf8').trim();
const newer = patch.replace(/\d+$/, value => Number(value) + 1);
let mode = 'interrupted';
let downloads = 0;
let announced = patch;
const feed = https.createServer({ pfx: readFileSync(certificate), passphrase: 'local-test' }, (req, res) => {
  if (req.url === '/latest.json') {
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify({
      version: announced,
      installMode: 'direct',
      platforms: { 'windows-x86_64': { url: 'https://localhost:42723/update.exe', signature } },
    }));
  } else if (req.url === '/update.exe') {
    downloads++;
    res.setHeader('Content-Length', payload.length);
    if (mode === 'interrupted') {
      res.write(payload.subarray(0, 4096));
      setTimeout(() => res.destroy(), 50);
    } else {
      res.end(payload);
    }
  } else {
    res.writeHead(404).end();
  }
});

async function waitForPanel(version) {
  const deadline = Date.now() + 120_000;
  while (Date.now() < deadline) {
    const response = await fetch('http://127.0.0.1:42724/json/list').catch(() => null);
    if (response?.ok && (await response.json()).some(target => target.url.includes('tauri.localhost'))) {
      const browser = await chromium.connectOverCDP('http://127.0.0.1:42724', { timeout: 3000 }).catch(() => null);
      const page = browser?.contexts().flatMap(context => context.pages())
        .find(candidate => candidate.url().includes('tauri.localhost'));
      const renderedVersion = await page?.locator('#app-version').textContent({ timeout: 1500 }).catch(() => '');
      if (renderedVersion === 'v' + version) return page;
      await browser?.close().catch(() => {});
    }
    await delay(500);
  }
  throw Error('Desktop panel did not open at v' + version);
}

async function confirmUpdate(page) {
  await page.locator('#confirm-dialog button[value="confirm"]').click();
}

async function closeRepairGuide(page) {
  const guide = page.locator('#repair-guide-dialog');
  if (await guide.evaluate(dialog => dialog.open)) {
    await page.locator('#close-repair-guide').click();
    await guide.waitFor({ state: 'hidden' });
  }
}

async function startUpdate(page) {
  const update = page.locator('#available-update');
  for (let attempt = 0; attempt < 3; attempt++) {
    await closeRepairGuide(page);
    try {
      await update.click({ timeout: 5000 });
      break;
    } catch (error) {
      const guideOpen = await page.locator('#repair-guide-dialog').evaluate(dialog => dialog.open);
      if (!guideOpen || attempt === 2) throw error;
    }
  }
  await confirmUpdate(page);
}

async function verifySupportFlow(page) {
  await closeRepairGuide(page);
  const guide = page.locator('#repair-guide-dialog');
  await page.evaluate(() => renderReport({
    score: 22,
    complete: true,
    launchBlocked: true,
    counts: { failed: 2, unknown: 4 },
    groups: [
      { id: 1, title: 'Windows VPN 路由', level: 'failed', detail: 'VPN 路由未确认', weight: 12, earned: 0, blocksLaunch: true, elapsedMs: 9 },
      { id: 2, title: '系统时区', level: 'unknown', detail: '尚无基准', weight: 8, earned: 0, blocksLaunch: true, elapsedMs: 1 },
      { id: 3, title: 'VPN 接口基准', level: 'unknown', detail: '无法核对接口基准', weight: 12, earned: 0, blocksLaunch: true, elapsedMs: 1 },
      { id: 4, title: '出口一致性', level: 'unknown', detail: '正在等待建立出口基准', weight: 16, earned: 0, blocksLaunch: true, elapsedMs: 8009 },
      { id: 8, title: 'Anthropic API 连通性', level: 'unknown', detail: 'HTTP 403', weight: 12, earned: 0, blocksLaunch: true, elapsedMs: 603 },
      { id: 12, title: '官方支持地区', level: 'failed', detail: '不在支持名单', weight: 14, earned: 0, blocksLaunch: true, elapsedMs: 20 },
    ],
  }));
  const blocker = page.locator('#launch-blocker');
  assert.match(await blocker.textContent(), /可查看修复方案/);
  await blocker.click();
  await guide.waitFor();
  assert.match(await guide.innerText(), /没有 TUN 选项也可以/);
  assert.match(await guide.innerText(), /不会自动更改第三方 VPN/);
  assert.equal(await page.locator('[data-action="repair"]').textContent(), '检查并修复');
  assert.equal(await page.locator('#retry-auto-repair').count(), 0);
  assert.doesNotMatch(await page.locator('#settings-form').innerText(), /允许自动修复可控项目/);
  assert.equal(await page.evaluate(() => armAssistedRepair(state.report)), true);
  await page.locator('#repair-guide-feedback').click();
  const feedback = page.locator('#feedback-dialog');
  await feedback.waitFor();
  assert.match(await feedback.innerText(), /不会自动上传/);
  await page.locator('#close-feedback').click();
}

function expectStatus(page, text) {
  return page.locator('#update-result').filter({ hasText: text }).waitFor({ timeout: 60_000 });
}

async function run() {
  await new Promise((resolve, reject) => {
    feed.once('error', reject);
    feed.listen(42723, resolve);
  });
  const launcher = spawn(exe, [], {
    env: { ...process.env, WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS: '--remote-debugging-port=42724' },
    stdio: 'ignore',
    windowsHide: true,
  });
  launcher.on('error', error => console.error('Could not start installed app:', error.message));
  const previous = await waitForPanel(base);
  await previous.waitForFunction(() => !document.querySelector('#monitor-toggle').disabled, null, { timeout: 90_000 });

  await startUpdate(previous);
  await previous.locator('#update-action').filter({ hasText: '重试更新' }).waitFor({ timeout: 60_000 });
  assert.match(await previous.locator('#update-result').textContent(), /下载.*失败|下载.*中断|网络.*重试/);
  assert.equal(downloads, 1);
  assert.equal(launcher.exitCode, null, 'interrupted download must leave the installed app running');
  console.log('Baseline app survived an interrupted download.');

  mode = 'complete';
  await previous.locator('#update-action').click();
  await confirmUpdate(previous);
  const updated = await waitForPanel(patch);
  await updated.locator('#monitor-status').filter({ hasText: '等待 Claude 运行' }).waitFor();
  assert.notEqual(launcher.exitCode, null, 'baseline process must exit after handing off to the updater');
  assert.deepEqual(readFileSync(baselinePath), baseline, 'baseline file must survive unchanged');
  const settings = await updated.evaluate(() => window.__TAURI__.core.invoke('load_settings'));
  assert.equal(settings.hasBaseline, true);
  assert.equal(settings.claudeGroup, 'Upgrade smoke baseline');
  assert.equal(Object.hasOwn(settings, 'autoRepair'), false);
  console.log('Direct update relaunched at the new version, retaining baseline and tray monitoring.');

  await updated.evaluate(() => showRuntimeRisk({ risks: ['出口一致性'] }));
  const riskDialog = updated.locator('#runtime-risk-dialog');
  await riskDialog.waitFor();
  assert.match(await updated.locator('#runtime-risk-message').textContent(), /出口一致性.*关闭 Claude/);
  await updated.locator('#keep-claude-running').click();
  await riskDialog.waitFor({ state: 'hidden' });
  const closableClaude = spawn(mockClaude, [], { stdio: 'ignore', windowsHide: false });
  try {
    await updated.waitForFunction(async () => {
      const snapshot = await window.__TAURI__.core.invoke('get_snapshot');
      return snapshot.claudeRunning && snapshot.monitorMode === 'watching';
    }, null, { timeout: 30_000 });
    await updated.evaluate(() => showRuntimeRisk({ risks: ['出口一致性'] }));
    await riskDialog.waitFor();
    await updated.locator('#close-risk-claude').click();
    await Promise.race([
      riskDialog.waitFor({ state: 'hidden', timeout: 20_000 }),
      updated.locator('#runtime-risk-error').filter({ hasNotText: '正在请求' }).waitFor({ timeout: 20_000 })
        .then(async () => { throw Error(await updated.locator('#runtime-risk-error').textContent()); }),
    ]);
    await updated.waitForFunction(async () => {
      const snapshot = await window.__TAURI__.core.invoke('get_snapshot');
      return !snapshot.claudeRunning;
    }, null, { timeout: 20_000 });
    assert.notEqual(closableClaude.exitCode, null, 'confirmed risk prompt must close Claude');
    await updated.waitForFunction(
      () => !state.busy && !document.querySelector('#close-risk-claude').disabled,
      null,
      { timeout: 120_000 },
    );
  } finally {
    if (closableClaude.exitCode === null) closableClaude.kill();
  }
  console.log('Runtime risk changes offered both choices and closed a confirmed Claude fixture.');

  await verifySupportFlow(updated);
  console.log('Repair guidance and privacy-preserving feedback entry are interactive.');

  announced = newer;
  await updated.locator('#settings').click();
  await updated.locator('#check-updates').click();
  await expectStatus(updated, '发现新版本 v' + newer);
  const claude = spawn(mockClaude, [], { stdio: 'ignore', windowsHide: true });
  try {
    await updated.waitForFunction(async () => {
      const snapshot = await window.__TAURI__.core.invoke('get_snapshot');
      return snapshot.claudeRunning && snapshot.monitorMode === 'watching';
    }, null, { timeout: 30_000 });
    await updated.locator('#update-action').click();
    await confirmUpdate(updated);
    await expectStatus(updated, 'Claude 正在运行');
    assert.equal(downloads, 2, 'Claude process must block download and installation');
    assert.equal(await updated.locator('#update-action').textContent(), '重试更新');
  } finally {
    claude.kill();
  }
  await updated.waitForFunction(async () => {
    const snapshot = await window.__TAURI__.core.invoke('get_snapshot');
    return !snapshot.claudeRunning;
  }, null, { timeout: 30_000 });

  mode = 'interrupted';
  await updated.locator('#update-action').click();
  await confirmUpdate(updated);
  await expectStatus(updated, '更新包下载失败');
  assert.equal(await updated.locator('#update-action').textContent(), '重试更新');

  mode = 'complete';
  await updated.locator('#update-action').click();
  await confirmUpdate(updated);
  await expectStatus(updated, '更新包签名校验失败');
  assert.equal(await updated.locator('#update-action').textContent(), '打开正式发布页');
  assert.equal(await updated.locator('#app-version').textContent(), 'v' + patch);
  assert.equal(downloads, 4);
  console.log('The updated app distinguished a Claude lock, interrupted transfer and wrong signed version.');
}

run().then(() => process.exit(0)).catch(error => {
  console.error(error);
  process.exit(1);
});
