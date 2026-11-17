// [Mac glass 2026-11-17] DEBUG: `-HQDebugHostile YES` puts the content the owner lives with under every frosted, blurred
// and Liquid Glass surface, so a tour shows what his own chats do to them (owner 2026-11-17: "the bottom backdrop filter
// thing picks up ALL of the color from a text bubble"): the stand-in chats' own messages become long (eight to twelve
// lines), so a bubble is wide and tall enough to pass under a bar, a pill or a pop-over whole. Pair it with the message
// colour he uses, `-HQDebugMessageColour '#000000'` in a light look and `'#FFFFFF'` in a dark one (ThemeDebugHooks),
// and for pictures `-HQDemoPhotos generated`. Display only: nothing is sent, the stand-in gateway is untouched.
#if DEBUG
import Foundation

enum HostileContent {
    static let on = UserDefaults.standard.bool(forKey: "HQDebugHostile")

    private static let long = """
    Here is everything I need you to look at before the end of the week, all of it in one place so nothing slips: the \
    quarterly numbers for the north and south teams, the two contracts waiting on a signature, the travel for the \
    conference in March, the replacement laptop for the new starter, and the follow-up with the landlord about the \
    heating. Put them in the order you think matters most, tell me which ones you can handle yourself without asking \
    me, and for the rest give me one line each on what you need from me and by when. If two of them clash on the same \
    afternoon, say so and suggest which one should move. Keep it short enough that I can read it on my phone between \
    meetings, but do not leave anything out.
    """

    /// The chat's messages with every own message long. Messages with no words (photos alone) stay as they are.
    static func lengthen(_ messages: [ChatMessage]) -> [ChatMessage] {
        guard on else { return messages }
        return messages.map { message in
            guard message.role == .user else { return message }
            var message = message
            var replaced = false
            message.parts = message.parts.map { part in
                if case .text = part, !replaced { replaced = true; return .text(long) }
                return part
            }
            return message
        }
    }
}
#endif
