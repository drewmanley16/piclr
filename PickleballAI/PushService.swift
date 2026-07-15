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

    /// Called when the user taps a push. If a tap arrives before a handler is
    /// set (e.g. cold launch from the lock screen, before sign-in wires this
    /// up), it's buffered and delivered as soon as `onTap` is assigned.
    var onTap: (([AnyHashable: Any]) -> Void)? {
        didSet {
            if let pending = pendingTap, let handler = onTap {
                pendingTap = nil
                handler(pending)
            }
        }
    }
    private var pendingTap: [AnyHashable: Any]?

    func handleTap(_ userInfo: [AnyHashable: Any]) {
        if let handler = onTap {
            handler(userInfo)
        } else {
            pendingTap = userInfo
        }
    }

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

    // User tapped a push (lock screen, banner, or Notification Center).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        await MainActor.run { PushService.shared.handleTap(userInfo) }
    }
}
