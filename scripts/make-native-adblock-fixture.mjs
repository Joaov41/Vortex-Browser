// Extract the existing native builder/parser unchanged and generate public-list probe data.
// No browser preferences, browsing history, or device containers are read.
import fs from 'node:fs';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
const [directory, output, mode = 'indexed'] = process.argv.slice(2);
assert(directory && output, 'Usage: node scripts/make-native-adblock-fixture.mjs PUBLIC_FIXTURE_DIR OUTPUT_JSON');
for (const name of ['easylist','easyprivacy']) assert(fs.existsSync(directory+'/'+name+'.txt'), 'Missing required public fixture '+name);
const source = fs.readFileSync('Browser/Services/AdBlockService.swift','utf8');
function between(start,end) {
 const a=source.indexOf(start), b=source.indexOf(end,a+start.length);
 assert(a>=0 && b>a, 'Missing extraction boundary '+start);
 return source.slice(a,b);
}
const policy=between('nonisolated enum AdBlockContentRulePolicy','@MainActor\nclass AdBlockService');
const parser=between('    nonisolated private static func parseFilterList','    private func compileCustomRules');
const targets=between('    private let adNetworkDomains: [String] = [','    private let adSelectors');
const normalize=between('    private func normalizedResourceTypes','    private func pruneOversizedRuleCaches');
const builder=between('        // Build comprehensive rules','        print("DEBUG: AdBlock attempting');
const legacyCode=`import Foundation
${policy}
struct FixtureList { var isEnabled=true; let name:String }
enum Kind { case network }
struct Fixture {
 let filterLists=[FixtureList(name:"easylist"),FixtureList(name:"easyprivacy")]
 ${targets}
 ${parser}
 ${normalize}
 func loadRuleCache(for list:FixtureList,kind:Kind)->[String]? {
  guard let raw=try? String(contentsOfFile:${JSON.stringify(directory)}+"/"+list.name+".txt",encoding:.utf8) else {return nil}
  return Array(Self.parseFilterList(raw).networkRules.prefix(5000))
 }
 func run() throws {
 ${builder}
 let data=try JSONSerialization.data(withJSONObject:limitedRules,options:[.sortedKeys])
 try data.write(to:URL(fileURLWithPath:${JSON.stringify(output)}),options:.atomic)
 print("Native fixture: \\(limitedRules.count) rules, \\(data.count) bytes")
 }
}
try Fixture().run()
`;
const code = mode === 'legacy' ? legacyCode : `import Foundation
${fs.readFileSync('Browser/Utilities/IndexedAdBlockRules.swift','utf8')}
${fs.readFileSync('Browser/Utilities/NativeAdResourceRules.swift','utf8')}
struct Fixture {
 ${targets}
 func run() throws {
  let docs = try ["easylist","easyprivacy"].map { name in
   IndexedAdBlockRules.parse(try String(contentsOfFile:${JSON.stringify(directory)}+"/"+name+".txt",encoding:.utf8))
  }
  let index = try IndexedAdBlockRules.merge(docs)
  let result = try NativeAdResourceRules.make(indexJSON:index.json,preferredHosts:adNetworkDomains)
  try Data(result.json.utf8).write(to:URL(fileURLWithPath:${JSON.stringify(output)}),options:.atomic)
  print("Native indexed fixture: \\(result.blocks) blocks, \\(result.omitted) omitted, \\(result.json.utf8.count) bytes")
 }
}
try Fixture().run()
`;
const result=spawnSync('swift',['-module-cache-path',directory+'/module-cache','-'],{input:code,encoding:'utf8',timeout:120000,maxBuffer:4*1024*1024});
process.stdout.write(result.stdout??'');process.stderr.write(result.stderr??'');
process.exit(result.status??1);
