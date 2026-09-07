// Pure builder/semantics checks; actual WebKit compilation/request checks live in the iPad probe.
import fs from 'node:fs';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
const directory=process.argv[2];assert(directory,'Pass a temporary module-cache directory');
const fixture=`
||tracker.fixture.invalid^
||allow.fixture.invalid^
@@||allow.fixture.invalid/okay$xmlhttprequest,domain=news.invalid
||case.fixture.invalid^
@@||case.fixture.invalid/Allowed$script,match-case,domain=news.invalid
||except.fixture.invalid^
@@||except.fixture.invalid/allowed$script,domain=~blocked.news.invalid
||same.fixture.invalid^
@@||same.fixture.invalid/allowed$script,~third-party
||separator.fixture.invalid^
@@||separator.fixture.invalid^*/allowed.js$script,domain=news.invalid
||first.fixture.invalid/ad.js$script,~third-party
||guard.fixture.invalid^tracking$script
||typed.fixture.invalid^$image
||scoped.fixture.invalid^$domain=news.invalid
||socket.fixture.invalid^$websocket
||twimg.com^
||openai.com^
@@||exempt.invalid^$document
@@||path-exempt.invalid/allowed/$document
|https://terminal.fixture.invalid/ad^$script
||same-site.fixture.invalid/assets/ads.js$script
||scoped-script.fixture.invalid/assets/ads.js$script,domain=news.invalid
||explicit-third.fixture.invalid/assets/ads.js$script,third-party
||explicit-first.fixture.invalid/assets/ads.js$script,~third-party
|https://anchored.fixture.invalid/vortex-scope/path.js$script
ads.js$script,domain=~news.invalid
`;
const code=fs.readFileSync('Browser/Utilities/IndexedAdBlockRules.swift','utf8')+'\n'+fs.readFileSync('Browser/Utilities/NativeAdResourceRules.swift','utf8')+`
func check(_ value:Bool,_ text:String){if !value{fatalError(text)}}
let raw=String(data:Data(base64Encoded:"${Buffer.from(fixture).toString('base64')}")!,encoding:.utf8)!
let parsed=IndexedAdBlockRules.parse(raw)
let legacyIndex=try IndexedAdBlockRules.merge([parsed])
let index=try IndexedAdBlockRules.merge([parsed],policy:.ios27Scripts)
let native=try NativeAdResourceRules.make(indexJSON:index.json,preferredHosts:[])
let legacyPayload=try JSONDecoder().decode(IndexedAdBlockRules.Payload.self,from:Data(legacyIndex.json.utf8))
let ios27Payload=try JSONDecoder().decode(IndexedAdBlockRules.Payload.self,from:Data(index.json.utf8))
func find(_ payload:IndexedAdBlockRules.Payload,_ host:String)->IndexedAdBlockRules.Rule? { payload.hosts[host]?.first }
check(find(legacyPayload,"same-site.fixture.invalid")?.f == 1,"Legacy path remains third-party")
check(find(ios27Payload,"same-site.fixture.invalid")?.f == 0,"iOS27 path is first-party eligible")
check(find(ios27Payload,"scoped-script.fixture.invalid")?.f == 0,"iOS27 source-scoped script is first-party eligible")
check(find(ios27Payload,"explicit-third.fixture.invalid")?.f == 1,"Explicit third-party remains third-party")
check(find(ios27Payload,"explicit-first.fixture.invalid")?.f == 2,"Explicit first-party remains first-party")
let genericRule = IndexedAdBlockRules.parseRule("ads.js$script")!
check(IndexedAdBlockRules.applying(.ios27Scripts,to:IndexedAdBlockRules.Document(rules:[genericRule])).rules[0].f == 1,"Unscoped generic script remains third-party")
check(ios27Payload.generic.first(where: {$0.p.contains("anchored")})?.f == 0,"Anchored URL path becomes first-party eligible")
check(ios27Payload.generic.first(where: {$0.x == ["news.invalid"]})?.f == 1,"Exclusion-only generic scope remains third-party")
let wildcardRule = IndexedAdBlockRules.parseRule("/*$script")!
check(IndexedAdBlockRules.applying(.ios27Scripts,to:IndexedAdBlockRules.Document(rules:[wildcardRule])).rules[0].f == 1,"Wildcard-only path remains third-party")
let oldRuleJSON = #"{"h":"legacy.fixture.invalid","p":"^https?://legacy.fixture.invalid/assets/ads.js","i":[],"x":[],"t":2,"n":0,"f":1,"a":false,"c":false,"d":false}"#
let migratedRule = try JSONDecoder().decode(IndexedAdBlockRules.Rule.self,from:Data(oldRuleJSON.utf8))
check(migratedRule.q,"Old cache without provenance must remain conservative")
check(IndexedAdBlockRules.applying(.ios27Scripts,to:IndexedAdBlockRules.Document(rules:[migratedRule])).rules[0].f == 1,"Old cache must retain its prior party semantics")
check(NativeAdResourceRules.supports(majorVersion:27,osBuild:"24A5430a",sdkBuild:"24A5380g"),"Verified pair")
check(!NativeAdResourceRules.supports(majorVersion:26,osBuild:"24A5430a",sdkBuild:"24A5380g"),"iOS26 must use existing path")
check(!NativeAdResourceRules.supports(majorVersion:28,osBuild:"24A5430a",sdkBuild:"24A5380g"),"Unknown major")
check(!NativeAdResourceRules.supports(majorVersion:27,osBuild:"new",sdkBuild:"24A5380g"),"Unknown OS")
check(!NativeAdResourceRules.supports(majorVersion:27,osBuild:"24A5430a",sdkBuild:nil),"Unknown SDK")
let large=try IndexedAdBlockRules.merge([IndexedAdBlockRules.Document(domains:(0..<100000).map{"host\\($0).invalid"}.sorted())])
let bounded=try NativeAdResourceRules.make(indexJSON:large.json,preferredHosts:["host99999.invalid"])
check(bounded.blocks==20000 && bounded.omitted==80000+SupplementalAdResourceRules.entries.count,"Supplement must fit the existing native budget")
let absentData=Data(bounded.json.utf8)
check(!String(decoding:absentData,as:UTF8.self).contains("adtago"),"Retention priority must not manufacture an absent endpoint")
let withEndpointDomains=(0..<100000).map{"host\\($0).invalid"}+["adtago.s3.amazonaws.com"]
let withEndpoint=try NativeAdResourceRules.make(indexJSON:try IndexedAdBlockRules.merge([IndexedAdBlockRules.Document(domains:withEndpointDomains.sorted())]).json,preferredHosts:[])
check(String(decoding:Data(withEndpoint.json.utf8),as:UTF8.self).contains("adtago"),"Indexed endpoint should be retained under the fixed budget")
var roundRobinFiller=(0..<1999).map { String(format:"||fill%04d.invalid/path.js$script,domain=scope.invalid",$0) }
roundRobinFiller.append("||zz-two.invalid/path.js^$script,domain=scope.invalid")
roundRobinFiller.append("||zzz-later.invalid/path.js$script,domain=scope.invalid")
let roundRobinIndex=try IndexedAdBlockRules.merge([IndexedAdBlockRules.parse(roundRobinFiller.joined(separator:"\\n"))],policy:.ios27Scripts)
let roundRobinNative=try NativeAdResourceRules.make(indexJSON:roundRobinIndex.json,preferredHosts:[])
let roundRobinHasTwo=roundRobinNative.json.contains("zz-two")
let roundRobinHasLater=roundRobinNative.json.contains("zzz-later")
check(roundRobinHasLater,"Round-robin must advance past an oversized candidate so a later fitting candidate can fill the final slot; blocks="+String(roundRobinNative.blocks)+", patterns="+String(roundRobinIndex.patterns)+", hasTwo="+String(roundRobinHasTwo))
check(SupplementalAdResourceRules.entries(forMajorVersion:26).isEmpty,"Supplement must not alter iOS26")
check(SupplementalAdResourceRules.entries(forMajorVersion:27).count==14,"Expected reviewed supplement")
check(SupplementalAdResourceRules.entries(forMajorVersion:28).isEmpty,"Unknown major must not inherit supplement")
var unsafeAllow=IndexedAdBlockRules.Rule();unsafeAllow.p="foo|bar";unsafeAllow.a=true
let unsafe=try IndexedAdBlockRules.merge([IndexedAdBlockRules.Document(rules:[unsafeAllow])])
do { _=try NativeAdResourceRules.make(indexJSON:unsafe.json,preferredHosts:[]);fatalError("Unsupported allow must not be dropped") }
catch NativeAdResourceRules.BuildError.unsupportedException {}
let mixedRule=IndexedAdBlockRules.parseRule("@@||mixed.fixture.invalid/allowed$script,domain=news.invalid|~blocked.news.invalid")!
do { _=try NativeAdResourceRules.exceptionRules(mixedRule);fatalError("Unsupported scope intersection must retain JS fallback") }
catch NativeAdResourceRules.BuildError.unsupportedException {}
print(native.json)
print(String(decoding:try JSONEncoder().encode(SupplementalAdResourceRules.entries),as:UTF8.self))
`;
const run=spawnSync('swift',['-module-cache-path',directory+'/module-cache','-'],{input:code,encoding:'utf8',timeout:120000,maxBuffer:8*1024*1024});
assert.equal(run.status,0,run.stderr+run.stdout);
const [rules,supplement]=run.stdout.trim().split('\n').map(line=>JSON.parse(line));
function blocked(url,page='https://news.invalid/',type='script',party='third-party',context='top-frame') {
 let result=false;
 for(const {trigger:t,action:a} of rules) {
  if(!new RegExp(t['url-filter'],t['url-filter-is-case-sensitive']?'':'i').test(url))continue;
  if(t['resource-type']&&!t['resource-type'].includes(type))continue;
  if(t['load-type']&&!t['load-type'].includes(party))continue;
  if(t['load-context']&&!t['load-context'].includes(context))continue;
  if(t['if-top-url']&&!t['if-top-url'].some(p=>new RegExp(p).test(page)))continue;
  if(t['unless-top-url']&&t['unless-top-url'].some(p=>new RegExp(p).test(page)))continue;
  if(t['if-frame-url']&&!t['if-frame-url'].some(p=>new RegExp(p).test(page)))continue;
  if(t['unless-frame-url']&&t['unless-frame-url'].some(p=>new RegExp(p).test(page)))continue;
  result=a.type==='block';
 }
 return result;
}
assert(blocked('https://tracker.fixture.invalid/ad'));
assert(blocked('https://sub.tracker.fixture.invalid/ad'));
assert(!blocked('https://nottracker.fixture.invalid/ad'));
assert(!blocked('https://tracker.fixture.invalid.evil.invalid/ad'));
assert(!blocked('https://tracker.fixture.invalid:password@ordinary.invalid/ad'));
assert(!blocked('https://tracker.fixture.invalid:123@ordinary.invalid/ad'));
assert(blocked('https://tracker.fixture.invalid:8443/ad'));
assert(!blocked('https://user:pass@tracker.fixture.invalid:8443/ad')); // Conservative native fallback; JS still has host matching.
assert(!blocked('https://tracker.fixture.invalid/ad',undefined,'document'));
assert(!blocked('https://tracker.fixture.invalid/ad',undefined,'script','third-party','child-frame'));
assert(!blocked('https://guard.fixture.invalid@ordinary.invalid/tracking'));
assert(!blocked('https://tracker.fixture.invalid/ad',undefined,'script','first-party'));
assert(blocked('https://allow.fixture.invalid/ad'));
assert(!blocked('https://allow.fixture.invalid/okay',undefined,'raw'));
assert(!blocked('https://allow.fixture.invalid/okay','https://sub.news.invalid/','raw'));
assert(blocked('https://allow.fixture.invalid/okay',undefined,'script'));
assert(blocked('https://allow.fixture.invalid/okay','https://other.invalid/','raw'));
assert(blocked('https://allow.fixture.invalid/okay','https://notnews.invalid/','raw'));
assert(!blocked('https://case.fixture.invalid/Allowed'));
assert(blocked('https://case.fixture.invalid/allowed'));
assert(blocked('https://case.fixture.invalid/Allowed',undefined,'image'));
assert(!blocked('https://except.fixture.invalid/allowed'));
assert(blocked('https://except.fixture.invalid/allowed','https://blocked.news.invalid/'));
assert(blocked('https://except.fixture.invalid/allowed','https://sub.blocked.news.invalid/'));
assert(!blocked('https://same.fixture.invalid/allowed','https://sibling.fixture.invalid/'));
assert(blocked('https://same.fixture.invalid/allowed','https://other.invalid/'));
assert(!blocked('https://separator.fixture.invalid/folder/allowed.js'));
assert(blocked('https://separator.fixture.invalid/folder/other.js'));
assert(blocked('https://separator.fixture.invalid/folder/allowed.js','https://other.invalid/'));
assert(!blocked('https://tracker.fixture.invalid/ad','https://exempt.invalid/article'));
assert(!blocked('https://tracker.fixture.invalid/ad','https://user:pass@exempt.invalid/article'));
assert(!blocked('https://tracker.fixture.invalid/ad','https://path-exempt.invalid/allowed/article'));
assert(blocked('https://tracker.fixture.invalid/ad','https://path-exempt.invalid/other/article'));
assert(blocked('https://tracker.fixture.invalid/ad','https://notexempt.invalid/'));
assert(!blocked('https://typed.fixture.invalid/pixel',undefined,'script'));
assert(blocked('https://typed.fixture.invalid/pixel',undefined,'image'));
assert(blocked('https://scoped.fixture.invalid/ad'));
assert(blocked('https://scoped.fixture.invalid/ad','https://news.invalid/'));
assert(!blocked('https://scoped.fixture.invalid/ad','https://other.invalid/'));
assert(!blocked('https://socket.fixture.invalid/ad'));
assert(blocked('https://first.fixture.invalid/ad.js',undefined,'script','first-party'));
assert(!blocked('https://first.fixture.invalid/ad.js',undefined,'script','third-party'));
assert(blocked('https://same-site.fixture.invalid/assets/ads.js',undefined,'script','first-party'));
assert(blocked('https://same-site.fixture.invalid/assets/ads.js',undefined,'script','third-party'));
assert(blocked('https://scoped-script.fixture.invalid/assets/ads.js','https://news.invalid/','script','first-party'));
assert(!blocked('https://scoped-script.fixture.invalid/assets/ads.js','https://other.invalid/','script','first-party'));
assert(blocked('https://explicit-third.fixture.invalid/assets/ads.js',undefined,'script','third-party'));
assert(!blocked('https://explicit-third.fixture.invalid/assets/ads.js',undefined,'script','first-party'));
assert(!blocked('https://explicit-first.fixture.invalid/assets/ads.js',undefined,'script','third-party'));
assert(blocked('https://explicit-first.fixture.invalid/assets/ads.js',undefined,'script','first-party'));
assert(!blocked('https://same-site.fixture.invalid/assets/ads.js',undefined,'image','first-party'));
assert(blocked('https://terminal.fixture.invalid/ad'));
assert(blocked('https://terminal.fixture.invalid/ad?key=1'));
assert(!blocked('https://terminal.fixture.invalid/advice'));
assert(!blocked('https://openai.com/asset.js'));
assert(blocked('https://twimg.com/asset.js'));
assert(!blocked('https://twimg.com/asset.js','https://x.com/home'));
for(const entry of supplement) {
 for(const type of ['raw','fetch','script','image'])assert(blocked('https://'+entry.host+'/',undefined,type),entry.host+' '+type);
 assert(!blocked('https://'+entry.host+'/',undefined,'document'),'Direct navigation '+entry.host);
 assert(!blocked('https://'+entry.host+'/',undefined,'raw','first-party'),'First-party '+entry.host);
 assert(!blocked('https://'+entry.host+'/',undefined,'raw','third-party','child-frame'),'Child-frame policy '+entry.host);
 assert(!blocked('https://not'+entry.host+'/'),'Prefix boundary '+entry.host);
 assert(!blocked('https://'+entry.host+'.ordinary.invalid/'),'Suffix boundary '+entry.host);
 assert(!blocked('https://'+entry.host+'@ordinary.invalid/'),'Credential boundary '+entry.host);
 for(const site of entry.firstPartySites) {
  assert(!blocked('https://'+entry.host+'/','https://www.'+site+'/home','raw'),'Own service '+entry.host+' from '+site);
  assert(blocked('https://'+entry.host+'/','https://'+site+'.ordinary.invalid/','raw'),'Source boundary '+site);
 }
}
for(const {trigger:t} of rules)assert(!t['url-filter'].includes('|'),'WebKit does not support disjunction');
console.log('PASS: unchanged 20k native domain budget; 14 cross-site supplements and own-service/navigation safety; scoped iOS27 party policy; host boundaries; scoped exceptions; social/essential compatibility; unsupported condition fail-safe; OS/SDK guard');
