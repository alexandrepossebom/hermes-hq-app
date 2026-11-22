import Foundation
import UIKit
import WebKit
import Testing
@testable import HermesHQNative

// Owner, 2026-11-21: a page written for a white ground (navy headings, dark blue links, no background of its own)
// was navy on near-black in the dark app. Words a page leaves unreadable get an ink that reads.
@Suite("Page legibility") @MainActor
struct PageLegibilityTests {
    private static let pixel = "data:image/gif;base64,R0lGODlhAQABAIAAAP///wAAACH5BAAAAAAALAAAAAABAAEAAAICRAEAOw=="
    private static let page = """
    <html><head><style>
    h2{color:#1d3a5c} a{color:#1a4f8b} .blue{color:#4a90e2} .red{color:#c0452c}
    .card{background:#fff;color:#222} .card .faint{color:#f4f4f4}
    .pick{color:#123} .pick.on{background:#102040;color:#fff}
    .fades{color:#1d3a5c;transition:all 1s}
    .button{color:#1a4f8b;border:1px solid #1a4f8b;display:inline-block}
    .hero{position:relative;width:300px;height:80px} .hero img{width:300px;height:80px}
    .hero h3{position:absolute;top:20px;left:10px;margin:0;color:#111}
    .hero .tip{position:absolute;top:50px;left:10px;background:#111;color:#222}
    .ring{position:relative;width:140px;height:140px} .ring .mid{position:absolute;top:55px;left:50px;color:#111}
    </style></head><body>
    <h2 id=h>NORTH RIDGE TRAIL</h2><a id=a href=#>Trail website</a>
    <p id=blue class=blue>Easy</p><p id=red class=red>Steep</p><p id=bigRed class=red style="font-size:26px">Steep</p>
    <div class=card><span id=dark>fine</span> <span id=faint class=faint>faint</span></div>
    <div id=pick class=pick>Pick</div><p id=plain>plain</p><p id=pale style="color:#eee">pale</p>
    <p id=body style="color:#222">body</p><p id=note style="color:#555">note</p><p id=fades class=fades>fades</p><a id=button class=button href=#>Check the route</a>
    <svg width=100 height=30><text id=axis x=4 y=20 fill="#222">axis</text></svg>
    <svg id=forWhite width=300 height=120><line x1=20 y1=100 x2=280 y2=100 stroke="#333"/>
      <rect x=40 y=40 width=30 height=60 fill="#4a90e2"/><text id=forWhiteWords x=5 y=20 fill="#222">made for white</text></svg>
    <svg id=lightAxes width=300 height=120><line x1=20 y1=100 x2=280 y2=100 stroke="#ccc"/>
      <rect x=40 y=40 width=30 height=60 fill="#4a90e2"/><text id=lightAxesWords x=5 y=20 fill="#222">light axes</text></svg>
    <svg id=bars width=300 height=120><rect x=20 y=30 width=200 height=40 fill="#fde68a"/>
      <text id=inBar x=30 y=55 fill="#222">inside a bar</text><text id=byBar x=5 y=100 fill="#eee">beside it</text></svg>
    <div class=hero><img src="\(pixel)"><h3 id=overPicture>Over a picture</h3><span id=tip class=tip>its own dark</span></div>
    <div class=ring><svg width=140 height=140><circle cx=70 cy=70 r=55 fill="none" stroke="#4a90e2" stroke-width=14 /></svg>
      <span id=inRing class=mid>61</span></div>
    <div class=ring><svg width=140 height=140><circle cx=70 cy=70 r=55 fill="#fde68a"/></svg><span id=onDisc class=mid>39</span></div>
    <img src="\(pixel)" style="float:left;width:260px;height:60px"><p id=byFloat style="color:#111;margin:0">beside a float</p>
    <p id=aboveMap style="color:#111;margin:0;clear:both">above a map</p>
    <div style="height:60px;overflow:hidden;position:relative"><img src="\(pixel)" style="position:absolute;top:-40px;left:0;width:300px;height:140px"></div>
    </body></html>
    """

    /// The page drawn with the prelude a sheet hands it in `style`: each id's ink, `id.back` its own background and
    /// `id.edge` its top border.
    private func inks(_ style: UIUserInterfaceStyle, after script: String = "", wait: Duration = .milliseconds(600)) async throws -> [String: [Double]] {
        let traits = UITraitCollection(userInterfaceStyle: style)
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(source: HTMLPageSheet.prelude(traits, talks: false),
                                                                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), configuration: config)
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
        if !script.isEmpty {
            _ = try await web.evaluateJavaScript(script + ";0")
            try await Task.sleep(for: wait)   // the script has run again, and any fade of the page's has ended
        }
        let read = """
        (() => { const o = {}, n = c => (c.match(/[\\d.]+/g) || []).map(Number);
          for (const e of document.querySelectorAll('[id]')) { const cs = getComputedStyle(e);
            o[e.id] = n(e instanceof SVGElement ? cs.fill : cs.color).slice(0, 3);
            o[e.id + '.back'] = n(cs.backgroundColor); o[e.id + '.edge'] = n(cs.borderTopColor).slice(0, 3) }
          return JSON.stringify(o) })()
        """
        let json = try #require(try await web.evaluateJavaScript(read) as? String)
        return try JSONDecoder().decode([String: [Double]].self, from: Data(json.utf8))
    }

    private func ratio(_ a: [Double], _ b: [Double]) -> Double {
        func lum(_ c: [Double]) -> Double {
            let p = c.map { v -> Double in let s = v / 255; return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
            return 0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2]
        }
        let (x, y) = (lum(a), lum(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    private func ground(_ style: UIUserInterfaceStyle) -> [Double] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ChatPalette.page.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).getRed(&r, green: &g, blue: &b, alpha: &a)
        return [Double(r) * 255, Double(g) * 255, Double(b) * 255]
    }

    @Test func darkWordsOnTheDarkAppAreLifted() async throws {
        let inks = try await inks(.dark), back = ground(.dark)
        for id in ["h", "a", "axis", "pick", "plain", "fades", "button"] {
            #expect(ratio(try #require(inks[id]), back) >= 4.4, "\(id) reads on the app's page: \(inks[id] ?? [])")
        }
        // Still a blue, not a grey: the hue is kept.
        let h = try #require(inks["h"])
        #expect(h[2] > h[0] + 60, "navy is lifted to a blue: \(h)")
        // Made for white, they keep the contrast they had there: body text near white, a note quieter than it.
        let body = ratio(try #require(inks["body"]), back), note = ratio(try #require(inks["note"]), back)
        #expect(body >= 12 && note >= 6.5 && note <= 9.5, "body \(body), note \(note)")
        #expect(ratio(h, back) <= 8.5, "a colour is not washed out to white: \(h)")
        // Inks that already read are the page's own.
        #expect(inks["blue"] == [74, 144, 226] && inks["pale"] == [238, 238, 238])
        // A little short for body text (3.4:1): brought up to the standard, still its red.
        let red = try #require(inks["red"])
        #expect(ratio(red, back) >= 4.4 && ratio(red, back) <= 5.5 && red[0] > red[2] + 60, "\(red)")
        // The same red in large words reads at 3:1 and is the page's own.
        #expect(inks["bigRed"] == [192, 69, 44])
        // On the page's own white card: dark words stay, near-white ones are darkened.
        #expect(inks["dark"] == [34, 34, 34])
        #expect(ratio(try #require(inks["faint"]), [255, 255, 255]) >= 4.4)
        // A link drawn as a button keeps one colour: its border follows its words.
        #expect(inks["button.edge"] == inks["button"])
    }

    @Test func aLightAppLeavesTheSamePageAlone() async throws {
        let inks = try await inks(.light)
        #expect(inks["h"] == [29, 58, 92] && inks["a"] == [26, 79, 139] && inks["axis"] == [34, 34, 34])
        // A page with no background is written for white: a blue its writer chose there (3.3:1) is left as it is.
        #expect(inks["blue"] == [74, 144, 226] && inks["red"] == [192, 69, 44])
        #expect(inks["forWhite.back"]?.last == 0, "no card behind a drawing that reads")
        // The other way round: pale words made for a dark page are darkened.
        #expect(ratio(try #require(inks["pale"]), ground(.light)) >= 4.4)
    }

    @Test func aPartThatTurnsDarkGetsItsOwnInkBack() async throws {
        let inks = try await inks(.dark, after: "document.getElementById('pick').classList.add('on')")
        #expect(inks["pick"] == [255, 255, 255], "the page's white on its navy, not the ink lifted for the app's page")
    }

    /// The page's own `transition` showed the script its own ink, mid-fade, as the page's: it passed, was left, and
    /// faded back to navy.
    @Test func wordsThatFadeStayLiftedWhenThePageChanges() async throws {
        // The change comes once the first lift's own fade has ended, and is read once a fade back would have.
        let inks = try await inks(.dark, after: "setTimeout(function(){document.body.appendChild(document.createElement('i'))},1300)",
                                  wait: .milliseconds(3600))
        #expect(ratio(try #require(inks["fades"]), ground(.dark)) >= 4.4, "still lifted after another run: \(inks["fades"] ?? [])")
    }

    @Test func aDrawingMadeForWhiteKeepsItsColoursOnACard() async throws {
        let inks = try await inks(.dark), back = ground(.dark)
        // Dark words and a dark axis: a white card, every part as drawn.
        #expect(inks["forWhite.back"] == [255, 255, 255] && inks["forWhiteWords"] == [34, 34, 34])
        // Only its words are lost (the axis is light): they are lifted, no card.
        #expect(inks["lightAxes.back"]?.last == 0)
        #expect(ratio(try #require(inks["lightAxesWords"]), back) >= 4.4)
        // Dark words inside a pale bar read where they are; lifting them would lose them.
        #expect(inks["inBar"] == [34, 34, 34] && inks["byBar"] == [238, 238, 238] && inks["bars.back"]?.last == 0)
    }

    @Test func wordsOverSomethingElseAreOnlyChangedWhenItIsKnown() async throws {
        let inks = try await inks(.dark), back = ground(.dark)
        // Over a picture: what is behind them can't be known.
        #expect(inks["overPicture"] == [17, 17, 17])
        // A tooltip over the picture has its own background: judged against that.
        #expect(ratio(try #require(inks["tip"]), [17, 17, 17]) >= 4.4)
        // Over a drawing: in a ring's empty middle the page shows through; on a pale disc they read as they are.
        #expect(ratio(try #require(inks["inRing"]), back) >= 4.4)
        #expect(inks["onDisc"] == [17, 17, 17])
        // Beside a floated picture is not over it.
        #expect(ratio(try #require(inks["byFloat"]), back) >= 4.4)
        // Nor is a line above a map whose tiles run past its edge, clipped (a map page's own hint line).
        #expect(ratio(try #require(inks["aboveMap"]), back) >= 4.4)
    }
}
