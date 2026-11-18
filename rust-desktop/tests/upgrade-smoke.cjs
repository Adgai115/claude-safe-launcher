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

async function startUpdate(page) {
  await page.locator('#available-update').click();
  await confirmUpdate(page);
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
  await expectStatus(previous, '下载失败或更新签名校验未通过');
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
  console.log('Direct update relaunched at the new version, retaining baseline and tray monitoring.');

  announced = newer;
  await updated.locator('#settings').click();
  await updated.locator('#check-updates').click();
  await expectStatus(updated, '发现新版本 v' + newer);
  const claude = spawn(mockClaude, ['/d', '/q', '/k'], { stdio: ['pipe', 'ignore', 'ignore'], windowsHide: true });
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
