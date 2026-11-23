import ActivityKit
import AppIntents
import SwiftUI
import TeleportCore
import WidgetKit

@main
struct TeleportWidgets: WidgetBundle {
    var body: some Widget {
        // Started by push (push-to-start), which needs iOS 17.2; iOS 16 gets the notification only.
        if #available(iOS 17.2, *) { ClipLiveActivity() }
        if #available(iOS 18, *) { TeleportClipboardControl() }  // Control Center controls are iOS 18+
    }
}

/// The Control Center button: Edit Controls ▸ Add a Control ▸ Teleport.
@available(iOS 18, *)
struct TeleportClipboardControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.teleport.clipboard") {
            ControlWidgetButton(action: TeleportClipboardIntent()) {
                Label("Teleport", systemImage: "arrow.right.doc.on.clipboard")
            }
        }
        .displayName("Teleport Clipboard")
        .description("Send what you copied to one of your devices.")
    }
}

/// A photo or file on its way (the relay starts these; text arrives as a notification).
/// The notification extension starts the download; the app updates this with progress,
/// then Ready. Icon buttons: Copy, Save, Cancel.
@available(iOS 17.2, *)
struct ClipLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ClipActivityAttributes.self) { context in
            InboxActivityView(kind: context.attributes.kind, from: SenderName.of(context.attributes.from), state: context.state)
                .padding()
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let title = InboxTitle.of(kind: context.attributes.kind, state: context.state)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.attributes.kind == "image" ? "photo" : "doc").font(.title2)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline).lineLimit(1)
                        Text("from \(SenderName.of(context.attributes.from))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    InboxActivityControls(state: context.state)
                }
            } compactLeading: {
                Image(systemName: context.attributes.kind == "image" ? "photo" : "doc")
            } compactTrailing: {
                if let p = context.state.progress, context.state.ready != true {
                    ProgressView(value: p).progressViewStyle(.circular).frame(width: 18)
                } else if context.state.ready == true || context.state.note != nil {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    ProgressView().frame(width: 18)
                }
            } minimal: {
                Image(systemName: context.attributes.kind == "image" ? "photo" : "doc")
            }
        }
    }
}

/// "IMG_2041.jpg" once the app has named it; until then "Photo" / "File".
enum InboxTitle {
    static func of(kind: String, state: ClipActivityAttributes.ContentState) -> String {
        if let name = state.name { return name }
        if let name = Inbox(appGroup: TeleportConfig.fromBundle().appGroup).item(env: state.env)?.name { return name }
        return kind == "image" ? "Photo" : "File"
    }
}

@available(iOS 17.2, *)
private struct InboxActivityView: View {
    let kind: String
    let from: String
    let state: ClipActivityAttributes.ContentState
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: kind == "image" ? "photo" : "doc").font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(InboxTitle.of(kind: kind, state: state)).font(.headline).lineLimit(1)
                    Text("from \(from)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            InboxActivityControls(state: state)
        }
    }
}

/// The status line (progress, Ready or an outcome) and the Copy / Save / Cancel icons.
@available(iOS 17.2, *)
private struct InboxActivityControls: View {
    let state: ClipActivityAttributes.ContentState
    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let note = state.note {
                    Label(note, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else if state.ready == true {
                    Text("Ready").foregroundStyle(.secondary)
                } else if let p = state.progress {
                    VStack(alignment: .leading, spacing: 2) {
                        ProgressView(value: p)
                        Text("\(Int(p * 100))%").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                } else {
                    HStack(spacing: 6) { ProgressView(); Text("Downloading…").foregroundStyle(.secondary) }
                }
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)

            if state.note == nil {
                Button(intent: CopyInboxIntent(env: state.env)) { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.bordered).buttonBorderShape(.circle).accessibilityLabel("Copy")
                Button(intent: SaveInboxIntent(env: state.env)) { Image(systemName: "square.and.arrow.down") }
                    .buttonStyle(.bordered).buttonBorderShape(.circle).accessibilityLabel("Save")
                Button(intent: CancelInboxIntent(env: state.env)) { Image(systemName: "xmark") }
                    .buttonStyle(.bordered).buttonBorderShape(.circle).accessibilityLabel(state.ready == true ? "Dismiss" : "Cancel")
            }
        }
    }
}

/// The paired device's name for a fingerprint, from the store the app shares with this widget.
enum SenderName {
    static func of(_ fingerprint: String?) -> String {
        guard let fingerprint else { return "a paired device" }
        let store = SharedStore(appGroup: TeleportConfig.fromBundle().appGroup)
        return store.peers[fingerprint]?.name ?? "a paired device"
    }
}
