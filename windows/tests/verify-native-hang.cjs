const fs=require('fs'),path=require('path'),net=require('net');
const {spawn,spawnSync}=require('child_process');
const {chromium}=require(process.env.CSL_PLAYWRIGHT_MODULE || 'playwright');
const root=process.env.CSL_QA_OUTPUT || path.join(require('os').tmpdir(),'claude-hang-qa-'+Date.now()),fixture=path.join(root,'fixture');
fs.mkdirSync(fixture,{recursive:true});
const ps=path.join(process.env.SystemRoot||'C:/Windows','System32/WindowsPowerShell/v1.0/powershell.exe');
const write=(name,value)=>fs.writeFileSync(path.join(fixture,name),'\uFEFF'+value);
const source=path.resolve(__dirname,'..');
for(const name of ['observer.pid','check.pid','check-hang']){const p=path.join(fixture,name);if(fs.existsSync(p))fs.unlinkSync(p)}
for(const name of ['claude-common.ps1','claude-diagnostics.ps1','claude-risk.ps1','claude-envfix.ps1','claude-issueexport.ps1','claude-panel-observer.ps1','claude-panel.ps1','claude-panel.html'])fs.copyFileSync(path.join(source,name),path.join(fixture,name));
// All process/socket observations below are synthetic. No real account or proxy is queried.
fs.appendFileSync(path.join(fixture,'claude-common.ps1'),`
function Read-VergeRuntime { return @{} }
function Find-ClaudeApp { return @{aumid='Fixture!Claude';exe=''} }
function Find-ClashExe { return 'fixture.exe' }
function Find-NpmGlobalDir { return '' }
`);
const sample={active:true,status:'observed',remaining:0,unknown:0,fixed:0,
 routes:{status:'observed',code:'route_observed',processCount:9,observed:2,message:'合成只读观测：2 条连接核对通过'},
 account:{status:'observed',code:'no_recent_alerts',message:'合成日志扫描：未发现相关告警',categories:[]}};
write('preflight.json',JSON.stringify({expectedNode:'fixture-node',claudeAumid:'Fixture!Claude',clashExe:'fixture.exe',npmGlobalDir:'fixture'}));
write('panel.json',JSON.stringify({theme:'anime'}));
fs.writeFileSync(path.join(fixture,'observer-hang'),'fixture');
fs.appendFileSync(path.join(fixture,'claude-risk.ps1'),`
function Get-CslRuntimeRiskSummary($Cfg) {
 [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'observer.pid'),[string]$PID)
 if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'observer-hang')){Start-Sleep -Seconds 60}
 $sample='${JSON.stringify(sample)}'|ConvertFrom-Json
 $sample|Add-Member -NotePropertyName timestampUtc -NotePropertyValue ([datetime]::UtcNow.ToString('o')) -Force
 return $sample
}
`);
const panel=fs.readFileSync(path.join(fixture,'claude-panel.ps1'),'utf8')
 .replace('$last = Get-Date; $quit = $false','$last = (Get-Date).AddSeconds(-60); $quit = $false')
 .replace("$(if($mode -eq 'full'){240}else{120})","$(if($mode -eq 'full'){4}else{4})");
write('claude-panel.ps1',panel.replace(/^\uFEFF/,''));
const observer=fs.readFileSync(path.join(fixture,'claude-panel-observer.ps1'),'utf8').replace('timeoutSeconds=20','timeoutSeconds=3').replaceAll('AddSeconds(30)','AddSeconds(8)');
write('claude-panel-observer.ps1',observer.replace(/^\uFEFF/,''));
write('claude-preflight.ps1',`
param([switch]$NoPause,[switch]$NoLaunch,[switch]$Relearn,[switch]$ApplySettings,[switch]$TestMode,[string]$CheckMode,[string]$ResultPath,[string]$RunId,[string[]]$FixVarPattern)
[Console]::OutputEncoding=[Text.Encoding]::UTF8
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'check.pid'),[string]$PID)
Write-Host '== 1. 合成检查'
Write-Host '  [信息] 原生后台进度可正常显示'
if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'check-hang')){Start-Sleep -Seconds 60}
. (Join-Path $PSScriptRoot 'claude-diagnostics.ps1')
$stages=@(1..13|ForEach-Object{"$_. 合成标准"})+@('14. Claude 实际进程连接','15. 客户端告警扫描')
$events=@($stages|ForEach-Object{[pscustomobject]@{Group=$_;Level='PASS';Text='合成测试通过'}})
Write-CslCheckReport -Path $ResultPath -RunId $RunId -Complete $true -Result 'PASS' -Score 100 -ExitCode 0 -Stages $stages -Events $events
exit 0
`);
const child=spawn(ps,['-NoProfile','-ExecutionPolicy','Bypass','-File',path.join(fixture,'claude-panel.ps1'),'-Port','47856'],{windowsHide:true,env:{...process.env,CSL_PANEL_TESTMODE:'1',CSL_PANEL_NO_OPEN:'1'}});
let stderr='';child.stderr.on('data',b=>stderr+=b);child.stdout.on('data',()=>{});
let browser,page,passed=0;const errors=[],latencies=[];
const delay=ms=>new Promise(r=>setTimeout(r,ms));
function check(ok,name){if(!ok)throw Error(name);passed++;console.log('PASS: '+name)}
async function alive(id){const r=spawnSync(ps,['-NoProfile','-Command',`[bool](Get-Process -Id ${Number(id)} -ErrorAction SilentlyContinue)`],{windowsHide:true,encoding:'utf8'});return r.stdout.trim()==='True'}
async function waitFor(fn,timeout=15000){const until=Date.now()+timeout;while(Date.now()<until){if(await fn())return;await delay(150)}throw Error('fixture condition timed out')}
(async()=>{
 try{
  await delay(2500);
  check(child.exitCode===null,'backend survives a 60-second heartbeat gap that previously caused exit');
  browser=await chromium.launch({headless:true,executablePath:process.env.CSL_EDGE_EXE});
  page=await browser.newPage({viewport:{width:1120,height:1000}});page.on('pageerror',e=>errors.push(e.message));
  await page.addInitScript(()=>{window.RTCPeerConnection=class{constructor(){throw Error('isolated fixture')}}});
  await page.goto('http://localhost:47856/');
  await page.waitForFunction(()=>!document.getElementById('bCheck').disabled);
  console.log('INITIAL '+JSON.stringify(await page.evaluate(()=>({state:$('state').textContent,hint:$('hint').textContent,cards:st.groups.length}))));
  check(await page.locator('#groups .card').count()===15,'native full report renders all fifteen stages');
  check(await page.locator('#score').innerText()==='100','native direct check process returns a validated complete report');
  check((await page.locator('.ver').innerText())==='v3.5.3','native page version is correct');
  await waitFor(()=>fs.existsSync(path.join(fixture,'observer.pid')));
  const slowId=fs.readFileSync(path.join(fixture,'observer.pid'),'utf8').trim();
  for(let i=0;i<6;i++){
   const result=await page.evaluate(async()=>{const begin=performance.now();const r=await api('GET','/api/ping');return{ok:r.ok,ms:performance.now()-begin}});
   latencies.push(result.ms);check(result.ok&&result.ms<1500,'heartbeat responds while the observation worker is blocked '+(i+1));await delay(150);
  }
  check(await page.locator('#bCheck').isEnabled(),'check button stays enabled during a slow read-only observation');
  await waitFor(async()=>!(await alive(slowId)));
  check(!(await alive(slowId)),'only the timed-out observation child is terminated');
  check(child.exitCode===null,'HTTP backend survives the observation timeout');
  const cooldown=await page.evaluate(()=>api('GET','/api/risk-status'));
  check(cooldown.state==='timed_out'&&!cooldown.pending,'timeout state is explicit and leaves no duplicate running observer');
  await page.evaluate(()=>refreshLiveRisk());
  check((await page.locator('#riskLive').innerText()).includes('超时'),'observation timeout is visible without freezing the panel');
  await page.screenshot({path:path.join(root,'observation-timeout.png'),fullPage:true,animations:'disabled'});
  fs.unlinkSync(path.join(fixture,'observer-hang'));
  await waitFor(async()=>{const r=await page.evaluate(()=>api('GET','/api/risk-status'));return r.active&&r.summary?.routes.observed===2});
  check(true,'observation recovers after a bounded retry');
  fs.writeFileSync(path.join(fixture,'check-hang'),'fixture');
  await page.click('#bCheck');
  await page.waitForFunction(()=>document.getElementById('bCheck').disabled);
  await page.waitForFunction(()=>document.getElementById('hint').textContent.includes('已用'),null,{timeout:5000});
  await page.waitForFunction(()=>document.getElementById('groups').textContent.includes('原生后台进度'),null,{timeout:3000});
  check((await page.locator('#groups').innerText()).includes('原生后台进度'),'redirected native stdout preserves Chinese progress text');
  await page.waitForFunction(()=>document.getElementById('state').textContent==='检查未完成',null,{timeout:10000});
  check((await page.locator('#hint').innerText()).includes('检查超时'),'a blocked main check ends with a clear timeout');
  check(await page.locator('#score').innerText()==='--','a timed-out check cannot display a passing score');
  check(await page.locator('#bCheck').isEnabled(),'retry is enabled after main check timeout');
  const checkId=fs.readFileSync(path.join(fixture,'check.pid'),'utf8').trim();
  check(!(await alive(checkId)),'timed-out direct preflight leaves no orphan check process');
  check(child.exitCode===null,'backend remains available after the check timeout');
  await page.screenshot({path:path.join(root,'check-timeout.png'),fullPage:true,animations:'disabled'});
  fs.unlinkSync(path.join(fixture,'check-hang'));await page.click('#bCheck');
  await page.waitForFunction(()=>document.getElementById('state').textContent!=='检查未完成'&&!document.getElementById('bCheck').disabled);
  check(await page.locator('#score').innerText()==='100','retry completes successfully after the simulated fault is removed');
  check(errors.length===0,'native UI has no JavaScript errors');
  check(!stderr.trim(),'native backend has no startup or redirect errors');
  fs.writeFileSync(path.join(root,'native-results.json'),JSON.stringify({passed,errors,maxHeartbeatMs:Math.max(...latencies),browser:'Edge; Browser plugin not available',fixture:'isolated native PowerShell; synthetic observations and checks'},null,2));
  console.log(JSON.stringify({passed,maxHeartbeatMs:Math.max(...latencies),artifacts:root}));
  await page.evaluate(()=>api('POST','/api/quit',{}));
 }finally{if(page&&child.exitCode===null)await page.evaluate(()=>api('POST','/api/quit',{})).catch(()=>{});if(browser)await browser.close();if(child.exitCode===null)child.kill()}
})().catch(e=>{console.error(e.stack);if(stderr)console.error(stderr);process.exitCode=1});
