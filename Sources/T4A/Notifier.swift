//  Notifier.swift — OSC 9 and OSC 777 become real macOS notifications, and
//  clicking one lands on the pane that sent it (ISC-65).
//
//  The pane identifier travels in the notification's userInfo, so the click
//  does not have to guess which terminal it came from — the fact was known at
//  the moment the notification was posted and is carried, not re-derived.

import AppKit
import UserNotifications

@MainActor
final class Notifier: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Called with the session id encoded in the notification the user clicked.
    var onActivate: ((UUID) -> Void)?
    var isEnabled = true

    /// The pane the user is looking at right now, or nil when no T4A window
    /// is key. Asked at presentation time rather than stored, because the
    /// answer changes between posting a notification and showing it.
    var activePaneProvider: (() -> UUID?)?

    /// Every presentation decision, with the reason. A banner that was
    /// correctly suppressed and a banner that never arrived look identical
    /// from outside, and ISC-108 is a claim about which of the two happened.
    private(set) var presentationLog: [[String: String]] = []

    private var authorized = false
    private var authorizationAsked = false

    private override init() { super.init() }

    /// UNUserNotificationCenter asserts a bundle identity the moment it is
    /// touched, so a bare `swift run` build would die inside the framework
    /// rather than fall back. The terminal has nothing to do with
    /// notifications, so it keeps working and this stays asleep.
    private(set) var isAvailable = false

    func start() {
        guard Bundle.main.bundleIdentifier != nil else {
            NSLog("T4A: not running from a bundle; notifications are off")
            return
        }
        isAvailable = true
        UNUserNotificationCenter.current().delegate = self
        requestAuthorization()
    }

    private func requestAuthorization() {
        guard !authorizationAsked else { return }
        authorizationAsked = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, error in
                Task { @MainActor in
                    self.authorized = granted
                    if let error {
                        NSLog("T4A: notification authorization failed: \(error.localizedDescription)")
                    }
                }
            }
    }

    func post(title: String, body: String, sessionID: UUID) {
        guard isEnabled, isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "T4A" : title
        content.body = body
        content.sound = .default
        content.userInfo = ["session": sessionID.uuidString]
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("T4A: notification not delivered: \(error.localizedDescription)")
            }
        }
    }

    /// What macOS is actually holding in Notification Center. Asking the
    /// system beats trusting our own log: the log says we asked, this says it
    /// arrived.
    /// What macOS thinks T4A is allowed to do. A notification can be
    /// delivered and still show no banner, and the two look identical from
    /// inside the app: this is where the difference is readable.
    func settingsSummary() async -> [String: String] {
        guard isAvailable else { return ["available": "false"] }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        func name(_ value: UNNotificationSetting) -> String {
            switch value {
            case .enabled: return "enabled"
            case .disabled: return "disabled"
            case .notSupported: return "notSupported"
            @unknown default: return "unknown"
            }
        }
        return [
            "available": "true",
            "authorization": String(describing: settings.authorizationStatus),
            "alert": name(settings.alertSetting),
            "notificationCenter": name(settings.notificationCenterSetting),
            "sound": name(settings.soundSetting),
            "alertStyle": String(describing: settings.alertStyle),
        ]
    }

    func delivered() async -> [[String: String]] {
        guard isAvailable else { return [] }
        let notifications = await UNUserNotificationCenter.current().deliveredNotifications()
        return notifications.map { item in
            let content = item.request.content
            return [
                "title": content.title,
                "body": content.body,
                "session": (content.userInfo["session"] as? String) ?? "",
            ]
        }
    }

    /// The same call the delegate makes when a person clicks a banner.
    func simulateActivation(sessionID: UUID) { onActivate?(sessionID) }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler handler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        // A notification about a tab you are not looking at is the point, so
        // it shows even while T4A is frontmost — but a banner about the pane
        // already under your eyes tells you something you have just watched
        // happen, and covers the terminal to do it (ISC-108).
        let raw = (notification.request.content.userInfo["session"] as? String) ?? ""
        let decision = presentation(for: raw)
        presentationLog.append([
            "session": raw,
            // The body identifies WHICH notification this decision was about.
            // Keyed by session alone, two messages from one pane collapse and
            // the check reads the wrong decision.
            "body": notification.request.content.body,
            "presented": decision.presented ? "true" : "false",
            "reason": decision.reason,
        ])
        handler(decision.presented ? [.banner, .sound] : [])
    }

    /// Whether a notification for this session becomes a banner, and why.
    ///
    /// Kept apart from the delegate call so both poles can be asked of it
    /// directly: the pane in front and app active, and the same pane while
    /// the app is behind something else.
    func presentation(for sessionID: String) -> (presented: Bool, reason: String) {
        guard NSApp.isActive else { return (true, "app not frontmost") }
        guard let active = activePaneProvider?()?.uuidString else {
            return (true, "no pane in focus")
        }
        guard active == sessionID else { return (true, "another pane") }
        return (false, "pane already in focus")
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler handler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let raw = info["session"] as? String, let id = UUID(uuidString: raw) {
            onActivate?(id)
        }
        NSApp.activate(ignoringOtherApps: true)
        handler()
    }
}
