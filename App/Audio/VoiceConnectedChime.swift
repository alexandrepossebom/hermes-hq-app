import AVFAudio
import Foundation

/// Plays through the call's existing audio route. Unlike a reply-completion cue, this must
/// never switch the audio session to ambient or take the microphone away from the call.
nonisolated enum VoiceConnectedChime {
    // Confined to AudioWork.queue; retain the player until both notes finish.
    nonisolated(unsafe) private static var player: AVAudioPlayer?

    static func play() {
        AudioWork.later {
            guard let url = Bundle.main.url(forResource: "voice-connected", withExtension: "wav") else { return }
            if player == nil { player = try? AVAudioPlayer(contentsOf: url) }
            player?.currentTime = 0
            player?.play()
        }
    }
}
