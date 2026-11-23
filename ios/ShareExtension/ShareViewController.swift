import Intents
import SwiftUI
import TeleportCore
import UIKit

/// Hosts the shared "Teleport to…" picker. Used by both iOS extensions:
/// - the Share extension (app row, and the paired devices in the suggestions row), and
/// - the "Teleport…" action in the actions list.
/// A device picked in the suggestions row arrives as the intent's recipient and is sent to directly.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        let context = extensionContext
        // Only Share extensions may read `intent`; in the "Teleport…" action it throws (crash).
        let recipient = Self.isShareExtension
            ? (context?.intent as? INSendMessageIntent)?.recipients?.first?.customIdentifier
            : nil
        // The "Teleport to Mac / Android / iPhone" actions set this in their Info.plist.
        let only = (Bundle.main.object(forInfoDictionaryKey: "TeleportTargetPlatform") as? String).flatMap(Platform.init)
        // iOS 17+ gets the @Observable model, iOS 16 the legacy one (Legacy/).
        let picker = SendPickerFactory.make(
            preselected: recipient,
            only: only,
            loadClip: { [weak self] in try await ClipExtractor.outgoing(from: self?.extensionContext?.inputItems ?? []) },
            onSent: { ShareSuggestion.donate(for: $0) },
            finish: { context?.completeRequest(returningItems: nil) })

        let host = UIHostingController(rootView: picker)
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        host.didMove(toParent: self)
    }

    private static var isShareExtension: Bool {
        let ext = Bundle.main.object(forInfoDictionaryKey: "NSExtension") as? [String: Any]
        return ext?["NSExtensionPointIdentifier"] as? String == "com.apple.share-services"
    }
}
