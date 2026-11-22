import Foundation
import UIKit
import WebKit
import Testing
@testable import HermesHQNative

// Owner, 2026-11-21: bots' pages kept making the same small faults on a phone. Plain HTML gets the app's defaults
// (fields in the page's type, a checkbox kept beside its words, tinted links, long words wrapped), and a page that
// styles any of it keeps its own.
@Suite("Page defaults") @MainActor
struct PageDefaultsTests {
    private static let page = """
    <!doctype html><html><head><style>
    body{font-size:16px} .own{display:block} .small{font-size:12px} .mine{color:#c0452c}
    #narrow{width:120px}
    </style></head><body>
    <div id=narrow><label id=lab><input id=box type=checkbox checked> Breakfast included at the lodge</label></div>
    <label id=ownLabel class=own><input type=checkbox> its own block</label>
    <select id=pick><option>Find one…</option></select><button id=go>Show all</button><button id=small class=small>Tiny</button>
    <input id=field placeholder="Search">
    <a id=link href=#>A plain link</a><a id=mine class=mine href=#>its own colour</a>
    <p id=long>https://example.com/a/very/long/address/that/would/otherwise/push/the/whole/page/sideways/on/a/phone</p>
    </body></html>
    """

    private func measure(_ style: UIUserInterfaceStyle = .dark) async throws -> [String: Double] {
        let traits = UITraitCollection(userInterfaceStyle: style)
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(source: HTMLPageSheet.prelude(traits, talks: false),
                                                                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: config)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = web.frame
        window.addSubview(web)
        window.isHidden = false
        defer { window.isHidden = true }
        web.loadHTMLString(Self.page, baseURL: nil)
        for _ in 0..<80 {
            try await Task.sleep(for: .milliseconds(100))
            if (try? await web.evaluateJavaScript("document.readyState === 'complete' && !!window.__hqLegible")) as? Bool == true { break }
        }
        let read = """
        (() => { const o = {}, $ = id => document.getElementById(id), cs = id => getComputedStyle($(id)),
            n = c => (c.match(/[\\d.]+/g) || []).map(Number);
          const box = $('box').getBoundingClientRect(), r = document.createRange();
          r.selectNodeContents($('lab').lastChild); const words = r.getClientRects()[0];
          o.boxMid = (box.top + box.bottom) / 2; o.wordsTop = words.top; o.wordsBottom = words.bottom;
          o.boxRight = box.right; o.wordsLeft = words.left;
          o.labInline = cs('lab').display === 'inline-flex' ? 1 : 0; o.ownBlock = cs('ownLabel').display === 'block' ? 1 : 0;
          o.pickSize = parseFloat(cs('pick').fontSize); o.goSize = parseFloat(cs('go').fontSize);
          o.fieldSize = parseFloat(cs('field').fontSize); o.smallSize = parseFloat(cs('small').fontSize);
          o.goInkIsPage = cs('go').color === getComputedStyle(document.body).color ? 1 : 0;
          const accent = document.createElement('i'); accent.style.color = 'var(--accent)'; document.body.append(accent);
          o.linkIsAccent = cs('link').color === getComputedStyle(accent).color ? 1 : 0;
          o.boxIsAccent = cs('box').accentColor === getComputedStyle(accent).color ? 1 : 0;
          o.mineIsAccent = cs('mine').color === getComputedStyle(accent).color ? 1 : 0; accent.remove();
          o.scrollWidth = document.documentElement.scrollWidth; o.clientWidth = document.documentElement.clientWidth;
          return JSON.stringify(o) })()
        """
        let json = try #require(try await web.evaluateJavaScript(read) as? String)
        return try JSONDecoder().decode([String: Double].self, from: Data(json.utf8))
    }

    @Test func aCheckboxStaysOnTheLineOfItsWords() async throws {
        let m = try await measure()
        #expect(m["labInline"] == 1)
        let mid = try #require(m["boxMid"]), top = try #require(m["wordsTop"]), bottom = try #require(m["wordsBottom"])
        #expect(mid >= top && mid <= bottom, "the box sits beside its first line of words: \(m)")
        #expect(try #require(m["wordsLeft"]) > (try #require(m["boxRight"])), "the words wrap beside the box, not under it")
        #expect(m["ownBlock"] == 1, "a page's own label rule wins")
    }

    @Test func fieldsAndButtonsTakeThePagesTypeAndInk() async throws {
        let m = try await measure()
        #expect(m["pickSize"] == 16 && m["goSize"] == 16 && m["fieldSize"] == 16, "16, so iOS doesn't zoom: \(m)")
        #expect(m["smallSize"] == 12, "a page's own size wins")
        #expect(m["goInkIsPage"] == 1)
    }

    @Test func linksAndCheckboxesTakeTheThemesTintUnlessThePageChoseOne() async throws {
        for style in [UIUserInterfaceStyle.dark, .light] {
            let m = try await measure(style)
            #expect(m["linkIsAccent"] == 1 && m["boxIsAccent"] == 1, "\(style.rawValue): \(m)")
            #expect(m["mineIsAccent"] == 0, "the page's own link colour is kept")
        }
    }

    @Test func aLongAddressWrapsInsteadOfWideningThePage() async throws {
        let m = try await measure()
        #expect(try #require(m["scrollWidth"]) <= (try #require(m["clientWidth"])), "\(m)")
    }
}
