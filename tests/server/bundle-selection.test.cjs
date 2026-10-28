const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('typescript');
const { of, firstValueFrom } = require('rxjs');
const { map, switchMap } = require('rxjs/operators');
const source = ts.createSourceFile('bundle.ts', fs.readFileSync('src/app/core/data/bundle-data.service.ts', 'utf8'), ts.ScriptTarget.Latest, true);
const cls = source.statements.find(n => ts.isClassDeclaration(n));
const method = cls.members.find(n => n.name?.getText(source) === 'findByItemAndName').getText(source);
class RemoteData {
  constructor(a,b,c,state,error,payload) { Object.assign(this,{state,error,payload,hasSucceeded:state==='Success'}); }
}
const Service = vm.runInNewContext(ts.transpileModule('class Service {'+method+'}',{compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText+';Service',{
  of,map,switchMap,RemoteData,hasValue:v=>v!=null,RequestEntryState:{Success:'Success',Error:'Error'}
});
test('file embeds are requested only after choosing ORIGINAL, never for the backup bundle', async () => {
  const service = new Service();
  const requests = [];
  service.findAllByItem = (...args) => {
    requests.push(['list',args]);
    return of({payload:{page:[{uuid:'backup',name:'ZIP_SOURCE_BACKUP'},{uuid:'original',name:'ORIGINAL'}]}});
  };
  service.findById = (...args) => { requests.push(['one',args]); return of({hasSucceeded:true,payload:{uuid:args[0]}}); };
  const link = {name:'bitstreams'};
  const result = await firstValueFrom(service.findByItemAndName({},'ORIGINAL',true,true,undefined,link));
  assert.equal(requests[0][1].length,4);
  assert.equal(requests[1][1][0],'original');
  assert.equal(requests[1][1][3],link);
  assert.equal(result.payload.uuid,'original');
});
test('missing ORIGINAL produces an error without loading backup files', async () => {
  const service = new Service();
  service.findAllByItem = () => of({payload:{page:[{uuid:'backup',name:'ZIP_SOURCE_BACKUP'}]}});
  service.findById = () => { throw Error('Unexpected file request'); };
  const result = await firstValueFrom(service.findByItemAndName({},'ORIGINAL',true,true,undefined,{}));
  assert.equal(result.hasSucceeded,false);
});
