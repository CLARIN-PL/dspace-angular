// Run against the isolated local UI. Requires Chrome and Node with WebSocket.
const {spawn} = require('node:child_process');
const {readFileSync, mkdtempSync, rmSync} = require('node:fs');
const {tmpdir} = require('node:os');
const {join} = require('node:path');
const assert = require('node:assert/strict');
const {setTimeout: delay} = require('node:timers/promises');

const profile = mkdtempSync(join(tmpdir(), 'clarin-bootstrap-test-'));
const chrome = spawn('/usr/bin/google-chrome', [
  '--headless=new', '--disable-gpu', '--disable-background-networking', '--disable-sync',
  '--no-first-run', `--user-data-dir=${profile}`, '--remote-debugging-port=19239', 'about:blank',
], {stdio:'ignore'});
let socket;
(async () => {
  let version;
  for (let attempt=0; attempt<40; attempt++) {
    try {version=await (await fetch('http://127.0.0.1:19239/json/version')).json(); break;}
    catch {await delay(250);}
  }
  assert(version, 'Chrome should start');
  socket = new WebSocket(version.webSocketDebuggerUrl);
  await new Promise((resolve,reject) => {socket.onopen=resolve; socket.onerror=reject;});
  let id=0;
  const pending = new Map();
  socket.onmessage = event => {
    const message=JSON.parse(event.data);
    const waiter=pending.get(message.id);
    if (waiter) {
      pending.delete(message.id);
      message.error ? waiter.reject(message.error) : waiter.resolve(message.result);
    }
  };
  const send=(method,params={},sessionId) => new Promise((resolve,reject) => {
    const sequence=++id;
    pending.set(sequence,{resolve,reject});
    socket.send(JSON.stringify({id:sequence,method,params,sessionId}));
  });
  const target=await send('Target.createTarget',{url:'about:blank'});
  const {sessionId}=await send('Target.attachToTarget',{targetId:target.targetId,flatten:true});
  const evaluate=async expression => {
    const result=await send('Runtime.evaluate',{expression,returnByValue:true},sessionId);
    assert(!result.exceptionDetails, 'Evaluation should not throw outside the fixture');
    return result.result?.value;
  };
  await send('Page.navigate',{url:'http://127.0.0.1:4400/dspace/login'},sessionId);
  let ready=false;
  for (let attempt=0;attempt<80;attempt++) {
    ready=await evaluate("document.readyState==='complete' && typeof window.jQuery==='function' && !!window.jQuery.fn.button");
    if (ready) break;
    await delay(250);
  }
  assert(ready, 'Real Bootstrap bundle should load');
  const fixed=readFileSync('src/app/shared/view-mode-switch/view-mode-switch.component.html','utf8');
  assert(!fixed.includes('data-toggle="buttons"'));
  const legacy=fixed.replace('class="btn-group"','class="btn-group" data-toggle="buttons"');
  const check=html => evaluate(`(()=>{
    const fixture=document.createElement('div');fixture.innerHTML=${JSON.stringify(html)};
    document.body.append(fixture);
    try {window.jQuery(window).triggerHandler('load');return {ok:true};}
    catch(error) {return {ok:false,name:error.name,message:error.message};}
    finally {fixture.remove();}
  })()`);
  const before=await check(legacy);
  assert.equal(before.name,'TypeError');
  assert.match(before.message,/checked/);
  const after=await check(fixed);
  assert.equal(after.ok,true);
  console.log(JSON.stringify({before,after}));
})().catch(error=>{console.error(error.message||String(error));process.exitCode=1;})
  .finally(async()=>{socket?.close();chrome.kill('SIGTERM');await delay(500);rmSync(profile,{recursive:true,force:true});});
setTimeout(()=>{chrome.kill('SIGKILL');process.exit(2);},35000).unref();
