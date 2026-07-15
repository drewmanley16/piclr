import UIKit
import UserNotifications

/// Owns the APNs registration lifecycle. The app delegate feeds device tokens
/// here; `AppStore` observes `onToken` to persist them to Supabase.
@MainActor
final class PushService: NSObject, ObservableObject {
    static let shared = PushService()

    /// Called whenever a fresh APNs device token arrives.
    var onToken: ((String) -> Void)?
    /// The most recent token, if registration has succeeded this launch.
    private(set) var latestToken: String?

    /// Prompts for notification permission (once) and registers with APNs if
    /// granted. Returns whether the app is authorized to show notifications.
    @discardableResult
    func requestAuthorizationAndRegister() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        if granted {
            UIApplication.shared.registerForRemoteNotifications()
        }
        return granted
    }

    /// Re-registers silently if the user has already granted permission, so the
    /// token stays fresh across launches without re-prompting.
    func registerIfAuthorized() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .authorized {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Turns a raw APNs token into the hex string APNs providers expect.
    func handle(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        latestToken = token
        onToken?(token)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in PushService.shared.handle(deviceToken: deviceToken) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[Push] APNs registration failed: \(error.localizedDescription)")
    }

    // Show banners even when the app is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }
}
