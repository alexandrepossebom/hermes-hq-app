// [utf8-pages] A page file that declares no charset is read as UTF-8 when its bytes are UTF-8 (WebKit reads a local file
// as Latin-1: "·" showed as "Â·" in tiles and opened pages). A declared charset, a BOM or plain ASCII is left to WebKit.

import Foundation
import Testing
@testable import HermesHQNative

@Suite struct PageEncodingTests {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    @Test func undeclaredUTF8IsReadAsUTF8() {
        #expect(PageEncoding.needsUTF8(data("<html><body>Revenue · $12K — up</body></html>")))
    }

    @Test func declaredOrPlainIsLeftAlone() {
        #expect(!PageEncoding.needsUTF8(data("<html><head><meta charset=\"utf-8\"></head><body>a · b</body></html>")))
        #expect(!PageEncoding.needsUTF8(data("<meta http-equiv=\"Content-Type\" content=\"text/html; CHARSET=windows-1252\">·")))
        #expect(!PageEncoding.needsUTF8(Data([0xEF, 0xBB, 0xBF]) + data("<p>a · b</p>")))
        #expect(!PageEncoding.needsUTF8(data("<p>plain ascii</p>")))
        #expect(!PageEncoding.needsUTF8(Data("<p>caf".utf8) + Data([0xE9]) + Data("</p>".utf8)))   // Latin-1 bytes, not UTF-8
    }

    @Test func onlyHTMLFilesAreRead() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "page-encoding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let page = folder.appending(path: "tile.html"), text = folder.appending(path: "notes.txt")
        try data("<p>a · b</p>").write(to: page)
        try data("a · b").write(to: text)
        #expect(PageEncoding.utf8Undeclared(page) != nil)
        #expect(PageEncoding.utf8Undeclared(text) == nil)
    }
}
