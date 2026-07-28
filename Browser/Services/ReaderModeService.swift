import Foundation

enum ReaderModeService {
    static let toggleScript: String = {
        let readability = loadReadabilitySource()
        let readerScript = """
        (function() {
          try {
            if (window.__codexReaderActive) {
              window.__codexReaderActive = false;
              var url = window.__codexReaderURL || location.href;
              if (url) { location.href = url; }
              return false;
            }

            if (typeof Readability === 'undefined') { return false; }
            var clone = document.cloneNode(true);
            var article = new Readability(clone).parse();
            if (!article || !article.content) { return false; }

            function escapeHtml(text) {
              return (text || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
            }

            var title = article.title || document.title || '';
            var byline = article.byline || '';
            var bylineHtml = byline ? '<div class="codex-reader-byline">' + escapeHtml(byline) + '</div>' : '';
            var baseHref = document.baseURI || location.href;
            var dirAttr = article.dir ? ' dir="' + article.dir + '"' : '';

            var html = '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' +
              '<base href="' + baseHref + '">' +
              '<title>' + escapeHtml(title) + '</title>' +
              '<style>body{margin:0;background:#f6f4ef;color:#1e1e1e;}@media (prefers-color-scheme: dark){body{background:#101113;color:#f2f2f2;}} .codex-reader-shell{max-width:860px;margin:0 auto;padding:32px 20px 60px;} .codex-reader-title{font-size:30px;line-height:1.2;margin:0 0 16px;} .codex-reader-byline{font-size:14px;color:#6b6b6b;margin-bottom:20px;} @media (prefers-color-scheme: dark){.codex-reader-byline{color:#a5a5a5;}} .codex-reader-article{font-size:18px;line-height:1.7;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",Helvetica,Arial,sans-serif;} .codex-reader-article img{max-width:100%;height:auto;} .codex-reader-article a{color:inherit;text-decoration:underline;} .codex-reader-article figure{margin:24px 0;} .codex-reader-article pre{white-space:pre-wrap;}</style>' +
              '</head><body><div class="codex-reader-shell"' + dirAttr + '><h1 class="codex-reader-title">' + escapeHtml(title) + '</h1>' + bylineHtml + '<article class="codex-reader-article">' + article.content + '</article></div></body></html>';

            window.__codexReaderURL = location.href;
            document.open();
            document.write(html);
            document.close();
            window.__codexReaderActive = true;
            return true;
          } catch (e) {
            return false;
          }
        })();
        """

        guard !readability.isEmpty else {
            return readerScript
        }

        return readability + "\n;" + readerScript
    }()

    private static func loadReadabilitySource() -> String {
        let bundle = Bundle.main
        let candidates: [URL?] = [
            bundle.url(forResource: "Readability", withExtension: "js"),
            bundle.url(forResource: "readability", withExtension: "js"),
            bundle.bundleURL.appendingPathComponent("Readability.js"),
            bundle.bundleURL.appendingPathComponent("readability.js")
        ]

        for url in candidates {
            guard let url else { continue }
            if let source = try? String(contentsOf: url) {
                return source
            }
        }

        return ""
    }
}
