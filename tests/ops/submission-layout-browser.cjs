// Local UI check on a dedicated test account/draft. Never publishes a deposit.
const fs=require('node:fs');
const path=require('node:path');
const {spawn}=require('node:child_process');
const {setTimeout:delay}=require('node:timers/promises');
const assert=require('node:assert/strict');
const account=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const output=path.resolve(process.argv[3]); fs.mkdirSync(output,{recursive:true});
const before=process.argv.includes('--before');
const origin='http://127.0.0.1:4400';
const profile=fs.mkdtempSync('/tmp/clarin-layout-browser-');
const chrome=spawn('/usr/bin/google-chrome',['--headless=new','--disable-gpu','--disable-background-networking','--disable-sync','--no-first-run',`--user-data-dir=${profile}`,'--remote-debugging-port=19249','about:blank'],{stdio:'ignore'});
let socket;
const report={before,checks:[],screenshots:[]};
async function run(){
  let version;
  for(let n=0;n<40;n++){try{version=await(await fetch('http://127.0.0.1:19249/json/version')).json();break;}catch{await delay(250);}}
  assert(version,'Chrome should start');
  socket=new WebSocket(version.webSocketDebuggerUrl);
  await new Promise((resolve,reject)=>{socket.onopen=resolve;socket.onerror=reject;});
  let id=0;const pending=new Map();
  socket.onmessage=event=>{const m=JSON.parse(event.data);const waiter=pending.get(m.id);if(waiter){pending.delete(m.id);m.error?waiter.reject(m.error):waiter.resolve(m.result);}};
  const send=(method,params={},sessionId)=>new Promise((resolve,reject)=>{const key=++id;pending.set(key,{resolve,reject});socket.send(JSON.stringify({id:key,method,params,sessionId}));});
  const target=await send('Target.createTarget',{url:'about:blank'});
  const {sessionId}=await send('Target.attachToTarget',{targetId:target.targetId,flatten:true});
  const command=(method,params={})=>send(method,params,sessionId);
  const evaluate=async expression=>{const r=await command('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});if(r.exceptionDetails)throw Error(r.exceptionDetails.text);return r.result?.value;};
  const until=async(expression,label)=>{for(let n=0;n<80;n++){if(await evaluate(expression))return;await delay(250);}console.log(JSON.stringify({location:await evaluate('location.href'),text:await evaluate('document.body.innerText.slice(-1800)')}));throw Error('Timed out: '+label);};
  await command('Page.enable');
  await command('Emulation.setDeviceMetricsOverride',{width:1440,height:1100,deviceScaleFactor:1,mobile:false});
  await command('Page.navigate',{url:origin+'/dspace/login'});
  await until("!!document.querySelector('button[data-test=login-button]')",'login form');
  await evaluate(`(()=>{for(const [selector,value] of ${JSON.stringify([['input[type=email]',account.email],['input[type=password]',account.password]])}){const element=document.querySelector(selector);element.value=value;element.dispatchEvent(new Event('input',{bubbles:true}));}return true})()`);
  await delay(200);
  await evaluate("document.querySelector('button[data-test=login-button]').click()");
  await until("!location.pathname.includes('/login')",'authenticated route');
  await evaluate("(()=>{const reject=[...document.querySelectorAll('.klaro button, #klaro button')].find(b=>/^(Odrzuć|Decline|I decline|Reject)$/i.test(b.textContent.trim()));reject?.click();return true})()");
  if(await evaluate("location.pathname.includes('/info/end-user-agreement')")){
    await until("!!document.querySelector('#user-agreement-accept')",'test account agreement');
    await evaluate("document.querySelector('#user-agreement-accept').click()");
    await delay(200);
    await evaluate("document.querySelector('#button-save').click()");
    await until("!location.pathname.includes('/info/end-user-agreement')",'test account agreement saved');
  }
  const navigate=async(language)=>{
    await delay(1500);
    await evaluate(`document.cookie='dsLanguage=${language};path=/'`);
    await command('Page.navigate',{url:origin+'/dspace/workspaceitems/'+account.workspace+'/edit'});
    await until("!!document.querySelector('#button-holder') || !!document.querySelector('#user-agreement-accept')",'editor or test account agreement');
    if(await evaluate("!!document.querySelector('#user-agreement-accept')")){
      await evaluate("document.querySelector('#user-agreement-accept').click()");
      await delay(200);
      await evaluate("document.querySelector('#button-save').click()");
      await until("!location.pathname.includes('/info/end-user-agreement')",'test account agreement saved');
      await evaluate(`history.pushState(null,'','/dspace/workspaceitems/${account.workspace}/edit');window.dispatchEvent(new PopStateEvent('popstate'));true`);
    }
    await until("!!document.querySelector('ds-clarin-license-distribution') && !!document.querySelector('#button-holder')",'license sections');
    await until("!!document.querySelector('#save[data-test=save]')",'hydrated editor');
    await delay(1000);
    await evaluate("(()=>{const button=[...document.querySelectorAll('.klaro .cm-btn-decline, #klaro .cm-btn-decline, .klaro button, #klaro button')].find(b=>b.getClientRects().length&&/^(Odrzuć|Decline|I decline|Reject)$/i.test(b.textContent.trim()));button?.click();return true})()");
  };
  const capture=async(selector,name)=>{
    if(selector==='ds-submission-form-footer' && await evaluate('innerWidth<500')){
      await evaluate("document.querySelector('ds-submission-form-footer').scrollIntoView({block:'end'})");
      await delay(300);
      const buttons=await evaluate("['discard','saveForLater','deposit'].map(id=>{const e=document.getElementById(id),r=e.getBoundingClientRect();const hit=document.elementFromPoint(r.left+r.width/2,r.top+r.height/2);return{id,visible:r.top>=0&&r.bottom<=innerHeight&&r.left>=0&&r.right<=innerWidth,unobscured:hit?.closest('button')===e};})");
      assert(buttons.every(b=>b.visible&&b.unobscured),'Mobile actions should be visible and unobscured');
      report.checks.push('mobile action buttons visible and unobscured');
      const image=await command('Page.captureScreenshot',{format:'png',captureBeyondViewport:false});
      fs.writeFileSync(path.join(output,name+'.png'),Buffer.from(image.data,'base64'));report.screenshots.push(name+'.png');
      return;
    }
    const clip=await evaluate(`(()=>{const e=document.querySelector(${JSON.stringify(selector)});if(!e)return null;e.scrollIntoView({block:'center'});const r=e.getBoundingClientRect();return{x:r.left+scrollX,y:r.top+scrollY,width:r.width,height:r.height,scale:1};})()`);
    assert(clip,'Screenshot target should exist: '+selector);
    await delay(250);
    const result=await command('Page.captureScreenshot',{format:'png',captureBeyondViewport:true,clip});
    fs.writeFileSync(path.join(output,name+'.png'),Buffer.from(result.data,'base64'));report.screenshots.push(name+'.png');
  };
  await navigate('pl');
  await capture('#section_clarin-license','resource-desktop');
  await capture('#section_license','agreement-desktop');
  await capture('ds-submission-form-footer','actions-desktop');
  if(!before){
    assert(await evaluate("!!document.querySelector('.license-consent input[type=checkbox]')"));
    const csrfResponse=await fetch(origin+'/server/api/security/csrf');
    const csrf=csrfResponse.headers.get('DSPACE-XSRF-TOKEN');
    const login=await fetch(origin+'/server/api/authn/login',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded','X-XSRF-TOKEN':csrf,'Cookie':'DSPACE-XSRF-COOKIE='+csrf},body:new URLSearchParams({user:account.email,password:account.password})});
    assert.equal(login.status,200,'Separate readback session should authenticate');
    const authorization=login.headers.get('Authorization');
    const readGranted=async()=>{const r=await fetch(origin+'/server/api/submission/workspaceitems/'+account.workspace,{headers:{Authorization:authorization}});assert.equal(r.status,200);return(await r.json()).sections.license.granted;};
    assert.equal(await readGranted(),false,'Fresh test draft must not grant consent automatically');
    for(const expected of [true,false]){
      await evaluate("document.querySelector('.license-consent input').click()");
      await delay(500);
      await until("document.querySelector('#save')?.getAttribute('aria-disabled')!=='true'",'save enabled');
      await evaluate("document.querySelector('#save').click()");
      let saved=false;
      for(let n=0;n<40;n++){if(await readGranted()===expected){saved=true;break;}await delay(250);}
      assert(saved,'Consent should persist as '+expected);
      report.checks.push('consent persisted: '+expected);
      await delay(500);
    }
    assert(await evaluate("!document.querySelector('.license-consent').classList.contains('is-accepted')"));
    report.checks.push('unchecking restores the neutral consent appearance');
    await evaluate("document.querySelector('#button-holder').click()");
    await until("!!document.querySelector('section.license-selector[aria-hidden=false]')",'license wizard open');
    await evaluate("document.querySelector('section.license-selector .ls-modal-close').click()");
    await until("!!document.querySelector('section.license-selector[aria-hidden=true]')",'license wizard closed');
    report.checks.push('license wizard opens and closes');
    const state=async()=>{const r=await fetch(origin+'/server/api/submission/workspaceitems/'+account.workspace,{headers:{Authorization:authorization}});return JSON.stringify((await r.json()).sections['clarin-license']);};
    const previousState=await state();
    await evaluate("document.querySelector('.license-select').click()");
    await until("!!document.querySelector('.license-dropdown .dropdown-menu.show')",'license dropdown open');
    const selected=await evaluate("(()=>{const current=document.querySelector('.license-select').textContent.trim();const options=[...document.querySelectorAll('button[id^=license_option_]')].filter(e=>e.lastElementChild.textContent.trim()!==current);const option=options.find(e=>e.querySelector('.label-PUB'))||options[0];if(!option)return null;const name=option.lastElementChild.textContent.trim();option.click();return name;})()");
    assert(selected,'A supported license should be available');
    let selectionSaved=false;
    for(let n=0;n<40;n++){const current=await state();if(current!==previousState&&current.includes(selected)){selectionSaved=true;break;}await delay(250);}
    assert(selectionSaved,'Manual license choice should persist');
    report.checks.push('manual license selection persists through the API');
  }
  for(const [language,width] of [['pl',390],['en',1440],['en',390]]){
    await command('Emulation.setDeviceMetricsOverride',{width,height:1100,deviceScaleFactor:1,mobile:width<500});
    // A fresh navigation loads the language cookie through Angular initialization.
    await evaluate(`document.cookie='dsLanguage=${language};path=/'`);
    await command('Page.navigate',{url:origin+'/dspace/workspaceitems/'+account.workspace+'/edit'});
    await until("!!document.querySelector('#button-holder')",'localized editor');
    await until("!!document.querySelector('#save[data-test=save]')",'hydrated localized editor');
    await delay(800);
    if(!before){
      await evaluate(`(()=>{const button=[...document.querySelectorAll('.language-icon')].find(b=>b.getClientRects().length&&b.textContent.trim()===${JSON.stringify(language.toUpperCase())});button?.click();return true})()`);
      const title=language==='pl'?'Zapoznaj się z umową dotyczącą dystrybucji':'Review the distribution agreement';
      await until(`document.querySelector('ds-clarin-license-distribution .license-title')?.textContent.trim()===${JSON.stringify(title)}`,'language selection');
    }
    await evaluate("(()=>{const button=[...document.querySelectorAll('.klaro .cm-btn-decline, #klaro .cm-btn-decline, .klaro button, #klaro button')].find(b=>b.getClientRects().length&&/^(Odrzuć|Decline|I decline|Reject)$/i.test(b.textContent.trim()));button?.click();return true})()");
    const fits=await evaluate('document.documentElement.scrollWidth<=innerWidth');
    if(!fits){
      console.log(JSON.stringify(await evaluate(`({viewport:innerWidth,scrollWidth:document.documentElement.scrollWidth,wide:[...document.querySelectorAll('body *')].map(e=>({tag:e.tagName,cls:e.className,id:e.id,right:e.getBoundingClientRect().right,width:e.getBoundingClientRect().width})).filter(e=>e.right>innerWidth+1&&e.width>0).slice(0,18)})`)));
      const image=await command('Page.captureScreenshot',{format:'png'});fs.writeFileSync(path.join(output,'overflow-'+language+'-'+width+'.png'),Buffer.from(image.data,'base64'));
    }
    assert(fits,'No page overflow: '+language+' '+width);
    if(!before){
      assert(await evaluate("!document.querySelector('ds-clarin-license-distribution').textContent.includes('submission.license.')"),'Translated labels');
      const title=await evaluate("document.querySelector('ds-clarin-license-distribution .license-title').textContent.trim()");
      assert.equal(title,language==='pl'?'Zapoznaj się z umową dotyczącą dystrybucji':'Review the distribution agreement','Requested language should render');
      report.checks.push('translated consent title: '+language);
    }
    await capture('#section_clarin-license',`resource-${language}-${width}`);
    await capture('#section_license',`agreement-${language}-${width}`);
    await capture('ds-submission-form-footer',`actions-${language}-${width}`);
    report.checks.push('no horizontal overflow: '+language+' '+width);
  }
  fs.writeFileSync(path.join(output,'results.json'),JSON.stringify(report,null,2)+'\n');
  console.log(JSON.stringify(report));
}
run().catch(error=>{console.error(error.message||String(error));process.exitCode=1;}).finally(async()=>{socket?.close();chrome.kill('SIGTERM');await delay(500);fs.rmSync(profile,{recursive:true,force:true});});
setTimeout(()=>{chrome.kill('SIGKILL');process.exit(2);},150000).unref();
