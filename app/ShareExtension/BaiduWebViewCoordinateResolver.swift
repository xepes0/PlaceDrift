import Foundation
import UIKit
import WebKit

final class BaiduWebViewCoordinateResolver: NSObject, WKNavigationDelegate {
    private weak var containerView: UIView?
    private var webView: WKWebView?
    private var completion: ((MapShareCoordinate?) -> Void)?
    private var finished = false
    private var pollCount = 0
    private var lastSnapshot: Snapshot?
    private var navigationErrors: [String] = []

    private(set) var diagnosticSummary = ""

    func resolve(
        _ url: URL,
        in containerView: UIView,
        completion: @escaping (MapShareCoordinate?) -> Void
    ) {
        guard !finished else { return }
        self.containerView = containerView
        self.completion = completion

        let contentController = WKUserContentController()
        contentController.addUserScript(
            WKUserScript(
                source: Self.captureScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = contentController
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        // Do not use a hidden 1×1 WKWebView here. Baidu's mobile page delays parts of
        // its POI/map bootstrap when the page has no meaningful viewport or is hidden.
        // Keep a full-size WebView in the visible hierarchy but nearly transparent and
        // non-interactive, underneath the extension UI.
        let frame = containerView.bounds.isEmpty
            ? CGRect(x: 0, y: 0, width: 390, height: 844)
            : containerView.bounds
        let webView = WKWebView(frame: frame, configuration: configuration)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        webView.alpha = 0.01
        webView.isHidden = false
        webView.isUserInteractionEnabled = false
        webView.scrollView.isScrollEnabled = false
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/24A Safari/604.1"
        containerView.insertSubview(webView, at: 0)
        self.webView = webView

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("zh-CN,zh-Hans;q=0.9,en;q=0.5", forHTTPHeaderField: "Accept-Language")
        webView.load(request)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.poll()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 16) { [weak self] in
            guard let self else { return }
            self.updateDiagnostic()
            self.finish(nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        inspect(webView)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        navigationErrors.append(error.localizedDescription)
        inspect(webView)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        navigationErrors.append(error.localizedDescription)
        inspect(webView)
    }

    private func poll() {
        guard !finished, let webView else { return }
        pollCount += 1
        inspect(webView)
        guard !finished, pollCount < 22 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            self?.poll()
        }
    }

    private func inspect(_ webView: WKWebView) {
        guard !finished else { return }
        webView.evaluateJavaScript(Self.snapshotScript) { [weak self] value, _ in
            guard let self, !self.finished else { return }
            guard let json = value as? String,
                  let data = json.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(Snapshot.self, from: data)
            else { return }

            self.lastSnapshot = payload

            if let hrefURL = URL(string: payload.href),
               let coordinate = MapShareCoordinateParser.parse(url: hrefURL) {
                self.finish(coordinate)
                return
            }

            for text in [
                payload.href,
                payload.captured,
                payload.resources,
                payload.globals,
                payload.html,
                payload.body,
            ] {
                if let coordinate = Self.parseBaiduWebText(text) {
                    self.finish(coordinate)
                    return
                }
            }

            self.updateDiagnostic()
        }
    }

    // Baidu's current mobile page does not always expose point.x / point.y as two
    // adjacent JSON fields. It may use JSONP, escaped JSON, global state objects, or
    // a response where x and y / lng and lat are separated by other metadata.
    // Normalize a few common forms and feed them back into the existing, validated
    // Baidu conversion path instead of duplicating coordinate conversion here.
    private static func parseBaiduWebText(_ raw: String) -> MapShareCoordinate? {
        guard !raw.isEmpty else { return nil }

        var candidates = [raw]
        let unescapedQuotes = raw
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "&quot;", with: "\"")
        if unescapedQuotes != raw {
            candidates.append(unescapedQuotes)
        }

        for text in candidates {
            if let coordinate = MapShareCoordinateParser.parse(
                text: text,
                providerHint: .baidu,
                allowBare: false
            ) {
                return coordinate
            }

            // BD09MC: x then y, possibly separated by other object fields.
            if let values = firstMatch(
                #"(?is)[\"']?x[\"']?\s*[:=]\s*[\"']?(-?\d{6,9}(?:\.\d+)?)[\"']?.{0,900}?[\"']?y[\"']?\s*[:=]\s*[\"']?(-?\d{6,9}(?:\.\d+)?)[\"']?"#,
                in: text
            ), let x = Double(values[1]), let y = Double(values[2]),
               let coordinate = parseMC(x: x, y: y) {
                return coordinate
            }

            // BD09MC: y then x.
            if let values = firstMatch(
                #"(?is)[\"']?y[\"']?\s*[:=]\s*[\"']?(-?\d{6,9}(?:\.\d+)?)[\"']?.{0,900}?[\"']?x[\"']?\s*[:=]\s*[\"']?(-?\d{6,9}(?:\.\d+)?)[\"']?"#,
                in: text
            ), let y = Double(values[1]), let x = Double(values[2]),
               let coordinate = parseMC(x: x, y: y) {
                return coordinate
            }

            // Some Baidu payloads carry a semantic key followed by a raw MC pair.
            if let values = firstMatch(
                #"(?is)(?:point|geo|center|location|coord|coordinate).{0,160}?(-?\d{6,9}(?:\.\d+)?)\s*[,|]\s*(-?\d{6,9}(?:\.\d+)?)"#,
                in: text
            ), let x = Double(values[1]), let y = Double(values[2]),
               let coordinate = parseMC(x: x, y: y) {
                return coordinate
            }

            // Degree-form BD-09: longitude followed by latitude.
            if let values = firstMatch(
                #"(?is)[\"']?(?:lng|longitude)[\"']?\s*[:=]\s*[\"']?(-?\d{1,3}(?:\.\d+)?)[\"']?.{0,700}?[\"']?(?:lat|latitude)[\"']?\s*[:=]\s*[\"']?(-?\d{1,2}(?:\.\d+)?)[\"']?"#,
                in: text
            ), let longitude = Double(values[1]), let latitude = Double(values[2]),
               let coordinate = parseDegrees(latitude: latitude, longitude: longitude) {
                return coordinate
            }

            // Degree-form BD-09: latitude followed by longitude.
            if let values = firstMatch(
                #"(?is)[\"']?(?:lat|latitude)[\"']?\s*[:=]\s*[\"']?(-?\d{1,2}(?:\.\d+)?)[\"']?.{0,700}?[\"']?(?:lng|longitude)[\"']?\s*[:=]\s*[\"']?(-?\d{1,3}(?:\.\d+)?)[\"']?"#,
                in: text
            ), let latitude = Double(values[1]), let longitude = Double(values[2]),
               let coordinate = parseDegrees(latitude: latitude, longitude: longitude) {
                return coordinate
            }

            // x/y can also be ordinary BD-09 degrees rather than MC meters.
            if let values = firstMatch(
                #"(?is)[\"']?x[\"']?\s*[:=]\s*[\"']?(-?\d{1,3}\.\d{4,})[\"']?.{0,500}?[\"']?y[\"']?\s*[:=]\s*[\"']?(-?\d{1,2}\.\d{4,})[\"']?"#,
                in: text
            ), let longitude = Double(values[1]), let latitude = Double(values[2]),
               let coordinate = parseDegrees(latitude: latitude, longitude: longitude) {
                return coordinate
            }
        }

        return nil
    }

    private static func parseMC(x: Double, y: Double) -> MapShareCoordinate? {
        guard abs(x) > 100_000, abs(y) > 100_000 else { return nil }
        let fake = "https://map.baidu.com/poi/placedrift/@\(x),\(y),19z"
        guard let url = URL(string: fake) else { return nil }
        return MapShareCoordinateParser.parse(url: url)
    }

    private static func parseDegrees(latitude: Double, longitude: Double) -> MapShareCoordinate? {
        guard latitude.isFinite, longitude.isFinite,
              (-90.0...90.0).contains(latitude),
              (-180.0...180.0).contains(longitude)
        else { return nil }
        let fake = "https://map.baidu.com/?location=\(latitude),\(longitude)"
        guard let url = URL(string: fake) else { return nil }
        return MapShareCoordinateParser.parse(url: url)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            let r = match.range(at: index)
            return r.location == NSNotFound ? "" : nsText.substring(with: r)
        }
    }

    private func updateDiagnostic() {
        guard let snapshot = lastSnapshot else {
            diagnosticSummary = navigationErrors.isEmpty
                ? "Baidu debug: no page snapshot"
                : "Baidu debug: no snapshot; \(navigationErrors.suffix(1).joined())"
            return
        }

        let resourceLines = snapshot.resources
            .split(separator: "\n")
            .map(String.init)
        let interesting = resourceLines.filter {
            let lower = $0.lowercased()
            return lower.contains("baidu") || lower.contains("poi") || lower.contains("detail") || lower.contains("qt=")
        }
        let sample = interesting.suffix(2)
            .map { String($0.prefix(150)) }
            .joined(separator: " | ")

        let markerSource = snapshot.captured + snapshot.globals + snapshot.html
        let lower = markerSource.lowercased()
        let markers = ["uid", "detailconinfo", "\"x\"", "\"y\"", "lng", "lat", "point"]
            .filter { lower.contains($0) }
            .joined(separator: ",")

        let href = String(snapshot.href.prefix(180))
        diagnosticSummary = "Baidu debug: href=\(href)\nmarkers=\(markers.isEmpty ? \"none\" : markers) resources=\(resourceLines.count) captured=\(snapshot.captured.count) globals=\(snapshot.globals.count)\(sample.isEmpty ? \"\" : \"\nresource=\(sample)\")"
    }

    private func finish(_ coordinate: MapShareCoordinate?) {
        guard !finished else { return }
        finished = true
        if coordinate == nil {
            updateDiagnostic()
        }
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        let completion = completion
        self.completion = nil
        completion?(coordinate)
    }

    private struct Snapshot: Decodable {
        let href: String
        let html: String
        let body: String
        let captured: String
        let resources: String
        let globals: String
    }

    private static let captureScript = #"""
    (() => {
      if (window.__placeDriftCaptureInstalled) return;
      window.__placeDriftCaptureInstalled = true;
      window.__placeDriftCaptured = [];

      const keep = (value) => {
        try {
          if (typeof value !== 'string' || value.length === 0) return;
          const list = window.__placeDriftCaptured;
          if (!Array.isArray(list) || list.length >= 96) return;
          list.push(value.slice(0, 300000));
        } catch (_) {}
      };

      try {
        const originalFetch = window.fetch;
        if (typeof originalFetch === 'function') {
          window.fetch = function(...args) {
            try { keep(String(args[0] ?? '')); } catch (_) {}
            return originalFetch.apply(this, args).then((response) => {
              try { response.clone().text().then(keep).catch(() => {}); } catch (_) {}
              return response;
            });
          };
        }
      } catch (_) {}

      try {
        const originalOpen = XMLHttpRequest.prototype.open;
        const originalSend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open = function(method, url, ...rest) {
          try { this.__placeDriftURL = String(url ?? ''); keep(this.__placeDriftURL); } catch (_) {}
          return originalOpen.call(this, method, url, ...rest);
        };
        XMLHttpRequest.prototype.send = function(...args) {
          try {
            this.addEventListener('load', function() {
              try { keep(this.__placeDriftURL || ''); } catch (_) {}
              try { keep(this.responseText || ''); } catch (_) {}
            });
          } catch (_) {}
          return originalSend.apply(this, args);
        };
      } catch (_) {}

      try {
        const push = history.pushState;
        history.pushState = function(state, title, url) {
          try { keep(String(url || '')); keep(JSON.stringify(state || {})); } catch (_) {}
          return push.apply(this, arguments);
        };
        const replace = history.replaceState;
        history.replaceState = function(state, title, url) {
          try { keep(String(url || '')); keep(JSON.stringify(state || {})); } catch (_) {}
          return replace.apply(this, arguments);
        };
      } catch (_) {}
    })();
    """#

    private static let snapshotScript = #"""
    (() => {
      try {
        const resources = (() => {
          try {
            return performance.getEntriesByType('resource')
              .map(e => String(e.name || ''))
              .filter(Boolean)
              .slice(-180)
              .join('\n')
              .slice(0, 400000);
          } catch (_) { return ''; }
        })();

        const globals = (() => {
          const out = [];
          let total = 0;
          try {
            const names = Object.getOwnPropertyNames(window);
            for (const key of names) {
              if (!/(poi|point|place|detail|map|state|data|info|geo|coord|center|location)/i.test(key)) continue;
              if (out.length >= 90 || total >= 900000) break;
              try {
                const descriptor = Object.getOwnPropertyDescriptor(window, key);
                if (!descriptor || !Object.prototype.hasOwnProperty.call(descriptor, 'value')) continue;
                const value = descriptor.value;
                if (!value || (typeof value !== 'object' && typeof value !== 'string')) continue;
                let encoded = typeof value === 'string' ? value : JSON.stringify(value);
                if (!encoded || encoded.length < 4) continue;
                encoded = String(encoded).slice(0, 180000);
                total += encoded.length;
                out.push(key + '=' + encoded);
              } catch (_) {}
            }
          } catch (_) {}
          return out.join('\n').slice(0, 900000);
        })();

        const payload = {
          href: String(location.href || ''),
          html: document.documentElement ? document.documentElement.outerHTML.slice(0, 1000000) : '',
          body: document.body ? document.body.innerText.slice(0, 220000) : '',
          captured: Array.isArray(window.__placeDriftCaptured)
            ? window.__placeDriftCaptured.join('\n').slice(0, 1600000)
            : '',
          resources,
          globals
        };
        return JSON.stringify(payload);
      } catch (_) {
        return JSON.stringify({ href: '', html: '', body: '', captured: '', resources: '', globals: '' });
      }
    })();
    """#
}
