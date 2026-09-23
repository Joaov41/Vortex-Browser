// Offline checks for the HaGeZi Pro extra blocklist: parsing, hosts left to uBOL, rule generation, and
// compilation by macOS WebKit. usage: node scripts/test-extra-blocklist.mjs <temp-dir>
import fs from 'node:fs';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
const directory = process.argv[2]; assert(directory, 'Pass a temporary directory');
fs.mkdirSync(directory, {recursive: true});
const store = fs.readFileSync('Browser/Services/ExtraBlocklistService.swift', 'utf8');
const storeOnly = store.slice(0, store.indexOf('/// HaGeZi Pro as native WebKit rules'));
const code = fs.readFileSync('Browser/Utilities/ZipArchive.swift', 'utf8') + '\n' + fs.readFileSync('Browser/Services/UBOLPackageStore.swift', 'utf8') + '\n' + storeOnly + `
import WebKit
func check(_ v: Bool, _ t: String) { if !v { fatalError("FAILED: " + t) } }
let list = try ExtraBlocklistStore.parse(Data(contentsOf: URL(fileURLWithPath: "Browser/hagezi-pro.txt")))
check(list.domains.count > 200_000 && list.version.hasPrefix("20"), "parses bundled list: \\(list.domains.count) \\(list.version)")
check(ExtraBlocklistStore.isNewer("2026.0924.0100.1", than: list.version) && !ExtraBlocklistStore.isNewer(list.version, than: list.version), "version compare")
for bad in ["[Adblock Plus]\\n! Title: Other\\n! Version: 1\\n", "[Adblock Plus]\\n! Title: HaGeZi x\\n||a.com^\\n"] {
    do { _ = try ExtraBlocklistStore.parse(Data(bad.utf8)); fatalError("accepted bad list") } catch {}
}
let rulesets = try UBOLPackageStore.defaultEnabledRulesetData(from: .archive(URL(fileURLWithPath: "Browser/UBOLite.safari.zip")))
check(rulesets.count == 3, "three default rulesets")
let left = ExtraBlocklistStore.hostsLeftToUBOL(rulesets: rulesets)
check(left.contains("doubleclick.net") && left.contains("pagead2.googlesyndication.com"), "redirect hosts are left to uBOL")
let generated = ExtraBlocklistStore.makeRuleLists(list, leaving: left)
print("domains \\(list.domains.count), blocked \\(generated.blockedDomains), left to uBOL \\(generated.leftToUBOL), lists \\(generated.json.count)")
// Evaluate the generated url-filters the way WebKit would, in list order, for sample requests.
var rules: [(NSRegularExpression, String, [String]?, [String]?)] = []
for json in generated.json {
    for rule in try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [[String: Any]] {
        let trigger = rule["trigger"] as! [String: Any], action = (rule["action"] as! [String: Any])["type"] as! String
        rules.append((try NSRegularExpression(pattern: trigger["url-filter"] as! String), action, trigger["resource-type"] as? [String], trigger["load-context"] as? [String]))
    }
    rules.append((try NSRegularExpression(pattern: "^$"), "list-end", nil, nil))
}
func blocked(_ url: String, type: String = "fetch", context: String = "child-frame") -> Bool {
    var result = false, listResult = false
    for (regex, action, types, contexts) in rules {
        if action == "list-end" { result = result || listResult; listResult = false; continue }
        if let types, !types.contains(type) { continue }
        if let contexts, !contexts.contains(context) { continue }
        guard regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil else { continue }
        listResult = action == "block"
    }
    return result
}
for host in ["c.bing.com", "gemini.yahoo.com", "log.fc.yahoo.com", "adtech.yahooinc.com", "udcm.yahoo.com", "analyticsengine.s3.amazonaws.com", "ads.microsoft.com"] {
    check(blocked("https://\\(host)/x"), "blocks \\(host)")
}
for host in ["pagead2.googlesyndication.com", "googleads.g.doubleclick.net", "stats.g.doubleclick.net", "www.facebook.com", "example.com", "notc.bing.com.example.org"] {
    check(!blocked("https://\\(host)/x"), "leaves \\(host)")
}
check(blocked("https://sub.c.bing.com:8443/p"), "blocks subdomain with port")
check(!blocked("https://c.bing.com/", type: "document", context: "top-frame"), "never blocks a page the user opens")
check(blocked("https://c.bing.com/", type: "document", context: "child-frame"), "blocks listed iframes")
let storeURL = URL(fileURLWithPath: "${directory}/rules", isDirectory: true)
try? FileManager.default.removeItem(at: storeURL); try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
let ruleStore = WKContentRuleListStore(url: storeURL)!
Task { @MainActor in
    let start = Date()
    for (index, json) in generated.json.enumerated() {
        do { _ = try await ruleStore.compileContentRuleList(forIdentifier: "t\\(index)", encodedContentRuleList: json) }
        catch { fatalError("FAILED: list \\(index) does not compile: \\(error)") }
    }
    print(String(format: "compiled \\(generated.json.count) lists in %.1f s", Date().timeIntervalSince(start)))
    print("extra blocklist checks passed"); exit(0)
}
RunLoop.main.run()
`;
fs.writeFileSync(directory + '/main.swift', code);
const build = spawnSync('swiftc', ['-O', '-module-cache-path', directory + '/mc', directory + '/main.swift', '-o', directory + '/test'], {encoding: 'utf8'});
if (build.status !== 0) { process.stderr.write(build.stderr); assert.fail('compile failed'); }
const run = spawnSync(directory + '/test', [], {encoding: 'utf8', timeout: 600000, maxBuffer: 8 * 1024 * 1024});
process.stdout.write(run.stdout || ''); process.stderr.write(run.stderr || '');
assert.equal(run.status, 0, 'swift checks failed');
