"""Serve a synthetic uBOL release for the DEBUG `--ubol-rules-update-audit` probe.

usage: python3 scripts/ubol-release-fixture.py <official safari.zip> <tag> <host-ip> [port]

The synthetic package is the official archive with one rule appended to rulesets/main/adguard-mobile.json
that blocks https://adblock-tester.com/head.inject*, so a successful apply is observable on the device.
GitHub's release JSON shape (tag_name, assets[].name/browser_download_url/size/digest) is reproduced.
"""
import hashlib, io, json, sys, zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

source, tag, host = sys.argv[1], sys.argv[2], sys.argv[3]
port = int(sys.argv[4]) if len(sys.argv) > 4 else 18765

buffer = io.BytesIO()
with zipfile.ZipFile(source) as original, zipfile.ZipFile(buffer, 'w', zipfile.ZIP_DEFLATED) as synthetic:
    for info in original.infolist():
        data = original.read(info.filename)
        if info.filename == 'rulesets/main/adguard-mobile.json':
            rules = json.loads(data)
            rules.append({'id': 9000001, 'priority': 1, 'action': {'type': 'block'},
                          'condition': {'urlFilter': '||adblock-tester.com/head.inject', 'resourceTypes': ['script', 'xmlhttprequest']}})
            data = json.dumps(rules, sort_keys=True).encode()
        elif info.filename == 'manifest.json':
            manifest = json.loads(data); manifest['version'] = tag; data = json.dumps(manifest, indent=1).encode()
        synthetic.writestr(info, data)
package = buffer.getvalue()
digest = hashlib.sha256(package).hexdigest()
name = f'uBOLite_{tag}.safari.zip'
latest = json.dumps({'tag_name': tag, 'assets': [{'name': name, 'size': len(package), 'digest': f'sha256:{digest}',
                                                  'browser_download_url': f'http://{host}:{port}/{name}'}]}).encode()
print(f'serving {name} ({len(package)} bytes, sha256 {digest}) at http://{host}:{port}/latest.json', flush=True)

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/latest.json': body, kind = latest, 'application/json'
        elif self.path == f'/{name}': body, kind = package, 'application/zip'
        else: self.send_response(404); self.end_headers(); return
        self.send_response(200); self.send_header('Content-Type', kind); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, fmt, *args): print(fmt % args, flush=True)

ThreadingHTTPServer(('0.0.0.0', port), Handler).serve_forever()
