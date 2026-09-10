import SwiftUI
import AppKit
import UserNotifications

@MainActor final class MeetingNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var permission = "Notifications have not been checked."
    weak var store: Store?
    private var timer: Timer?
    private var lastPrompt: [String: Date] = [:]
    private var recommendationSent = false
    func start(store: Store) {
        self.store = store
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Task { if store.preferences.meetingPrompts != false || store.preferences.recommendationNotifications != false { await request() } }
        center.setNotificationCategories([UNNotificationCategory(identifier: "meeting", actions: [UNNotificationAction(identifier: "start-note", title: "Start note", options: [])], intentIdentifiers: [])])
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in Task { @MainActor in self?.check() } }
    }
    func request() async {
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            permission = allowed ? "Notifications enabled" : "Notifications disabled in macOS Settings"
        } catch { permission = error.localizedDescription }
    }
    func check() {
        guard let store, !store.recording, !store.busy else { return }
        if store.preferences.meetingPrompts != false, AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &focused) == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
                let window = unsafeBitCast(focused, to: AXUIElement.self)
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success, let title = value as? String {
                    let bundle = app.bundleIdentifier ?? ""
                    if MeetingWindowMatcher.matches(bundle: bundle, title: title), Date().timeIntervalSince(lastPrompt[bundle] ?? .distantPast) > 1800 {
                        lastPrompt[bundle] = Date()
                        send(id: "softspoke-call-\(bundle)", title: "Taking notes for this meeting?", body: "A meeting window is open in \(app.localizedName ?? "your app"). With participants’ consent, start Notetaker or press Option M.", category: "meeting")
                    }
                }
            }
        }
        if store.preferences.recommendationNotifications != false, !recommendationSent, store.entries.filter({ $0.kind == "Dictation" }).count >= 3 {
            recommendationSent = true
            let defaults = UserDefaults.standard
            let previous = defaults.object(forKey: "lastRecommendationDate") as? Date ?? .distantPast
            if Date().timeIntervalSince(previous) > 7 * 86400 {
                defaults.set(Date(), forKey: "lastRecommendationDate")
                send(id: "softspoke-recommendation", title: "Make recurring phrases quicker", body: "Add names to Dictionary and reusable phrases to Snippets. You can also choose English, Romanian or Multilingual from the widget.")
            }
        }
    }
    func send(id: String, title: String, body: String, category: String = "") {
        let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.categoryIdentifier = category
        if store?.preferences.sounds == true { content.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .list] }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run {
            guard let store = self.store else { return }
            if response.actionIdentifier == "start-note", !store.recording, !store.busy { store.toggle(kind: "Notetaker") }
            else if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                let meeting = response.notification.request.content.categoryIdentifier == "meeting"
                store.notifyWidget(meeting ? "Meeting reminder. Press Option M or use the widget to start Notetaker." : response.notification.request.content.body)
                NSApp.hide(nil)
            }
        }
    }
    deinit { timer?.invalidate() }
}
struct NotificationSettingsView: View {
    @EnvironmentObject var s: Store
    var body: some View { NotificationOptions(notifications: s.notifications).environmentObject(s) }
}
struct NotificationOptions: View {
    @EnvironmentObject var s: Store
    @ObservedObject var notifications: MeetingNotifications
    func option(_ key: WritableKeyPath<Preferences, Bool?>) -> Binding<Bool> {
        Binding(get: { s.preferences[keyPath: key] ?? true }, set: { value in s.preferences[keyPath: key] = value; s.save(); if value { Task { await notifications.request() } } })
    }
    var body: some View {
        GroupBox("Meeting prompts & recommendations") {
            VStack(alignment: .leading, spacing: 18) {
                Toggle("Suggest Notetaker for Zoom and Google Meet", isOn: option(\.meetingPrompts))
                Text("Checks the focused window title locally every 8 seconds. Requires Accessibility. A meeting window can include a pre-join screen; this is a suggestion, not confirmation of an active call. At most one prompt per app every 30 minutes.").font(.caption).foregroundStyle(.secondary)
                Toggle("Occasional tips and recommendations", isOn: option(\.recommendationNotifications))
                Text("A dictionary and snippets tip after your first three dictations, at most once a week. Scheduled meeting reminders are configured under Notetaker.").font(.caption).foregroundStyle(.secondary)
                Text(notifications.permission).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Enable notifications") { Task { await notifications.request() } }
                    Button("macOS notification settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!) }
                }
            }.padding(14)
        }
    }
}
