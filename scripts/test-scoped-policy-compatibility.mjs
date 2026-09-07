// Compare effective legacy/iOS26 rules with the exact pre-repair checkpoint.
// Uses the same public lists for both versions, not historical test results.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {execFileSync, spawnSync} from 'node:child_process';
const directory = process.argv[2];
assert(directory, 'Pass a temporary directory containing easylist.txt and easyprivacy.txt');
const before = execFileSync('git', ['show', '5e831f8:Browser/Utilities/IndexedAdBlockRules.swift'], {encoding:'utf8'});
const after = fs.readFileSync('Browser/Utilities/IndexedAdBlockRules.swift', 'utf8');
function snapshot(source, policy) {
  const code = source + `
let directory=String(decoding:Data(base64Encoded:"${Buffer.from(directory).toString('base64')}")!,as:UTF8.self)
let documents=try ["easylist","easyprivacy"].map { name in
  IndexedAdBlockRules.parse(try String(contentsOfFile:directory+"/"+name+".txt",encoding:.utf8))
}
let result=try IndexedAdBlockRules.merge(documents${policy ? ', policy:.' + policy : ''})
print(result.json)
`;
  const run = spawnSync('swift',['-module-cache-path',directory+'/module-cache','-'],
    {input:code,encoding:'utf8',timeout:120000,maxBuffer:24*1024*1024});
  assert.equal(run.status,0,run.stderr+run.stdout);
  return JSON.parse(run.stdout);
}
function rules(payload) { return [...Object.values(payload.hosts).flat(),...payload.generic,...payload.documentExceptions]; }
function normalize(payload) {
  return {
    domains:payload.domains,
    rules:rules(payload).map(rule => {
      // Only effective matching fields, not new cache/provenance metadata.
      const entry={};
      for (const key of ['h','p','i','x','t','n','f','a','c','d']) entry[key]=rule[key];
      return JSON.stringify(entry);
    }).sort()
  };
}
const baseline=snapshot(before);
const legacy=snapshot(after,'legacy');
assert.deepEqual(normalize(legacy),normalize(baseline),'Effective iOS26/legacy rules changed');
const corrected=snapshot(after,'ios27Scripts');
const promoted=rules(corrected).filter(rule=>!rule.a && rule.f===0);
assert(promoted.length>0,'New policy did not promote any actual list rules');
assert(promoted.every(rule=>!rule.q),'Explicit party restrictions were widened');
assert.equal(corrected.domains,legacy.domains,'Broad domain first-party safety changed');
const emptySource = after + `
let empty=try IndexedAdBlockRules.merge([],policy:.ios27Scripts)
print(empty.json)
`;
const emptyRun=spawnSync('swift',['-module-cache-path',directory+'/module-cache','-'],
  {input:emptySource,encoding:'utf8',timeout:120000,maxBuffer:1024*1024});
assert.equal(emptyRun.status,0,emptyRun.stderr);
const empty=JSON.parse(emptyRun.stdout);
assert.equal(empty.domains,''); assert.equal(rules(empty).length,0,'Removed lists remained in the shared index');
console.log(`PASS: legacy/iOS26 public-list matching rules equal checkpoint (${normalize(legacy).rules.length} patterns); ${promoted.length} actual-list implicit scoped/path rules promoted only on iOS27; explicit party restrictions and domain safety retained; removing lists clears index.`);
