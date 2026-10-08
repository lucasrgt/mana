#!/usr/bin/env node
import {createHash,randomUUID} from 'node:crypto';
import {existsSync,readFileSync,writeFileSync,mkdirSync,renameSync,rmSync,lstatSync} from 'node:fs';
import {dirname,resolve,relative,join,isAbsolute} from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {parseArgs} from 'node:util';
import {spawnSync} from 'node:child_process';
import {readManifest} from '../cli/manifest.mjs';
const here=dirname(fileURLToPath(import.meta.url));
const digest=value=>createHash('sha256').update(value).digest('hex');
const json=value=>JSON.stringify(value,null,2)+'\n';
const pascal=value=>value.split('_').map(v=>v[0].toUpperCase()+v.slice(1)).join('');
const camel=value=>{const p=pascal(value);return p[0].toLowerCase()+p.slice(1);};
const snake=value=>value.replace(/([a-z0-9])([A-Z])/g,'$1_$2').toLowerCase();
const reserved=new Set(['id','title','owner_id','read','list','type','class','default','state','new','delete','update','create','null','true','false','end','do']);
function identifier(value,label) {
 if(typeof value!=='string'||! /^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$/.test(value)||value.length>48||reserved.has(value))throw Error(`Invalid ${label}: use a non-reserved snake_case identifier`);
 return value;
}
function inside(root,path) {
 if(typeof path!=='string'||!path||isAbsolute(path))throw Error('Project paths must be relative');
 const target=resolve(root,path),rel=relative(root,target);
 if(!rel||rel.startsWith('..')||isAbsolute(rel))throw Error('Path escapes the project');
 let current=root;
 for(const part of rel.split('/')) {current=join(current,part);if(existsSync(current)&&lstatSync(current).isSymbolicLink())throw Error('Scaffold does not follow symlinks');}
 return target;
}
function formatDart(source) {
 const result=spawnSync('dart',['format','--output=show','--summary=none'],{input:source,encoding:'utf8',timeout:15000});
 if(result.error||result.status!==0)throw Error('Dart formatter unavailable or rejected the scaffold; install the project Flutter SDK');
 return result.stdout;
}
function registries(config,slices) {
 const domains=[...config.baseDomains,...slices.map(s=>`${config.module}.${pascal(s.name)}`)];
 return {
  [`${config.server}/config/mana_slices.exs`]:`# Generated index; edit features and the Mana manifest instead.\nimport Config\nconfig :${config.otpApp}, ash_domains: [${domains.join(', ')}]\n`,
  [`${config.app}/lib/generated/mana_routes.dart`]:`// Generated index; feature source is app-owned.\nimport 'package:dio/dio.dart';\nimport 'package:go_router/go_router.dart';\n${slices.map(s=>`import '../features/${s.name}.dart';`).join('\n')}\n\nList<RouteBase> manaSliceRoutes(Dio dio) => [\n${slices.map(s=>`  GoRoute(path: '/${s.name}', builder: (_, _) => ${pascal(s.name)}Screen(api: ${pascal(s.name)}Api(dio))),`).join('\n')}\n];\n`,
  [`${config.app}/moments/slices.mjs`]:`// Generated index; recipes are app-owned.\n${slices.map(s=>`import {${s.name}Moments} from './features/${s.name}.mjs';`).join('\n')}\nexport const generatedDomains=${JSON.stringify(domains)};\nexport const generatedRecipes=options=>({${slices.map(s=>`...${s.name}Moments(options)`).join(',')}});\n`,
 };
}
export function scaffoldSlice(project,options) {
 project=resolve(project);
 if(lstatSync(project).isSymbolicLink())throw Error('Scaffold project must not be a symlink');
 const config=readManifest(project,true);
 if(config.version!==1||! /^[A-Z][A-Za-z0-9]*(?:\.[A-Z][A-Za-z0-9]*)*$/.test(config.module))throw Error('Invalid Mana manifest module/version');
 for(const key of ['otpApp','apiPackage','database'])identifier(config[key],key);
 for(const key of ['app','server'])inside(project,config[key]);
 if(!Array.isArray(config.baseDomains)||config.baseDomains.some(v=>typeof v!=='string'||! /^[A-Z][A-Za-z0-9]*(?:\.[A-Z][A-Za-z0-9]*)*$/.test(v)))throw Error('Invalid baseDomains');
 if(typeof config.fixtureActorId!=='string'||! /^[a-zA-Z0-9_-]{1,100}$/.test(config.fixtureActorId))throw Error('fixtureActorId must be a simple local identity');
 if(typeof config.base!=='string'||! /^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/.test(config.base))throw Error('Invalid Moment base');
 const name=identifier(options.name,'collection'),action=identifier(options.action,'action'),state=identifier(options.state,'state');
 if(! /^[A-Z][a-zA-Z0-9]*$/.test(options.record??'')||options.record.length>48||pascal(snake(options.record))!==options.record)throw Error('Record must be PascalCase');
 if(new Set([name,action,state]).size!==3)throw Error('Collection, action and state must be distinct');
 const manifestPath=inside(project,'.mana/slices.json'),lock=inside(project,'.mana/scaffold.lock');
 mkdirSync(dirname(lock),{recursive:true});
 try{writeFileSync(lock,json({pid:process.pid,startedAt:new Date().toISOString()}),{flag:'wx'});}catch{throw Error('Scaffold lock exists; inspect any interrupted generation before removing .mana/scaffold.lock');}
 const changes=[];
 try {
  const previous=existsSync(manifestPath)?JSON.parse(readFileSync(manifestPath)): {version:1,slices:[],registries:{}};
  if(previous.version!==1||!Array.isArray(previous.slices)||!previous.registries)throw Error('Invalid slice manifest');
  if(options.record===pascal(name)||previous.slices.some(s=>s.name===name||s.record===options.record||s.record===pascal(name)||pascal(s.name)===options.record)||config.baseDomains.includes(`${config.module}.${pascal(name)}`)||config.baseDomains.includes(`${config.module}.${options.record}`))throw Error('Slice/domain already exists');
  const slice={name,record:options.record,action,state,fixtureId:randomUUID()};
  const slices=[...previous.slices,slice].sort((a,b)=>a.name.localeCompare(b.name));
  const nextIndices=registries(config,slices);
  for(const path of Object.keys(nextIndices))if(path.endsWith('.dart'))nextIndices[path]=formatDart(nextIndices[path]);
  // Check owned indices before any feature write. Never silently replace app edits.
  for(const [path,hash] of Object.entries(previous.registries)) {
   const file=inside(project,path);
   if(!(path in nextIndices)||!existsSync(file)||digest(readFileSync(file))!==hash)throw Error(`Generated index changed or moved: ${path}; reconcile it before adding a slice`);
  }
  for(const path of Object.keys(nextIndices))if(existsSync(inside(project,path))&&!previous.registries[path])throw Error(`Refusing to take ownership of ${path}`);
  const values={...config,...slice,Module:config.module,Record:slice.record,Collection:pascal(name),Action:pascal(action),State:pascal(state),stateCamel:camel(state),actionCamel:camel(action),type:snake(slice.record),typeCamel:camel(snake(slice.record)),nameDash:name.replaceAll('_','-'),baseAtom:config.base.replaceAll('-','_'),ApiClient:pascal(config.apiPackage)};
  const recipePath=`${config.app}/moments/features/${name}.mjs`;
  values.ownershipImport=relative(dirname(inside(project,recipePath)),resolve(here,'../moments/database_ownership.mjs')).split('\\').join('/');
  if(!values.ownershipImport.startsWith('.'))values.ownershipImport='./'+values.ownershipImport;
  const timestamp=new Date().toISOString().replace(/\D/g,'').slice(0,14);
  const templates={
   [`${config.server}/lib/features/${name}.ex`]:'resource.ex.tpl',
   [`${config.server}/priv/repo/migrations/${timestamp}_create_${name}.exs`]:'migration.exs.tpl',
   [`${config.app}/lib/features/${name}.dart`]:'feature.dart.tpl',
   [recipePath]:'moments.mjs.tpl',
  };
  const features={};
  for(const [path,template] of Object.entries(templates)) {
   if(existsSync(inside(project,path)))throw Error(`Feature already exists: ${path}`);
   features[path]=readFileSync(join(here,'templates',template),'utf8').replace(/\{\{(\w+)\}\}/g,(_,key)=>{if(values[key]===undefined)throw Error(`Missing template value: ${key}`);return values[key];});
  }
  for(const path of Object.keys(features))if(path.endsWith('.dart'))features[path]=formatDart(features[path]);
  const manifest={version:1,slices,registries:Object.fromEntries(Object.entries(nextIndices).map(([path,content])=>[path,digest(content)]))};
  const outputs={...features,...nextIndices,'.mana/slices.json':json(manifest)};
  // Per-file atomic publish; restore on normal errors. A process kill leaves the
  // lock as an explicit interruption marker, never an automatic replay signal.
  for(const [path,content] of Object.entries(outputs)) {
   const file=inside(project,path);mkdirSync(dirname(file),{recursive:true});
   const before=existsSync(file)?readFileSync(file):null,temp=`${file}.${randomUUID()}.tmp`;
   try{writeFileSync(temp,content,{flag:'wx'});renameSync(temp,file);}finally{rmSync(temp,{force:true});}
   changes.push({file,before});
  }
  return {version:1,slice,files:Object.keys(outputs),next:[`Compile and migrate ${config.server}`,`Export OpenAPI and generate ${config.apiPackage}`,`Sync Moments and run ${values.nameDash}-${action.replaceAll('_','-')}`]};
 } catch(error) {
  for(const {file,before} of changes.reverse()){if(before===null)rmSync(file,{force:true});else writeFileSync(file,before);}
  throw error;
 } finally{rmSync(lock,{force:true});}
}
if(process.argv[1]&&pathToFileURL(resolve(process.argv[1])).href===import.meta.url) {
 try {
  const {values,positionals}=parseArgs({allowPositionals:true,options:{project:{type:'string'},record:{type:'string'},action:{type:'string'},state:{type:'string'}}});
  if(positionals.length!==1||!values.project)throw Error('Usage: slice.mjs collection --record Record --action archive --state archived --project directory');
  console.log(json(scaffoldSlice(values.project,{...values,name:positionals[0]})));
 }catch(error){console.error(error.message);process.exitCode=1;}
}
