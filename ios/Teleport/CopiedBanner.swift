import SwiftUI

/// "Copied from peso's pixel ✓" with a preview, shown for a moment when a notification's
/// clip is copied (tapping a text notification opens Teleport; without this it looked blank).
struct CopiedBanner: ViewModifier {
    @State private var shown: (from: String, preview: String)?
    @State private var hide: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let shown {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Copied from \(shown.from)").font(.subheadline.weight(.semibold))
                            Text(shown.preview).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .padding(.horizontal)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.35), value: shown?.preview)
            .onReceive(NotificationCenter.default.publisher(for: .teleportCopied)) { note in
                guard let raw = note.object as? String, let bar = raw.firstIndex(of: "|") else { return }
                shown = (String(raw[..<bar]), String(raw[raw.index(after: bar)...]))
                hide?.cancel()
                hide = Task {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    if !Task.isCancelled { shown = nil }
                }
            }
    }
}
