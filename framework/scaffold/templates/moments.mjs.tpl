// App-owned development recipe. No fixture/reset HTTP endpoint is exposed.
import {execFileSync} from 'node:child_process';
import {assertOwned} from '{{ownershipImport}}';
export const {{name}}Fixture={id:'{{fixtureId}}',owner:'{{fixtureActorId}}',title:'Mana fixture: {{name}}'};
export function {{name}}Moments({headers}) {
 async function inspect(instance) {
  const response=await fetch(`${instance.apiUrl}/api/{{name}}`,{headers:{...await headers(instance),Accept:'application/vnd.api+json'},signal:AbortSignal.timeout(5000)});
  if(!response.ok)throw Error('{{Collection}} observation unavailable');
  const {data}=await response.json();
  if(!Array.isArray(data)||data.length>100||data.some(v=>v.type!=='{{type}}'||! /^[a-f0-9-]{36}$/.test(v.id)||typeof v.attributes?.{{state}}!=='boolean')||new Set(data.map(v=>v.id)).size!==data.length)throw Error('Invalid {{name}} observation');
  const ids=rows=>rows.map(v=>v.id).sort().join(',')||'none';
  return {status:'ready',source:'ash-json-api',projection:{storage:'ash-postgres',ids:ids(data),changedIds:ids(data.filter(v=>v.attributes.{{state}})),changed:data.some(v=>v.id==={{name}}Fixture.id&&v.attributes.{{state}})}};
 }
 const inbox={inspect,prepare:async instance=>{await inspect(instance);}};
 return {
  '{{nameDash}}-inbox':inbox,
  '{{nameDash}}-journey':{inspect,prepare:async instance=>{
   assertOwned(instance);
   // Only this declared synthetic identity may be reset. A collision with
   // another owner/title is refused instead of overwriting their record.
   const sql="INSERT INTO {{name}} (id,owner_id,title,{{state}}) VALUES ('{{fixtureId}}','{{fixtureActorId}}','Mana fixture: {{name}}',false) ON CONFLICT (id) DO UPDATE SET {{state}}=false WHERE {{name}}.owner_id=EXCLUDED.owner_id AND {{name}}.title=EXCLUDED.title RETURNING id";
   let result;try{result=execFileSync('docker',['exec',instance.container,'psql','-v','ON_ERROR_STOP=1','-U','postgres','-d','{{database}}','-Atc',sql],{encoding:'utf8',timeout:10000,stdio:['ignore','pipe','pipe']});}catch{throw Error('{{Collection}} fixture preparation failed');}
   if(!result.includes({{name}}Fixture.id))throw Error('Fixture identity is occupied by another record');
   const state=await inspect(instance);if(state.projection.changed||!state.projection.ids.split(',').includes({{name}}Fixture.id))throw Error('Fixture not visible to this actor');
  }},
 };
}
