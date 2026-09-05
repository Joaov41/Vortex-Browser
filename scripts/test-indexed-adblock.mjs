// Offline matcher/parser regression and benchmark. Optional public list fixtures, no user app data.
import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {performance} from 'node:perf_hooks';

const directory = process.argv[2];
assert(directory, 'Pass a temporary fixture/module-cache directory');
const parser = fs.readFileSync('Browser/Utilities/IndexedAdBlockRules.swift', 'utf8');
const fixture = `
||ads.fixture.invalid^
||scoped.fixture.invalid^$third-party,domain=news.invalid|~allowed.news.invalid
||typed.fixture.invalid^$image
||api.fixture.invalid/beacon$ping
@@||ads.fixture.invalid/allowed$xmlhttprequest
@@||exempt.news.invalid^$document
||option.fixture.invalid/track$xmlhttprequest,~third-party
||case.fixture.invalid/Track$match-case
||skip.fixture.invalid^$redirect=noop.js
||skip2.fixture.invalid^$removeparam=foo
||socket.fixture.invalid/track$websocket
/raw-regex/$script
@@||scoped.fixture.invalid/okay$domain=news.invalid
`;
const swift = parser + `
func check(_ value: Bool, _ description: String) { if !value { fatalError(description) } }
let fixture = IndexedAdBlockRules.parse(String(data: Data(base64Encoded: "${Buffer.from(fixture).toString('base64')}")!, encoding: .utf8)!)
check(fixture.unsupported == 3, "Unsupported modifiers and raw regex must not become URL patterns")
check(fixture.domains == ["ads.fixture.invalid"], "Domain classification")
let a = IndexedAdBlockRules.Document(domains: (0..<60000).map { "a\\($0).invalid" }.sorted())
let b = IndexedAdBlockRules.Document(domains: (0..<60000).map { "b\\($0).invalid" }.sorted())
let fair = try IndexedAdBlockRules.merge([a,b])
check(fair.domains == 100000 && fair.omitted == 20000, "Shared domain budget")
let fairPayload = try JSONDecoder().decode(IndexedAdBlockRules.Payload.self, from: Data(fair.json.utf8))
check(fairPayload.domains.split(separator: "\\n").filter { $0.hasPrefix("a") }.count == 50000, "First list monopolized budget")
check(fairPayload.domains.split(separator: "\\n").filter { $0.hasPrefix("b") }.count == 50000, "Second list starved")
var result: [String: Any] = ["fixture": try IndexedAdBlockRules.merge([fixture]).json, "synthetic": fair.json]
let base = ${JSON.stringify(directory)}
var real: [IndexedAdBlockRules.Document] = []
for name in ["easylist", "easyprivacy"] {
 if let content = try? String(contentsOfFile: base + "/" + name + ".txt", encoding: .utf8) {
  let start = Date(); let document = IndexedAdBlockRules.parse(content)
  result[name] = ["domains":document.domains.count,"patterns":document.rules.count,"unsupported":document.unsupported,"parseMS":Date().timeIntervalSince(start)*1000]
  real.append(document)
 }
}
if !real.isEmpty {
 let start=Date(); let snapshot=try IndexedAdBlockRules.merge(real)
 result["real"] = snapshot.json
 result["merge"] = ["domains":snapshot.domains,"patterns":snapshot.patterns,"omitted":snapshot.omitted,"bytes":snapshot.json.utf8.count,"mergeMS":Date().timeIntervalSince(start)*1000]
}
let output = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(decoding: output, as: UTF8.self))
`;
const run = spawnSync('swift', ['-module-cache-path', directory + '/module-cache', '-'], {
    input: swift, encoding: 'utf8', timeout: 120000, maxBuffer: 32 * 1024 * 1024
});
if (run.status !== 0) { console.error(run.stderr, run.stdout); process.exit(1); }
const result = JSON.parse(run.stdout);
const source = fs.readFileSync('Browser/indexed-adblock.js', 'utf8');
const create = vm.runInNewContext(source + ';createVortexRuleIndex', {URL});
const index = create(JSON.parse(result.fixture));
function decision(url, page = 'https://news.invalid/', type = 1, third = true) {
    return index.decide(new URL(url), new URL(page), type, third);
}
assert.equal(decision('https://ads.fixture.invalid/ad'), 1);
assert.equal(decision('https://sub.ads.fixture.invalid/ad'), 1);
assert.equal(decision('https://notads.fixture.invalid/ad'), 0);
assert.equal(decision('https://ads.fixture.invalid.evil.invalid/ad'), 0);
assert.equal(decision('https://ads.fixture.invalid/allowed'), -1);
assert.equal(decision('https://ads.fixture.invalid/ad', 'https://exempt.news.invalid/'), -1);
assert.equal(decision('https://scoped.fixture.invalid/ad'), 1);
assert.equal(decision('https://scoped.fixture.invalid/ad', 'https://allowed.news.invalid/'), 0);
assert.equal(decision('https://scoped.fixture.invalid/ad', 'https://other.invalid/'), 0);
assert.equal(decision('https://typed.fixture.invalid/pixel'), 0);
assert.equal(decision('https://typed.fixture.invalid/pixel', undefined, 4), 1);
assert.equal(decision('https://api.fixture.invalid/beacon', undefined, 128), 1);
assert.equal(decision('https://option.fixture.invalid/track', 'https://option.fixture.invalid/', 1, false), 1);
assert.equal(decision('https://option.fixture.invalid/track'), 0);
assert.equal(decision('https://case.fixture.invalid/track'), 0);
assert.equal(decision('https://case.fixture.invalid/Track'), 1);
assert.equal(decision('https://skip.fixture.invalid/ad'), 0);
assert.equal(decision('https://constructor/ad'), 0);
assert.equal(decision('https://toString/ad'), 0);
assert.equal(decision('wss://socket.fixture.invalid/track', undefined, 64), 1);
assert.equal(decision('wss://socket.fixture.invalid/track'), 0);
// Exhaustive binary-search membership over 100k entries, plus negative boundaries.
const largePayload = JSON.parse(result.synthetic);
const large = create(largePayload);
for (const domain of largePayload.domains.split('\n')) {
    assert.equal(large.decide(new URL('https://' + domain + '/ad'), new URL('https://page.invalid/'), 1, true), 1);
}
assert.equal(large.decide(new URL('https://z.invalid/'), new URL('https://page.invalid/'), 1, true), 0);

function benchmark(label, payload) {
    const startup = performance.now(); const matcher = create(payload);
    const initMS = performance.now()-startup;
    const page = new URL('https://news.invalid/');
    const samples = [];
    for (let round=0; round<6; round++) {
        const start=performance.now();
        for(let i=0;i<5000;i++) matcher.decide(new URL('https://clean'+i+'.invalid/assets/'+round+'.js'),page,1,true);
        samples.push((performance.now()-start)/5000);
    }
    console.log(JSON.stringify({label,initMS,perRequestMS:samples.slice(1),payloadBytes:JSON.stringify(payload).length}));
}
benchmark('100k synthetic indexed domains',largePayload);
if(result.real) benchmark('current public lists', JSON.parse(result.real));
console.log(JSON.stringify({easylist:result.easylist,easyprivacy:result.easyprivacy,merge:result.merge}));
console.log('PASS: 100k binary search, fair budget, host boundaries, exceptions, document exemptions, domain scopes, resource types, party restrictions, case sensitivity and unsupported options');

// Separate processes, identical eight-runtime workload. JavaScriptCore-only incremental footprint;
// this deliberately does NOT claim to measure iPad WebContent or full-page memory.
if (process.env.VORTEX_MEMORY_BENCH === '1' && result.real) {
    const raw = fs.readFileSync(directory+'/easylist.txt','utf8');
    const escape = s => s.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
    const patterns = raw.split(/\r?\n/).map(s=>s.trim()).filter(s=>s&&!/^[!\[]/.test(s)&&!s.startsWith('@@')&&!s.includes('#')).slice(0,5000).map(s=>{
        let prefix=''; if(s.startsWith('||')) {s=s.slice(2);prefix='^https?://([^/]*\\.)?';}
        else if(s.startsWith('|')){s=s.slice(1);prefix='^';}
        return prefix+escape(s).replaceAll('\\*','.*').replaceAll('\\^','[^a-zA-Z0-9_.%-]');
    });
    const old = `const p=${JSON.stringify(patterns)};const r=[];for(let i=0;i<p.length;i+=80)r.push(new RegExp(p.slice(i,i+80).map(p=>'(?:'+p+')').join('|'),'i'));function probe(i){return r.some(r=>r.test('https://clean'+i+'.invalid/assets/test.js'));}`;
    const fresh = source+`;const matcher=createVortexRuleIndex(${result.real});function probe(i){return matcher.decide({hostname:'clean'+i+'.invalid',href:'https://clean'+i+'.invalid/assets/test.js'},{hostname:'news.invalid',href:'https://news.invalid/'},1,true);}`;
    for(const [label,js] of [['legacy-5k-regex-model',old],['indexed-public-lists',fresh]]) {
        const program=`import Foundation
import JavaScriptCore
import Darwin
func footprint() -> UInt64 {
 var info=task_vm_info_data_t();var count=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size)
 let status=withUnsafeMutablePointer(to:&info){ p in p.withMemoryRebound(to:integer_t.self,capacity:Int(count)){task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count)}}
 return status == KERN_SUCCESS ? info.phys_footprint : 0
}
let code=String(data:Data(base64Encoded:"${Buffer.from(js).toString('base64')}")!,encoding:.utf8)!
let before=footprint();let start=Date();var contexts:[JSContext]=[]
for _ in 0..<8 {
 let context=JSContext()!; context.exceptionHandler={_,error in print("JS_ERROR",error?.toString() ?? "unknown")}
 context.evaluateScript(code);context.evaluateScript("for(let i=0;i<5000;i++)probe(i)");contexts.append(context)
}
let after=footprint()
print("MEMORY ${label} contexts=8 deltaMiB=\\(Double(after-before)/1048576) elapsedSeconds=\\(Date().timeIntervalSince(start))")
withExtendedLifetime(contexts) {}
`;
        const measured=spawnSync('swift',['-module-cache-path',directory+'/module-cache','-'],{input:program,encoding:'utf8',maxBuffer:4*1024*1024,timeout:120000});
        assert.equal(measured.status,0,measured.stderr);assert(!measured.stdout.includes('JS_ERROR'),measured.stdout);
        console.log(measured.stdout.trim());
    }
}
