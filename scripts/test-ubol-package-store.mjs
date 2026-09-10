// Offline checks for the uBOL package store: ZIP extraction parity, the WebKit compatibility policy,
// rule-data validation, and the stage/apply/rollback round trip. Device behavior lives in the
// `--ubol-rules-update-audit` probe. usage: node scripts/test-ubol-package-store.mjs <temp-dir>
import fs from 'node:fs';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
const directory = process.argv[2]; assert(directory, 'Pass a temporary directory');
fs.mkdirSync(directory, {recursive: true});
const code = fs.readFileSync('Browser/Utilities/ZipArchive.swift', 'utf8') + '\n' + fs.readFileSync('Browser/Services/UBOLPackageStore.swift', 'utf8') + `
func check(_ v: Bool, _ t: String) { if !v { fatalError("FAILED: " + t) } }
let official = try ZipArchive(url: URL(fileURLWithPath: "Browser/UBOLite.safari.zip"))
check(official.entries.count > 900, "official archive lists entries")
let extracted = URL(fileURLWithPath: "${directory}/extracted")
try official.extract(to: extracted)
for entry in official.entries where !entry.isDirectory {
    let data = try Data(contentsOf: extracted.appendingPathComponent(entry.path))
    check(ZipArchive.crc32(data) == entry.crc32 && data.count == entry.uncompressedSize, "extracted \\(entry.path) matches CRC")
}
let filtered = try UBOLPackageStore.applyCompatibilityPolicy(to: try official.contents(of: official.entry(named: "rulesets/main/ublock-filters.json")!), path: "ublock-filters")
check(filtered.omittedRuleIDs.sorted() == [4286, 5154, 5165], "policy omits exactly the global-scope excluded-domain block rules: \\(filtered.omittedRuleIDs)")
for name in ["easylist", "easyprivacy", "adguard-mobile"] {
    let untouched = try UBOLPackageStore.applyCompatibilityPolicy(to: try official.contents(of: official.entry(named: "rulesets/main/\\(name).json")!), path: name)
    check(untouched.omittedRuleIDs.isEmpty, "\\(name) untouched")
}
let store = UBOLPackageStore(root: URL(fileURLWithPath: "${directory}/root"))
let state = try store.prepareActivePackage(bundledArchive: URL(fileURLWithPath: "Browser/UBOLite.safari.zip"), packageVersion: "2026.907.2003")
check(state.omittedRuleIDs["ublock-filters"]?.sorted() == [4286, 5154, 5165], "active package records omissions")
let manifest = try UBOLPackageStore.readManifest(at: store.activeURL)
check(manifest.rulesets.count == 51, "manifest declares 51 rulesets")
let overlay = try UBOLPackageStore.makeOverlay(from: official, pinnedManifest: manifest, version: "2026.907.2003")
check(overlay.files.keys.allSatisfy { $0.hasPrefix("rulesets/") && $0.hasSuffix(".json") }, "overlay only contains JSON rule data")
let activeEasylist = try Data(contentsOf: store.activeURL.appendingPathComponent("rulesets/main/easylist.json"))
check(overlay.files["rulesets/main/easylist.json"] == activeEasylist, "same-release overlay is byte-identical")
func rejects(_ json: String, _ label: String) { do { try UBOLPackageStore.validateDeclarativeRules(Data(json.utf8), path: "x"); fatalError("accepted " + label) } catch {} }
rejects(#"{"a":1}"#, "non-array")
rejects(#"[{"id":1,"action":{"type":"evil"},"condition":{"urlFilter":"a"}}]"#, "unknown action")
rejects(#"[{"id":1,"action":{"type":"block"},"condition":{"urlFilter":"a"}},{"id":1,"action":{"type":"block"},"condition":{"urlFilter":"b"}}]"#, "duplicate id")
rejects(#"[{"id":1,"action":{"type":"redirect","redirect":{"extensionPath":"/../x"}},"condition":{"urlFilter":"a"}}]"#, "path traversal")
var modified = overlay; modified.version = "2026.999.0001"; modified.files["rulesets/main/adguard-mobile.json"] = Data("[]".utf8)
try store.stage(modified, digest: "abc")
let applied = try store.applyPending()
let swapped = try Data(contentsOf: store.activeURL.appendingPathComponent("rulesets/main/adguard-mobile.json"))
check(applied.rulesVersion == "2026.999.0001" && swapped == Data("[]".utf8), "apply swaps rule files")
let rolled = try store.rollback(rejecting: "2026.999.0001")
check(rolled.rulesVersion == "2026.907.2003" && rolled.appliedRulesVersion == nil && rolled.rejectedReleases == ["2026.999.0001"], "rollback restores state")
let restored = try Data(contentsOf: store.activeURL.appendingPathComponent("rulesets/main/adguard-mobile.json"))
check(restored.count > 100, "rollback restores files")
let again = try store.prepareActivePackage(bundledArchive: URL(fileURLWithPath: "Browser/UBOLite.safari.zip"), packageVersion: "2026.907.2003")
check(again == store.loadState(), "prepare is idempotent")
print("ubol package store checks passed")
`;
const run = spawnSync('swift', ['-module-cache-path', directory + '/module-cache', '-'], {input: code, encoding: 'utf8', timeout: 300000, maxBuffer: 8 * 1024 * 1024});
process.stdout.write(run.stdout || ''); process.stderr.write(run.stderr || '');
assert.equal(run.status, 0, 'swift checks failed');
