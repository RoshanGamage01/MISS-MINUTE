import Foundation
import UserNotifications
import MinutesCore

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private weak var appModel: AppModel?
    /// UserNotifications requires a real `.app` bundle; raw `swift run` binaries crash otherwise.
    private let isAvailable: Bool

    init(appModel: AppModel) {
        self.appModel = appModel
        self.isAvailable = Self.runningInsideAppBundle
        super.init()
        guard isAvailable else {
            print("Minutes: notifications disabled (run via Minutes.app, not a bare binary).")
            return
        }
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            if let error {
                print("Notification auth error: \(error.localizedDescription)")
            }
        }
    }

    func deliver(reminder: Reminder) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "Miss Minute"
        content.body = reminder.text
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: reminder.id.uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    private static var runningInsideAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }
}
