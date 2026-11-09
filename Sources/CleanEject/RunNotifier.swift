import Foundation
import UserNotifications

/// Posts a run's result as a user notification when the window is closed. Authorization is requested
/// on first use (the system prompt appears once); a denial silently skips the post.
enum RunNotifier {
    static func post(title: String, body: String?) {
        // The bare binary from `swift build` has no bundle, and UNUserNotificationCenter needs one.
        guard Bundle.main.bundleIdentifier != nil else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            if let body { content.body = body }
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
