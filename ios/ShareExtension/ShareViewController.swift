import Intents
import TeleportCore
import UIKit

/// Share sheet → encrypt → relay. Plain UIKit, no heavy frameworks (extension memory limit).
/// Picking a device in the share sheet's suggestions row opens this with that device as
/// the intent's recipient; otherwise it sends to the only paired device, or asks which.
final class ShareViewController: UIViewController {
    private let stack = UIStackView()
    private let label = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground.withAlphaComponent(0.95)
        label.text = "Teleporting…"
        label.font = .preferredFont(forTextStyle: .headline)
        label.textAlignment = .center
        label.numberOfLines = 0
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(label)
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.8),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await start() }
    }

    private func start() async {
        do {
            let teleport = try Teleport()
            if let id = (extensionContext?.intent as? INSendMessageIntent)?.recipients?.first?.customIdentifier,
               let peer = teleport.store.peers[id] {
                return await send(to: peer, with: teleport)
            }
            let peers = teleport.store.sortedPeers
            switch peers.count {
            case 0: finish(ClipExtractor.message(for: TeleportError.notPaired))
            case 1: await send(to: peers[0], with: teleport)
            default: showPicker(peers, teleport: teleport)
            }
        } catch {
            finish(ClipExtractor.message(for: error))
        }
    }

    private func showPicker(_ peers: [Peer], teleport: Teleport) {
        label.text = "Teleport to…"
        for peer in peers {
            var config = UIButton.Configuration.filled()
            config.title = peer.name
            config.image = UIImage(systemName: Self.symbol(peer.platform))
            config.imagePadding = 8
            stack.addArrangedSubview(UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                self.stack.arrangedSubviews.dropFirst().forEach { $0.removeFromSuperview() }
                Task { await self.send(to: peer, with: teleport) }
            }))
        }
        var cancel = UIButton.Configuration.plain()
        cancel.title = "Cancel"
        stack.addArrangedSubview(UIButton(configuration: cancel, primaryAction: UIAction { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }))
    }

    private func send(to peer: Peer, with teleport: Teleport) async {
        label.text = "Teleporting to \(peer.name)…"
        do {
            guard let clip = try await ClipExtractor.clip(from: extensionContext?.inputItems ?? []) else {
                return finish("Nothing to send")
            }
            try await teleport.send(clip, to: peer)
            ShareSuggestion.donate(for: peer)
            finish("Sent to \(peer.name) ✓")
        } catch RelayError.offline {
            finish("\(peer.name) is offline")
        } catch {
            finish(ClipExtractor.message(for: error))
        }
    }

    private func finish(_ message: String) {
        label.text = message
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private static func symbol(_ platform: Platform) -> String {
        switch platform {
        case .ios: "iphone"
        case .android: "candybarphone"
        case .mac: "laptopcomputer"
        }
    }
}
