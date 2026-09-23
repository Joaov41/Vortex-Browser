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
check(state.omittedRuleIDs["regex/ublock-filters"]?.count == 8 && state.omittedRuleIDs["strictblock/ublock-filters"]?.count == 2 && state.omittedRuleIDs["strictblock/jpn-1"]?.count == 3, "regex and strict-block rules are filtered and recorded separately: \\(state.omittedRuleIDs)")
check(state.omittedRuleIDs.values.reduce(0) { $0 + $1.count } == 16, "16 rules omitted in total")
let manifest = try UBOLPackageStore.readManifest(at: store.activeURL)
check(manifest.rulesets.count == 51, "manifest declares 51 rulesets")
let overlay = try UBOLPackageStore.makeOverlay(from: official, pinnedManifest: manifest, pinnedPackageURL: store.activeURL, version: "2026.907.2003")
check(state.policyVersion == UBOLPackageStore.compatibilityPolicyVersion, "active package records policy version")
check(overlay.omittedRuleIDs == state.omittedRuleIDs, "update overlay and bundled package omit the same rules")
check(overlay.files.keys.allSatisfy { $0.hasPrefix("rulesets/") && $0.hasSuffix(".json") }, "overlay only contains JSON rule data")
let activeEasylist = try Data(contentsOf: store.activeURL.appendingPathComponent("rulesets/main/easylist.json"))
check(overlay.files["rulesets/main/easylist.json"] == activeEasylist, "same-release overlay is byte-identical")
let activeAdguard = try Data(contentsOf: store.activeURL.appendingPathComponent("rulesets/main/adguard-mobile.json"))
func rejects(_ json: String, _ label: String) { do { try UBOLPackageStore.validateDeclarativeRules(Data(json.utf8), path: "x", packageURL: store.activeURL); fatalError("accepted " + label) } catch {} }
rejects(#"{"a":1}"#, "non-array")
rejects(#"[{"id":1,"action":{"type":"evil"},"condition":{"urlFilter":"a"}}]"#, "unknown action")
rejects(#"[{"id":1,"action":{"type":"block"},"condition":{"urlFilter":"a"}},{"id":1,"action":{"type":"block"},"condition":{"urlFilter":"b"}}]"#, "duplicate id")
rejects(#"[{"id":1,"action":{"type":"redirect","redirect":{"extensionPath":"/../x"}},"condition":{"urlFilter":"a"}}]"#, "path traversal")
rejects(#"[{"id":1,"action":{"type":"redirect","redirect":{"extensionPath":"/web_accessible_resources/not-in-pinned-package.js"}},"condition":{"urlFilter":"a"}}]"#, "missing redirect target")
try UBOLPackageStore.validateDeclarativeRules(Data(#"[{"id":1,"action":{"type":"redirect","redirect":{"extensionPath":"/web_accessible_resources/noop.html"}},"condition":{"urlFilter":"a"}}]"#.utf8), path: "x", packageURL: store.activeURL)
let redirectPolicy = try UBOLPackageStore.applyCompatibilityPolicy(to: Data(#"[{"id":7,"action":{"type":"redirect","redirect":{"extensionPath":"/x"}},"condition":{"urlFilter":"a","excludedRequestDomains":["com"]}},{"id":8,"action":{"type":"redirect","redirect":{"extensionPath":"/x"}},"condition":{"urlFilter":"a","excludedRequestDomains":["com"],"initiatorDomains":["example.org"]}},{"id":9,"action":{"type":"allow"},"condition":{"urlFilter":"a","excludedRequestDomains":["com"]}}]"#.utf8), path: "x")
check(redirectPolicy.omittedRuleIDs == [7], "policy omits global-scope redirects too, keeps initiator-scoped and allow rules: \(redirectPolicy.omittedRuleIDs)")
// A failed move part-way through apply must restore the active files and keep the update pending.
let fm = FileManager.default
var partial = overlay; partial.version = "2026.998.0001"; partial.files["rulesets/main/adguard-mobile.json"] = Data("[]".utf8)
try store.stage(partial, digest: "def")
let beforeState = store.loadState()!
let blocked = store.pendingURL.appendingPathComponent("rulesets/urlskip")
try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: blocked.path)
var partialFailed = false
do { _ = try store.applyPending() } catch { partialFailed = true }
try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blocked.path)
check(partialFailed, "blocked move makes apply fail")
check(try Data(contentsOf: store.activeURL.appendingPathComponent("rulesets/main/adguard-mobile.json")) == activeAdguard, "failed apply restores moved rule files")
check(fm.fileExists(atPath: store.activeURL.appendingPathComponent("rulesets/urlskip").path), "failed apply keeps untouched directories")
check(try Data(contentsOf: store.pendingURL.appendingPathComponent("rulesets/main/adguard-mobile.json")) == Data("[]".utf8), "failed apply keeps the update pending")
check(store.loadState() == beforeState, "failed apply leaves state unchanged")
check(!fm.fileExists(atPath: store.previousURL.path), "failed apply removes its partial backup")
var modified = overlay; modified.version = "2026.999.0001"; modified.files["rulesets/main/adguard-mobile.json"] = Data("[]".utf8)
try store.stage(modified, digest: "abc")
let applied = try store.applyPending()
let swapped = try Data(contentsOf: store.activeURL.appendingPathComponent("rulesets/main/adguard-mobile.json"))
check(applied.rulesVersion == "2026.999.0001" && swapped == Data("[]".utf8), "apply swaps rule files")
// A package prepared under an older policy is re-filtered, keeping the accepted overlay.
var oldPolicy = store.loadState()!; oldPolicy.policyVersion = nil; try store.save(oldPolicy)
let refiltered = try store.prepareActivePackage(bundledArchive: URL(fileURLWithPath: "Browser/UBOLite.safari.zip"), packageVersion: "2026.907.2003")
check(refiltered.policyVersion == UBOLPackageStore.compatibilityPolicyVersion && refiltered.rulesVersion == "2026.999.0001", "policy change re-prepares and keeps applied version")
check(try Data(contentsOf: store.activeURL.appendingPathComponent("rulesets/main/adguard-mobile.json")) == Data("[]".utf8), "policy re-prepare keeps overlay files")
check(refiltered.omittedRuleIDs["ublock-filters"]?.sorted() == [4286, 5154, 5165], "policy re-prepare records omissions: \\(refiltered.omittedRuleIDs)")
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
