import { execFileSync, spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, mkdirSync, writeFileSync, existsSync, rmSync, copyFileSync } from 'node:fs';
import { tmpdir, homedir } from 'node:os';
import { join } from 'node:path';
import assert from 'node:assert/strict';

const simctl = (...args) => execFileSync('xcrun',['simctl', ...args],{encoding:'utf8'}).trim();
const devices = Object.values(JSON.parse(simctl('list','devices','available','-j')).devices).flat();
const sim = process.env.CLIPRELAY_SIM ?? devices.find(d=>d.name==='ClipRelay-QA')?.udid;
assert.ok(sim,'Build and install using cliprelay/build.sh first');
const id='cc.macseek.cliprelay';
const container=simctl('get_app_container',sim,id,'data');
const mac=mkdtempSync(join(tmpdir(),'cliprelay-qa-'));
const ios=join(container,'Documents','relay-qa');
const wait=async(file,dir) => {
  for(let i=0; i<600; i++) {
    if(existsSync(join(dir,file))) return readFileSync(join(dir,file),'utf8');
    const terminal=join(dir,'result');
    if(existsSync(terminal)) throw Error(readFileSync(terminal,'utf8'));
    await new Promise(r=>setTimeout(r,250));
  }
  throw Error('Timeout waiting for '+file+' in '+dir);
};
const localOnly = process.argv.includes('--local-only');
const mode = localOnly ? '1' : '0';
let proc;
try {
  try{execFileSync('xcrun',['simctl','terminate',sim,id],{stdio:'ignore'})}catch{}
  rmSync(ios,{recursive:true,force:true});
  mkdirSync(ios,{recursive:true,mode:0o700});
  if (!localOnly) {
    const conf=process.env.CLIPRELAY_CONFIG_DIR ?? join(homedir(),'.config','cliprelay-test');
    const { RELAY_TOKEN }=JSON.parse(readFileSync(join(conf,'worker-secrets.json'),'utf8'));
    assert.match(RELAY_TOKEN,/^[a-f0-9]{64}$/);
    for(const d of [mac,ios]) writeFileSync(join(d,'credential'),RELAY_TOKEN,{mode:0o600});
  }
  proc=spawn('/Applications/ClipRelay.app/Contents/MacOS/ClipRelay',['--relay-qa'],{env:{...process.env,CLIPRELAY_QA_DIR:mac,CLIPRELAY_QA_LOCAL_ONLY:mode},stdio:'ignore'});
  process.env.SIMCTL_CHILD_CLIPRELAY_QA_LOCAL_ONLY = mode;
  simctl('launch',sim,id,'--relay-qa');
  for(const d of [mac,ios]) await wait('card',d);
  copyFileSync(join(mac,'card'),join(ios,'peer')); copyFileSync(join(ios,'card'),join(mac,'peer'));
  for(const d of [mac,ios]) await wait('ready',d);
  copyFileSync(join(ios,'phone.clipnote'),join(mac,'phone.clipnote'));
  for(const d of [mac,ios]) writeFileSync(join(d,'go'),'');
  for(const [name,d] of [['Mac',mac],['iOS Simulator',ios]]) {
    const result=await wait('result',d);
    console.log(name,result,'Discovery:',existsSync(join(d,'discovery'))?readFileSync(join(d,'discovery'),'utf8'):'unavailable');
    assert.match(result,/^PASS /);
  }
} finally {
  if(proc?.exitCode===null) proc.kill();
  try{simctl('terminate',sim,id)}catch{}
  rmSync(mac,{recursive:true,force:true});
  rmSync(ios,{recursive:true,force:true});
}
