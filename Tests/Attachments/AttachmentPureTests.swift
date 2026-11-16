import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
import Testing
import Synchronization
@testable import HermesHQNative

// Acceptance checks 1–4, 10–13 of docs/spec/1x-attachments.md §15.1: multipart bytes, the photo normaliser, safe
// names, the prompt text, retention, the remote-image policy, media layout and markdown media.

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "hqn-attach-tests-" + UUID().uuidString, directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Attachments: multipart body (§3.3, check 1)")
struct MultipartBodyTests {
    @Test func bodyIsByteExact() throws {
        let dir = tempDir()
        let source = dir.appending(path: "a.pdf")
        try Data("xyz".utf8).write(to: source)
        let built = try MultipartBody.build(source: source, destination: "/r/.dispatch-attachments/F/a.pdf", filename: "a.pdf",
                                            boundary: "hermes-B", in: dir)
        let expected = "--hermes-B\r\nContent-Disposition: form-data; name=\"path\"\r\n\r\n/r/.dispatch-attachments/F/a.pdf\r\n"
            + "--hermes-B\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\nfalse\r\n"
            + "--hermes-B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.pdf\"\r\n"
            + "Content-Type: application/octet-stream\r\n\r\nxyz\r\n--hermes-B--\r\n"
        #expect(try Data(contentsOf: built.url) == Data(expected.utf8))
        #expect(built.length == Int64(expected.utf8.count))
        #expect(built.contentType == "multipart/form-data; boundary=hermes-B")
    }

    @Test func unsafeNamesAreRefused() throws {
        let dir = tempDir()
        let source = dir.appending(path: "a.pdf")
        try Data("xyz".utf8).write(to: source)
        for bad in ["a\rb.pdf", "a\nb.pdf", "a\r\nb.pdf", "a\"b.pdf", "a\\b.pdf"] {
            #expect(throws: MultipartBody.Failure.unsafeName) {
                try MultipartBody.build(source: source, destination: "/r/x/" + bad, filename: bad, boundary: "hermes-B", in: dir)
            }
        }
    }

    /// A Windows gateway's upload folder has backslashes (a tester's screenshot was stopped by them, build 382).
    @Test func aWindowsFolderIsSent() throws {
        let dir = tempDir()
        let source = dir.appending(path: "a.png")
        try Data("xyz".utf8).write(to: source)
        let destination = #"C:\Users\Ann\.hermes\files/.dispatch-attachments/F/a.png"#
        let built = try MultipartBody.build(source: source, destination: destination, filename: "a.png", boundary: "hermes-B", in: dir)
        let body = String(decoding: try Data(contentsOf: built.url), as: UTF8.self)
        #expect(body.contains("name=\"path\"\r\n\r\n" + destination + "\r\n"))
        #expect(throws: MultipartBody.Failure.unsafeName) {
            try MultipartBody.build(source: source, destination: "C:\\x\r\ny/a.png", filename: "a.png", boundary: "hermes-B", in: dir)
        }
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func tooLargeStopsAndLeavesNoBody() throws {
        let dir = tempDir()
        let out = dir.appending(path: "bodies", directoryHint: .isDirectory)
        let source = dir.appending(path: "big.bin")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(AttachmentStaging.maxItemBytes) + 1024 * 1024)   // past the limit, whatever it is (100 MB since the tester fixes)
        try handle.close()
        #expect(throws: MultipartBody.Failure.tooLarge) {
            try MultipartBody.build(source: source, destination: "/r/x/big.bin", filename: "big.bin", boundary: "hermes-B", in: out)
        }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
        #expect(left.isEmpty)
    }
}

@Suite("Attachments: photo normaliser (§5.1, check 2)")
struct PhotoNormalizerTests {
    private func write(_ image: CGImage, type: UTType, to url: URL, properties: [CFString: Any]? = nil, frames: Int = 1) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, frames, nil) else { return false }
        for _ in 0..<frames { CGImageDestinationAddImage(dest, image, properties as CFDictionary?) }
        return CGImageDestinationFinalize(dest)
    }

    private func image(_ w: Int, _ h: Int, alpha: Bool = false, clearCorner: Bool = false) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if clearCorner { ctx.clear(CGRect(x: 0, y: 0, width: w / 2, height: h / 2)) }
        return ctx.makeImage()!
    }

    @Test func phonePhotoBecomesAMetadataFreePortraitJPEG() throws {
        let dir = tempDir()
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLatitudeRef: "N",
                                    kCGImagePropertyGPSLongitude: 122.0, kCGImagePropertyGPSLongitudeRef: "W"]
        let props: [CFString: Any] = [kCGImagePropertyOrientation: 6, kCGImagePropertyGPSDictionary: gps,
                                      kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Phone", kCGImagePropertyTIFFModel: "One"],
                                      kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:10 09:00:00"]]
        var source = dir.appending(path: "IMG_0001.heic")
        if !write(image(4032, 3024), type: .heic, to: source, properties: props) {
            source = dir.appending(path: "IMG_0001.jpg")        // no HEIC encoder here: the same photo as JPEG
            #expect(write(image(4032, 3024), type: .jpeg, to: source, properties: props))
        }
        let folder = dir.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let out = try PhotoNormalizer.normalize(source, stem: "photo", into: folder)
        #expect(out.name == "photo.jpg")
        #expect(out.typeIdentifier == UTType.jpeg.identifier)
        #expect(max(out.pixelWidth, out.pixelHeight) == 3072)
        #expect(out.pixelWidth < out.pixelHeight)                 // orientation 6 applied to the pixels
        let check = try #require(CGImageSourceCreateWithURL(out.url as CFURL, nil))
        let read = try #require(CGImageSourceCopyPropertiesAtIndex(check, 0, nil) as? [CFString: Any])
        #expect(read[kCGImagePropertyGPSDictionary] == nil)
        let tiff = read[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFMake] == nil)
        #expect(tiff?[kCGImagePropertyTIFFModel] == nil)
        let exif = read[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] == nil)
        let orientation = (read[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        #expect(orientation == 1)
    }

    @Test func transparencyKeepsPNGOpaquePNGBecomesJPEG() throws {
        let dir = tempDir()
        let clear = dir.appending(path: "clear.png"), opaque = dir.appending(path: "opaque.png")
        #expect(write(image(200, 200, alpha: true, clearCorner: true), type: .png, to: clear))
        #expect(write(image(200, 200, alpha: true), type: .png, to: opaque))
        let a = try PhotoNormalizer.normalize(clear, stem: "clear", into: dir)
        let b = try PhotoNormalizer.normalize(opaque, stem: "opaque", into: dir)
        #expect(a.name == "clear.png")
        #expect(b.name == "opaque.jpg")
    }

    @Test func animatedGIFIsCopiedUnchanged() throws {
        let dir = tempDir()
        let gif = dir.appending(path: "spin.gif")
        #expect(write(image(40, 40), type: .gif, to: gif, frames: 3))
        let folder = dir.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let out = try PhotoNormalizer.normalize(gif, stem: "spin", into: folder)
        #expect(out.name == "spin.gif")
        #expect(try Data(contentsOf: out.url) == Data(contentsOf: gif))
    }

    /// A pick of many photos normalises at most two at a time.
    @Test func thePrepGateRunsTwoAtATime() async {
        PhotoPrepGate.debugInFlight.withLock { $0.peak = 0 }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            for _ in 0..<6 {
                DispatchQueue.global(qos: .userInitiated).async(group: group) { @Sendable in PhotoPrepGate.run { Thread.sleep(forTimeInterval: 0.05) } }
            }
            group.notify(queue: .global()) { @Sendable in done.resume() }
        }
        let peak = PhotoPrepGate.debugInFlight.withLock { $0.peak }
        #expect(peak >= 1 && peak <= 2)
    }

    /// A pasted image is written and normalised off the main thread.
    @Test @MainActor func aPastedImageIsPreparedOffMain() async throws {
        let dir = tempDir()
        let png = dir.appending(path: "paste.png")
        #expect(write(image(300, 200), type: .png, to: png))
        let provider = NSItemProvider(item: try Data(contentsOf: png) as NSData, typeIdentifier: UTType.png.identifier)
        let staging = AttachmentStaging(accountId: "paste-test", base: dir)
        let id = UUID().uuidString
        let out = try await LibraryImport.loadPasted(provider, id: id, staging: staging)
        #expect(out.name == "clipboard.jpg")
        #expect(out.pixelWidth == 300)
        #expect(LibraryImport.debugPasteOnMain.withLock { $0 } == false)
    }
}

@Suite("Attachments: names, prompt text, retention (checks 3, 4, 10)")
struct AttachmentNamingTests {
    @Test func safeNamesMatchTheWebs() {
        #expect(AttachmentStaging.safeName("../x") == "x")
        #expect(AttachmentStaging.safeName("a\"b.pdf") == "ab.pdf")
        #expect(AttachmentStaging.safeName("con:trol") == "control")
        #expect(AttachmentStaging.safeName(".") == "attachment")
        #expect(AttachmentStaging.safeName("") == "attachment")
        let emoji = String(repeating: "😀", count: 75) + ".pdf"       // 300 + 4 bytes
        let safe = AttachmentStaging.safeName(emoji)
        #expect(safe.utf8.count <= 180)
        #expect(safe.hasSuffix(".pdf"))
        #expect(safe.unicodeScalars.dropLast(4).allSatisfy { $0 == "😀".unicodeScalars.first! })
    }

    @Test func promptTextTable() {
        typealias S = AttachmentSender
        #expect(S.promptText(typed: "hello", fileRefs: [], hasImages: true) == "hello")
        #expect(S.promptText(typed: "", fileRefs: [], hasImages: true) == "What do you see in this image?")
        #expect(S.promptText(typed: "  \n ", fileRefs: [], hasImages: true) == "What do you see in this image?")
        #expect(S.promptText(typed: "summarise", fileRefs: ["@file:/Users/ivy/.hermes/attachments/report.pdf"], hasImages: false)
            == "@file:/Users/ivy/.hermes/attachments/report.pdf\n\nsummarise")
        #expect(S.promptText(typed: "", fileRefs: ["@file:/a/report.pdf", "@file:`/a/My Notes.md`"], hasImages: false)
            == "@file:/a/report.pdf\n@file:`/a/My Notes.md`")
        #expect(S.promptText(typed: "look", fileRefs: ["@file:/a/report.pdf"], hasImages: true) == "@file:/a/report.pdf\n\nlook")
        #expect(S.promptText(typed: "", fileRefs: [], hasImages: false) == "")
    }

    @Test func stagedCopyReleasedTable() {
        let folder = "/r/.dispatch-attachments/F"
        #expect(AttachmentStager.stagedCopyReleased(uploaded: true, storedPath: "/home/.hermes/attachments/a.pdf", folder: folder))
        #expect(!AttachmentStager.stagedCopyReleased(uploaded: true, storedPath: folder + "/a.pdf", folder: folder))
        #expect(!AttachmentStager.stagedCopyReleased(uploaded: true, storedPath: folder, folder: folder))
        #expect(!AttachmentStager.stagedCopyReleased(uploaded: false, storedPath: "/elsewhere/a.pdf", folder: folder))
        #expect(!AttachmentStager.stagedCopyReleased(uploaded: nil, storedPath: "/elsewhere/a.pdf", folder: folder))
        #expect(!AttachmentStager.stagedCopyReleased(uploaded: true, storedPath: "", folder: folder))
    }

    @Test func sweepKeepsReferencedAndYoungFolders() throws {
        let base = tempDir()
        let staging = AttachmentStaging(accountId: "sweep-test", base: base)
        let old = UUID().uuidString, kept = UUID().uuidString, young = UUID().uuidString
        for id in [old, kept, young] { _ = try staging.write(Data("x".utf8), id: id, name: "a.txt") }
        let past = Date().addingTimeInterval(-3600)
        for id in [old, kept] {
            try FileManager.default.setAttributes([.creationDate: past, .modificationDate: past],
                                                  ofItemAtPath: staging.root.appending(path: id).path)
        }
        let removed = staging.sweep(keeping: [kept])
        #expect(removed == [old])
        #expect(FileManager.default.fileExists(atPath: staging.root.appending(path: kept).path))
        #expect(FileManager.default.fileExists(atPath: staging.root.appending(path: young).path))
        #expect(staging.url(forLocalFile: "../etc/passwd") == nil)
        #expect(staging.url(forLocalFile: "not-a-uuid/a.txt") == nil)
    }
}

@Suite("Attachments: remote images (§8.4, check 11)")
struct RemoteImagePolicyTests {
    @Test func onlyPublicHTTPSHostsAreFetched() {
        let publicResolver: (String) -> [String] = { _ in ["93.184.216.34"] }
        for refused in ["http://example.com/a.png", "https://10.0.0.1/a.png", "https://192.168.1.2/a.png", "https://172.20.0.1/a.png",
                        "https://100.100.1.1/a.png", "https://127.0.0.1/a.png", "https://[::1]/a.png", "https://[fd7a:115c:a1e0::1]/a.png",
                        "https://x.local/a.png", "https://box.tail1234.ts.net/a.png", "https://localhost/a.png"] {
            #expect(!RemoteImagePolicy.admits(URL(string: refused)!, resolver: publicResolver), "\(refused)")
        }
        #expect(RemoteImagePolicy.admits(URL(string: "https://images.example.com/a.png")!, resolver: publicResolver))
        // A public name that resolves to a private address (DNS rebinding, a redirect target) is refused too.
        #expect(!RemoteImagePolicy.admits(URL(string: "https://evil.example.com/a.png")!, resolver: { _ in ["10.1.2.3"] }))
        #expect(!RemoteImagePolicy.admits(URL(string: "https://mixed.example.com/a.png")!, resolver: { _ in ["8.8.8.8", "100.64.0.1"] }))
        #expect(RemoteImagePolicy.maxRedirects == 5)
    }

    @Test func theAsyncCheckMatchesTheBlockingOne() async {
        #expect(await RemoteImagePolicy.admitsAsync(URL(string: "https://images.example.com/a.png")!, resolver: { _ in ["93.184.216.34"] }))
        #expect(!(await RemoteImagePolicy.admitsAsync(URL(string: "https://evil.example.com/a.png")!, resolver: { _ in ["10.1.2.3"] })))
        #expect(!(await RemoteImagePolicy.admitsAsync(URL(string: "https://mixed.example.com/a.png")!, resolver: { _ in ["8.8.8.8", "100.64.0.1"] })))
        #expect(!(await RemoteImagePolicy.admitsAsync(URL(string: "https://none.example.com/a.png")!, resolver: { _ in [] })))
    }

    /// A lookup that hangs answers "timed out" (nil) by the deadline, which the fetch treats as unreachable.
    @Test func aSlowLookupTimesOut() async {
        let started = ContinuousClock.now
        let answer = await RemoteImagePolicy.admission(URL(string: "https://slow.example.com/a.png")!, timeout: .milliseconds(50),
                                                       resolver: { _ in Thread.sleep(forTimeInterval: 1); return ["93.184.216.34"] })
        #expect(answer == nil)
        #expect(ContinuousClock.now - started < .milliseconds(800))
    }

    /// Literals and refused names answer without a lookup.
    @Test func cheapChecksSkipTheLookup() async {
        let calls = Mutex(0)
        let counting: @Sendable (String) -> [String] = { _ in calls.withLock { $0 += 1 }; return ["93.184.216.34"] }
        #expect(await RemoteImagePolicy.admitsAsync(URL(string: "https://93.184.216.34/a.png")!, resolver: counting))
        #expect(!(await RemoteImagePolicy.admitsAsync(URL(string: "https://10.0.0.1/a.png")!, resolver: counting)))
        #expect(!(await RemoteImagePolicy.admitsAsync(URL(string: "http://example.com/a.png")!, resolver: counting)))
        #expect(!(await RemoteImagePolicy.admitsAsync(URL(string: "https://x.local/a.png")!, resolver: counting)))
        #expect(calls.withLock { $0 } == 0)
    }
}

@Suite("Attachments: media layout (§7.3, check 12)")
struct MediaLayoutTests {
    @Test func singlePhotoRules() {
        #expect(MediaLayout.single(width: 1200, height: 800, maxWidth: 320) == CGSize(width: 260, height: 173))
        #expect(MediaLayout.single(width: 1000, height: 3000, maxWidth: 320) == CGSize(width: 150, height: 320))   // tall: ≥ 150 wide
        #expect(MediaLayout.single(width: 3000, height: 400, maxWidth: 320) == CGSize(width: 260, height: 100))    // wide: ≥ 100 tall
        #expect(MediaLayout.single(width: nil, height: nil, maxWidth: 320) == CGSize(width: 260, height: 195))     // unknown
        #expect(MediaLayout.single(width: nil, height: nil, maxWidth: 200) == CGSize(width: 200, height: 195))
    }

    @Test func fileRowsGetRealPadding() {
        let style = ChatStyleCache.shared.style(for: .large)
        let item = FileItem(attachment: MessageAttachment(kind: .file, source: .gateway(path: "/a/report.pdf"), name: "report.pdf"),
                            index: 0, context: nil, detail: "PDF · 2.4 MB")
        let one = MediaLayout.row(item, at: .zero, width: 260, mine: true, style: style)
        #expect(one.nameLines == 1)
        #expect(one.frame.height == CGFloat(64))
        let long = FileItem(attachment: MessageAttachment(kind: .file, source: .gateway(path: "/a/x.pdf"),
                                                          name: String(repeating: "Quarterly financial report ", count: 3) + ".pdf"),
                            index: 0, context: nil, detail: "PDF")
        let two = MediaLayout.row(long, at: .zero, width: 260, mine: true, style: style)
        #expect(two.nameLines == 2)
        #expect(two.frame.height >= 12 + two.name.height + 2 + two.detail.height + 12 - 0.5)
        #expect(two.name.minY >= 12 && two.frame.height - two.detail.maxY >= 12)
    }

    @Test func generatedCardFrames() {
        let portrait = GeneratedImageInfo(source: nil, aspect: .portrait, success: true)
        #expect(MediaLayout.generated(portrait, column: 370).height == 400)                  // 9:16 capped at 400
        let square = GeneratedImageInfo(source: "/f.png", pixelWidth: 1024, pixelHeight: 1024, aspect: .landscape, success: true)
        #expect(MediaLayout.generated(square, column: 370) == CGSize(width: 320, height: 320)) // pixel size beats the hint
        let landscape = GeneratedImageInfo(source: nil, aspect: .landscape, success: true)
        #expect(MediaLayout.generated(landscape, column: 370) == CGSize(width: 320, height: 180))
    }
}

@Suite("Attachments: markdown media (§7.5, check 13)")
struct MarkdownMediaTests {
    private let style = ChatStyleCache.shared.style(for: .large)

    private func refs(_ markdown: String) -> [MediaRef]? {
        let r = MarkdownRenderer.render(markdown, style: style)
        guard r.blocks.count == 1, case .media(let refs) = r.blocks[0] else { return nil }
        return refs
    }

    @Test func mediaAloneIsABlock() throws {
        let block = try #require(refs("MEDIA:/fixture/media/result.png"))
        #expect(block.count == 1)
        #expect(block[0].kind == .image)
        #expect(block[0].attachment.source == .gateway(path: "/fixture/media/result.png"))
        #expect(refs("![chart](https://images.example.com/chart.png)")?.first?.attachment.source
            == .remote(URL(string: "https://images.example.com/chart.png")!))
        #expect(refs("![a](/p.png)")?.first?.attachment.source == .gateway(path: "/p.png"))
        #expect(refs("[notes](/x/notes.md)")?.first?.kind == .file)
        #expect(refs("MEDIA:/a/vector.svg")?.first?.kind == .file)               // svg is a file row
        #expect(MarkdownPreprocess.mediaKind("/a/vector.svg") == "File")
    }

    @Test func mediaLineInsideTextIsItsOwnParagraph() throws {
        let r = MarkdownRenderer.render("Here you go:\nMEDIA:/fixture/media/result.png\nAnd the data: MEDIA:/fixture/media/data.csv", style: style)
        #expect(r.blocks.count == 3)
        guard r.blocks.count == 3, case .media(let refs) = r.blocks[1], case .text(let tail) = r.blocks[2] else {
            Issue.record("blocks: \(r.blocks.count)")
            return
        }
        #expect(refs.first?.kind == .image)
        // Inline: a glyph, then the name as a link to the media.
        #expect(tail.string.contains("data.csv"))
        #expect(!tail.string.contains("File: "))
        var link: URL?
        tail.enumerateAttribute(.chatLink, in: NSRange(location: 0, length: tail.length)) { value, _, _ in if let u = value as? URL { link = u } }
        let url = try #require(link)
        #expect(MarkdownMedia.ref(fromLink: url)?.attachment.source == .gateway(path: "/fixture/media/data.csv"))
        var glyph = false
        tail.enumerateAttribute(.attachment, in: NSRange(location: 0, length: tail.length)) { value, _, _ in if value != nil { glyph = true } }
        #expect(glyph)
    }

    @Test func ordinaryLinksStayLinks() {
        let r = MarkdownRenderer.render("See [docs](https://example.com/docs) for more.", style: style)
        #expect(r.blocks.count == 1)
        guard case .text(let t)? = r.blocks.first else { Issue.record("not text"); return }
        var link: URL?
        t.enumerateAttribute(.chatLink, in: NSRange(location: 0, length: t.length)) { value, _, _ in if let u = value as? URL { link = u } }
        #expect(link?.absoluteString == "https://example.com/docs")
    }
}

// A pasted phone screenshot with words: the bubble isn't a 150 pt sliver, and the stored row's plugin steer stays hidden.
@MainActor
struct CaptionedScreenshotTests {
    let style = ChatStyle.make(category: .large)

    private func layout(_ text: String, width px: Int = 1179, height ph: Int = 2556) -> BubbleLayout? {
        var a = MessageAttachment(kind: .image, source: .gateway(path: "/tmp/shot.jpg"), name: "shot.jpg")
        a.pixelWidth = px
        a.pixelHeight = ph
        var b = BubbleRow(mine: true, text: text, markdown: false, partIndex: 0, joinsAbove: false, joinsBelow: false,
                          tail: true, time: nil, pending: false, streaming: false)
        b.media = [MediaItem(attachment: a, index: 0, context: nil, label: "Photo")]
        let row = ChatRow(id: "m1|b0", messageId: "m1", scope: "acct|default|s1",
                          fingerprint: ChatRowBuilder.bubbleFingerprint(text, mine: true, speaker: nil),
                          kind: .bubble(b), gapAbove: 6, variant: 0)
        guard case .bubble(let box) = AttachmentBubbleLayout.bubble(b, row: row, width: 402, style: style, keep: false).content
        else { return nil }
        return box
    }

    @Test func longCaptionWidensATallPhoto() throws {
        let box = try #require(layout("This is what I see in the app, and it wraps over a few lines at least"))
        #expect(box.frame.width == 260)
        #expect(box.mediaGroups.first?.fits == true)
        #expect(box.mediaGroups.first?.tiles.first?.frame.size == CGSize(width: 260, height: 320))
    }

    @Test func photoAloneOrShortCaptionKeepsItsShape() throws {
        let alone = try #require(layout(""))
        #expect(alone.frame.width == 150)
        #expect(alone.mediaGroups.first?.fits == false)
        let short = try #require(layout("Hi"))
        #expect(short.frame.width == 150)
        let wide = try #require(layout("This is a landscape photo with a long caption under it", width: 1600, height: 900))
        #expect(wide.mediaGroups.first?.fits == false)
    }

    @Test func pluginSteerAndMemoryLeaveTheStoredRow() {
        let steer = "(Hermes HQ: for websites use your own browser tools (browser_exec). Sign in yourself.)"
        let memory = "<memory-context>\n[System note: recalled]\n\n- likes tea\n</memory-context>"
        #expect(Hydration.strippingTurnContext("This is what I see\n[screenshot]\n" + steer) == "This is what I see\n[screenshot]")
        #expect(Hydration.strippingTurnContext("Look\n" + memory + "\n\n" + steer) == "Look")
        #expect(Hydration.strippingTurnContext("My note (Hermes HQ: is great)") == "My note (Hermes HQ: is great)")   // mid-line: theirs
        #expect(Hydration.strippingTurnContext("Plain words") == "Plain words")
        let rows: [JSONValue] = [.object(["role": "user", "id": 1, "timestamp": 1,
                                          "content": .string("This is what I see\n\n[Image attached at: /tmp/a.jpg]\n[screenshot]\n" + steer)])]
        let folded = Hydration.fold(rows, pageSeq: 1)
        let shown = folded.messages.first?.parts.compactMap { part -> String? in if case .text(let t) = part { t } else { nil } }
            .joined() ?? ""
        #expect(!shown.contains("Hermes HQ:"))
        #expect(shown.contains("This is what I see"))
    }
}

/// [mac] Drag and drop and Finder paste: what attaches, what stays text, and the copy that leaves the original alone.
@Suite("Attachments: drop and file paste")
struct AttachmentDropTests {
    @Test func whatAttaches() {
        #expect(AttachmentDrop.fileType(["public.file-url", "public.utf8-plain-text"]) == "public.file-url")
        #expect(AttachmentDrop.fileType(["com.adobe.pdf"]) == "com.adobe.pdf")
        #expect(AttachmentDrop.fileType(["public.png"]) == "public.png")
        #expect(AttachmentDrop.fileType(["public.utf8-plain-text"]) == nil, "text stays the field's")
        #expect(AttachmentDrop.fileType(["public.url", "public.utf8-plain-text"]) == nil, "a link stays the field's")
        // [mac] A file dragged from the Finder reaches a Catalyst app as its own type alone (measured 2026-11-07: a .txt
        // as public.plain-text, a .png as public.png); a text snippet always carries a UTF-8 or UTF-16 flavour.
        #expect(AttachmentDrop.fileType(["public.plain-text"]) == "public.plain-text", "a dragged .txt")
        #expect(AttachmentDrop.fileType(["public.html"]) == "public.html", "a dragged .html")
        #expect(AttachmentDrop.fileType(["public.html", "public.utf8-plain-text"]) == nil, "a rich text selection")
        #expect(AttachmentDrop.fileType(["public.rtf", "public.utf16-external-plain-text"]) == nil)
    }

    @Test func whatTheMessageFieldAttaches() {
        #expect(AttachmentDrop.isFile(["public.file-url"]))
        #expect(AttachmentDrop.isFile(["public.plain-text"]), "a dragged .txt attaches, not its contents typed in")
        #expect(AttachmentDrop.isFile(["com.adobe.pdf"]))
        #expect(!AttachmentDrop.isFile(["public.png"]), "a picture is the picture paste's")
        #expect(!AttachmentDrop.isFile(["public.utf8-plain-text"]), "text is typed in")
    }

    @Test func whenAPasteIsFiles() {
        // A Finder copy: the file URL, its name as text and its icon as a picture.
        #expect(AttachmentDrop.pastesFiles(types: [["public.file-url", "public.utf8-plain-text", "public.tiff"]], hasStrings: true))
        // A copy in Files: the file alone.
        #expect(AttachmentDrop.pastesFiles(types: [["com.adobe.pdf"]], hasStrings: false))
        // A screenshot is the picture paste's, and copied text is text.
        #expect(!AttachmentDrop.pastesFiles(types: [["public.png"]], hasStrings: false))
        #expect(!AttachmentDrop.pastesFiles(types: [["public.utf8-plain-text"]], hasStrings: true))
    }

    @Test func names() {
        let file = URL(fileURLWithPath: "/tmp/x/abc.png")
        #expect(AttachmentDrop.name("Screenshot", file: file, type: "public.png") == "Screenshot.png")
        #expect(AttachmentDrop.name("Report.pdf", file: file, type: "com.adobe.pdf") == "Report.pdf")
        #expect(AttachmentDrop.name(nil, file: file, type: "public.png") == "abc.png")
    }

    @Test func aDroppedFileIsCopiedAndTheOriginalKept() async throws {
        let dir = tempDir()
        let original = dir.appending(path: "notes.pdf")
        try Data("%PDF-1.4 hello".utf8).write(to: original)
        for provider in [NSItemProvider(object: original as NSURL), try #require(NSItemProvider(contentsOf: original))] {
            let copy = try await AttachmentDrop.copyOut(provider)
            #expect(copy.lastPathComponent.hasSuffix(".pdf"))
            #expect(try Data(contentsOf: copy) == Data("%PDF-1.4 hello".utf8))
            #expect(copy.deletingLastPathComponent() != dir)
            try FileManager.default.removeItem(at: copy.deletingLastPathComponent())
            #expect(FileManager.default.fileExists(atPath: original.path), "the original is never touched")
        }
        try? FileManager.default.removeItem(at: dir)
    }
}

@Suite("Attachments: upload refusals say the gateway's reason")
struct UploadRefusalTests {
    @Test func a400ShowsTheGatewaysDetail() {
        let body = #"{"detail":"Invalid Host header. Dashboard requests must use the bound hostname or the configured public hostname."}"#
        let error = AttachmentStager.map(HTTPError(status: 400, body: body), name: "Screenshot.png", reading: false)
        #expect(error as? AttachmentUploadError == AttachmentUploadError(kind: .final, reason:
            "Your gateway refused “Screenshot.png”: Invalid Host header. Dashboard requests must use the bound hostname or the configured public hostname."))
    }

    /// Audit 14-6: reading the upload folder, a gateway restarting (502) is worth a retry and a 401 a session ended;
    /// only "not there" is no folder.
    @Test func readingTheFolderTellsAMissingOneFromAPassingError() {
        func kind(_ status: Int) -> AttachmentUploadError.Kind? {
            (AttachmentStager.map(HTTPError(status: status, body: nil), name: "", reading: true) as? AttachmentUploadError)?.kind
        }
        #expect(AttachmentStager.map(HTTPError(status: 404, body: nil), name: "", reading: true) as? AttachmentUploadError == .noFolder)
        #expect(kind(403) == .final)
        #expect(kind(502) == .retryable && kind(500) == .retryable && kind(429) == .retryable)
        #expect(kind(401) == .sessionEnded)
    }

    @Test func a400WithoutADetailSaysTheStatusNotTheName() {
        for body in [nil, "", "<html>Bad Request</html>", #"{"detail":"  "}"#] {
            let error = AttachmentStager.map(HTTPError(status: 400, body: body), name: "a.png", reading: false)
            #expect((error as? AttachmentUploadError)?.reason == "Your gateway refused “a.png” (HTTP 400).")
        }
    }
}

@Suite("Attachments: a failed tile's Try Again")
struct FailedTileRetryTests {
    private func tile(_ upload: DraftAttachment.Upload) -> DraftAttachment {
        DraftAttachment(id: "a", kind: .image, name: "a.png", localFile: "a/a.png", byteSize: 3, pixelWidth: 30, pixelHeight: 40,
                        typeIdentifier: "public.png", upload: upload)
    }

    @Test func aFinalRefusalOffersOnlyRemove() {
        #expect(tile(.failed(reason: AttachmentUploadError.connection("a.png").reason, retryable: true)).offersRetry)
        #expect(!tile(.failed(reason: AttachmentUploadError.tooBig("a.png").reason, retryable: false)).offersRetry)
        #expect(!tile(.failed(reason: AttachmentUploadError.badName.reason, retryable: false)).offersRetry)
        // The gateway's owner can add the upload folder meanwhile.
        #expect(tile(.failed(reason: AttachmentUploadError.noFolder.reason, retryable: false)).offersRetry)
        #expect(!tile(.waiting).offersRetry)
    }
}

@Suite("Attachments: a Windows gateway's paths")
struct WindowsGatewayPathTests {
    /// The gateway answers with backslashes for a folder the app named with slashes: a copy still inside it stays.
    @Test func aCopyInsideTheStagingFolderStays() {
        let folder = #"C:\Users\Ann\.hermes\files/.dispatch-attachments/F"#
        #expect(!AttachmentStager.stagedCopyReleased(uploaded: true, storedPath: #"C:\Users\Ann\.hermes\files\.dispatch-attachments\F\a.png"#, folder: folder))
        #expect(AttachmentStager.stagedCopyReleased(uploaded: true, storedPath: #"C:\Users\Ann\.hermes\uploads\a.png"#, folder: folder))
        #expect(!MemoUploader.stagedCopyReleased(uploaded: true, storedPath: #"C:\Users\Ann\.hermes\files\.dispatch-attachments\F\m.m4a"#, folder: folder))
    }
}

// Owner 2026-11-16: the swipe-through pile showed several photos "tiny" and was "hard to get through"; a grid across
// the chat's width, "+N" on its last tile, and a tap opens them swipeable (the viewer).
@MainActor
@Suite("Attachments: photo grids")
struct PhotoGridTests {
    let style = ChatStyle.make(category: .large)
    static let phone = (1179, 2556), mac = (2560, 1600), square = (1200, 1200)

    private func photo(_ name: String, _ w: Int?, _ h: Int?, index: Int = 0) -> MediaItem {
        var a = MessageAttachment(kind: .image, source: .gateway(path: "/tmp/\(name)"), name: name)
        a.pixelWidth = w
        a.pixelHeight = h
        return MediaItem(attachment: a, index: index, context: nil, label: "Photo, \(name)")
    }

    private func bubble(_ text: String, _ media: [MediaItem], mine: Bool = true) -> BubbleLayout? {
        var b = BubbleRow(mine: mine, text: text, markdown: false, partIndex: 0, joinsAbove: false, joinsBelow: false,
                          tail: true, time: Date(timeIntervalSince1970: 1_793_389_000), pending: false, streaming: false)
        b.media = media
        let row = ChatRow(id: "m1|b0", messageId: "m1", scope: "acct|default|s1",
                          fingerprint: ChatRowBuilder.bubbleFingerprint(text, mine: mine, speaker: nil),
                          kind: .bubble(b), gapAbove: 6, variant: 0)
        guard case .bubble(let box) = AttachmentBubbleLayout.bubble(b, row: row, width: 402, style: style, keep: false).content
        else { return nil }
        return box
    }

    /// The rows a grid came out as: how many tiles share each top edge.
    private func rows(_ frames: [CGRect]) -> [Int] {
        var out: [Int] = []
        var y: CGFloat = -1
        for f in frames {
            if f.minY == y { out[out.count - 1] += 1 } else { out.append(1); y = f.minY }
        }
        return out
    }

    @Test func twoColumnsOfSquareTiles() {
        let gap = MediaLayout.gridGap
        let two = MediaLayout.grid(count: 2, maxWidth: 370)
        #expect(two.frames == [CGRect(x: 0, y: 0, width: 181, height: 181), CGRect(x: 189, y: 0, width: 181, height: 181)])
        #expect(two.size == CGSize(width: 370, height: 181))
        // Three: the first across the top at the same height, two under it.
        let three = MediaLayout.grid(count: 3, maxWidth: 370)
        #expect(three.frames[0] == CGRect(x: 0, y: 0, width: 370, height: 181))
        #expect(rows(three.frames) == [1, 2] && three.size.height == 181 * 2 + gap)
        let four = MediaLayout.grid(count: 4, maxWidth: 370)
        #expect(rows(four.frames) == [2, 2] && four.size == CGSize(width: 370, height: 181 * 2 + gap))
        // More than four still lay out four tiles; never wider than 520 pt (an iPad's or the Mac's column).
        #expect(MediaLayout.grid(count: 14, maxWidth: 370).frames == four.frames)
        #expect(MediaLayout.grid(count: 2, maxWidth: 728).size.width == MediaLayout.gridMaxWidth)
        #expect(MediaLayout.grid(count: 1, maxWidth: 370).frames.isEmpty, "one photo is not a grid")
        for n in 2...9 {
            for width in [284.0, 296.0, 338.0, 370.0, 728.0] as [CGFloat] {
                let laid = MediaLayout.grid(count: n, maxWidth: width)
                #expect(laid.frames.count == min(n, 4))
                #expect(laid.frames.map(\.maxX).max() == laid.size.width && laid.frames.map(\.maxY).max() == laid.size.height)
                for (i, a) in laid.frames.enumerated() {
                    for b in laid.frames[(i + 1)...] { #expect(!a.insetBy(dx: -gap + 0.5, dy: -gap + 0.5).intersects(b), "\(a) \(b)") }
                }
            }
        }
    }

    @Test func pastFourTheLastTileStandsForTheRest() throws {
        let box = try #require(bubble("", (0..<14).map { photo("p\($0).png", 1179, 2556, index: $0) }))
        let group = try #require(box.mediaGroups.first)
        #expect(group.tiles.count == 4 && group.more.count == 10)
        #expect(group.tiles.map(\.item.index) == Array(0..<4) && group.more.map(\.index) == Array(4..<14))
        // Four or fewer: every photo has its tile.
        let four = try #require(bubble("", (0..<4).map { photo("p\($0).png", 1179, 2556, index: $0) }))
        #expect(four.mediaGroups.first?.tiles.count == 4 && four.mediaGroups.first?.more.isEmpty == true)
    }

    @Test func aTallPhotoShowsFromItsTopInACard() {
        let tile = CGRect(x: 0, y: 0, width: 181, height: 181)
        // A phone screenshot: the card's width, its own height, from the top.
        #expect(MediaTileView.imageFrame(card: true, image: CGSize(width: 1179, height: 2556), in: tile)
            == CGRect(x: 0, y: 0, width: 181, height: 393))
        // A wide one, a square one, a tile that is not a card, a picture not loaded yet: the tile itself (filled, centred).
        #expect(MediaTileView.imageFrame(card: true, image: CGSize(width: 2560, height: 1600), in: tile) == tile)
        #expect(MediaTileView.imageFrame(card: true, image: CGSize(width: 1200, height: 1200), in: tile) == tile)
        #expect(MediaTileView.imageFrame(card: false, image: CGSize(width: 1179, height: 2556), in: tile) == tile)
        #expect(MediaTileView.imageFrame(card: true, image: nil, in: tile) == tile)
    }

    @Test func photosAloneAreTheBubbleWithTheTimeInTheCorner() throws {
        let box = try #require(bubble("", (0..<3).map { photo("p\($0).png", 1600, 1200, index: $0) }))
        #expect(box.mediaOnly)
        let group = try #require(box.mediaGroups.first)
        #expect(box.mediaGroups.count == 1 && group.tiles.count == 3)
        #expect(group.frame == CGRect(origin: .zero, size: box.frame.size).insetBy(dx: 0, dy: 4), "the grid is the bubble, with a little air")
        #expect(group.tileRadius == AttachmentBubbleLayout.gridRadius(inFill: false), "each tile its own rounded card")
        let capsule = try #require(box.timeCapsule)
        let last = try #require(group.tiles.last?.frame)
        #expect(last.offsetBy(dx: group.frame.minX, dy: group.frame.minY).contains(capsule), "the time sits on the last tile: \(capsule) \(last)")
    }

    @Test func aCaptionComesUnderTheGridInsideTheFill() throws {
        let box = try #require(bubble("Which of these three works best for the header?",
                                      (0..<3).map { photo("p\($0).png", 1600, 1200, index: $0) }))
        #expect(!box.mediaOnly)
        let group = try #require(box.mediaGroups.first)
        #expect(group.frame.minX == 6 && group.frame.minY == 6 && group.frame.maxX == box.frame.width - 6, "in from the fill's edges")
        #expect((group.tileRadius ?? 99) < ChatMetrics.bubbleRadius, "a smaller corner inside the bubble's")
        #expect(box.blocks.allSatisfy { $0.frame.minY >= group.frame.maxY }, "the caption comes under the photos")
    }

    @Test func onePhotoKeepsItsOwnRules() throws {
        let box = try #require(bubble("", [photo("p.png", 1600, 1200)]))
        let group = try #require(box.mediaGroups.first)
        #expect(group.tiles.count == 1 && group.more.isEmpty && group.tileRadius == nil)
        #expect(box.frame.size == CGSize(width: 260, height: 195))
    }

    @Test func aRepliesPicturesAreAGrid() {
        let refs = ["a", "b", "c"].compactMap { MarkdownMedia.ref(destination: "#media:%2Ftmp%2F\($0).png", title: "Image: \($0).png", image: false) }
        let block = AttachmentBubbleLayout.mediaBlock(refs, context: nil, maxText: 338, mine: false, style: style)
        #expect(block.media.groups.count == 1)
        let group = block.media.groups[0]
        #expect(group.tiles.count == 3 && group.more.isEmpty)
        #expect(block.size == group.frame.size && block.size.width == 338, "across the reply's words")
        #expect(group.tileRadius == MediaLayout.replyRadius)
        // A grid never waits for pixels: learnt sizes leave it where it is.
        let tall = MediaPixelSize(width: 1179, height: 2556)
        let learnt = AttachmentBubbleLayout.mediaBlock(refs, context: nil, maxText: 338, mine: false, style: style,
                                                       sizes: ["/tmp/a.png": tall, "/tmp/b.png": tall, "/tmp/c.png": tall])
        #expect(learnt.media.groups[0].tiles.map(\.frame) == group.tiles.map(\.frame))
        #expect(learnt.media.groups.first?.tiles.first?.item.attachment.pixelHeight == 2556)
        // One picture in a reply stays one photo (≤ 280 wide), and takes its learnt shape.
        let one = AttachmentBubbleLayout.mediaBlock(Array(refs.prefix(1)), context: nil, maxText: 338, mine: false, style: style)
        #expect(one.size == CGSize(width: 260, height: 195) && one.media.groups[0].tileRadius == nil)
        let oneTall = AttachmentBubbleLayout.mediaBlock(Array(refs.prefix(1)), context: nil, maxText: 338, mine: false, style: style,
                                                        sizes: ["/tmp/a.png": tall])
        #expect(oneTall.size == CGSize(width: 150, height: 320))
        #expect(ChatRowBuilder.bubbleFingerprint("MEDIA:/tmp/a.png", mine: false, speaker: nil)
            != ChatRowBuilder.bubbleFingerprint("MEDIA:/tmp/a.png", mine: false, speaker: nil, sizes: ["/tmp/a.png": tall]))
    }

    @Test func aReplyOfPicturesAloneIsAGridAcrossTheColumn() {
        let text = "MEDIA:/tmp/wide.png\nMEDIA:/tmp/square.png"
        var b = BubbleRow(mine: false, text: text, markdown: true, partIndex: 0, joinsAbove: false, joinsBelow: false,
                          tail: true, time: Date(timeIntervalSince1970: 1_793_389_000), pending: false, streaming: false)
        let row = ChatRow(id: "m2|b0", messageId: "m2", scope: "acct|default|s1",
                          fingerprint: ChatRowBuilder.bubbleFingerprint(text, mine: false, speaker: nil, sizes: b.mediaSizes),
                          kind: .bubble(b), gapAbove: 6, variant: 0)
        b.mediaSizes = [:]
        let rendered = MarkdownRenderer.render(text, style: style)
        guard case .bubble(let box)? = AttachmentBubbleLayout.photoOnlyReply(rendered, b, row: row, width: 402, style: style)?.content,
              let group = box.mediaGroups.first else { Issue.record("no photo-only reply"); return }
        #expect(box.frame.width == 370, "the reply column's width")
        #expect(rows(group.tiles.map(\.frame)) == [2])
    }

    @Test func picturesNextToEachOtherMakeOneGrid() {
        let style = ChatStyleCache.shared.style(for: .large)
        let media = { (markdown: String) in
            MarkdownRenderer.render(markdown, style: style).blocks.compactMap { if case .media(let r) = $0 { r } else { nil } }
        }
        #expect(media("Here are the screenshots:\n\n/tmp/a.png\n\n/tmp/b.png\n\n/tmp/c.png").map(\.count) == [3])
        #expect(media("- /tmp/a.png\n- /tmp/b.png\n- /tmp/c.png\n\nAll three use demo data.").map(\.count) == [3])
        #expect(media("MEDIA:/tmp/a.png\nMEDIA:/tmp/b.png").map(\.count) == [2])
        // Words between them keep them apart.
        #expect(media("/tmp/a.png\n\nThen the second:\n\n/tmp/b.png").map(\.count) == [1, 1])
    }

    @Test func theViewFindsATileForEveryShownPhotoAndNoneForTheRest() throws {
        let items = (0..<9).map { photo("v\($0).png", 1179, 2556, index: $0) }
        let box = try #require(bubble("", items))
        let view = BubbleMediaView(frame: .zero)
        view.configure(box, messageId: "m1", style: style)
        let shown = view.accessibleViews.compactMap { $0 as? MediaTileView }
        #expect(shown.count == 4)
        #expect(shown.map(\.accessibilityIdentifier) == (0..<4).map { "chat.media.m1.\($0)" })
        #expect(shown.prefix(3).allSatisfy { $0.accessibilityHint == "Opens the photo" })
        #expect(shown.last?.accessibilityHint == "Opens this photo and 5 more")
        #expect(shown.allSatisfy { $0.layer.cornerRadius == AttachmentBubbleLayout.gridRadius(inFill: false) })
        // Off screen no tile is a zoom's landing place; past the "+5" there is none at all (and no crash asking).
        #expect(view.tile(at: 7) == nil && view.tile(at: 40) == nil)
        // Reused for a message with two photos: the last tile no longer stands for more.
        let two = try #require(bubble("", Array(items.prefix(2))))
        view.configure(two, messageId: "m2", style: style)
        let again = view.accessibleViews.compactMap { $0 as? MediaTileView }
        #expect(again.count == 2 && again.allSatisfy { $0.accessibilityHint == "Opens the photo" })
        // And for one photo: a plain tile again, no card.
        let one = try #require(bubble("", Array(items.prefix(1))))
        view.configure(one, messageId: "m3", style: style)
        #expect(view.accessibleViews.compactMap { $0 as? MediaTileView }.first?.layer.cornerRadius == 0)
    }
}
