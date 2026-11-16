// What a live voice session is seeded with from a real chat (`LiveChatSession.spokenSeed`, docs/spec/3x-gpt-live.md §3.1).

import Foundation
import Testing
@testable import HermesHQNative

@MainActor
@Suite(.serialized)
struct VoiceSeedTests {
    private func rows(_ count: Int, from first: Int, word: String) -> [JSONValue] {
        (0..<count).map { (i: Int) -> JSONValue in
            let role: JSONValue = i % 2 == 0 ? "user" : "assistant"
            let row: [String: JSONValue] = ["role": role, "content": .string("\(word) \(i)"), "row_id": .number(Double(first + i)),
                                            "timestamp": .number(Double(1_791_600_000 + first + i))]
            return .object(row)
        }
    }

    /// Talk from a bot's menu starts as the chat opens: the seed waits for the open, then reads further back than the
    /// page on screen.
    @Test func theSeedWaitsForTheChatAndReadsFurtherBack() async throws {
        let h = try ChatHarness()
        h.setPage("24", rows: rows(4, from: 9_016, word: "late"), hasMore: true)
        h.setPage("120", rows: rows(20, from: 9_000, word: "turn"), hasMore: true)
        let s = h.make()
        s.start()
        #expect(s.spokenHistory.isEmpty)                         // nothing has loaded yet
        let seed = await s.spokenSeed()
        #expect(s.openSettled)
        #expect(seed.count == 20)
        #expect(seed.first?.text == "turn 0" && seed.last?.text == "turn 19")
        #expect(seed.last?.assistant == true)
        #expect(s.messages.count <= 4)                           // the transcript is not touched
        #expect(h.client.restLog.contains { $0.query.contains { $0.name == "limit" && $0.value == "120" } })
    }

    /// The read further back failing leaves what is loaded.
    @Test func aFailedReadFurtherBackKeepsWhatIsLoaded() async throws {
        let h = try ChatHarness()
        h.setPage("24", rows: rows(4, from: 9_016, word: "late"), hasMore: true)
        let s = h.make()
        #expect(await h.open())
        let seed = await s.spokenSeed()
        #expect(seed.map(\.text) == ["late 0", "late 1", "late 2", "late 3"])
    }

    /// A chat that is whole on screen is not read again.
    @Test func aWholeChatIsNotReadAgain() async throws {
        let h = try ChatHarness()
        h.setPage("24", rows: rows(4, from: 9_016, word: "late"))
        let s = h.make()
        #expect(await h.open())
        let reads = h.client.restLog.count
        let seed = await s.spokenSeed()
        #expect(seed.count == 4)
        #expect(h.client.restLog.count == reads)
    }
}
