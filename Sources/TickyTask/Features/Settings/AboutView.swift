import SwiftUI
import AppKit

/// Settings › About: app identity, links, license, and quick help tips.
struct AboutView: View {
    private let repoURL = URL(string: "https://github.com/nikhilkomakula/ticky-task")!
    private let issuesURL = URL(string: "https://github.com/nikhilkomakula/ticky-task/issues")!

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)

                VStack(spacing: 4) {
                    Text("TickyTask").font(.title.weight(.bold))
                    Text("Version \(Bundle.main.appVersion) (\(Bundle.main.appBuild))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Text("A privacy-first, local-only weekly & monthly planner for macOS. Your data lives only on your Mac — no account, server, or telemetry.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 380)

                HStack(spacing: 16) {
                    Link(destination: repoURL) { Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right") }
                    Link(destination: issuesURL) { Label("Report an Issue", systemImage: "ladybug") }
                }
                .font(.callout)

                Text("Licensed under GPL-3.0 · a native macOS fork of WeekToDo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider().padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Help & tips").font(.headline)
                    tip("magnifyingglass", "Press ⌘F to search every task and jump straight to one.")
                    tip("externaldrive", "Back up or restore everything in Settings › Data (optionally encrypted).")
                    tip("keyboard", "Set global shortcuts in Settings › Shortcuts to open the app or capture a task from any app.")
                    tip("checklist", "The menu-bar icon shows a mini calendar and the selected day's tasks.")
                    tip("calendar", "Switch between Week and Month with the toolbar picker; ‹ Today › re-centers.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(24)
        }
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).font(.callout).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Color.accentColor)
        }
    }
}
