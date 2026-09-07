// Production parser -> JS matcher and native conversion; public lists are optional fixtures.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import {spawnSync} from 'node:child_process';
const directory = process.argv[2];
assert(directory, 'Pass the public-list/module-cache fixture directory');
const fixture = String.raw`
/^https?:\/\/track\.example\.com\/[a-z0-9]{3,6}\.js$/$script,domain=news.example
@@/^https?:\/\/track\.example\.com\/safe\.js$/$script,domain=news.example
/\/pixel[0-9]{2}\.gif/$image,third-party
/\/Case[0-9]{2}\.js/$script,match-case,domain=news.example
`;
const rejected = [String.raw`/\/(a+)+$/`, String.raw`/\/a.*b/`,
  String.raw`/\/a[0-9]{1,64}/`, String.raw`/\/a[0-9]{65}/`,
  String.raw`/\/a(?=b)/`, String.raw`/\/a\1/`, String.raw`/\/a|b/`,
  String.raw`/\/a[0-9]{2}/$redirect=noop.js`, String.raw`/\/a[0-9]{2}/$unknown`,
  String.raw`/\/a[9-0]{2}/`, String.raw`/\/a[0-9]{2,}/`];
const production = fs.readFileSync('Browser/Utilities/IndexedAdBlockRules.swift','utf8') + '\n'
  + fs.readFileSync('Browser/Utilities/NativeAdResourceRules.swift','utf8');
const b64 = value => Buffer.from(value).toString('base64');
const swift = production + `
func check(_ value:Bool,_ message:String){if !value{fatalError(message)}}
func decode(_ value:String)->String{String(decoding:Data(base64Encoded:value)!,as:UTF8.self)}
let document=IndexedAdBlockRules.parse(decode("${b64(fixture)}"))
check(document.unsupported==0 && document.rules.count==4,"Regex fixture parsing")
check(document.rules.allSatisfy{$0.r},"Raw provenance missing")
for line in decode("${b64(rejected.join('\n'))}").split(whereSeparator:\\.isNewline) {
 check(IndexedAdBlockRules.parseRule(String(line))==nil,"Unsafe/unsupported regex accepted: \\(line)")
}
let index=try IndexedAdBlockRules.merge([document],policy:.ios27Scripts)
check(try IndexedAdBlockRules.merge([document],policy:.legacy).patterns==0,"Legacy policy gained raw regex")
let native=try NativeAdResourceRules.make(indexJSON:index.json,preferredHosts:[])
let roundTrip=try JSONDecoder().decode(IndexedAdBlockRules.Document.self,from:JSONEncoder().encode(document))
check(roundTrip.rules==document.rules && !roundTrip.needsProvenanceRefresh,"Regex cache roundtrip")
check(IndexedAdBlockRules.Document(format:2).needsProvenanceRefresh,"v2 caches must refresh for regex support")
var real:[String]=[]
var documents:[IndexedAdBlockRules.Document]=[]
for name in ["easylist","easyprivacy"] {
 let content=try String(contentsOfFile:decode("${b64(directory)}")+"/"+name+".txt",encoding:.utf8)
 documents.append(IndexedAdBlockRules.parse(content))
 for line in content.split(whereSeparator:\\.isNewline) {
  if let rule=IndexedAdBlockRules.parseRule(String(line)),rule.r{real.append(String(line))}
 }
}
let fullIndex=try IndexedAdBlockRules.merge(documents,policy:.ios27Scripts)
let payload=try JSONDecoder().decode(IndexedAdBlockRules.Payload.self,from:Data(fullIndex.json.utf8))
let retained=payload.generic.filter{$0.r}
check(retained.count==real.count,"New regex rules starved by index budget")
let fullNative=try NativeAdResourceRules.make(indexJSON:fullIndex.json,preferredHosts:[])
let nativeActions=try JSONSerialization.jsonObject(with:Data(fullNative.json.utf8)) as! [[String:Any]]
for rule in retained {
 check(nativeActions.contains{ entry in
  let trigger=entry["trigger"] as? [String:Any]
  return trigger?["url-filter"] as? String == rule.p
 },"New regex missing from native allocation")
}
print(String(decoding:try JSONSerialization.data(withJSONObject:["index":index.json,"native":native.json,"real":real]),as:UTF8.self))
`;
const run=spawnSync('swift',['-module-cache-path',directory+'/module-cache','-'],{input:swift,encoding:'utf8',timeout:120000,maxBuffer:8*1024*1024});
assert.equal(run.status,0,run.stderr+run.stdout);
const result=JSON.parse(run.stdout);
const create=vm.runInNewContext(fs.readFileSync('Browser/indexed-adblock.js','utf8')+';createVortexRuleIndex',{URL});
const index=create(JSON.parse(result.index));
const decide=(url,page='https://news.example/',type=2,third=true)=>index.decide(new URL(url),new URL(page),type,third);
assert.equal(decide('https://track.example.com/abc.js'),1);
assert.equal(decide('https://track.example.com/abcdef.js'),1);
assert.equal(decide('https://track.example.com/ab.js'),0);
assert.equal(decide('https://track.example.com/abcdefg.js'),0);
assert.equal(decide('https://track.example.com/abc.js?ordinary=1'),0,'Regex $ anchor misparsed as options');
assert.equal(decide('https://track.example.com/abc.js','https://other.example/'),0);
assert.equal(decide('https://track.example.com/abc.js',undefined,4),0);
assert.equal(decide('https://track.example.com/safe.js'),-1);
assert.equal(decide('https://news.example/Case12.js',undefined,2,false),1);
assert.equal(decide('https://news.example/case12.js',undefined,2,false),0);
assert.equal(decide('https://ads.example/pixel12.gif',undefined,4),1);
assert.equal(decide('https://news.example/pixel12.gif',undefined,4,false),0);
const rules=JSON.parse(result.native);
assert(rules.some(r=>r.action.type==='block' && new RegExp(r.trigger['url-filter']).test('https://track.example.com/abc.js')));
assert(rules.some(r=>r.action.type==='ignore-previous-rules' && new RegExp(r.trigger['url-filter']).test('https://track.example.com/safe.js')));
assert(result.real.some(line=>line.includes('invoke')),'Actual EasyList hashed script rule not supported');
assert(result.real.some(line=>line.includes('fdts')),'Actual EasyPrivacy scoped tracking rule not supported');
console.log('PASS: bounded regex matching, anchors/options, scope/type/party/case, exceptions, cache refresh, legacy exclusion and unsafe rejection.');
console.log('Newly supported public regex rules:',JSON.stringify(result.real));
