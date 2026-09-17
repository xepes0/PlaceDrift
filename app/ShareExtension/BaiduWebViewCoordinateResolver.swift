import Foundation
import UIKit
import WebKit

final class BaiduWebViewCoordinateResolver: NSObject, WKNavigationDelegate {
    private weak var containerView: UIView?
    private var webView: WKWebView?
    private var completion: ((MapShareCoordinate?) -> Void)?
    private var finished = false
    private var pollCount = 0

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

        let webView = WKWebView(frame: CGRect(x: -2, y: -2, width: 1, height: 1), configuration: configuration)
        webView.navigationDelegate = self
        webView.isHidden = true
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/24A Safari/604.1"
        containerView.addSubview(webView)
        self.webView = webView

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("zh-CN,zh-Hans;q=0.9,en;q=0.5", forHTTPHeaderField: "Accept-Language")
        webView.load(request)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.poll()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            self?.finish(nil)
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
        inspect(webView)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        inspect(webView)
    }

    private func poll() {
        guard !finished, let webView else { return }
        pollCount += 1
        inspect(webView)
        guard !finished, pollCount < 14 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
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

            if let hrefURL = URL(string: payload.href),
               let coordinate = MapShareCoordinateParser.parse(url: hrefURL) {
                self.finish(coordinate)
                return
            }

            for text in [payload.href, payload.captured, payload.html, payload.body] {
                if let coordinate = MapShareCoordinateParser.parse(
                    text: text,
                    providerHint: .baidu,
                    allowBare: false
                ) {
                    self.finish(coordinate)
                    return
                }
            }
        }
    }

    private func finish(_ coordinate: MapShareCoordinate?) {
        guard !finished else { return }
        finished = true
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
          if (!Array.isArray(list) || list.length >= 48) return;
          list.push(value.slice(0, 250000));
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
          try { this.__placeDriftURL = String(url ?? ''); } catch (_) {}
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
    })();
    """#

    private static let snapshotScript = #"""
    (() => {
      try {
        const payload = {
          href: String(location.href || ''),
          html: document.documentElement ? document.documentElement.outerHTML.slice(0, 900000) : '',
          body: document.body ? document.body.innerText.slice(0, 180000) : '',
          captured: Array.isArray(window.__placeDriftCaptured)
            ? window.__placeDriftCaptured.join('\n').slice(0, 1200000)
            : ''
        };
        return JSON.stringify(payload);
      } catch (_) {
        return JSON.stringify({ href: '', html: '', body: '', captured: '' });
      }
    })();
    """#
}
