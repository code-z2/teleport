import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct TeleportWidgets: WidgetBundle {
    var body: some Widget {
        ClipLiveActivity()
        TeleportClipboardControl()
    }
}

/// The Control Center button: Edit Controls ▸ Add a Control ▸ Teleport.
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

/// Started remotely by push-to-start. Shows no plaintext (content-state is ciphertext);
/// Copy (and Save, for images) run intents in the app process, which decrypt first.
struct ClipLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ClipActivityAttributes.self) { context in
            HStack {
                Label(title(context.attributes.kind), systemImage: icon(context.attributes.kind))
                    .font(.headline)
                Spacer()
                ClipButtons(env: context.state.env, kind: context.attributes.kind)
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.6))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: icon(context.attributes.kind)).font(.title2)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(title(context.attributes.kind)).font(.headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ClipButtons(env: context.state.env, kind: context.attributes.kind).frame(maxWidth: .infinity)
                }
            } compactLeading: {
                Image(systemName: icon(context.attributes.kind))
            } compactTrailing: {
                Button(intent: CopyClipIntent(env: context.state.env)) { Text("Copy") }
                    .buttonStyle(.plain).foregroundStyle(.tint)
            } minimal: {
                Image(systemName: "arrow.right.doc.on.clipboard")
            }
        }
    }

    private func title(_ kind: String) -> String { kind == "blob" ? "New image or file" : "New clip" }
    private func icon(_ kind: String) -> String { kind == "blob" ? "photo" : "arrow.right.doc.on.clipboard" }
}

/// Copy, plus Save for images (blobs). Both run in the app's process.
private struct ClipButtons: View {
    let env: String
    let kind: String
    var body: some View {
        HStack(spacing: 8) {
            Button(intent: CopyClipIntent(env: env)) {
                Label("Copy", systemImage: "doc.on.doc").frame(minWidth: 72)
            }
            .buttonStyle(.borderedProminent)
            if kind == "blob" {
                Button(intent: SaveClipIntent(env: env)) {
                    Label("Save", systemImage: "square.and.arrow.down").frame(minWidth: 72)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
