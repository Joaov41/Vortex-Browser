// Disk-level migration checks in a fresh temporary directory, never Browser's cache.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {spawnSync} from 'node:child_process';
const directory=process.argv[2];
assert(directory,'Pass a temporary fixture/module-cache directory');
const cache=fs.mkdtempSync(directory+'/migration-');
const source=fs.readFileSync('Browser/Utilities/IndexedAdBlockRules.swift','utf8');
const service=fs.readFileSync('Browser/Services/AdBlockService.swift','utf8');
const prepareStart=service.indexOf('func prepareAsync()');
const readyAt=service.indexOf('isReady = true',prepareStart);
const migrationScheduleAt=service.indexOf('await self?.refreshProvenanceFilterLists()',prepareStart);
assert(prepareStart >= 0 && readyAt > prepareStart && migrationScheduleAt > readyAt,
  'Provenance migration must be scheduled only after cached startup is ready');
const missingStart=service.indexOf('private func downloadMissingFilterLists()');
const migrationStart=service.indexOf('private func refreshProvenanceFilterLists()');
assert(missingStart >= 0 && migrationStart > missingStart,
  'Missing-list startup and provenance migration must remain separate');
assert(!service.slice(missingStart,migrationStart).includes('needsProvenanceRefresh'),
  'Missing-list startup must not wait on old-cache provenance refresh');
const migrationEnd=service.indexOf('private func rebuildIndexedRules()',migrationStart);
const migrationBody=service.slice(migrationStart,migrationEnd);
assert(migrationBody.includes('refreshJavaScriptConfiguration(reloadPages: false)'),
  'Background provenance migration must not reload active pages');
const swift=source+`
func check(_ ok:Bool,_ message:String){if !ok{fatalError(message)}}
let directory=URL(fileURLWithPath:String(decoding:Data(base64Encoded:"${Buffer.from(cache).toString('base64')}")!,as:UTF8.self))
let list="https://lists.fixture.invalid/migration.txt"
let oldJSON=#"{"version":1,"domains":[],"rules":[{"h":"","p":"/migration/ad\\\\.js","i":["news.invalid"],"x":[],"t":2,"n":0,"f":1,"a":false,"c":false,"d":false}],"unsupported":0}"#
let file=IndexedAdBlockRules.cacheURL(directory:directory,listURL:list)
let bytes=Data(oldJSON.utf8)
try bytes.write(to:file,options:.atomic)
let old=IndexedAdBlockRules.load(directory:directory,listURL:list)!
check(old.needsProvenanceRefresh,"v1 must be marked for migration")
check(IndexedAdBlockRules.applying(.ios27Scripts,to:old).rules[0].f==1,"offline old cache was widened")
check(try Data(contentsOf:file)==bytes,"loading old cache rewrote/deleted protection")
let refreshed=IndexedAdBlockRules.parse("/migration/ad.js$script,domain=news.invalid")
try IndexedAdBlockRules.store(refreshed,directory:directory,listURL:list)
let loaded=IndexedAdBlockRules.load(directory:directory,listURL:list)!
check(!loaded.needsProvenanceRefresh,"fresh provenance was not persisted")
check(IndexedAdBlockRules.applying(.ios27Scripts,to:loaded).rules[0].f==0,"refreshed iOS27 rule not corrected")
check(IndexedAdBlockRules.applying(.legacy,to:loaded).rules[0].f==1,"migration altered legacy semantics")
try Data("{}".utf8).write(to:file,options:.atomic)
check(IndexedAdBlockRules.load(directory:directory,listURL:list)==nil,"malformed cache was accepted")
let partial=#"{"version":1,"domains":[],"rules":[{"h":"bad.invalid"}],"unsupported":0}"#
try Data(partial.utf8).write(to:file,options:.atomic)
check(IndexedAdBlockRules.load(directory:directory,listURL:list)==nil,"partial rule cache was accepted")
print("PASS: v1 disk cache retained conservatively; migration marker and refreshed provenance round-trip; legacy behavior unchanged; malformed/partial caches rejected.")
`;
const run=spawnSync('swift',['-module-cache-path',directory+'/module-cache','-'],
  {input:swift,encoding:'utf8',timeout:120000,maxBuffer:2*1024*1024});
assert.equal(run.status,0,run.stderr+run.stdout);
process.stdout.write(run.stdout);
