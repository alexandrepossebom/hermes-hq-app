// [1password-allow] The login sheet's two boxes as a page of the site itself, so the phone's password manager offers
// that site's login above the keyboard. Owner 2026-11-16, on being asked for his 1Password password to fetch a
// login: "It must be as fluid as possible. Seamless."
//
// iOS offers a saved login by the page's address. A plain text field has no address, so the keyboard showed only a
// "Passwords" key and the login had to be searched for. These boxes are a tiny local page loaded with the site's
// address as its base (nothing is fetched from the site, nothing can navigate, no storage): 1Password or Passwords
// then shows "bestbuy.com — you@example.com" above the keyboard, one tap and Face ID fills both boxes, and the sheet
// sends them on. Typing by hand still works.

import UIKit
import WebKit

@MainActor final class LoginWebFields: UIView, WKScriptMessageHandler, WKNavigationDelegate {
    /// Both boxes as they are now; `filled` when a password manager put them in at once (the sheet sends then).
    var onChange: ((_ username: String, _ password: String, _ filled: Bool) -> Void)?
    /// Return in the password box.
    var onGo: (() -> Void)?
    private let web: WKWebView
    private var loaded = false

    /// nil when the site's address isn't one a login can belong to.
    static func address(_ origin: String) -> URL? {
        guard let url = URL(string: origin.trimmingCharacters(in: .whitespaces)), url.scheme?.lowercased() == "https",
              let host = url.host(), !host.isEmpty else { return nil }
        return URL(string: "https://\(host)/")
    }

    /// The page: two boxes, no scripts but its own, nothing loaded from anywhere.
    static func page(font: CGFloat) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
        <meta name="color-scheme" content="light dark">
        <style>
        html, body { margin: 0; padding: 0; background: transparent; -webkit-text-size-adjust: none; }
        form { margin: 0; }
        input { display: block; box-sizing: border-box; width: 100%; height: 48px; margin: 0; padding: 0 16px; border: 0; border-radius: 0;
                outline: none; background: transparent; color: -apple-system-label; font: \(Int(font))px -apple-system; -webkit-appearance: none; }
        input::placeholder { color: -apple-system-tertiary-label; }
        input:-webkit-autofill { -webkit-text-fill-color: -apple-system-label; box-shadow: 0 0 0 100px transparent inset; }
        hr { margin: 0; border: 0; height: 1px; background: -apple-system-separator; transform: scaleY(0.5); }
        </style></head><body>
        <form id="f" autocomplete="on" onsubmit="return false">
        <input id="u" name="username" type="email" autocomplete="username" placeholder="you@example.com" autocapitalize="none" autocorrect="off" spellcheck="false" enterkeyhint="next">
        <hr>
        <input id="p" name="password" type="password" autocomplete="current-password" placeholder="Password" enterkeyhint="go">
        </form>
        <script>
        (function () {
          var u = document.getElementById('u'), p = document.getElementById('p'), last = {u: '', p: '', at: 0};
          function tell(filled) { window.webkit.messageHandlers.login.postMessage({u: u.value, p: p.value, filled: !!filled}); }
          function changed() {
            var now = Date.now(), jumpU = u.value.length - last.u.length > 2, jumpP = p.value.length - last.p.length > 2;
            // A password manager writes both boxes in one go; a person types a character at a time.
            var filled = u.value.length > 0 && p.value.length > 0 && jumpP && (jumpU || now - last.at < 700);
            last = {u: u.value, p: p.value, at: (jumpU || jumpP) ? now : last.at};
            tell(filled);
          }
          u.addEventListener('input', changed); p.addEventListener('input', changed);
          u.addEventListener('change', changed); p.addEventListener('change', changed);
          u.addEventListener('keydown', function (e) { if (e.key === 'Enter') { e.preventDefault(); p.focus(); } });
          p.addEventListener('keydown', function (e) { if (e.key === 'Enter') { e.preventDefault(); window.webkit.messageHandlers.login.postMessage({go: true}); } });
        })();
        </script></body></html>
        """
    }

    init(address: URL) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.suppressesIncrementalRendering = true
        web = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        configuration.userContentController.add(WeakHandler(self), name: "login")
        web.navigationDelegate = self
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.allowsLinkPreview = false
        web.accessibilityIdentifier = "prompt.login-web"
        web.translatesAutoresizingMaskIntoConstraints = false
        addSubview(web)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: topAnchor), web.bottomAnchor.constraint(equalTo: bottomAnchor),
            web.leadingAnchor.constraint(equalTo: leadingAnchor), web.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 97),
        ])
        web.loadHTMLString(Self.page(font: min(22, max(15, HQFont.preferred(.body).pointSize))), baseURL: address)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Empties both boxes (the request went).
    func clear() { web.evaluateJavaScript("document.getElementById('u').value='';document.getElementById('p').value='';") }

    // Nothing but the page itself ever loads here: no link, no form post, no redirect to the real site.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        if !loaded, action.navigationType == .other { loaded = true; return .allow }
        return .cancel
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "login", let body = message.body as? [String: Any] else { return }
        if body["go"] as? Bool == true { onGo?(); return }
        onChange?(body["u"] as? String ?? "", body["p"] as? String ?? "", body["filled"] as? Bool ?? false)
    }

    /// The page's messages without the web view keeping this view alive.
    private final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: LoginWebFields?
        init(_ target: LoginWebFields) { self.target = target }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated { target?.userContentController(controller, didReceive: message) }
        }
    }
}
