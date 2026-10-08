import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,writeFileSync,readFileSync,rmSync,existsSync,mkdirSync,symlinkSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {scaffoldSlice} from '../slice.mjs';
const config={version:1,module:'Example',otpApp:'example',server:'server',app:'app',apiPackage:'example_api',fixtureActorId:'local-owner',database:'example',base:'workspace',baseDomains:['Example.Tasks']};
function project(t) {const root=mkdtempSync(join(tmpdir(),'mana-scaffold-'));t.after(()=>rmSync(root,{recursive:true,force:true}));writeFileSync(join(root,'mana.json'),JSON.stringify(config));return root;}
const options={name:'bookmarks',record:'Bookmark',action:'archive',state:'archived'};
test('TOML manifest drives the real scaffold without changing feature ownership',t=>{
 const root=project(t);rmSync(join(root,'mana.json'));
 writeFileSync(join(root,'mana.toml'),Object.entries(config).map(([key,value])=>`${key} = ${JSON.stringify(value)}`).join('\n')+'\n[agents.claude]\nmods = ["agents/mods/claude/local"]\n');
 const result=scaffoldSlice(root,options);
 assert.equal(result.slice.name,'bookmarks');
 assert.match(readFileSync(join(root,'server/lib/features/bookmarks.ex'),'utf8'),/Example.Bookmark/);
 assert.equal(existsSync(join(root,'mana.json')),false);
});
test('second slice preserves app edits and shares only explicit indices',t=>{
 const root=project(t),first=scaffoldSlice(root,options);
 const feature=join(root,'app/lib/features/bookmarks.dart');writeFileSync(feature,'// developer-owned implementation\n');
 scaffoldSlice(root,{name:'saved_links',record:'SavedLink',action:'mark_read',state:'has_read'});
 assert.equal(readFileSync(feature,'utf8'),'// developer-owned implementation\n');
 const dart=readFileSync(join(root,'app/lib/features/saved_links.dart'),'utf8');
 assert.match(dart,/getSavedLinkApi/);assert.match(dart,/markReadSavedLinkRequest/);assert.match(dart,/value.hasRead/);
 assert.match(readFileSync(join(root,'server/config/mana_slices.exs'),'utf8'),/Example.Tasks, Example.Bookmarks, Example.SavedLinks/);
 assert.match(readFileSync(join(root,'server/lib/features/bookmarks.ex'),'utf8'),/authorize_if\(expr\(owner_id == \^actor\(:id\)\)\)/);
 assert.equal(JSON.parse(readFileSync(join(root,'.mana/slices.json'))).slices[0].fixtureId,first.slice.fixtureId);
 assert.throws(()=>scaffoldSlice(root,options),/already exists/);
});
test('edited indices stop generation before any new feature is written',t=>{
 const root=project(t);scaffoldSlice(root,options);
 const index=join(root,'app/moments/slices.mjs');writeFileSync(index,'// intentional app edit\n');
 const manifest=readFileSync(join(root,'.mana/slices.json'),'utf8');
 assert.throws(()=>scaffoldSlice(root,{...options,name:'notes',record:'Note'}),/index changed/);
 assert.equal(readFileSync(index,'utf8'),'// intentional app edit\n');assert.equal(readFileSync(join(root,'.mana/slices.json'),'utf8'),manifest);
 assert.equal(existsSync(join(root,'server/lib/features/notes.ex')),false);
});
test('refuses hand-owned files, traversal, interpolation and symlinks',t=>{
 const root=project(t);mkdirSync(join(root,'app/lib/features'),{recursive:true});writeFileSync(join(root,'app/lib/features/bookmarks.dart'),'existing');
 assert.throws(()=>scaffoldSlice(root,options),/Feature already exists/);assert.equal(existsSync(join(root,'server/lib/features/bookmarks.ex')),false);
 for(const invalid of ['../outside','bad-name',"x');DROP",'title'])assert.throws(()=>scaffoldSlice(root,{...options,name:invalid}),/Invalid/);
 writeFileSync(join(root,'mana.json'),JSON.stringify({...config,fixtureActorId:"owner'"}));assert.throws(()=>scaffoldSlice(root,options),/fixtureActorId/);
 writeFileSync(join(root,'mana.json'),JSON.stringify({...config,server:'../outside'}));assert.throws(()=>scaffoldSlice(root,options),/escapes/);
 writeFileSync(join(root,'mana.json'),JSON.stringify(config));symlinkSync('/tmp',join(root,'server'));assert.throws(()=>scaffoldSlice(root,options),/symlinks/);
});
test('an interrupted generation marker requires inspection, never replay',t=>{
 const root=project(t);mkdirSync(join(root,'.mana'));writeFileSync(join(root,'.mana/scaffold.lock'),'interrupted');
 assert.throws(()=>scaffoldSlice(root,options),/interrupted generation/);assert.equal(readFileSync(join(root,'.mana/scaffold.lock'),'utf8'),'interrupted');
 assert.equal(existsSync(join(root,'server')),false);
});
