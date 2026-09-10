from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from urllib.parse import urlparse
class Handler(BaseHTTPRequestHandler):
 def do_GET(self):
  path=urlparse(self.path).path
  if path=='/control.js':body=b'window.controlLoaded=true;';kind='text/javascript'
  elif path=='/ads/!rotator/banner.js':body=b'window.adLoaded=true;';kind='text/javascript'
  else:body=b'<!doctype html><title>uBlock Lite network probe</title><h2>Network filtering fixture</h2><div id="adElement" class="adsbygoogle-wrapper">Ad placeholder</div><script src="/control.js"></script><script src="/ads/!rotator/banner.js"></script>';kind='text/html'
  self.send_response(200);self.send_header('Content-Type',kind);self.send_header('Cache-Control','no-store');self.end_headers();self.wfile.write(body)
ThreadingHTTPServer(('127.0.0.1',18764),Handler).serve_forever()
