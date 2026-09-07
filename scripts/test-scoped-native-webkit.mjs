// Independent integration check: production Swift parser/converter -> actual WKWebView.
// Local HTTP only, private stores, execution markers AND server-side request counts.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import {spawn} from 'node:child_process';

const [directory, publicFixture] = process.argv.slice(2);
assert(directory, 'Usage: node scripts/test-scoped-native-webkit.mjs TEMP_DIR [PUBLIC_NATIVE_JSON]');
const requests = new Map();
const cases = ['static', 'dynamic', 'excluded', 'third', 'cross', 'except', 'pagead', 'path', 'image-only', 'ordinary'];
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://' + req.headers.host);
  const phase = url.searchParams.get('phase') || '';
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Access-Control-Allow-Origin', '*');
  if (url.pathname === '/page') {
    res.setHeader('Content-Type', 'text/html');
    const port = server.address().port;
    const opposite = url.hostname === 'localhost' ? '127.0.0.1' : 'localhost';
    const suffix = '?phase=' + encodeURIComponent(phase);
    const tags = cases.filter(x => x !== 'dynamic').map(name => {
      const src = name === 'cross'
        ? `http://${opposite}:${port}/vortex-scope/third.js${suffix}&cross=1`
        : `/vortex-scope/${name}.js${suffix}`;
      return `<script src="${src}"></script>`;
    }).join('');
    res.end(`<html><head><script>window.runs=[];window.done=false;</script>${tags}</head><body>
      <script>let s=document.createElement('script');s.src='/vortex-scope/dynamic.js${suffix}';
      s.onload=s.onerror=()=>{window.done=true};document.head.appendChild(s);</script></body></html>`);
  } else if (url.pathname.startsWith('/vortex-scope/')) {
    const name = url.searchParams.has('cross') ? 'cross' : url.pathname.split('/').pop().replace('.js', '');
    const key = phase + ':' + name;
    requests.set(key, (requests.get(key) || 0) + 1);
    res.setHeader('Content-Type', 'application/javascript');
    res.end(`window.runs.push(${JSON.stringify(name)});`);
  } else { res.statusCode = 404; res.end(); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const port = server.address().port;
const fixture = String.raw`
/\/vortex-scope\/stat[a-z]{2}\.js/$script,domain=127.0.0.1
/\/vortex-scope\/dynam[a-z]{2}\.js/$script,domain=127.0.0.1
/vortex-scope/excluded.js$script,domain=~127.0.0.1
/vortex-scope/third.js$script,third-party,domain=127.0.0.1
/\/vortex-scope\/except\.js/$script,domain=127.0.0.1
@@/\/vortex-scope\/except\.js/$script,domain=127.0.0.1
/vortex-scope/pagead.js$domain=127.0.0.1
/vortex-scope/path.js$script
/vortex-scope/image-only.js$image,domain=127.0.0.1
ordinary$script
`;
const production = fs.readFileSync('Browser/Utilities/IndexedAdBlockRules.swift', 'utf8') + '\n'
  + fs.readFileSync('Browser/Utilities/NativeAdResourceRules.swift', 'utf8');
if (publicFixture) assert(fs.existsSync(publicFixture), 'Missing full public native fixture');
const swift = `
import AppKit
import WebKit
${production}
enum Failure: Error { case assertion(String) }
func require(_ ok: Bool, _ text: String) throws { if !ok { throw Failure.assertion(text) } }
@MainActor final class Navigation: NSObject, WKNavigationDelegate {
  var continuation: CheckedContinuation<Void, Error>?
  func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) { continuation?.resume(); continuation=nil }
  func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { continuation?.resume(throwing:error); continuation=nil }
  func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { continuation?.resume(throwing:error); continuation=nil }
  func webViewWebContentProcessDidTerminate(_ view: WKWebView) { continuation?.resume(throwing:Failure.assertion("WebContent terminated")); continuation=nil }
}
@MainActor func compile(_ json: String, _ id: String) async throws -> WKContentRuleList {
  let started=Date()
  let list: WKContentRuleList = try await withCheckedThrowingContinuation { c in
    WKContentRuleListStore.default()!.compileContentRuleList(forIdentifier:id, encodedContentRuleList:json) { value,error in
      if let value { c.resume(returning:value) } else { c.resume(throwing:error ?? Failure.assertion("compile")) }
    }
  }
  print("Compiled \\(id): \\(Int(Date().timeIntervalSince(started)*1000))ms"); fflush(stdout)
  return list
}
@MainActor func load(_ view: WKWebView, _ nav: Navigation, _ host: String, _ phase: String) async throws -> Set<String> {
  try await withCheckedThrowingContinuation { c in
    nav.continuation=c
    view.load(URLRequest(url:URL(string:"http://"+host+":${port}/page?phase="+phase)!,cachePolicy:.reloadIgnoringLocalCacheData))
  }
  for _ in 0..<100 {
    if let runs=try await view.evaluateJavaScript("window.done ? window.runs : null") as? [String] { return Set(runs) }
    try await Task.sleep(for:.milliseconds(50))
  }
  throw Failure.assertion("dynamic script completion timeout")
}
let app=NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in
  do {
    let raw=String(decoding:Data(base64Encoded:"${Buffer.from(fixture).toString('base64')}")!,as:UTF8.self)
    let document=IndexedAdBlockRules.parse(raw)
    try require(document.unsupported==0,"fixture contains unsupported syntax")
    let index=try IndexedAdBlockRules.merge([document], policy:.ios27Scripts)
    let native=try NativeAdResourceRules.make(indexJSON:index.json,preferredHosts:[])
    let list=try await compile(native.json,"vortex-scoped-independent-synthetic")
    let fixturePath=String(decoding:Data(base64Encoded:"${Buffer.from(publicFixture || '').toString('base64')}")!,as:UTF8.self)
    let full=try fixturePath.isEmpty ? Data("[]".utf8) : Data(contentsOf:URL(fileURLWithPath:fixturePath))
    let publicRules=try JSONSerialization.jsonObject(with:full) as! [[String:Any]]
    var batches:[(String,WKContentRuleList)]=[("synthetic",list)]
    if !publicRules.isEmpty {
      _=try await compile(String(decoding:full,as:UTF8.self),"vortex-scoped-independent-public")
      let controls=try JSONSerialization.jsonObject(with:Data(native.json.utf8)) as! [[String:Any]]
      let combined=try JSONSerialization.data(withJSONObject:publicRules+controls)
      batches.append(("full",try await compile(String(decoding:combined,as:UTF8.self),"vortex-scoped-independent-combined")))
    }
    let all=Set(${JSON.stringify(cases)})
    for (name,rule) in batches {
      let config=WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
      let view=WKWebView(frame:NSRect(x:0,y:0,width:800,height:600),configuration:config)
      let window=NSWindow(contentRect:view.frame,styleMask:[.titled],backing:.buffered,defer:false)
      window.contentView=view; window.orderFront(nil)
      let nav=Navigation(); view.navigationDelegate=nav
      let baseline=try await load(view,nav,"127.0.0.1",name+"-before")
      try require(baseline==all,"baseline scripts did not all execute")
      config.userContentController.add(rule)
      let protected=try await load(view,nav,"127.0.0.1",name+"-protected")
      try require(protected==Set(["ordinary","except","third","excluded","image-only"]),"same-site blocking/type/source/party mismatch: \\(protected)")
      let outside=try await load(view,nav,"localhost",name+"-outside")
      try require(outside==all.subtracting(["excluded","path"]),"scope escaped source or exclude was lost: \\(outside)")
      config.userContentController.remove(rule)
      let restored=try await load(view,nav,"127.0.0.1",name+"-removed")
      try require(restored==all,"removal did not restore scripts")
      view.navigationDelegate=nil; window.orderOut(nil)
      print("PASS execution: \\(name) static/dynamic, same-site, source exclusion, explicit third-party, exception, ordinary script, removal"); fflush(stdout)
    }
    exit(0)
  } catch { print("FAIL: \\(error)"); fflush(stdout); exit(1) }
}
app.run()
`;
try {
  const child = spawn('swift', ['-module-cache-path', directory + '/module-cache', '-'], {stdio:['pipe','pipe','pipe']});
  let output = '', errors = '';
  child.stdout.on('data', d => { output += d; process.stdout.write(d); });
  child.stderr.on('data', d => { errors += d; process.stderr.write(d); });
  const timer = setTimeout(() => child.kill('SIGKILL'), 180000);
  child.stdin.end(swift);
  const code = await new Promise((resolve,reject) => { child.on('error',reject); child.on('close',resolve); });
  clearTimeout(timer);
  assert.equal(code, 0, 'Native execution test failed: ' + errors + output);
  for (const batch of publicFixture ? ['synthetic','full'] : ['synthetic']) {
    for (const phase of ['before','protected','outside','removed']) {
      for (const name of cases) {
        const allowed = phase === 'protected' ? ['ordinary','except','third','excluded','image-only'].includes(name)
          : phase === 'outside' ? !['excluded','path'].includes(name) : true;
        assert.equal(requests.get(batch+'-'+phase+':'+name) || 0, allowed ? 1 : 0,
          'Server observed unexpected request count for '+batch+'-'+phase+':'+name);
      }
    }
  }
  console.log('PASS server counts: blocked scripts never reached HTTP server; permitted and restored scripts did. No public network requests.');
} finally { server.close(); server.closeAllConnections(); }
