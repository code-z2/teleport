import TeleportCore
import UIKit

/// Share sheet → encrypt → relay. Plain UIKit, no heavy frameworks (extension memory limit).
/// Also opened when the paired device is picked from the share sheet's suggestions row.
final class ShareViewController: UIViewController {
    private let label = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground.withAlphaComponent(0.95)
        label.text = "Teleporting…"
        label.font = .preferredFont(forTextStyle: .headline)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await run() }
    }

    private func run() async {
        do {
            guard let clip = try await ClipExtractor.clip(from: extensionContext?.inputItems ?? []) else {
                return finish("Nothing to send")
            }
            let teleport = try Teleport()
            try await teleport.send(clip)
            if let peer = teleport.store.peer { ShareSuggestion.donate(for: peer) }
            finish("Sent ✓")
        } catch {
            finish(ClipExtractor.message(for: error))
        }
    }

    private func finish(_ message: String) {
        label.text = message
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
