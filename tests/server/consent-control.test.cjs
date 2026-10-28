const {test}=require('node:test');
const assert=require('node:assert/strict');
const {readFileSync}=require('node:fs');
const vm=require('node:vm');
const ts=require('typescript');

// Exercise the actual consent methods without loading Angular's browser runtime.
// Dependencies at the patch/service boundary are fakes; method bodies come from source.
const source=ts.createSourceFile('consent.ts',readFileSync('src/app/submission/sections/clarin-license-distribution/clarin-license-distribution.component.ts','utf8'),ts.ScriptTarget.Latest,true);
const component=source.statements.find(node=>ts.isClassDeclaration(node)&&node.name?.text==='SubmissionSectionClarinLicenseDistributionComponent');
const methods=component.members.filter(node=>['setAcceptance','changeToNotInit','onChange'].includes(node.name?.getText(source))).map(node=>node.getText(source)).join('\n');
const compiled=ts.transpileModule('class Consent {'+methods+'}',{compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText;
const Consent=vm.runInNewContext(compiled+';Consent',{isNull:value=>value===null,isNotUndefined:value=>value!==undefined});

function fixture(){
  const controller=new Consent();const patches=[];
  Object.assign(controller,{
    isInit:true,acceptanceReadOnly:false,toggleAcceptation:{value:false},
    pathCombiner:{getPath:path=>({path})},
    operationsBuilder:{add:(path,value)=>patches.push({path:path.path,value}),remove:()=>{throw Error('Unexpected consent removal');}},
    sectionService:{dispatchRemoveSectionErrors:()=>{}},sectionData:{id:'license'},submissionId:'local-test',
    updateSectionStatus:()=>{},
  });
  return{controller,patches};
}
test('the first deliberate consent change is persisted, and consent can be revoked',()=>{
  const{controller,patches}=fixture();
  assert.equal(patches.length,0);
  assert.equal(controller.toggleAcceptation.value,false);
  controller.setAcceptance(true);
  controller.setAcceptance(false);
  assert.deepEqual(patches,[{path:'/sections/license/granted',value:'true'},{path:'/sections/license/granted',value:'false'}]);
  assert.equal(controller.toggleAcceptation.value,false);
});
test('read-only consent refuses mutations even if its handler is invoked directly',()=>{
  const{controller,patches}=fixture();controller.acceptanceReadOnly=true;
  controller.setAcceptance(true);
  assert.equal(controller.toggleAcceptation.value,false);
  assert.equal(patches.length,0);
});
