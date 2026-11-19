// Puts the paired device in the share sheet's top suggestions row (the row where
// Messages contacts appear), by donating "send message" interactions to it.
// The Share extension declares INSendMessageIntent in IntentsSupported, so picking
// the suggestion opens it. iOS ranks suggestions by use, so every send donates again.

import Intents
import TeleportCore
import UIKit

enum ShareSuggestion {
    static func donate(for peer: Peer) {
        let person = INPerson(
            personHandle: INPersonHandle(value: peer.fingerprint, type: .unknown),
            nameComponents: nil,
            displayName: peer.name,
            image: avatar(for: peer),
            contactIdentifier: nil,
            customIdentifier: peer.fingerprint)
        let intent = INSendMessageIntent(
            recipients: [person],
            outgoingMessageType: .outgoingMessageText,
            content: nil,
            speakableGroupName: INSpeakableString(spokenPhrase: peer.name),
            conversationIdentifier: "teleport-\(peer.fingerprint)",
            serviceName: nil,
            sender: nil,
            attachments: nil)
        intent.setImage(avatar(for: peer), forParameterNamed: \.speakableGroupName)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .outgoing
        interaction.groupIdentifier = "teleport-\(peer.fingerprint)"
        interaction.donate(completion: nil)
    }

    /// Indigo circle with a phone glyph, matching the app icon.
    private static func avatar(for peer: Peer) -> INImage? {
        let size = CGSize(width: 180, height: 180)
        let symbol = peer.platform == .ios ? "iphone" : "candybarphone"
        let png = UIGraphicsImageRenderer(size: size).pngData { _ in
            UIColor(red: 0.31, green: 0.27, blue: 0.90, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
            let config = UIImage.SymbolConfiguration(pointSize: 84, weight: .semibold)
            if let glyph = UIImage(systemName: symbol, withConfiguration: config)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) {
                glyph.draw(at: CGPoint(x: (size.width - glyph.size.width) / 2, y: (size.height - glyph.size.height) / 2))
            }
        }
        return INImage(imageData: png)
    }
}
