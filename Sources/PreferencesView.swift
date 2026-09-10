import SwiftUI
import AppKit

struct PreferencesView: View {
    @EnvironmentObject var s: Store
    @State private var section = "General"
    @State private var shortcut = false
    @State private var hoveredSection: String?

    let sections = [
        ("General", "slider.horizontal.3"),
        ("System", "desktopcomputer"),
        ("Notetaker", "record.circle"),
        ("Notifications", "bell"),
        ("Claude", "sparkles"),
        ("Data & Privacy", "lock.shield")
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("SETTINGS")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 16)

                ForEach(sections, id: \.0) { item in
                    Button {
                        section = item.0
                    } label: {
                        Label(item.0, systemImage: item.1)
                            .frame(
                                maxWidth: .infinity,
                                alignment: .leading
                            )
                            .padding(11)
                            .background(
                                section == item.0
                                    ? Color.primary.opacity(0.09)
                                    : hoveredSection == item.0
                                    ? Color.primary.opacity(0.05)
                                    : .clear,
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                            .contentShape(Rectangle())
                            .onHover {
                                hoveredSection = $0 ? item.0 : nil
                            }
                    }
                    .buttonStyle(.plain)
                    .focusable()
                    .accessibilityLabel(item.0)
                    .accessibilityHint("Opens \(item.0) settings")
                }

                Spacer()
            }
            .padding(18)
            .frame(width: 165)
            .background(
                Color(nsColor: .controlBackgroundColor)
                    .opacity(0.5)
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(section)
                        .font(
                            .system(
                                size: 30,
                                weight: .regular,
                                design: .serif
                            )
                        )
                        .padding(.bottom, 8)

                    content
                }
                .frame(
                    maxWidth: 760,
                    alignment: .leading
                )
                .padding(28)
            }
        }
        .toggleStyle(.switch)
        .sheet(isPresented: $shortcut) {
            ShortcutSheet(store: s)
        }
    }

    @ViewBuilder
    var content: some View {
        switch section {
        case "General":
            GroupBox("Shortcuts") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Hold \(s.shortcutName) and speak.")
                        Spacer()

                        Button("Change") {
                            shortcut = true
                        }
                    }

                    Text(
                        "Release to paste. Double-tap for hands-free recording; press again to finish."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Toggle(
                        "Paste into the active text field",
                        isOn: $s.preferences.autoPaste
                    )
                    .onChange(of: s.preferences.autoPaste) {
                        s.save()
                    }

                    Toggle(
                        "Suggest Dictionary corrections after I edit pasted text",
                        isOn: Binding(
                            get: {
                                s.preferences.suggestCorrections ?? true
                            },
                            set: {
                                s.preferences.suggestCorrections = $0
                                s.save()
                            }
                        )
                    )

                    Button(
                        s.accessibilityGranted
                            ? "Accessibility enabled · open settings"
                            : "Enable Accessibility for shortcuts and paste"
                    ) {
                        s.openAccessibilitySettings()
                    }
                }
                .padding(14)
            }

            LocalSettingsView(section: "General")

            GroupBox("Dictation languages") {
                VStack(alignment: .leading, spacing: 14) {
                    Picker(
                        "Spoken language",
                        selection: $s.preferences.locale
                    ) {
                        Text("English").tag("en-US")
                        Text("Română").tag("ro-RO")
                        Text("Multilingual · English + Romanian").tag("auto")
                    }
                    .onChange(of: s.preferences.locale) {
                        s.save()
                    }

                    Text(
                        "Multilingual preserves both languages. A short pause between language changes helps recognition. Transcription runs on your Mac."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    LabeledContent(
                        "App language",
                        value: "English"
                    )
                }
                .padding(14)
            }

        case "System":
            LocalSettingsView(section: "System")

        case "Notetaker":
            LocalSettingsView(section: "Notetaker")

            GroupBox("Meeting audio") {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(
                        "Include computer audio",
                        isOn: $s.preferences.captureSystem
                    )
                    .onChange(of: s.preferences.captureSystem) {
                        s.save()
                    }

                    Text(
                        "Records your microphone and meeting audio. Use headphones to avoid echo. macOS requires Screen & System Audio Recording permission; no video is saved."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Text(
                        "Ask participants before recording. The transcript becomes available after recording stops."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(14)
            }

            CalendarSettingsView(calendar: s.calendar)

        case "Notifications":
            NotificationSettingsView()

        case "Claude":
            GroupBox("Your Claude subscription") {
                VStack(alignment: .leading, spacing: 16) {
                    Text(s.claudeStatus)

                    HStack {
                        Button("Sign in") {
                            s.login()
                        }

                        Button("Check connection") {
                            s.checkClaude()
                        }
                    }

                    Toggle(
                        "Clean up dictation with Claude before pasting",
                        isOn: Binding(
                            get: {
                                s.preferences.cleanDictation ?? false
                            },
                            set: {
                                s.preferences.cleanDictation = $0
                                s.save()
                            }
                        )
                    )

                    Text(
                        "Removes fillers and applies spoken self-corrections such as “by Tuesday, oh no, sorry, by Thursday” so the pasted text is the message you meant. Adds a few seconds before paste. If Claude is slow, signed out, or returns something unusable, the raw dictation is pasted instead. The literal transcript is kept in the library."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Toggle(
                        "Automatically create meeting insights",
                        isOn: $s.preferences.autoInsights
                    )
                    .onChange(of: s.preferences.autoInsights) {
                        s.save()
                    }

                    Text(
                        "Uses Claude Code with your subscription. Transcript text is sent to Claude for cleanup, insights, style and transforms. Account usage limits and extra-usage settings apply."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(14)
            }

        default:
            GroupBox("Stored on this Mac") {
                VStack(alignment: .leading, spacing: 16) {
                    Text(
                        "Recordings, transcripts, notes, dictionary, snippets and preferences stay in your local library."
                    )

                    Button("Show local files") {
                        NSWorkspace.shared.open(s.root)
                    }

                    Text(
                        "Claude actions send selected transcript text to Anthropic. Meeting detection checks window titles locally; titles are not saved or sent to Claude."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Text(
                        "Team sharing, connector management, live transcription and automatic call-end recording control are not available in this preview."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(14)
            }
        }
    }
}
