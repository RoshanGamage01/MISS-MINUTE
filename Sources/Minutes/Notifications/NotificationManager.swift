import Foundation
import UserNotifications
import MinutesCore

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private weak var appModel: AppModel?

    init(appModel: AppModel) {
        self.appModel = appModel
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            if let error {
                print("Notification auth error: \(error.localizedDescription)")
            }
        }
    }

    func deliver(reminder: Reminder) {
        let content = UNMutableNotificationContent()
        content.title = "Minutes"
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
}
