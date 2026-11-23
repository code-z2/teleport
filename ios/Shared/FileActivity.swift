import ActivityKit
import Foundation

/// Updates a photo's or file's Live Activity from the app: progress while it downloads,
/// then ready (Copy / Save), then the outcome of a button, then it goes away.
enum FileActivity {
    @MainActor private static var lastUpdate = Date.distantPast

    @MainActor
    static func progress(_ env: String, _ value: Double, name: String?) {
        guard #available(iOS 17.2, *), Date().timeIntervalSince(lastUpdate) > 0.5 || value >= 1 else { return }
        lastUpdate = Date()
        update(env, ClipActivityAttributes.ContentState(env: env, progress: value, note: nil, name: name, ready: false))
    }

    @MainActor
    static func ready(_ env: String, name: String?) {
        update(env, ClipActivityAttributes.ContentState(env: env, progress: nil, note: nil, name: name, ready: true))
    }

    /// A short outcome ("Copied", "Saved to Photos"…); the activity stays a few seconds, then goes.
    @MainActor
    static func finish(_ env: String, note: String, after seconds: TimeInterval = 6) {
        guard #available(iOS 17.2, *) else { return }
        let state = ClipActivityAttributes.ContentState(env: env, progress: nil, note: note, name: nil, ready: nil)
        Task {
            for activity in Activity<ClipActivityAttributes>.activities where activity.content.state.env == env {
                var s = state
                s.name = activity.content.state.name
                await activity.end(ActivityContent(state: s, staleDate: nil), dismissalPolicy: .after(.now + seconds))
            }
        }
    }

    @MainActor
    static func dismiss(_ env: String) {
        guard #available(iOS 17.2, *) else { return }
        Task {
            for activity in Activity<ClipActivityAttributes>.activities where activity.content.state.env == env {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    @MainActor
    private static func update(_ env: String, _ state: ClipActivityAttributes.ContentState) {
        guard #available(iOS 17.2, *) else { return }
        Task {
            for activity in Activity<ClipActivityAttributes>.activities where activity.content.state.env == env {
                await activity.update(ActivityContent(state: state, staleDate: nil))
            }
        }
    }
}
