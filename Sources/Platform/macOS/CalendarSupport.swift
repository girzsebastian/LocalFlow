import SwiftUI
import EventKit
import UserNotifications

struct LocalMeeting: Identifiable { let id: String; let title: String; let start: Date; let url: URL? }
@MainActor final class CalendarSupport: ObservableObject {
    @Published var meetings: [LocalMeeting] = []
    @Published var message = "Connect the calendars already available on your Mac."
    @Published var connected = false
    let events = EKEventStore()
    var timer: Timer?
    var lead = 15
    var scheduled: Set<String> = []
    func connect() async {
        do {
            guard try await events.requestFullAccessToEvents() else { message = "Calendar permission was not granted."; return }
            connected = true
            let notifications = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            message = notifications ? "Mac calendars connected" : "Calendars connected; notifications are disabled in macOS."
            start()
        } catch { message = error.localizedDescription }
    }
    func start() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        connected = true; refresh(); timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }
    func disconnect() {
        timer?.invalidate(); timer = nil; meetings = []; connected = false
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: Array(scheduled)); scheduled = []
        message = "Calendar reminders are off."
    }
    func configure(lead: Int) {
        self.lead = lead
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: Array(scheduled)); scheduled = []
        if connected { refresh() }
    }
    func refresh() {
        let now = Date(), end = Calendar.current.date(byAdding: .day, value: 2, to: Date())!
        let predicate = events.predicateForEvents(withStart: now, end: end, calendars: nil)
        meetings = events.events(matching: predicate).filter { !$0.isAllDay && $0.startDate >= now }.sorted { $0.startDate < $1.startDate }.prefix(15).map { LocalMeeting(id: ($0.eventIdentifier ?? UUID().uuidString) + "-\($0.startDate.timeIntervalSince1970)", title: $0.title ?? "Meeting", start: $0.startDate, url: $0.url) }
        guard lead > 0 else { return }
        for meeting in meetings {
            let key = "softspoke-meeting-\(meeting.id)"
            guard !scheduled.contains(key) else { continue }; scheduled.insert(key)
            let content = UNMutableNotificationContent()
            content.categoryIdentifier = "meeting"
            content.title = meeting.title; content.body = "Meeting starting soon. Press Option M to start a note."; content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, meeting.start.timeIntervalSinceNow - Double(lead)), repeats: false)
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: trigger))
        }
    }
    deinit { timer?.invalidate() }
}

struct CalendarSettingsView: View {
    @EnvironmentObject var s: Store
    @ObservedObject var calendar: CalendarSupport
    var body: some View {
        GroupBox("Calendar reminders") {
            VStack(alignment: .leading, spacing: 14) {
                Text(calendar.message).foregroundStyle(.secondary)
                HStack {
                    Button(calendar.connected ? "Refresh calendar" : "Connect Mac calendars") {
                        Task { if calendar.connected { calendar.refresh() } else { await calendar.connect(); s.preferences.calendarEnabled = calendar.connected; s.save() } }
                    }
                    if calendar.connected { Button("Disconnect") { calendar.disconnect(); s.preferences.calendarEnabled = false; s.save() } }
                }
                Picker("Remind before meetings", selection: Binding(get: { s.preferences.meetingReminderSeconds ?? 15 }, set: { s.preferences.meetingReminderSeconds = $0; s.save(); calendar.configure(lead: $0) })) {
                    Text("Off").tag(0); Text("15 seconds").tag(15); Text("1 minute").tag(60); Text("5 minutes").tag(300)
                }
                Toggle("Show next meeting in the menu bar", isOn: Binding(get: { s.preferences.showNextMeeting ?? false }, set: { s.preferences.showNextMeeting = $0; s.save() }))
                Text("Reads upcoming events from your Mac’s calendar accounts. Softspoke does not join calls or modify events automatically.").font(.caption).foregroundStyle(.secondary)
            }.padding(12)
        }
    }
}
struct UpcomingMeetingsView: View {
    @ObservedObject var calendar: CalendarSupport
    @EnvironmentObject var s: Store
    var body: some View {
        if calendar.connected {
            VStack(alignment: .leading, spacing: 9) {
                Text("UPCOMING MEETINGS").font(.caption.bold()).foregroundStyle(.secondary)
                if calendar.meetings.isEmpty { Text("No upcoming meetings in the next two days.").foregroundStyle(.secondary) }
                ForEach(calendar.meetings.prefix(3)) { meeting in
                    HStack { Text(meeting.title).lineLimit(1); Spacer(); Text(meeting.start.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary); Button("Start note") { s.toggle(kind: "Notetaker") }.disabled(s.busy || s.recording) }
                }
            }.padding(.horizontal, 20).padding(.bottom, 12)
        }
    }
}
struct FlowMenuLabel: View {
    @ObservedObject var store: Store
    @ObservedObject var calendar: CalendarSupport
    var body: some View {
        HStack {
            Image(systemName: store.recording ? "record.circle.fill" : "waveform")
            if store.preferences.showNextMeeting == true, let meeting = calendar.meetings.first {
                TimelineView(.periodic(from: .now, by: 30)) { context in Text("\(meeting.title.prefix(22)) · \(max(0, Int(meeting.start.timeIntervalSince(context.date) / 60)))m") }
            }
        }
    }
}
