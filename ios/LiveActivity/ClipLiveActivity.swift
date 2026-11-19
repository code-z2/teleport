import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct TeleportWidgets: WidgetBundle {
    var body: some Widget { ClipLiveActivity() }
}

/// Started remotely by push-to-start. Shows no plaintext (content-state is ciphertext);
/// the Copy button runs CopyClipIntent in the app process, which decrypts and copies.
struct ClipLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ClipActivityAttributes.self) { context in
            HStack {
                Label(title(context.attributes.kind), systemImage: icon(context.attributes.kind))
                    .font(.headline)
                Spacer()
                CopyButton(env: context.state.env)
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
                    CopyButton(env: context.state.env).frame(maxWidth: .infinity)
                }
            } compactLeading: {
                Image(systemName: icon(context.attributes.kind))
            } compactTrailing: {
                Button(intent: CopyClipIntent(env: context.state.env)) { Text("Copy") }
                    .buttonStyle(.plain).foregroundStyle(.tint)
            } minimal: {
                Image(systemName: "arrow.down.doc")
            }
        }
    }

    private func title(_ kind: String) -> String { kind == "blob" ? "New image or file" : "New clip" }
    private func icon(_ kind: String) -> String { kind == "blob" ? "photo" : "doc.on.clipboard" }
}

private struct CopyButton: View {
    let env: String
    var body: some View {
        Button(intent: CopyClipIntent(env: env)) {
            Label("Copy", systemImage: "doc.on.doc").frame(minWidth: 80)
        }
        .buttonStyle(.borderedProminent)
    }
}
