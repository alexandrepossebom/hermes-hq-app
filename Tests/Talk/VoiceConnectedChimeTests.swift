import AVFAudio
import Foundation
import Testing

struct VoiceConnectedChimeTests {
    @Test func bundledChimeHasTwoShortNotesAndASilentGap() throws {
        let url = try #require(Bundle.main.url(forResource: "voice-connected", withExtension: "wav"))
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?[0])
        #expect(Double(buffer.frameLength) / format.sampleRate < 0.4)
        var lastSound = -Int(format.sampleRate)
        var notes = 0
        for i in 0..<Int(buffer.frameLength) where abs(channel[i]) > 0.01 {
            // A gap of 20 ms separates notes, not the zero crossings within a note.
            if i - lastSound > Int(format.sampleRate * 0.020) { notes += 1 }
            lastSound = i
        }
        #expect(notes == 2)
    }
}
